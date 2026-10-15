-- New members give their postcode when they join. If it's more than 5 miles from BR3
-- their account is held: they can look around but can't book, post, comment, vote,
-- sign up to chats or invite guests until the admin approves them.
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
          first_admin or coalesce(mi <= 5, false));
  if pc <> '' then
    insert into member_postcodes (user_id, postcode, miles) values (new.id, pc, round(mi, 1));
  end if;
  return new;
end $$;

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
