-- ---------- check-in shows who booked and their booking details (also in schema.sql) ----------
alter table public.bookings add column if not exists note text check (length(note) <= 500);

alter table public.bookings add column if not exists request text check (length(request) <= 500);
alter table public.bookings add column if not exists age int check (age between 0 and 120);
alter table public.bookings add column if not exists gender text check (gender in ('Male', 'Female'));

-- Whoever holds a booking's code (the booker, or a guest) fills in who's coming and anything we should know.
drop function if exists public.set_booking_note(text, text);
create or replace function public.set_booking_details(p_code text, p_name text, p_age int, p_gender text, p_note text, p_request text) returns void
language sql security definer set search_path = public as $$
  update bookings set
    display_name = coalesce(nullif(left(trim(p_name), 80), ''), display_name),
    age = p_age, gender = nullif(p_gender, ''),
    note = nullif(left(trim(p_note), 500), ''), request = nullif(left(trim(p_request), 500), '')
  where code = upper(trim(p_code))
$$;
grant execute on function public.set_booking_details(text, text, int, text, text, text) to anon, authenticated;

-- Checks a ticket in and returns what the organiser needs to see at the door.
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
    'note', b.note, 'request', b.request, 'age', coalesce(b.age, g.age), 'gender', b.gender, 'title', e.title, 'day', e.day, 'time', e.time,
    'guest', g.booking_id is not null, 'guest_name', g.full_name, 'guest_age', g.age,
    'booked_by', v_by);
end $$;
revoke execute on function public.check_in_details(text) from public, anon;
grant execute on function public.check_in_details(text) to authenticated;
