-- Applications for public events (first used for the Speed Chess Tournament, Sat 12 Dec 2026).
-- Anyone can apply as a Player or as non-playing Audience. Non-members fill in a Jotform
-- application; the admin approves or declines it; once approved they pay by card and get the QR ticket.
-- Members book straight in (they are already vetted), choosing Player or Audience.
-- Safe to run more than once.

-- ---------- events: the application form and two ticket types ----------
alter table public.events add column if not exists apply_form text;        -- Jotform link; when set, non-members apply
alter table public.events add column if not exists player_places int;      -- e.g. 24; null = one kind of ticket as before
alter table public.events add column if not exists audience_places int;    -- e.g. 3
alter table public.events add column if not exists audience_price numeric(8,2);

-- ---------- bookings: ticket type, who they're with, the form answers ----------
alter table public.bookings add column if not exists ticket_type text;
alter table public.bookings drop constraint if exists bookings_ticket_type_check;
alter table public.bookings add constraint bookings_ticket_type_check check (ticket_type is null or ticket_type in ('player', 'audience'));
alter table public.bookings add column if not exists linked_to text;       -- audience: the applicant they come with
alter table public.bookings add column if not exists adult_name text;      -- under 16: parent or responsible adult attending
alter table public.bookings add column if not exists application text;     -- the Jotform answers, one per line
alter table public.bookings add column if not exists application_at timestamptz;

-- Places taken per ticket type (booked only), for "x of 24 player places left".
create or replace function public.event_type_places(p_event uuid) returns table (ticket_type text, taken bigint)
language sql stable security definer set search_path = public as $$
  select coalesce(ticket_type, 'player'), coalesce(sum(places), 0) from bookings
  where event_id = p_event and status = 'booked' group by 1
$$;
grant execute on function public.event_type_places(uuid) to anon, authenticated;

-- Apply (non-members: waits for approval) or book (approved members: straight in).
create or replace function public.apply_event(p_event uuid, p_type text, p_name text, p_age int, p_email text,
  p_linked text default '', p_adult text default '', p_consent boolean default null)
returns table (id uuid, code text, status text)
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; type_taken int; cap int; v_price numeric; v_status text;
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
    -- a member: booked straight away
    if exists (select 1 from bookings where event_id = p_event and user_id = uid and bookings.status <> 'cancelled') then
      raise exception 'You have already booked this event.';
    end if;
    insert into bookings (event_id, user_id, display_name, places, charge, amount, paid, status, code, ticket_type, linked_to, adult_name, age, parent_ok)
    values (p_event, uid, coalesce(nullif(trim(p_name), ''), p.name), 1, 'ticket', v_price, v_price = 0, 'booked', new_code('AA-'),
            p_type, nullif(trim(p_linked), ''), nullif(trim(p_adult), ''), p_age, case when p_age <= 18 then coalesce(p_consent, p_age < 16) end)
    returning * into b;
  else
    if e.access <> 'open' then raise exception 'This event is not open to the public.'; end if;
    if coalesce(p_email, '') !~ '^\S+@\S+\.\S+$' then raise exception 'Enter a valid email address.'; end if;
    insert into bookings (event_id, display_name, places, charge, amount, paid, status, code, ticket_type, linked_to, adult_name, age, parent_ok)
    values (p_event, trim(p_name), 1, 'ticket', v_price, v_price = 0, 'pending', new_code('AA-'),
            p_type, nullif(trim(p_linked), ''), nullif(trim(p_adult), ''), p_age, case when p_age <= 18 then coalesce(p_consent, p_age < 16) end)
    returning * into b;
    insert into guests (booking_id, full_name, age, email) values (b.id, trim(p_name), p_age, trim(p_email));
  end if;
  return query select b.id, b.code, b.status;
end $$;
revoke execute on function public.apply_event(uuid, text, text, int, text, text, text, boolean) from public;
grant execute on function public.apply_event(uuid, text, text, int, text, text, text, boolean) to anon, authenticated;

-- Approving now also checks the ticket type's places (24 players, 3 audience): approvals stop when full.
create or replace function public.decide_booking(p_id uuid, p_ok boolean) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; taken int; type_taken int; cap int; v text;
begin
  if not is_organiser() then raise exception 'Only organisers can approve bookings.'; end if;
  select * into b from bookings where id = p_id for update;
  if not found or b.status <> 'pending' then raise exception 'That booking is no longer waiting for approval.'; end if;
  select * into e from events where id = b.event_id;
  select coalesce(sum(places), 0) into taken from bookings where event_id = b.event_id and status = 'booked';
  cap := case when b.ticket_type = 'player' then e.player_places when b.ticket_type = 'audience' then e.audience_places end;
  select coalesce(sum(places), 0) into type_taken from bookings
   where event_id = b.event_id and status = 'booked' and coalesce(ticket_type, 'player') = coalesce(b.ticket_type, 'player');
  v := case when not p_ok then 'declined'
            when taken + b.places > e.capacity or (cap is not null and type_taken + b.places > cap) then 'waitlist'
            else 'booked' end;
  update bookings set status = v where id = p_id;
  return v;
