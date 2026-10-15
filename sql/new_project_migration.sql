-- ============================================================
-- CWC "forum" project schema -- login-based rewrite
-- Ported from WorkingCWCDB-DEBUGGING, with the anonymous-voter
-- anti-cheat machinery (voter_log, comment_reaction_log,
-- fingerprint/hardware/session columns) removed and replaced
-- by real Supabase Auth identity.
-- ============================================================

-- ------------------------------------------------------------
-- 0. RESET (safe to re-run on an empty/dev project only)
-- ------------------------------------------------------------
drop table if exists public.comment_reactions cascade;
drop table if exists public.user_votes cascade;
drop table if exists public.comments cascade;
drop table if exists public.recognitions cascade;
drop table if exists public.monthly_snapshots cascade;
drop table if exists public.votes cascade;
drop table if exists public.submissions cascade;
drop table if exists public.writers cascade;
drop table if exists public.site_config cascade;

drop function if exists public.enforce_daily_submission_limit() cascade;
drop function if exists public.cast_vote(text) cascade;
drop function if exists public.staff_role() cascade;
drop function if exists public.is_verified_user() cascade;
drop function if exists public.react_to_comment(text, text) cascade;

-- ------------------------------------------------------------
-- 1. EXTENSIONS
-- ------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

-- ------------------------------------------------------------
-- 2. TABLES
-- ------------------------------------------------------------

create table public.site_config (
  key text primary key,
  value jsonb
);

create table public.writers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  grade text not null,
  student_code text check (student_code ~ '^\d{1,9}$'),
  created_at timestamptz default now(),
  phone text
);

create table public.submissions (
  id text primary key,
  writer_id uuid references public.writers(id),
  user_id uuid references auth.users(id) on delete set null,
  name text not null,
  student_code text check (student_code ~ '^\d{1,9}$'),
  grade text not null,
  category text not null,
  theme text not null,
  title text not null,
  content text not null,
  submitted_at timestamptz default now(),
  status text not null default 'unverified'
    check (status = any (array['unverified','pending','waiting_confirmation','writing_confirmation','approved','rejected'])),
  phone text,
  editor_notes text
);

create table public.votes (
  article_id text primary key,
  count integer not null default 0
);

-- One row per (user, article) -- replaces voter_log entirely. Real
-- identity is the dedup key now, no fingerprint/IP heuristics needed.
create table public.user_votes (
  user_id uuid not null references auth.users(id) on delete cascade,
  article_id text not null,
  voted_at timestamptz not null default now(),
  primary key (user_id, article_id)
);

create table public.monthly_snapshots (
  id text primary key,
  month_label text not null,
  captured_at timestamptz default now(),
  top_writers jsonb not null default '[]'::jsonb,
  top_writings jsonb not null default '[]'::jsonb
);

create table public.recognitions (
  id uuid primary key default gen_random_uuid(),
  student_code text not null,
  name text not null,
  category text not null check (category = any (array['wom','editors_choice'])),
  article_id text,
  awarded_at timestamptz not null default now()
);

