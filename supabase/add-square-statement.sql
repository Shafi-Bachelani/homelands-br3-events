-- One Square balance photo (or PDF) on the Funds page, to compare with "All funds together".
-- Only the latest is kept: uploading a new one replaces it.
create table if not exists public.square_statement (
  id int primary key default 1 check (id = 1),
  file text not null,                -- data URL: a photo (image/jpeg etc.) or a PDF
  file_name text,
  uploaded_at timestamptz not null default now(),
  uploaded_by uuid references public.profiles(id) on delete set null
);
alter table public.square_statement enable row level security;
drop policy if exists "members read statement" on public.square_statement;
create policy "members read statement" on public.square_statement for select to authenticated
  using (exists (select 1 from profiles where id = auth.uid() and approved));
drop policy if exists "admin writes statement" on public.square_statement;
create policy "admin writes statement" on public.square_statement for all to authenticated
  using (is_admin()) with check (is_admin() and (file like 'data:application/pdf;base64,%' or file like 'data:image/%') and length(file) < 8000000);
grant select, insert, update, delete on public.square_statement to authenticated;
