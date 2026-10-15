-- ============================================================
-- CWC Database Migration Script
-- Source project: WorkingCWCDB-DEBUGGING (yxbxunsqipswvrcfgrsm)
-- Generated: 2026-09-15
--
-- Run this against your NEW Supabase project's SQL editor
-- (or via `psql`) AFTER creating the project. It reconstructs
-- schema, RLS policies, functions and the one custom trigger.
-- It does NOT copy data or Auth/Storage/webhook settings —
-- see the notes at the bottom.
-- ============================================================

-- ------------------------------------------------------------
-- 0. RESET (safe to re-run)
-- Drops these 8 tables if a previous run of this script got partway
-- through before failing. CASCADE also drops their policies, indexes,
-- and the trigger on submissions, so everything below recreates cleanly.
-- Safe as long as you have NOT yet loaded real data into the new
-- project — if you have, do NOT run this block, since it deletes rows.
-- ------------------------------------------------------------
drop table if exists public.comment_reaction_log cascade;
drop table if exists public.comments cascade;
drop table if exists public.recognitions cascade;
drop table if exists public.monthly_snapshots cascade;
drop table if exists public.voter_log cascade;
drop table if exists public.votes cascade;
drop table if exists public.submissions cascade;
drop table if exists public.writers cascade;
drop table if exists public.site_config cascade;

drop function if exists public.enforce_daily_submission_limit() cascade;
drop function if exists public.increment_vote(text) cascade;
drop function if exists public.staff_role() cascade;
drop function if exists public.react_to_comment(text, text) cascade;
drop function if exists public.react_to_comment(text, text, text, text) cascade;

-- ------------------------------------------------------------
-- 1. EXTENSIONS
-- All 4 are Supabase defaults already present on new projects,
-- included here only for completeness / explicitness.
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

create table public.voter_log (
  session_id text not null,
  article_id text not null,
  voted_at timestamptz default now(),
  fingerprint text,
  primary key (session_id, article_id)
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
  author_name text not null,
  content text not null,
  status text not null default 'pending'
    check (status = any (array['pending','approved','rejected'])),
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 3. FUNCTIONS
-- ------------------------------------------------------------

-- Derives a "staff role" from the caller's JWT email local-part
-- (e.g. admin@yourdomain.com -> 'admin'). Used by RLS policies below.
create or replace function public.staff_role()
returns text
language sql
stable
as $function$
  select lower(split_part(coalesce((auth.jwt() ->> 'email'), ''), '@', 1))
$function$;

-- Atomically increments (or creates) a vote counter for an article.
create or replace function public.increment_vote(p_article_id text)
returns integer
language plpgsql
as $function$
declare
  new_count integer;
begin
  insert into votes (article_id, count)
  values (p_article_id, 1)
  on conflict (article_id)
  do update set count = votes.count + 1
  returning count into new_count;

  return new_count;
end;
$function$;

-- Enforces a max of 2 submissions/day per student_code AND per writer_id
-- (Asia/Dhaka timezone), using advisory locks to prevent race conditions
-- from concurrent submissions.
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

-- ------------------------------------------------------------
-- 4. TRIGGER
-- ------------------------------------------------------------

create trigger trg_enforce_daily_submission_limit
  before insert on public.submissions
  for each row execute function public.enforce_daily_submission_limit();

-- ------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- ------------------------------------------------------------

alter table public.site_config enable row level security;
alter table public.writers enable row level security;
alter table public.submissions enable row level security;
alter table public.votes enable row level security;
alter table public.voter_log enable row level security;
alter table public.monthly_snapshots enable row level security;
alter table public.recognitions enable row level security;
alter table public.comments enable row level security;

-- site_config
create policy "public can read site config" on public.site_config
  for select to anon, authenticated using (true);
create policy "public read site_config" on public.site_config
  for select to public using (true);
create policy "admins can insert site config" on public.site_config
  for insert to authenticated with check (true);
create policy "admins can update site config" on public.site_config
  for update to authenticated using (true) with check (true);

-- writers
create policy "public can read writers" on public.writers
  for select to anon, authenticated using (true);
create policy "public can insert writers" on public.writers
  for insert to anon, authenticated with check (true);
create policy "public can update writers" on public.writers
  for update to anon, authenticated using (true) with check (true);
create policy "only authenticated can delete writers" on public.writers
  for delete to authenticated using (true);

-- submissions
create policy "public read submissions" on public.submissions
  for select to public using (true);
create policy "public can read approved submissions" on public.submissions
  for select to anon using (status = 'approved');
create policy "reviewers can read all submissions" on public.submissions
  for select to authenticated using (true);
create policy "public can insert unverified submissions" on public.submissions
  for insert to anon, authenticated with check (status = 'unverified');
create policy "role-based submission updates" on public.submissions
  for update to public
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
create policy "reviewers can delete submissions" on public.submissions
  for delete to authenticated using (true);

-- votes
create policy "public can read votes" on public.votes
  for select to anon, authenticated using (true);
create policy "public can insert votes" on public.votes
  for insert to anon, authenticated with check (true);
create policy "only authenticated can delete votes" on public.votes
  for delete to authenticated using (true);

-- voter_log
create policy "public can read voter_log" on public.voter_log
  for select to anon, authenticated using (true);
create policy "public can insert voter_log" on public.voter_log
  for insert to anon, authenticated with check (true);
create policy "only authenticated can delete voter_log" on public.voter_log
  for delete to authenticated using (true);

-- monthly_snapshots
create policy "public read monthly_snapshots" on public.monthly_snapshots
  for select to public using (true);

-- recognitions
-- TIGHTENED from source project: the original had "temp open insert/delete"
-- policies granting anon + authenticated unrestricted insert AND delete
-- (leftover debug access — anyone with the public API key could wipe this
-- table). Locked down to match the access pattern used by `writers`:
-- reads stay public, writes require staff_role(), deletes require staff_role().
create policy "public can read recognitions" on public.recognitions
  for select to anon, authenticated using (true);
create policy "staff can insert recognitions" on public.recognitions
  for insert to authenticated
  with check (staff_role() = any (array['admin','eic','editor']));
create policy "staff can delete recognitions" on public.recognitions
  for delete to authenticated
  using (staff_role() = any (array['admin','eic','editor']));

-- comments
create policy "public can read comments" on public.comments
  for select to public using (true);
create policy "public can insert pending comments" on public.comments
  for insert to public with check (status = 'pending');
create policy "role-based comment moderation" on public.comments
  for update to public
  using (staff_role() = any (array['admin','eic','editor']))
  with check (staff_role() = any (array['admin','eic','editor']));

-- ------------------------------------------------------------
-- 6. STORAGE: notice-images bucket policies
-- Create the "notice-images" bucket first via Dashboard -> Storage
-- (toggle "Public bucket" on), THEN run this.
-- ------------------------------------------------------------

create policy "public can read notice images"
  on storage.objects for select
  to anon, authenticated
  using (bucket_id = 'notice-images');

create policy "staff can upload notice images"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'notice-images'
    and staff_role() = any (array['admin','eic','editor'])
  );

