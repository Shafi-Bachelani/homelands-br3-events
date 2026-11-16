-- ---------- event supervisors (run once in the Supabase SQL Editor) ----------
-- 1. Organisers already scan tickets and see who's in (is_door()). Event supervisors get the same,
--    but only for the event they supervise, and only until 4am the morning after it.
-- 2. Each event can ask for supervisors: "Supervisor applications open" and a deadline on the advert.
--    Members apply on their own with the jobs they'd like: door, crowd management, running the event.
-- 3. The admin picks up to 6: 3 teams of 2 (door, crowd and attendees, running the event).
-- Safe to run more than once.

alter table public.events add column if not exists supervisors_open boolean not null default false;
alter table public.events add column if not exists supervisor_deadline date;   -- last day to apply (UK time)

-- ---------- applications ----------
create table if not exists public.supervisor_applications (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  prefs text[] not null check (cardinality(prefs) between 1 and 3 and prefs <@ array['door', 'crowd', 'run']),
  note text check (length(note) <= 500),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.supervisor_applications enable row level security;
revoke all on public.supervisor_applications from anon;
grant select, delete on public.supervisor_applications to authenticated;
drop policy if exists "see own or admin" on public.supervisor_applications;
create policy "see own or admin" on public.supervisor_applications for select to authenticated using (user_id = auth.uid() or is_organiser());
drop policy if exists "withdraw own or admin" on public.supervisor_applications;
create policy "withdraw own or admin" on public.supervisor_applications for delete to authenticated using (user_id = auth.uid() or is_organiser());

-- ---------- who supervises which event ----------
-- role is the team: door, crowd (crowd management and attendees' needs) or run (running the event). 2 per team.
create table if not exists public.event_supervisors (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null check (role in ('door', 'crowd', 'run')),
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.event_supervisors enable row level security;
revoke all on public.event_supervisors from anon;
grant select, delete on public.event_supervisors to authenticated;
drop policy if exists "members see supervisors" on public.event_supervisors;
create policy "members see supervisors" on public.event_supervisors for select to authenticated using (true);
drop policy if exists "admin removes supervisors" on public.event_supervisors;
create policy "admin removes supervisors" on public.event_supervisors for delete to authenticated using (is_organiser());

-- When a supervisor's access ends: 4am UK time the morning after the event.
create or replace function public.supervisor_until(e public.events) returns timestamptz
language sql stable as $$ select ((e.day + 1) + time '04:00') at time zone 'Europe/London' $$;

-- Is the signed-in person a supervisor of this event right now?
create or replace function public.is_supervising(p_event uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from event_supervisors s join events e on e.id = s.event_id
                  where s.event_id = p_event and s.user_id = auth.uid() and e.day is not null and now() < supervisor_until(e))
$$;
grant execute on function public.is_supervising(uuid) to authenticated;

-- ---------- a member applies (or changes their application) ----------
create or replace function public.apply_supervisor(p_event uuid, p_prefs text[], p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare e events; p profiles;
begin
  select * into p from profiles where id = auth.uid();
  if not found then raise exception 'Sign in to apply.'; end if;
  if p.approved is false then raise exception 'You can apply once your membership is approved.'; end if;
  select * into e from events where id = p_event;
  if not found then raise exception 'That event no longer exists.'; end if;
  if not e.supervisors_open then raise exception 'Supervisor applications aren''t open for this event.'; end if;
  if e.supervisor_deadline is not null and (now() at time zone 'Europe/London')::date > e.supervisor_deadline then
    raise exception 'Sorry, applications closed on %.', to_char(e.supervisor_deadline, 'FMDay FMDD FMMonth');
  end if;
  if e.day is not null and (now() at time zone 'Europe/London')::date > e.day then raise exception 'This event has already happened.'; end if;
  if coalesce(cardinality(p_prefs), 0) = 0 then raise exception 'Tick at least one thing you''d like to help with.'; end if;
  insert into supervisor_applications (event_id, user_id, prefs, note)
  values (p_event, auth.uid(), (select array_agg(distinct x order by x) from unnest(p_prefs) x), nullif(left(trim(p_note), 500), ''))
  on conflict (event_id, user_id) do update set prefs = excluded.prefs, note = excluded.note;
  -- Let the admin know (needs add-phone-notifications.sql; skipped quietly if not there).
  begin
    perform queue_notice(array(select id from profiles where role = 'admin'), 'events',
      '🙋 Supervisor application: ' || e.title, p.name || ' would like to help with: ' ||
      (select string_agg(case x when 'door' then 'the door' when 'crowd' then 'crowd management' else 'running the event' end, ', ')
         from unnest(p_prefs) x), '#admin:' || e.id, 'sup-app-' || e.id);
  exception when others then null;
  end;
end $$;
revoke execute on function public.apply_supervisor(uuid, text[], text) from public, anon;
grant execute on function public.apply_supervisor(uuid, text[], text) to authenticated;

-- ---------- the admin puts someone in a team (or moves them) ----------
create or replace function public.assign_supervisor(p_event uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare e events; v_name text;
begin
  if not is_organiser() then raise exception 'Only the admin can choose supervisors.'; end if;
  if p_role not in ('door', 'crowd', 'run') then raise exception 'Choose a team.'; end if;
  select * into e from events where id = p_event;
  if not found then raise exception 'That event no longer exists.'; end if;
  select name into v_name from profiles where id = p_user;
  if not found then raise exception 'Member not found.'; end if;
  if (select count(*) from event_supervisors where event_id = p_event and role = p_role and user_id <> p_user) >= 2 then
    raise exception 'That team already has 2 people.';
  end if;
  if (select count(*) from event_supervisors where event_id = p_event and user_id <> p_user) >= 6 then
    raise exception 'This event already has 6 supervisors.';
  end if;
  insert into event_supervisors (event_id, user_id, role) values (p_event, p_user, p_role)
  on conflict (event_id, user_id) do update set role = excluded.role;
  begin
    perform queue_notice(array[p_user], 'events', '✅ You''re a supervisor: ' || e.title,
      'Team: ' || case p_role when 'door' then 'on the door' when 'crowd' then 'crowd management and attendees'' needs' else 'running the event' end
      || '. Please come to the pre-event and post-event meetings.', '#supervising', 'sup-' || e.id);
  exception when others then null;
  end;
end $$;
revoke execute on function public.assign_supervisor(uuid, uuid, text) from public, anon;
grant execute on function public.assign_supervisor(uuid, uuid, text) to authenticated;

-- ---------- "Supervisors wanted": everyone hears when an event opens applications ----------
create or replace function public.notify_supervisors_open() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'event' or not new.supervisors_open then return new; end if;
  if tg_op = 'UPDATE' and old.supervisors_open then return new; end if;
  perform queue_notice(array(select id from profiles), 'events', '🙋 Supervisors wanted: ' || new.title,
    'We''re looking for 6 members to run it in 3 teams of 2. Apply in the app'
    || case when new.supervisor_deadline is not null then ' by ' || to_char(new.supervisor_deadline, 'FMDay FMDD FMMonth') else '' end || '.',
    '#events:' || new.id, 'sup-open-' || new.id);
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zz_notify_supervisors_open on public.events;
create trigger zz_notify_supervisors_open after insert or update of supervisors_open on public.events
  for each row execute function public.notify_supervisors_open();

-- ---------- scanning: organisers and the admin anywhere, supervisors at their own event ----------
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
    'guest', g.booking_id is not null, 'guest_name', g.full_name, 'booked_by', v_by);
end $$;
revoke execute on function public.check_in_details(text) from public, anon;
grant execute on function public.check_in_details(text) to authenticated;

-- Supervisors see guests' names in the who's-in list for their event (organisers already can).
drop policy if exists "supervisors see guests" on public.guests;
create policy "supervisors see guests" on public.guests for select to authenticated
  using (exists (select 1 from bookings b where b.id = guests.booking_id and is_supervising(b.event_id)));
