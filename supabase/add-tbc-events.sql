-- Lets events be listed with the date still to be confirmed, and adds three upcoming events.
alter table public.events alter column day drop not null;

-- Nobody can book an event until it has a date.
create or replace function public.block_undated_booking() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select day from events where id = new.event_id) is null then
    raise exception 'This event''s date hasn''t been confirmed yet, so booking isn''t open.';
  end if;
  return new;
end $$;
drop trigger if exists block_undated_booking on public.bookings;
create trigger block_undated_booking before insert on public.bookings
  for each row execute function public.block_undated_booking();

insert into public.events (kind, title, day, time, location, details, price, capacity, access)
select 'event', t.title, null, '19:00', '', t.details, 0, 30, 'public'
from (values
  ('Film Night', 'A community film night. Date, film and venue to be announced.'),
  ('Chess Tournament', 'All levels welcome. Date, format and venue to be announced.'),
  ('Debate Evening', 'A friendly debate evening. Motion, date and venue to be announced.')
) as t(title, details)
where not exists (select 1 from public.events e where e.title = t.title);
