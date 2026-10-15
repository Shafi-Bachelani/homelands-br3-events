-- Every approved member can read the Football Accounts chat without signing up to it.
-- Run after add-membership-approval.sql. Safe to run more than once.
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
    or (g = 'football-accounts' and exists (select 1 from profiles where id = auth.uid() and approved))
$$;
update public.groups set about = 'Our football accounts, game by game. Every approved member can read them; only organisers post.'
 where id = 'football-accounts';
