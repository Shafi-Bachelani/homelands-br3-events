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