end $$;
revoke execute on function public.decide_booking(uuid, boolean) from public, anon;
grant execute on function public.decide_booking(uuid, boolean) to authenticated;

-- The ticket also says the ticket type, the form link and whether the form has come in.
drop function if exists public.ticket(text);
create function public.ticket(p_code text) returns table (code text, status text, display_name text, places int,
  title text, day date, "time" time, location text, checked_in boolean, paid boolean, amount numeric,
  ticket_type text, apply_form text, applied boolean, event_id uuid)
language sql stable security definer set search_path = public as $$
  select b.code, b.status, b.display_name, b.places, e.title, e.day, e.time, e.location, b.checked_in, b.paid, b.amount,
         b.ticket_type, e.apply_form, b.application_at is not null, e.id
  from bookings b join events e on e.id = b.event_id where b.code = upper(trim(p_code))
$$;
revoke execute on function public.ticket(text) from public;
grant execute on function public.ticket(text) to anon, authenticated;

-- Telegram alert when the application form comes in (the booking request alert is sent already).
create or replace function public.alert_application() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events;
begin
  if new.application_at is not null and old.application_at is distinct from new.application_at then
    select * into e from events where id = new.event_id;
    perform send_admin_alert('📝 Application form in: ' || coalesce(e.title, 'an event'),
      new.display_name || ' (' || coalesce(new.ticket_type, 'player') || E')\n' || left(coalesce(new.application, ''), 1500)
      || case when new.status = 'pending' then E'\nApprove or decline it in Admin → Guests.' else '' end);
  end if;
  return new;
exception when others then
  return new;
end $$;
revoke execute on function public.alert_application() from public, anon, authenticated;
drop trigger if exists zz_alert_application on public.bookings;
create trigger zz_alert_application after update of application_at on public.bookings
  for each row execute function public.alert_application();

-- Form answers are deleted 7 days after the event, like guests' other details.
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
         application = null, linked_to = null, adult_name = null
    from events e where e.id = b.event_id and e.kind = 'event' and e.day < current_date - 7
     and (b.age is not null or b.gender is not null or b.parent_ok is not null or b.note is not null or b.request is not null
          or b.application is not null or b.linked_to is not null or b.adult_name is not null);
  return n;
end $$;
revoke execute on function public.purge_old_event_data() from public, anon, authenticated;
grant execute on function public.purge_old_event_data() to service_role;

-- ---------- the Speed Chess Tournament ----------
-- Sat 12 Dec 2026, open to everyone, 24 players at £6 and 3 audience at £10 (3 organisers make 30).
-- Time and place: check them in Admin → Events and bookings after running this.
update public.events set
  title = 'Speed Chess Tournament',
  day = '2026-12-12',
  access = 'open',
  price = 6, audience_price = 10,
  player_places = 24, audience_places = 3, capacity = 27,
  apply_form = 'https://form.jotform.com/263227494603055',
  details = 'Speed chess tournament, open to the public. Players £6 (covers hall hire only). Non-playing audience £10, and must come with an applicant. 24 players, 3 organisers and 3 audience (room capacity 30).' || E'\n\n'
    || 'Everyone who is not a member applies first. The organiser checks each application before a ticket is issued. Once approved, pay by card and your QR ticket appears in the app.' || E'\n\n'
    || 'Bring your own portable chess set and a phone with a chess clock app if you can. The final between the 2 top rated players takes place at Dessert Hub, Penge. We rely on donations for a prize, so the winner may receive only accolade.' || E'\n\n'
    || 'Under 16s must come with a parent or responsible adult (as a player or audience). Ages 16 to 18 need their parents'' consent.'
where kind = 'event' and title ilike '%chess%';

-- If there was no chess event yet, add one (time and place to be set in Admin).
insert into public.events (kind, title, day, time, location, price, capacity, access)
select 'event', 'Speed Chess Tournament', '2026-12-12', '10:00', 'Hall to be confirmed', 6, 27, 'open'
where not exists (select 1 from public.events where kind = 'event' and title ilike '%chess%');
update public.events set audience_price = 10, player_places = 24, audience_places = 3,
  apply_form = 'https://form.jotform.com/263227494603055'
where kind = 'event' and title ilike '%chess%' and apply_form is null;
