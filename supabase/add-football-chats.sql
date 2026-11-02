-- =====================================================================
--  Chats: rename the hub, and football chats for footballers only.
--   * "Al-Ansaar Community Hub" is now just "Community Hub".
--   * Friday Football and the new Footballing Events chat can only be seen
--     (and posted in) by members marked Football (and family members, who
--     always play). Organisers and the admin see everything. Everyone else
--     doesn't see these chats at all.
--   * Event Enthusiasts Group stays open to everyone.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

alter table public.groups add column if not exists football_only boolean not null default false;

update public.groups set name = 'Community Hub' where id = 'hub';

update public.groups set football_only = true where id = 'football';

insert into public.groups (id, name, about, sort, football_only)
values ('football-events', 'Footballing Events', 'Tournaments, socials and other events for our footballers.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, football_only = true;

update public.groups set football_only = false, members_only = false, sort = 4 where id = 'enthusiasts';

-- Is this person a footballer? (Football ticked on their membership, or family.)
create or replace function public.is_footballer(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = u and (football or family))
$$;
grant execute on function public.is_footballer(uuid) to authenticated;

-- Can the signed-in person see this chat's posts? Same as before, plus football-only chats.
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when coalesce((select football_only from groups where id = g), false)
      then is_organiser() or is_footballer(auth.uid())
    else not coalesce((select members_only from groups where id = g), false)
      or is_organiser()
      or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
      or (g in ('football-accounts', 'events-accounts', 'family-accounts') and exists (select 1 from profiles where id = auth.uid() and approved))
  end
$$;

-- Phone notifications (if add-phone-notifications.sql has been run): don't tell
-- non-footballers about posts in the football chats.
do $$ begin
  if exists (select 1 from pg_proc where proname = 'user_sees_group' and pronamespace = 'public'::regnamespace) then
    execute $f$
      create or replace function public.user_sees_group(u uuid, g text) returns boolean
      language sql stable security definer set search_path = public as $q$
        select case
          when coalesce((select football_only from groups where id = g), false)
            then exists (select 1 from profiles where id = u and (role in ('organiser', 'admin') or football or family))
          else not coalesce((select members_only from groups where id = g), false)
            or exists (select 1 from profiles where id = u and role in ('organiser', 'admin'))
            or exists (select 1 from group_members where group_id = g and user_id = u)
            or (g in ('football-accounts', 'events-accounts', 'family-accounts') and exists (select 1 from profiles where id = u and approved))
        end
      $q$;
    $f$;
  end if;
end $$;
