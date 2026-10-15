-- Comment reactions: one reaction per user per comment, enforced server-side.
-- Safe to run directly on your live project — does not touch existing data,
-- and replaces the earlier react_to_comment() with a stricter version.

drop function if exists public.react_to_comment(text, text);

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

-- Replaces the earlier version: now checks session_id/fingerprint against
-- comment_reaction_log first (same "same device, cleared storage" pattern
-- voter_log uses) and rejects a second reaction from the same visitor,
-- instead of letting anyone increment any emoji unlimited times.
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