create table public.comments (
  id text primary key,
  article_id text not null,
  parent_id text references public.comments(id),
  user_id uuid references auth.users(id) on delete set null,
  author_name text not null,
  -- Set only when a staff member posts (their typed name + this role is
  -- what renders as "Aziz - Editor"). Null for public-account comments.
  staff_role text check (staff_role is null or staff_role = any (array['admin','editor','coordinator','eic'])),
  content text not null,
  status text not null default 'pending'
    check (status = any (array['pending','approved','rejected'])),
  reactions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.comment_reactions (
  user_id uuid not null references auth.users(id) on delete cascade,
  comment_id text not null references public.comments(id) on delete cascade,
  emoji text not null,
  reacted_at timestamptz not null default now(),
  primary key (user_id, comment_id)
);

create index idx_comments_article_id on public.comments(article_id);
create index idx_user_votes_user_id on public.user_votes(user_id);
create index idx_submissions_user_id on public.submissions(user_id);

-- ------------------------------------------------------------
-- 3. FUNCTIONS
-- ------------------------------------------------------------

-- Staff role from the JWT email local-part, but ONLY for @cwc.staff
-- accounts. Without the domain check, anyone who signs up with a real
-- address like admin@theirdomain.com would get the 'admin' role.
create or replace function public.staff_role()
returns text
language sql
stable
set search_path = public
as $function$
  select case
    when lower(coalesce(auth.jwt() ->> 'email', '')) like '%@cwc.staff'
      then lower(split_part(auth.jwt() ->> 'email', '@', 1))
    else ''
  end
$function$;

-- True only once the caller has clicked their email confirmation link.
-- Checked server-side (not just trusted from the client) before any
-- vote/comment/submission write is allowed.
create or replace function public.is_verified_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $function$
  select exists(
    select 1 from auth.users
    where id = auth.uid() and email_confirmed_at is not null
  )
$function$;

-- Atomically records a vote for the CALLER (auth.uid()) -- one per
-- (user, article) enforced by user_votes' primary key. Staff accounts
-- can call this too since they're auth.users rows like everyone else,
-- which is exactly how "admin also counts as a user" is satisfied.
create or replace function public.cast_vote(p_article_id text)
returns integer
language plpgsql
security definer
set search_path = public
as $function$
declare
  new_count integer;
begin
  if auth.uid() is null then
    raise exception 'NOT_LOGGED_IN' using errcode = 'P0001';
  end if;
  if not is_verified_user() then
    raise exception 'NOT_VERIFIED' using errcode = 'P0001';
  end if;

  begin
    insert into user_votes (user_id, article_id) values (auth.uid(), p_article_id);
  exception when unique_violation then
    raise exception 'ALREADY_VOTED' using errcode = 'P0001';
  end;

  insert into votes (article_id, count)
  values (p_article_id, 1)
  on conflict (article_id) do update set count = votes.count + 1
  returning count into new_count;

  return new_count;
end;
$function$;

grant execute on function public.cast_vote(text) to authenticated;

-- Same pattern for comment reactions, one emoji per (user, comment).
create or replace function public.react_to_comment(p_comment_id text, p_emoji text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  new_reactions jsonb;
begin
  if auth.uid() is null then
    raise exception 'NOT_LOGGED_IN' using errcode = 'P0001';
  end if;
  if not is_verified_user() then
    raise exception 'NOT_VERIFIED' using errcode = 'P0001';
  end if;

  begin
    insert into comment_reactions (user_id, comment_id, emoji) values (auth.uid(), p_comment_id, p_emoji);
  exception when unique_violation then
    raise exception 'ALREADY_REACTED' using errcode = 'P0001';
  end;

  update comments
  set reactions = jsonb_set(
    coalesce(reactions, '{}'::jsonb),
    array[p_emoji],
    to_jsonb(coalesce((reactions->>p_emoji)::int, 0) + 1)
  )
  where id = p_comment_id
  returning reactions into new_reactions;

  return new_reactions;
end;
$function$;

grant execute on function public.react_to_comment(text, text) to authenticated;

-- Daily submission limit -- unchanged logic (by student_code / writer_id),
-- since the submission form itself is staying exactly as it is.
create or replace function public.enforce_daily_submission_limit()
returns trigger
language plpgsql
as $function$
declare
  submissions_today_by_code integer := 0;
  submissions_today_by_writer integer := 0;
  daily_limit constant integer := 2;
  tz constant text := 'Asia/Dhaka';
begin
  if new.student_code is not null and btrim(new.student_code) <> '' then
    perform pg_advisory_xact_lock(hashtext('submission_code:' || lower(btrim(new.student_code))));
    select count(*) into submissions_today_by_code
    from submissions
    where lower(btrim(student_code)) = lower(btrim(new.student_code))
      and (submitted_at at time zone tz)::date = (now() at time zone tz)::date;
  end if;

  if new.writer_id is not null then
    perform pg_advisory_xact_lock(hashtext('submission_writer:' || new.writer_id::text));
    select count(*) into submissions_today_by_writer
    from submissions
    where writer_id = new.writer_id
      and (submitted_at at time zone tz)::date = (now() at time zone tz)::date;
  end if;

  if submissions_today_by_code >= daily_limit or submissions_today_by_writer >= daily_limit then
    raise exception 'DAILY_SUBMISSION_LIMIT_REACHED: already submitted % time(s) today by code and % time(s) today by writer (limit %)',
      submissions_today_by_code, submissions_today_by_writer, daily_limit
      using errcode = 'P0001';
  end if;

  return new;
end;
$function$;

create trigger trg_enforce_daily_submission_limit
  before insert on public.submissions
  for each row execute function public.enforce_daily_submission_limit();

-- ------------------------------------------------------------
-- 4. ROW LEVEL SECURITY
-- ------------------------------------------------------------

alter table public.site_config enable row level security;
alter table public.writers enable row level security;
alter table public.submissions enable row level security;
alter table public.votes enable row level security;
alter table public.user_votes enable row level security;
alter table public.monthly_snapshots enable row level security;
alter table public.recognitions enable row level security;
alter table public.comments enable row level security;
alter table public.comment_reactions enable row level security;

-- site_config
create policy "public can read site config" on public.site_config
  for select to anon, authenticated using (true);
create policy "admins can insert site config" on public.site_config
  for insert to authenticated with check (staff_role() = 'admin');
create policy "admins can update site config" on public.site_config
  for update to authenticated using (staff_role() = 'admin') with check (staff_role() = 'admin');

-- writers (unchanged -- still needed to support the submission form as-is)
create policy "public can read writers" on public.writers
  for select to anon, authenticated using (true);
create policy "public can insert writers" on public.writers
  for insert to anon, authenticated with check (true);
create policy "public can update writers" on public.writers
  for update to anon, authenticated using (true) with check (true);
create policy "staff can delete writers" on public.writers
  for delete to authenticated using (staff_role() = any (array['admin','eic']));

-- submissions -- now requires a logged-in, verified user (public or staff)
create policy "public can read approved submissions" on public.submissions
  for select to anon using (status = 'approved');
create policy "authenticated can read all submissions" on public.submissions
  for select to authenticated using (true);
create policy "logged in users can insert unverified submissions" on public.submissions
  for insert to authenticated
  with check (status = 'unverified' and is_verified_user() and user_id = auth.uid());
create policy "role-based submission updates" on public.submissions
  for update to authenticated
  using (
    case staff_role()
      when 'admin' then true
      when 'eic' then status = any (array['unverified','pending','waiting_confirmation','rejected'])
      when 'coordinator' then status = 'unverified'
      when 'editor' then status = 'pending'
      else false
    end
  )
  with check (
    case staff_role()
      when 'admin' then true
      when 'eic' then status = any (array['pending','waiting_confirmation','writing_confirmation','rejected'])
      when 'coordinator' then status = any (array['pending','rejected'])
      when 'editor' then status = any (array['waiting_confirmation','rejected'])
      else false
    end
  );
create policy "staff can delete submissions" on public.submissions
  for delete to authenticated using (staff_role() = any (array['admin','eic']));

-- votes -- reads open; writes only ever happen via cast_vote() (security definer)
create policy "public can read votes" on public.votes
  for select to anon, authenticated using (true);
create policy "staff can delete votes" on public.votes
  for delete to authenticated using (staff_role() = 'admin');

-- user_votes -- each user can see (and only see) their own vote history
create policy "users can read their own votes" on public.user_votes
  for select to authenticated using (user_id = auth.uid());

-- monthly_snapshots
create policy "public read monthly_snapshots" on public.monthly_snapshots
  for select to public using (true);

-- recognitions
create policy "public can read recognitions" on public.recognitions
  for select to anon, authenticated using (true);
create policy "staff can insert recognitions" on public.recognitions
  for insert to authenticated with check (staff_role() = any (array['admin','eic','editor']));
create policy "staff can delete recognitions" on public.recognitions
  for delete to authenticated using (staff_role() = any (array['admin','eic','editor']));

-- comments -- insert requires a logged-in, verified identity; author_name
-- and staff_role are trusted from the row itself (the frontend sets them
-- from the caller's own identity, never from arbitrary input)
create policy "public can read comments" on public.comments
  for select to public using (true);
create policy "logged in users can insert pending comments" on public.comments
  for insert to authenticated
  with check (
    status = 'pending'
    and is_verified_user()
    and user_id = auth.uid()
    and (staff_role is null or staff_role = public.staff_role())
    and reactions = '{}'::jsonb
  );
create policy "role-based comment moderation" on public.comments
  for update to authenticated
  using (staff_role() = any (array['admin','eic','editor']))
  with check (staff_role() = any (array['admin','eic','editor']));

-- comment_reactions -- reads scoped to own reactions; writes via
-- react_to_comment() (security definer) only
create policy "users can read their own reactions" on public.comment_reactions
  for select to authenticated using (user_id = auth.uid());


-- ------------------------------------------------------------
-- 5. STORAGE: notice-images bucket
-- Create the "notice-images" bucket first via Dashboard -> Storage
-- (Public bucket ON), then run this.
-- ------------------------------------------------------------
-- (Public bucket: reads by URL need no policy, so there is deliberately no
-- SELECT policy -- that would also let anyone list every file.)
create policy "staff can upload notice images"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'notice-images' and public.staff_role() = any (array['admin','eic','editor']));
create policy "staff can delete notice images"
  on storage.objects for delete to authenticated
  using (bucket_id = 'notice-images' and public.staff_role() = any (array['admin','eic','editor']));

-- ============================================================
-- AFTER running this:
-- 1. Auth -> Providers -> Email: turn ON "Confirm email".
-- 2. Auth -> URL Configuration: set Site URL + add your domain's
--    /login path to Redirect URLs (needed for the verification link).
-- 3. Create the 4 staff accounts manually (Auth -> Users -> Add user),
--    email = "<username>@cwc.staff" for admin/editor/coordinator/eic,
--    exactly as before.
-- 4. award_history table isn't included here -- send its current
--    schema from the old project and it can be folded in.
-- ============================================================

-- ------------------------------------------------------------
-- writers lockdown (applied after the original policies above).
-- Visitors can only read/insert/update THEIR OWN writer row; only
-- name and grade are updatable. Staff can read all rows.
-- ------------------------------------------------------------
alter table public.writers
  add column if not exists user_id uuid references auth.users(id) on delete set null default auth.uid();

drop policy if exists "public can read writers" on public.writers;
drop policy if exists "public can insert writers" on public.writers;
drop policy if exists "public can update writers" on public.writers;

create policy "users can read their own writer row" on public.writers
  for select to authenticated using (user_id = auth.uid());
create policy "staff can read all writers" on public.writers
  for select to authenticated
  using (staff_role() = any (array['admin','editor','coordinator','eic']));
create policy "users can insert their own writer row" on public.writers
  for insert to authenticated with check (user_id = auth.uid());
create policy "users can update their own writer row" on public.writers
  for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.writers from anon;
revoke truncate, trigger, references on public.writers from authenticated;
revoke update on public.writers from authenticated;
grant update (name, grade) on public.writers to authenticated;

-- ------------------------------------------------------------
-- Private phone number on submissions. Column SELECT is revoked from
-- API roles so approved rows never leak it; staff read it via RPC.
-- The frontend selects explicit columns (never "*") for this reason.
-- ------------------------------------------------------------
alter table public.submissions
  add constraint submissions_phone_format
  check (phone is null or phone ~ '^[0-9]{11}$');

revoke select on public.submissions from anon, authenticated;
grant select (id, writer_id, user_id, name, student_code, grade, category, theme, title, content, submitted_at, status, editor_notes)
  on public.submissions to anon, authenticated;

create or replace function public.get_submission_phones()
returns table (id text, phone text)
language sql
stable
security definer
set search_path = public
as $function$
  select s.id, s.phone
  from public.submissions s
  where s.phone is not null
    and public.staff_role() = any (array['admin','editor','coordinator','eic'])
$function$;

revoke all on function public.get_submission_phones() from public, anon;
grant execute on function public.get_submission_phones() to authenticated;

-- ------------------------------------------------------------
-- Submission tamper-proofing + least privilege
-- ------------------------------------------------------------
create or replace function public.sanitize_submission_insert()
returns trigger
language plpgsql
set search_path = public
as $function$
begin
  new.submitted_at := now();   -- server decides the time (daily limit can't be dodged)
  new.editor_notes := null;    -- submitters cannot pre-fill editor notes
  return new;
end;
$function$;

drop trigger if exists trg_a_sanitize_submission_insert on public.submissions;
create trigger trg_a_sanitize_submission_insert
  before insert on public.submissions
  for each row execute function public.sanitize_submission_insert();

revoke truncate, trigger, references on all tables in schema public from anon, authenticated;
revoke insert, update, delete on all tables in schema public from anon;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
