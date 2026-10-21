-- ---------- events open to everyone, booked from a shared link or QR code (also in schema.sql) ----------
alter table public.events drop constraint if exists events_access_check;
alter table public.events add constraint events_access_check check (access in ('open', 'public', 'members'));

-- Guests book 'public' events with a member's invite code, and 'open' events with no code.
create or replace function public.guest_book(p_event uuid, p_name text, p_age int, p_email text, p_code text, p_places int)
returns table (id uuid, code text, status text)
language plpgsql security definer set search_path = public as $$
declare e events; inv invites; b bookings; taken int;
begin
  if coalesce(trim(p_name), '') = '' or p_age is null or p_age < 1 or p_email !~ '^\S+@\S+\.\S+$' then
    raise exception 'Enter your full name, age and a valid email address.';
  end if;
  select * into e from events where events.id = p_event and kind = 'event';
  if not found then raise exception 'That event no longer exists.'; end if;
  if e.access not in ('public', 'open') then raise exception 'This event is for members only.'; end if;
  if e.access = 'public' then
    select * into inv from invites where invites.code = upper(trim(p_code)) for update;
    if not found then raise exception 'That invite code is not recognised. Ask the member who invited you to check it.'; end if;
    if inv.used_by is not null and lower(inv.used_by) <> lower(trim(p_name)) then
      raise exception 'That invite code has already been used by someone else.';
    end if;
    update invites set used_by = trim(p_name) where invites.code = inv.code;
  end if;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and bookings.status = 'booked';
  insert into bookings (event_id, display_name, places, charge, amount, paid, status, code)
  values (p_event, trim(p_name), p_places, 'ticket', e.price * p_places, e.price = 0,
          case when taken + p_places > e.capacity then 'waitlist' else 'booked' end, new_code('AA-'))
  returning * into b;
  insert into guests values (b.id, trim(p_name), p_age, trim(p_email), inv.created_by);
  return query select b.id, b.code, b.status;
end $$;

-- ---------- approval for public bookings, parent permission and 7-day deletion (also in schema.sql) ----------
-- Guests booking an 'open' event wait for an organiser to approve them ('pending'), who can also decline them.
alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings add constraint bookings_status_check check (status in ('booked', 'waitlist', 'cancelled', 'pending', 'declined'));
alter table public.bookings add column if not exists parent_ok boolean;
-- "Anything we should know" and special requests are no longer asked for, so clear any already given.
update public.bookings set note = null, request = null where note is not null or request is not null;

create or replace function public.guest_book(p_event uuid, p_name text, p_age int, p_email text, p_code text, p_places int)
returns table (id uuid, code text, status text)
language plpgsql security definer set search_path = public as $$
declare e events; inv invites; b bookings; taken int;
begin
  if coalesce(trim(p_name), '') = '' or p_age is null or p_age < 1 or p_email !~ '^\S+@\S+\.\S+$' then
    raise exception 'Enter your full name, age and a valid email address.';
  end if;
  select * into e from events where events.id = p_event and kind = 'event';
  if not found then raise exception 'That event no longer exists.'; end if;
  if e.access not in ('public', 'open') then raise exception 'This event is for members only.'; end if;
  if e.access = 'public' then
    select * into inv from invites where invites.code = upper(trim(p_code)) for update;
    if not found then raise exception 'That invite code is not recognised. Ask the member who invited you to check it.'; end if;
    if inv.used_by is not null and lower(inv.used_by) <> lower(trim(p_name)) then
      raise exception 'That invite code has already been used by someone else.';
    end if;
    update invites set used_by = trim(p_name) where invites.code = inv.code;
  end if;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and bookings.status = 'booked';
  insert into bookings (event_id, display_name, places, charge, amount, paid, status, code)
  values (p_event, trim(p_name), p_places, 'ticket', e.price * p_places, e.price = 0,
          case when e.access = 'open' then 'pending' when taken + p_places > e.capacity then 'waitlist' else 'booked' end, new_code('AA-'))
  returning * into b;
  insert into guests values (b.id, trim(p_name), p_age, trim(p_email), inv.created_by);
  return query select b.id, b.code, b.status;
end $$;

-- Organisers approve (booked, or waitlist if full) or decline a pending booking.
create or replace function public.decide_booking(p_id uuid, p_ok boolean) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; taken int; v text;
begin
  if not is_organiser() then raise exception 'Only organisers can approve bookings.'; end if;
  select * into b from bookings where id = p_id for update;
  if not found or b.status <> 'pending' then raise exception 'That booking is no longer waiting for approval.'; end if;
  select * into e from events where id = b.event_id;
  select coalesce(sum(places), 0) into taken from bookings where event_id = b.event_id and status = 'booked';
  v := case when not p_ok then 'declined' when taken + b.places > e.capacity then 'waitlist' else 'booked' end;
  update bookings set status = v where id = p_id;
  return v;
