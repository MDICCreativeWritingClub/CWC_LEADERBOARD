-- ============================================================
-- Remove public reader login/signup -- keep staff login as-is.
--
-- Voting, commenting, and submitting no longer require a real
-- account. Every visitor now silently gets a Supabase Auth
-- *anonymous* session (auth.signInAnonymously(), called from
-- context/AuthContext.tsx -- no UI, nothing to type). An
-- anonymous session still carries a real auth.uid() and an
-- "authenticated"-role JWT, so every existing RLS policy and
-- RPC (cast_vote, react_to_comment, the submissions/comments
-- insert policies) keeps working completely unchanged -- the
-- one-vote-per-article / one-reaction-per-comment dedup by
-- user_id is exactly as strong as before, just keyed to an
-- anonymous device session instead of an email account.
--
-- The only thing that no longer makes sense is "verified",
-- since that meant "clicked the email confirmation link" and
-- anonymous sessions have no email at all. This redefines
-- is_verified_user() to just mean "has a session" -- true for
-- both anonymous visitors and staff, false only for a caller
-- with no session whatsoever (which shouldn't happen once the
-- frontend change ships, but keeps the function meaningful as
-- a defense-in-depth check either way).
--
-- Safe to run on the live project: this only replaces one
-- function's body, nothing is dropped, no data is touched.
-- ============================================================

create or replace function public.is_verified_user()
returns boolean
language sql
stable
security definer
set search_path = public
as $function$
  select auth.uid() is not null
$function$;

-- ============================================================
-- AFTER running this:
-- 1. Auth -> Providers -> Anonymous Sign-Ins: turn this ON.
--    Without it, auth.signInAnonymously() will fail and every
--    visitor will be treated as logged out (voting/commenting/
--    submitting will silently not work).
-- 2. Auth -> Providers -> Email: "Confirm email" can stay on or
--    off, it no longer affects anything -- no one signs up with
--    an email anymore except the 4 staff accounts, which were
--    never subject to email confirmation in the first place.
-- 3. app_users and its signup trigger have been removed entirely.
-- ============================================================