create policy "staff can delete notice images"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'notice-images'
    and staff_role() = any (array['admin','eic','editor'])
  );

-- ------------------------------------------------------------
-- 7. COMMENT REACTIONS
-- One emoji reaction per visitor per comment (enforced via a log table +
-- session_id/fingerprint, same "same device, cleared storage" pattern
-- voter_log uses for votes), aggregated into a per-comment count
-- (e.g. {"❤️": 3, "😂": 1}) via a SECURITY DEFINER function so it works
-- regardless of the comments table's UPDATE policies.
-- ------------------------------------------------------------

alter table public.comments add column if not exists reactions jsonb not null default '{}'::jsonb;

create table if not exists public.comment_reaction_log (
  comment_id text not null references public.comments(id) on delete cascade,
  session_id text not null,
  fingerprint text,
  emoji text not null,
  reacted_at timestamptz not null default now(),
  primary key (comment_id, session_id)
);

alter table public.comment_reaction_log enable row level security;

create policy "public can read comment_reaction_log"
  on public.comment_reaction_log for select
  to anon, authenticated
  using (true);

create policy "public can insert comment_reaction_log"
  on public.comment_reaction_log for insert
  to anon, authenticated
  with check (true);

create or replace function public.react_to_comment(
  p_comment_id text,
  p_emoji text,
  p_session_id text,
  p_fingerprint text
)
returns jsonb
security definer
set search_path = public
language plpgsql
as $function$
declare
  new_reactions jsonb;
  already_reacted boolean;
begin
  select exists(
    select 1 from comment_reaction_log
    where comment_id = p_comment_id
      and (session_id = p_session_id or (fingerprint is not null and fingerprint = p_fingerprint))
  ) into already_reacted;

  if already_reacted then
    raise exception 'ALREADY_REACTED: this visitor has already reacted to this comment'
      using errcode = 'P0001';
  end if;

  insert into comment_reaction_log (comment_id, session_id, fingerprint, emoji)
  values (p_comment_id, p_session_id, p_fingerprint, p_emoji)
  on conflict (comment_id, session_id) do nothing;

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

grant execute on function public.react_to_comment(text, text, text, text) to anon, authenticated;

-- ============================================================
-- NOT included in this script — handle separately:
--
-- 1. DATA: this only creates empty tables. To copy the actual rows,
--    run (against the SOURCE project):
--      supabase db dump --db-url "<source-connection-string>" -f data.sql --data-only
--    then restore into the new project:
--      psql "<new-project-connection-string>" -f data.sql
--
-- 2. Auth settings (providers, email templates, redirect URLs),
--    Storage bucket configs, webhooks, API/rate-limit settings —
--    not visible through this schema. Copy via Dashboard or the
--    Management API script from Supabase's migration guide:
--    https://supabase.com/docs/guides/platform/migrating-and-upgrading-projects
--
-- 3. staff_role() depends on the logged-in user's JWT email
--    local-part matching 'admin' / 'eic' / 'editor' / 'coordinator'.
--    Make sure your staff accounts on the NEW project use matching
--    email addresses, or this access control will silently break.
--
-- 4. recognitions insert/delete policies were tightened vs. the source
--    project (see comment above) — insert/delete now require staff_role()
--    IN ('admin','eic','editor') instead of being open to anon. If your
--    frontend currently inserts recognitions from a public/unauthenticated
--    flow, that flow will break here and needs to go through an
--    authenticated staff session instead.
-- ============================================================
