-- ---------- supervisors for any event (run once in the Supabase SQL Editor, after add-event-supervisors.sql) ----------
-- Any event can ask for supervisors, including Friday Football and the Quran group.
-- Hall events: 6 supervisors in 3 teams of 2 (door, crowd, running the event), with the standard call.
-- Other events: "supervisors needed" from 1 to 6, no teams, and the admin's own blurb and tasks for that event.
-- Friday Football supervisors (chosen for one game) get the Football Supervisors screen for that game:
-- scan, tick people in, add people at the pitch. Weekly events (Quran) keep supervisors until the admin removes them.
-- Safe to run more than once.

alter table public.events add column if not exists supervisor_teams boolean;           -- empty = hall teams for events, none for football/weekly
alter table public.events add column if not exists supervisors_needed int;
alter table public.events add column if not exists supervisor_blurb text;
alter table public.events drop constraint if exists events_supervisors_needed_check;
alter table public.events add constraint events_supervisors_needed_check check (supervisors_needed between 1 and 6);
alter table public.events drop constraint if exists events_supervisor_blurb_check;
alter table public.events add constraint events_supervisor_blurb_check check (length(supervisor_blurb) <= 3000);

-- Hall events use the 3 teams; everything else is a simple list.
create or replace function public.sup_teams(e public.events) returns boolean
language sql stable as $$ select coalesce(e.supervisor_teams, e.kind = 'event' and not e.weekly) $$;
create or replace function public.sup_needed(e public.events) returns int
language sql stable as $$ select case when sup_teams(e) then 6 else coalesce(e.supervisors_needed, 2) end $$;

-- Simple events: applications have no team choices, and supervisors are just "helper".
alter table public.supervisor_applications drop constraint if exists supervisor_applications_prefs_check;
alter table public.supervisor_applications add constraint supervisor_applications_prefs_check
  check (cardinality(prefs) <= 3 and prefs <@ array['door', 'crowd', 'run']);
alter table public.event_supervisors drop constraint if exists event_supervisors_role_check;
alter table public.event_supervisors add constraint event_supervisors_role_check check (role in ('door', 'crowd', 'run', 'helper'));

-- Access ends at 4am the morning after the event; weekly events (like Quran) don't end by themselves.
create or replace function public.is_supervising(p_event uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from event_supervisors s join events e on e.id = s.event_id
                  where s.event_id = p_event and s.user_id = auth.uid() and e.day is not null
                    and (e.weekly or now() < supervisor_until(e)))
$$;

