-- Staff scoring + leaderboard.
-- Depends on the baseline schema (submissions, user_votes, staff_role()).
-- Schema only: no data is inserted or changed.

begin;

-- ---------------------------------------------------------------------------
-- 1. Vote flagging
-- ---------------------------------------------------------------------------

alter table public.user_votes
  add column flagged boolean not null default false;

create index idx_user_votes_article_valid
  on public.user_votes using btree (article_id)
  where not flagged;

-- ---------------------------------------------------------------------------
-- 2. Staff scores: one row per judge per article
-- ---------------------------------------------------------------------------

create table public.article_scores (
  article_id text not null references public.submissions (id) on delete cascade,
  judge_id   uuid not null default auth.uid() references auth.users (id),
  theme      smallint not null check (theme     between 0 and 20),
  writing    smallint not null check (writing   between 0 and 20),
  voice      smallint not null check (voice     between 0 and 20),
  structure  smallint not null check (structure between 0 and 20),
  created_at timestamptz not null default now(),
  primary key (article_id, judge_id)
);

alter table public.article_scores enable row level security;

-- Judges only see their own rows (so scores stay independent); admin sees all.
-- Writes go through save_article_score() below, so there are no insert/update policies.
create policy "staff can read own scores" on public.article_scores
  as permissive for select to authenticated
  using (
    staff_role() = 'admin'
    or (staff_role() = any (array['eic', 'editor']) and judge_id = auth.uid())
  );

create policy "staff can delete scores" on public.article_scores
  as permissive for delete to authenticated
  using (
    staff_role() = 'admin'
    or (staff_role() = any (array['eic', 'editor']) and judge_id = auth.uid())
  );

revoke all on public.article_scores from anon, authenticated;
grant select, delete on public.article_scores to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Scoring view in a private schema (not reachable through the API)
-- ---------------------------------------------------------------------------

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create view private.leaderboard_scores as
with judge as (
  select
    article_id,
    count(*)::integer      as judges,
    avg(theme)::numeric     as avg_theme,
    avg(writing)::numeric   as avg_writing,
    avg(voice)::numeric     as avg_voice,
    avg(structure)::numeric as avg_structure
  from public.article_scores
  group by article_id
),
valid as (
  select article_id, count(*)::integer as valid_votes
  from public.user_votes
  where not flagged
  group by article_id
)
select
  s.id           as article_id,
  s.title,
  s.name         as writer_name,
  s.student_code,
  s.grade,
  s.submitted_at,
  coalesce(j.judges, 0)       as judges,
  j.avg_theme,
  j.avg_writing,
  j.avg_voice,
  j.avg_structure,
  j.avg_theme + j.avg_writing + j.avg_voice + j.avg_structure as judge_score,
  coalesce(v.valid_votes, 0)  as valid_votes,
  least(coalesce(v.valid_votes, 0) * 0.4, 12)::numeric as vote_points,
  case
    when j.judges is null then null
    else j.avg_theme + j.avg_writing + j.avg_voice + j.avg_structure
         + least(coalesce(v.valid_votes, 0) * 0.4, 12)
  end as points
from public.submissions s
left join judge j on j.article_id = s.id
left join valid v on v.article_id = s.id
where s.status = 'approved';

revoke all on private.leaderboard_scores from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Public leaderboard: one sort key, one displayed number
-- ---------------------------------------------------------------------------
-- points -> rounded points; likes -> like count; theme/writing/voice/structure -> order only.

