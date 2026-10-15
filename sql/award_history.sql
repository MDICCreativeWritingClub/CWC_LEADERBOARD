create table if not exists public.award_history (
  id uuid primary key default gen_random_uuid(),
  award_type text not null check (award_type in ('wom','editors_choice')),
  student_code text,
  writer_name text not null,
  grade text,
  article_id text,
  article_title text,
  votes integer,
  month_label text not null,
  year integer not null,
  created_at timestamptz not null default now()
);

alter table public.award_history enable row level security;

create policy "public can read award_history" on public.award_history
  for select to anon, authenticated using (true);
create policy "staff can insert award_history" on public.award_history
  for insert to authenticated
  with check (staff_role() = any (array['admin','eic','editor']));
create policy "staff can delete award_history" on public.award_history
  for delete to authenticated
  using (staff_role() = any (array['admin','eic','editor']));