create or replace function public.apply_supervisor(p_event uuid, p_prefs text[], p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; v_prefs text[];
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
  if e.day is not null and not e.weekly and (now() at time zone 'Europe/London')::date > e.day then raise exception 'This event has already happened.'; end if;
  if sup_teams(e) then
    if coalesce(cardinality(p_prefs), 0) = 0 then raise exception 'Tick at least one thing you''d like to help with.'; end if;
    select array_agg(distinct x order by x) into v_prefs from unnest(p_prefs) x where x in ('door', 'crowd', 'run');
  else
    v_prefs := '{}';
  end if;
  insert into supervisor_applications (event_id, user_id, prefs, note)
  values (p_event, auth.uid(), coalesce(v_prefs, '{}'), nullif(left(trim(p_note), 500), ''))
  on conflict (event_id, user_id) do update set prefs = excluded.prefs, note = excluded.note;
  begin
    perform queue_notice(array(select id from profiles where role = 'admin'), 'events',
      '🙋 Supervisor application: ' || e.title,
      p.name || case when cardinality(v_prefs) > 0 then ' would like to help with: ' ||
        (select string_agg(case x when 'door' then 'the door' when 'crowd' then 'crowd management' else 'running the event' end, ', ') from unnest(v_prefs) x)
        else ' would like to supervise' end, '#admin:' || e.id, 'sup-app-' || e.id);
  exception when others then null;
  end;
end $$;

create or replace function public.assign_supervisor(p_event uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare e events; v_name text; v_role text := p_role;
begin
  if not is_organiser() then raise exception 'Only the admin can choose supervisors.'; end if;
  select * into e from events where id = p_event;
  if not found then raise exception 'That event no longer exists.'; end if;
  select name into v_name from profiles where id = p_user;
  if not found then raise exception 'Member not found.'; end if;
  if sup_teams(e) then
    if v_role not in ('door', 'crowd', 'run') then raise exception 'Choose a team.'; end if;
    if (select count(*) from event_supervisors where event_id = p_event and role = v_role and user_id <> p_user) >= 2 then
      raise exception 'That team already has 2 people.';
    end if;
  else
    v_role := 'helper';
  end if;
  if (select count(*) from event_supervisors where event_id = p_event and user_id <> p_user) >= sup_needed(e) then
    raise exception 'This event already has % supervisor%.', sup_needed(e), case when sup_needed(e) = 1 then '' else 's' end;
  end if;
  insert into event_supervisors (event_id, user_id, role) values (p_event, p_user, v_role)
  on conflict (event_id, user_id) do update set role = excluded.role;
  begin
    perform queue_notice(array[p_user], 'events', '✅ You''re a supervisor: ' || e.title,
      case v_role when 'door' then 'Team: on the door. ' when 'crowd' then 'Team: crowd management and attendees'' needs. '
                  when 'run' then 'Team: running the event. ' else '' end
      || case when sup_teams(e) then 'Please come to the pre-event and post-event meetings.' else 'Open Supervisor tools in the app for what''s needed.' end,
      '#supervising', 'sup-' || e.id);
  exception when others then null;
  end;
end $$;

-- "Supervisors wanted" for any event (football and weekly events too).
create or replace function public.notify_supervisors_open() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int := sup_needed(new);
begin
  if not new.supervisors_open then return new; end if;
  if tg_op = 'UPDATE' and old.supervisors_open then return new; end if;
  perform queue_notice(
    case when new.kind = 'football' then array(select id from profiles where role in ('organiser', 'admin') or football or family)
         else array(select id from profiles) end,
    'events', '🙋 Supervisors wanted: ' || new.title,
    case when sup_teams(new) then 'We''re looking for 6 members to run it in 3 teams of 2.'
         else 'We need ' || n || ' supervisor' || case when n = 1 then '' else 's' end || '.' end
    || ' Apply in the app' || case when new.supervisor_deadline is not null then ' by ' || to_char(new.supervisor_deadline, 'FMDay FMDD FMMonth') else '' end || '.',
    '#events:' || new.id, 'sup-open-' || new.id);
  return new;
exception when others then
  return new;
end $$;

-- ---------- Friday Football supervisors: the Football Supervisors screen for their game ----------
create or replace function public.set_here(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_door() and not exists (select 1 from bookings where id = p_id and is_supervising(event_id)) then
    raise exception 'Only organisers and this game''s supervisors can tick people in.';
  end if;
  update bookings b set checked_in = p_on from events e
   where b.id = p_id and e.id = b.event_id and not e.accounts_posted;
end $$;
revoke execute on function public.set_here(uuid, boolean) from public, anon;
grant execute on function public.set_here(uuid, boolean) to authenticated;

create or replace function public.set_risk(p_id uuid) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if not is_door() and not exists (select 1 from bookings where id = p_id and is_supervising(event_id)) then
    raise exception 'Only organisers and this game''s supervisors can record this.';
  end if;
  update bookings set risk_ok = true where id = p_id returning * into b;
  if not found then raise exception 'Booking not found.'; end if;
  return b;
end $$;
revoke execute on function public.set_risk(uuid) from public, anon;
grant execute on function public.set_risk(uuid) to authenticated;

-- Adding someone at the pitch: same as add-night-payments.sql, but this game's supervisors can do it too.
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text, p_choice text)
returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
begin
  if not is_door() and not is_supervising(p_event) then raise exception 'Only organisers and this game''s supervisors can add players.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game are already posted.'; end if;
  if p_method not in ('card', 'transfer', 'cash', 'owes', 'credit', 'link') then raise exception 'Choose how they paid.'; end if;
  if coalesce(p_choice, 'payg') not in ('payg', 'kitty', 'topup') then raise exception 'Choose what they are paying.'; end if;
  if p_user is null and p_choice in ('kitty', 'topup') then raise exception 'Only members can join the kitty.'; end if;
  select * into fs from fund_state where id = 1;

  if p_user is not null then
    select * into p from profiles where id = p_user for update;
    if not found then raise exception 'Member not found.'; end if;
    select * into b from bookings where event_id = p_event and user_id = p_user and status <> 'cancelled';

    -- Topping up (or paying £15 when already booked for pay and play): their place becomes a kitty place.
    if p_choice in ('kitty', 'topup') and found and b.charge = 'payg' then
      if p_method in ('owes', 'credit') then raise exception 'A top-up can be paid by QR, card, transfer or cash.'; end if;
      if not b.paid or b.method in ('owes', 'credit') then
        -- nothing paid yet, or paid from credit: that credit stays as credit used, and the rest is paid now
        -- by QR, the place stays unpaid until Square confirms the card payment
        update bookings set charge = 'kitty', amount = 15, intro_cover = 0, method = nullif(p_method, 'link'), paid = p_method <> 'link',
                            credit_used = case when b.paid and b.method = 'credit' then b.amount else b.credit_used end,
                            checked_in = true, status = 'booked', pitch_link = p_method = 'link',
                            square_order_id = case when p_method = 'link' then null else b.square_order_id end
         where id = b.id returning * into b;
      else
        -- by QR, topup_method stays 'link' until Square confirms the card payment; the new Square order replaces the old one
        update bookings set charge = 'kitty', amount = 15, intro_cover = 0, topup = 15 - b.amount, topup_method = p_method,
                            checked_in = true, status = 'booked', pitch_link = b.pitch_link or p_method = 'link',
                            square_order_id = case when p_method = 'link' then null else b.square_order_id end
         where id = b.id returning * into b;
      end if;
      update profiles set kitty_session = fs.session_no where id = p_user;
      return b;
    end if;
    if p_choice = 'topup' then
      if found and b.charge in ('covered', 'kitty') then raise exception '% is already in the kitty.', p.name; end if;
      raise exception '% isn''t on the list. Choose "Join the kitty, £15" instead.', p.name;
    end if;

    if found then
      update bookings set checked_in = true, status = 'booked' where id = b.id returning * into b;
      return b;
    end if;
    if p.kitty_session = fs.session_no then
      insert into bookings (event_id, user_id, display_name, charge, amount, paid, checked_in, code)
      values (p_event, p_user, p.name, 'covered', 0, true, true, new_code('AA-')) returning * into b;
      return b;
    end if;
    v_price := case when p_choice = 'kitty' then 15 else e.price end;
    if p_method = 'credit' then
      if p.credit < v_price then raise exception '% doesn''t have enough credit.', p.name; end if;
      perform set_config('app.credit_reason', 'credit used for football ' || to_char(e.day, 'FMDD Mon')
        || case when p_choice = 'kitty' then ' (kitty)' else '' end, true);
      update profiles set credit = credit - v_price where id = p_user;
      perform set_config('app.credit_reason', '', true);
    end if;
    if p_choice = 'kitty' then update profiles set kitty_session = fs.session_no where id = p_user; end if;
  elsif coalesce(trim(p_name), '') = '' then raise exception 'Choose a member or type their name.';
  elsif p_method = 'credit' then raise exception 'Only members can pay with credit.';
  end if;
  -- offer prices are for members; anyone else pays the full £6
  v_price := case when p_user is null then greatest(e.price, 6) when p_choice = 'kitty' then 15 else e.price end;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code, pitch_link)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), case when p_choice = 'kitty' then 'kitty' else 'payg' end, v_price,
          p_method not in ('owes', 'link'), nullif(p_method, 'link'), true, new_code('AA-'), p_method = 'link')
  returning * into b;
  return b;
end $$;
revoke execute on function public.add_walkin(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.add_walkin(uuid, uuid, text, text, text) to authenticated;