create or replace function public.get_leaderboard(
  p_sort  text    default 'points',
  p_limit integer default 50,
  p_month date    default null   -- any date inside the month to show; null = all time
)
returns table (
  rank          integer,
  article_id    text,
  title         text,
  writer_name   text,
  student_code  text,
  grade         text,
  display_value numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'private'
as $$
#variable_conflict use_column
begin
  if p_sort is null
     or p_sort <> all (array['points', 'likes', 'theme', 'writing', 'voice', 'structure']) then
    raise exception 'INVALID_SORT' using errcode = 'P0001';
  end if;

  return query
  with ranked as (
    select
      l.article_id,
      l.title,
      l.writer_name,
      l.student_code,
      l.grade,
      l.points,
      l.valid_votes,
      (row_number() over (
        order by
          (case p_sort
             when 'points'    then l.points
             when 'likes'     then l.valid_votes::numeric
             when 'theme'     then l.avg_theme
             when 'writing'   then l.avg_writing
             when 'voice'     then l.avg_voice
             when 'structure' then l.avg_structure
           end) desc nulls last,
          (case when p_sort = 'points' then l.avg_writing else l.points end) desc nulls last,
          (case when p_sort = 'likes' then l.avg_writing else l.valid_votes::numeric end) desc nulls last,
          l.submitted_at asc,
          l.article_id asc
      ))::integer as rnk
    from private.leaderboard_scores l
    where p_month is null
       or date_trunc('month', l.submitted_at at time zone 'Asia/Dhaka')
        = date_trunc('month', p_month::timestamp)
  )
  select
    r.rnk,
    r.article_id,
    r.title,
    r.writer_name,
    r.student_code,
    r.grade,
    case p_sort
      when 'points' then round(r.points)
      when 'likes'  then r.valid_votes::numeric
    end
  from ranked r
  order by r.rnk
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;

revoke execute on function public.get_leaderboard(text, integer, date) from public;
grant execute on function public.get_leaderboard(text, integer, date) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Staff leaderboard: full breakdown
-- ---------------------------------------------------------------------------

create or replace function public.get_leaderboard_staff()
returns table (
  rank          integer,
  article_id    text,
  title         text,
  writer_name   text,
  grade         text,
  judges        integer,
  avg_theme     numeric,
  avg_writing   numeric,
  avg_voice     numeric,
  avg_structure numeric,
  judge_score   numeric,
  valid_votes   integer,
  vote_points   numeric,
  points        numeric
)
language plpgsql
stable
security definer
set search_path to 'public', 'private'
as $$
#variable_conflict use_column
begin
  if not (staff_role() = any (array['admin', 'eic', 'editor'])) then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;

  return query
  select
    (row_number() over (
      order by l.points desc nulls last,
               l.avg_writing desc nulls last,
               l.valid_votes desc,
               l.submitted_at asc,
               l.article_id asc
    ))::integer,
    l.article_id,
    l.title,
    l.writer_name,
    l.grade,
    l.judges,
    round(l.avg_theme, 2),
    round(l.avg_writing, 2),
    round(l.avg_voice, 2),
    round(l.avg_structure, 2),
    round(l.judge_score, 2),
    l.valid_votes,
    round(l.vote_points, 2),
    round(l.points, 2)
  from private.leaderboard_scores l
  order by 1;
end;
$$;

revoke execute on function public.get_leaderboard_staff() from public, anon;
grant execute on function public.get_leaderboard_staff() to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Saving a score, flagging and burst detection (staff only)
-- ---------------------------------------------------------------------------

-- One judge, one article: inserts the judge's scores or replaces their earlier ones.
create or replace function public.save_article_score(
  p_article_id text,
  p_theme      integer,
  p_writing    integer,
  p_voice      integer,
  p_structure  integer
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null or not (staff_role() = any (array['admin', 'eic', 'editor'])) then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;

  if p_theme     is null or p_theme     not between 0 and 20
  or p_writing   is null or p_writing   not between 0 and 20
  or p_voice     is null or p_voice     not between 0 and 20
  or p_structure is null or p_structure not between 0 and 20 then
    raise exception 'INVALID_SCORE' using errcode = 'P0001';
  end if;

  insert into article_scores (article_id, judge_id, theme, writing, voice, structure)
  values (p_article_id, auth.uid(), p_theme, p_writing, p_voice, p_structure)
  on conflict (article_id, judge_id) do update
    set theme     = excluded.theme,
        writing   = excluded.writing,
        voice     = excluded.voice,
        structure = excluded.structure;
end;
$$;

revoke execute on function public.save_article_score(text, integer, integer, integer, integer) from public, anon;
grant execute on function public.save_article_score(text, integer, integer, integer, integer) to authenticated;

create or replace function public.flag_voter(
  p_user_id uuid,
  p_flagged boolean default true
)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  affected integer;
begin
  if not (staff_role() = any (array['admin', 'eic'])) then
    raise exception 'NOT_AUTHORIZED' using errcode = 'P0001';
  end if;

  update user_votes
  set flagged = p_flagged
  where user_id = p_user_id
    and flagged is distinct from p_flagged;

  get diagnostics affected = row_count;

  -- The site shows votes.count on article pages, so keep it equal to the valid votes.
  update votes v
  set count = (
    select count(*)::integer
    from user_votes uv
    where uv.article_id = v.article_id and not uv.flagged
  )
  where v.article_id in (select uv.article_id from user_votes uv where uv.user_id = p_user_id);

  return affected;
end;
$$;

revoke execute on function public.flag_voter(uuid, boolean) from public, anon;
grant execute on function public.flag_voter(uuid, boolean) to authenticated;

-- Users whose busiest window of unflagged votes reaches p_min_votes.
create or replace function public.list_burst_voters(
  p_window    interval default interval '10 minutes',
  p_min_votes integer  default 5
)
returns table (
  user_id         uuid,
  votes_in_window integer,
  window_start    timestamptz,
  total_votes     integer
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with windows as (
    select
      a.user_id,
      a.voted_at as window_start,
      count(*)::integer as votes_in_window
    from public.user_votes a
    join public.user_votes b
      on  b.user_id  = a.user_id
      and b.voted_at >= a.voted_at
      and b.voted_at <  a.voted_at + p_window
    where not a.flagged
      and not b.flagged
    group by a.user_id, a.article_id, a.voted_at
  ),
  worst as (
    select distinct on (user_id) user_id, window_start, votes_in_window
    from windows
    order by user_id, votes_in_window desc, window_start asc
  )
  select
    w.user_id,
    w.votes_in_window,
    w.window_start,
    (select count(*)::integer
       from public.user_votes t
      where t.user_id = w.user_id and not t.flagged)
  from worst w
  where w.votes_in_window >= p_min_votes
    and public.staff_role() = any (array['admin', 'eic', 'editor'])
  order by w.votes_in_window desc, w.user_id
$$;

revoke execute on function public.list_burst_voters(interval, integer) from public, anon;
grant execute on function public.list_burst_voters(interval, integer) to authenticated;

commit;
