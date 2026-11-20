-- Speed Chess Tournament additions (Shafi, 20 Nov 2026):
-- * full name and a separate handle ("how you'd like us to refer to you") on each application
-- * pre-event information and an instructions video link on an event
-- * the app records when a ticket holder last opened it, so the door scan can show whether
--   they opened the app in the 24 hours before the event
-- * the door scan shows full name, handle and age
-- Needs add-event-applications.sql and add-event-supervisors.sql first. Safe to run more than once.

alter table public.bookings add column if not exists handle text;
alter table public.bookings add column if not exists seen_at timestamptz;
alter table public.events add column if not exists pre_info text;
alter table public.events add column if not exists video_url text;

-- apply_event gains the handle. The old version is replaced (the app calls it by parameter name).
drop function if exists public.apply_event(uuid, text, text, int, text, text, text, boolean);
create or replace function public.apply_event(p_event uuid, p_type text, p_name text, p_age int, p_email text,
  p_linked text default '', p_adult text default '', p_consent boolean default null, p_handle text default '')
returns table (id uuid, code text, status text)
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; type_taken int; cap int; v_price numeric;
begin
  select * into e from events where events.id = p_event and kind = 'event';
  if not found then raise exception 'That event no longer exists.'; end if;
  if e.day is not null and now() > ((e.day + e.time) at time zone 'Europe/London') then raise exception 'This event has already started.'; end if;
  if p_type not in ('player', 'audience') then raise exception 'Choose Player or Audience.'; end if;
  if coalesce(trim(p_name), '') = '' or p_age is null or p_age < 1 then raise exception 'Enter your full name and age.'; end if;
  if p_type = 'audience' and coalesce(trim(p_linked), '') = '' then
    raise exception 'Audience places are for people coming with an applicant. Enter their name.';
  end if;
  if p_age < 16 and coalesce(trim(p_adult), '') = '' then
    raise exception 'Under 16s must come with a parent or responsible adult (as a player or audience). Enter their name.';
  end if;
  if p_age between 16 and 18 and p_consent is not true then
    raise exception 'Applicants aged 16 to 18 need their parents'' consent.';
  end if;
  cap := case when p_type = 'player' then e.player_places else e.audience_places end;
  v_price := case when p_type = 'audience' then coalesce(e.audience_price, e.price) else e.price end;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and bookings.status = 'booked';
  select coalesce(sum(places), 0) into type_taken from bookings where event_id = p_event and bookings.status = 'booked' and coalesce(ticket_type, 'player') = p_type;
  if cap is not null and type_taken >= cap or taken >= e.capacity then
    raise exception 'Sorry, all % places are taken.', case when p_type = 'player' then 'player' else 'audience' end;
  end if;

  if uid is not null then select * into p from profiles where profiles.id = uid; end if;
  if uid is not null and p.approved is not false then
    if exists (select 1 from bookings where event_id = p_event and user_id = uid and bookings.status <> 'cancelled') then
      raise exception 'You have already booked this event.';
    end if;
    insert into bookings (event_id, user_id, display_name, handle, places, charge, amount, paid, status, code, ticket_type, linked_to, adult_name, age, parent_ok, seen_at)
    values (p_event, uid, coalesce(nullif(trim(p_name), ''), p.name), nullif(left(trim(p_handle), 40), ''), 1, 'ticket', v_price, v_price = 0, 'pending', new_code('AA-'),
            p_type, nullif(trim(p_linked), ''), nullif(trim(p_adult), ''), p_age, case when p_age <= 18 then coalesce(p_consent, p_age < 16) end, now())
    returning * into b;
    perform send_admin_alert('🎟️ Member applying: ' || e.title, b.display_name || ' (' || p_type || E')\nApprove or decline it in Admin → Events and bookings.');
  else
    if e.access <> 'open' then raise exception 'This event is not open to the public.'; end if;
    insert into bookings (event_id, display_name, handle, places, charge, amount, paid, status, code, ticket_type, linked_to, adult_name, age, parent_ok, seen_at)
    values (p_event, trim(p_name), nullif(left(trim(p_handle), 40), ''), 1, 'ticket', v_price, v_price = 0, 'pending', new_code('AA-'),
            p_type, nullif(trim(p_linked), ''), nullif(trim(p_adult), ''), p_age, case when p_age <= 18 then coalesce(p_consent, p_age < 16) end, now())
    returning * into b;
    insert into guests (booking_id, full_name, age, email) values (b.id, trim(p_name), p_age, '');
  end if;
  return query select b.id, b.code, b.status;