end $$;
revoke execute on function public.decide_booking(uuid, boolean) from public, anon;
grant execute on function public.decide_booking(uuid, boolean) to authenticated;

-- Booking details now: name, age, gender and, for under-16s, parent or guardian permission.
drop function if exists public.set_booking_details(text, text, int, text, text, text);
create or replace function public.set_booking_details(p_code text, p_name text, p_age int, p_gender text, p_parent boolean) returns void
language sql security definer set search_path = public as $$
  update bookings set
    display_name = coalesce(nullif(left(trim(p_name), 80), ''), display_name),
    age = p_age, gender = nullif(p_gender, ''), parent_ok = case when p_age < 16 then coalesce(p_parent, false) end
  where code = upper(trim(p_code))
$$;
grant execute on function public.set_booking_details(text, text, int, text, boolean) to anon, authenticated;

create or replace function public.check_in_details(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; g guests; v_by text; v_was boolean;
begin
  if not is_organiser() then raise exception 'Only organisers can check people in.'; end if;
  select * into b from bookings where code = upper(trim(p_code));
  if not found then raise exception 'No ticket found with code %.', upper(trim(p_code)); end if;
  select * into e from events where id = b.event_id;
  select * into g from guests where booking_id = b.id;
  select name into v_by from profiles where id = coalesce(g.invited_by, b.booked_by);
  v_was := b.checked_in;
  if b.status = 'booked' and not b.checked_in then
    update bookings set checked_in = true where id = b.id;
  end if;
  return json_build_object(
    'code', b.code, 'name', b.display_name, 'status', b.status, 'places', b.places,
    'already', v_was, 'paid', b.paid, 'amount', b.amount, 'method', b.method, 'charge', b.charge,
    'age', coalesce(b.age, g.age), 'gender', b.gender, 'parent_ok', b.parent_ok,
    'title', e.title, 'day', e.day, 'time', e.time,
    'guest', g.booking_id is not null, 'guest_name', g.full_name, 'booked_by', v_by);
end $$;
revoke execute on function public.check_in_details(text) from public, anon;
grant execute on function public.check_in_details(text) to authenticated;

-- 7 days after an event (not football), guests' details are deleted and everyone's age and gender cleared.
-- The booking stays, so the head count is kept. Run hourly by the cleanup-applicants Netlify function.
create or replace function public.purge_old_event_data() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from guests g using bookings b, events e
   where g.booking_id = b.id and e.id = b.event_id and e.kind = 'event' and e.day < current_date - 7;
  get diagnostics n = row_count;
  update bookings b set display_name = 'Guest (details removed)'
    from events e where e.id = b.event_id and e.kind = 'event' and e.day < current_date - 7
     and b.user_id is null and b.booked_by is null and b.display_name <> 'Guest (details removed)';
  update bookings b set age = null, gender = null, parent_ok = null, note = null, request = null
    from events e where e.id = b.event_id and e.kind = 'event' and e.day < current_date - 7
     and (b.age is not null or b.gender is not null or b.parent_ok is not null or b.note is not null or b.request is not null);
  return n;
end $$;
revoke execute on function public.purge_old_event_data() from public, anon, authenticated;
grant execute on function public.purge_old_event_data() to service_role;

-- ---------- events-only membership (also in schema.sql) ----------
-- Members choose "events and football" or "events only" when they join; organisers can change it.
alter table public.profiles add column if not exists football boolean not null default true;

-- New applicants (not yet approved) set their own choice right after signing up.
create or replace function public.set_my_football(p_on boolean) returns void
language sql security definer set search_path = public as $$
  update profiles set football = p_on where id = auth.uid() and approved = false
$$;
grant execute on function public.set_my_football(boolean) to authenticated;

create or replace function public.set_member_football(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser() then raise exception 'Only organisers can change memberships.'; end if;
  update profiles set football = p_on or family where id = p_id; -- family members always play
end $$;
revoke execute on function public.set_member_football(uuid, boolean) from public, anon;
grant execute on function public.set_member_football(uuid, boolean) to authenticated;

-- Events-only members can't book football or add a friend to it.
create or replace function public.football_members_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from events where id = new.event_id and kind = 'football')
     and exists (select 1 from profiles where id = coalesce(new.booked_by, new.user_id) and not football and not family) then
    raise exception 'Your membership is for events only. Ask an organiser if you''d like to add football.';
  end if;
  return new;
end $$;
drop trigger if exists bookings_football_members_only on public.bookings;
create trigger bookings_football_members_only before insert on public.bookings
  for each row execute function public.football_members_only();
