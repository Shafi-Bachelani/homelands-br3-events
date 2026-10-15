-- Membership approval. New members give their postcode when they join, then fill in the
-- Jotform application. Until the admin approves them they can look around but can't book,
-- post, comment, vote, sign up to chats or invite guests. Anyone who hasn't sent the
-- application within 24 hours of joining is removed.
-- Existing members are approved already. Safe to run more than once.

alter table public.profiles add column if not exists approved boolean not null default true;

-- Postcodes are kept apart from profiles so other members can't see them.
create table if not exists public.member_postcodes (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  postcode text not null,
  miles numeric(6,1)
);
alter table public.member_postcodes enable row level security;
drop policy if exists "own or admin postcode" on public.member_postcodes;
create policy "own or admin postcode" on public.member_postcodes for select to authenticated
  using (user_id = auth.uid() or is_admin());

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  first_admin boolean := not exists (select 1 from profiles where role = 'admin');
  pc text := upper(trim(coalesce(new.raw_user_meta_data->>'postcode', '')));
  mi numeric := case when new.raw_user_meta_data->>'miles' ~ '^[0-9]+(\.[0-9]+)?$'
                     then (new.raw_user_meta_data->>'miles')::numeric end;
begin
  insert into profiles (id, name, role, approved)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
          case when first_admin then 'admin' else 'member' end,
          first_admin);
  if pc <> '' then
    insert into member_postcodes (user_id, postcode, miles) values (new.id, pc, round(mi, 1));
  end if;
  return new;
end $$;

-- Jotform applications, recorded by the jotform-webhook Netlify function.
create table if not exists public.applications (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  submitted_at timestamptz not null default now(),
  answers text
);
alter table public.applications enable row level security;
drop policy if exists "own or admin application" on public.applications;
create policy "own or admin application" on public.applications for select to authenticated
  using (user_id = auth.uid() or is_admin());

-- Blocks members waiting for approval from adding anything. Guests (not signed in) and
-- organisers acting for someone else are unaffected.
create or replace function public.require_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and exists (select 1 from profiles where id = auth.uid() and not approved) then
    raise exception 'Your membership is waiting for the admin to approve it.';
  end if;
  return new;
end $$;

drop trigger if exists require_approved on public.bookings;
create trigger require_approved before insert on public.bookings for each row execute function public.require_approved();
drop trigger if exists require_approved on public.posts;
create trigger require_approved before insert on public.posts for each row execute function public.require_approved();
drop trigger if exists require_approved on public.comments;
create trigger require_approved before insert on public.comments for each row execute function public.require_approved();
drop trigger if exists require_approved on public.poll_votes;
create trigger require_approved before insert on public.poll_votes for each row execute function public.require_approved();
drop trigger if exists require_approved on public.group_members;
create trigger require_approved before insert on public.group_members for each row execute function public.require_approved();
drop trigger if exists require_approved on public.invites;
create trigger require_approved before insert on public.invites for each row execute function public.require_approved();

create or replace function public.approve_member(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can approve members.'; end if;
  update profiles set approved = true where id = p_id;
end $$;
revoke execute on function public.approve_member(uuid) from public, anon;
grant execute on function public.approve_member(uuid) to authenticated;

-- Turn down someone waiting for approval: removes their account completely.
create or replace function public.decline_member(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Only the admin can decline members.'; end if;
  if not exists (select 1 from profiles where id = p_id and not approved) then
    raise exception 'Only members waiting for approval can be declined.';
  end if;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.decline_member(uuid) from public, anon;
grant execute on function public.decline_member(uuid) to authenticated;

-- Removes people who joined more than 24 hours ago and still haven't sent the application.
-- Run every hour by the cleanup-applicants Netlify function.
create or replace function public.remove_stale_applicants() returns int
language plpgsql security definer set search_path = public, auth as $$
declare n int;
begin
  with gone as (
    delete from auth.users u using profiles p
     where p.id = u.id and not p.approved and p.role = 'member'
       and p.created_at < now() - interval '24 hours'
       and not exists (select 1 from applications a where a.user_id = p.id)
       and not exists (select 1 from bookings b where b.user_id = p.id)
    returning u.id)
  select count(*) into n from gone;
  return n;
end $$;
revoke execute on function public.remove_stale_applicants() from public, anon, authenticated;
grant execute on function public.remove_stale_applicants() to service_role;

-- Members can only read these two tables (and only their own rows); the server writes them.
revoke insert, update, delete on public.applications, public.member_postcodes from anon, authenticated;
grant select on public.applications, public.member_postcodes to authenticated;

-- Football Accounts: a sign-up chat holding past accounts. Only organisers post there.
insert into public.groups (id, name, about, sort, members_only)
values ('football-accounts', 'Football Accounts', 'Our football accounts, game by game. Only organisers post here.', 2, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;
drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id <> 'football-accounts' or is_organiser()) and can_see_group(group_id));