end $$;
revoke execute on function public.apply_event(uuid, text, text, int, text, text, text, boolean, text) from public;
grant execute on function public.apply_event(uuid, text, text, int, text, text, text, boolean, text) to anon, authenticated;

-- The app calls this each time it opens, with the ticket codes saved on the phone (members' own
-- bookings are found by their sign-in). Only bookings for events that haven't finished are touched.
create or replace function public.mark_seen(p_codes text[]) returns void
language sql security definer set search_path = public as $$
  update bookings b set seen_at = now()
  from events e
  where e.id = b.event_id and e.kind = 'event' and (e.day is null or e.day >= current_date - 1)
    and b.status in ('booked', 'pending', 'waitlist')
    and (b.code = any(coalesce(p_codes, '{}')) or (auth.uid() is not null and b.user_id = auth.uid()))
$$;
grant execute on function public.mark_seen(text[]) to anon, authenticated;

-- The ticket also carries the handle, the pre-event information and the video link.
drop function if exists public.ticket(text);
create function public.ticket(p_code text) returns table (code text, status text, display_name text, places int,
  title text, day date, "time" time, location text, checked_in boolean, paid boolean, amount numeric,
  ticket_type text, apply_form text, applied boolean, event_id uuid, handle text, pre_info text, video_url text)
language sql stable security definer set search_path = public as $$
  select b.code, b.status, b.display_name, b.places, e.title, e.day, e.time, e.location, b.checked_in, b.paid, b.amount,
         b.ticket_type, e.apply_form, b.application_at is not null, e.id, b.handle, e.pre_info, e.video_url
  from bookings b join events e on e.id = b.event_id where b.code = upper(trim(p_code))
$$;
revoke execute on function public.ticket(text) from public;
grant execute on function public.ticket(text) to anon, authenticated;

-- Door scan: as before, plus handle, ticket type and when they last opened the app.
create or replace function public.check_in_details(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; g guests; v_by text; v_was boolean;
begin
  if not is_door() and not exists (select 1 from event_supervisors where user_id = auth.uid()) then
    raise exception 'Only organisers and event supervisors can check people in.';
  end if;
  select * into b from bookings where code = upper(trim(p_code));
  if not found then raise exception 'No ticket found with code %.', upper(trim(p_code)); end if;
  select * into e from events where id = b.event_id;
  if not is_door() and not is_supervising(b.event_id) then
    raise exception 'This ticket is for % on %. You can only check people in at the event you''re supervising.', e.title, coalesce(to_char(e.day, 'FMDD FMMonth'), 'a date to be confirmed');
  end if;
  select * into g from guests where booking_id = b.id;
  select name into v_by from profiles where id = coalesce(g.invited_by, b.booked_by);
  v_was := b.checked_in;
  if b.status = 'booked' and not b.checked_in then
    update bookings set checked_in = true where id = b.id;
  end if;
  return json_build_object(
    'id', b.id, 'code', b.code, 'name', b.display_name, 'status', b.status, 'places', b.places,
    'already', v_was, 'paid', b.paid, 'amount', b.amount, 'method', b.method, 'charge', b.charge,
    'age', coalesce(b.age, g.age), 'gender', b.gender, 'parent_ok', b.parent_ok,
    'title', e.title, 'day', e.day, 'time', e.time, 'kind', e.kind, 'event_id', e.id,
    'guest', g.booking_id is not null, 'guest_name', g.full_name, 'booked_by', v_by,
    'handle', b.handle, 'ticket_type', b.ticket_type, 'adult_name', b.adult_name, 'linked_to', b.linked_to,
    'seen_at', b.seen_at, 'starts_at', case when e.day is not null then (e.day + e.time) at time zone 'Europe/London' end,
    'app_check', e.apply_form is not null);
end $$;
revoke execute on function public.check_in_details(text) from public, anon;
grant execute on function public.check_in_details(text) to authenticated;

-- Handles are cleared 7 days after the event with the other details.
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
  update bookings b set age = null, gender = null, parent_ok = null, note = null, request = null,
         application = null, linked_to = null, adult_name = null, handle = null
    from events e where e.id = b.event_id and e.kind = 'event' and e.day < current_date - 7
     and (b.age is not null or b.gender is not null or b.parent_ok is not null or b.note is not null or b.request is not null
          or b.application is not null or b.linked_to is not null or b.adult_name is not null or b.handle is not null);
  return n;
end $$;
revoke execute on function public.purge_old_event_data() from public, anon, authenticated;
grant execute on function public.purge_old_event_data() to service_role;

-- Tips: event payments offer Square's tip screen; any tip is kept on the booking for the event accounts.
alter table public.bookings add column if not exists tip numeric(8,2) not null default 0;
