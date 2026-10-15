-- A "Latest Community Announcements" chat that always sits at the top of Chats.
-- Only the admin can post in it; everyone signed in can read and comment. Safe to run more than once.
insert into public.groups (id, name, about, sort)
values ('announcements', 'Latest Community Announcements', 'News from the admin. Only the admin can post here.', 0)
on conflict (id) do update set name = excluded.name, about = excluded.about, sort = excluded.sort;

drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin()));
