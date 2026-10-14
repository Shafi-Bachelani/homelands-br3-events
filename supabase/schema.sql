-- =====================================================================
--  Creating Our Homelands: BR3 events database
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  It is safe to run once on a fresh project.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- tables ----------

-- One row per signed-up person. The first person to sign up becomes admin.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  role text not null default 'member' check (role in ('member', 'organiser', 'admin')),
  family boolean not null default false,          -- pays by transfer, never by card
  credit numeric(8,2) not null default 0,         -- pay-as-you-play credit in £
  kitty_session int,                              -- kitty member while this equals fund_state.session_no
  created_at timestamptz not null default now()
);

-- Single row holding the football funds and the current kitty session.
create table public.fund_state (
  id int primary key default 1 check (id = 1),
  kitty numeric(10,2) not null default 100,
  events numeric(10,2) not null default 0,
  session_no int not null default 1,
  games_played int not null default 0
);
insert into public.fund_state default values;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'event' check (kind in ('event', 'football')),
  title text not null,
  day date,                                       -- empty while the date is to be confirmed
  time time not null,
  location text not null default '',
  details text not null default '',
  price numeric(8,2) not null default 0,
  capacity int not null default 50 check (capacity > 0),
  access text not null default 'members' check (access in ('public', 'members')),
  accounts_posted boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,  -- null for guests
  display_name text not null,
  places int not null default 1 check (places between 1 and 6),
  charge text not null default 'ticket' check (charge in ('ticket', 'payg', 'kitty', 'covered')),
  amount numeric(8,2) not null default 0,
  paid boolean not null default false,
  method text check (method in ('card', 'transfer', 'cash', 'credit', 'owes')),
  status text not null default 'booked' check (status in ('booked', 'waitlist', 'cancelled')),
  code text not null unique,
  checked_in boolean not null default false,
  created_at timestamptz not null default now()
);
create unique index bookings_one_per_member on public.bookings (event_id, user_id)
  where user_id is not null and status <> 'cancelled';

-- Guest details are only visible to organisers.
create table public.guests (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  full_name text not null,
  age int not null,
  email text not null,
  invited_by uuid references public.profiles(id) on delete set null
);

create table public.invites (
  code text primary key,
  created_by uuid not null references public.profiles(id) on delete cascade,
  used_by text,
  created_at timestamptz not null default now()
);

create table public.debts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(8,2) not null,
  reason text not null default '',
  on_date date not null default current_date,
  cleared boolean not null default false
);

create table public.ledger (
  id bigserial primary key,
  on_date date not null default current_date,
  fund text not null check (fund in ('kitty', 'events')),
  what text not null,
  amount numeric(10,2) not null,
  balance numeric(10,2) not null,
  created_at timestamptz not null default now()
);

create table public.accounts_posts (
  id bigserial primary key,
  event_id uuid references public.events(id) on delete set null,
  body text not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.groups (
  id text primary key,
  name text not null,
  about text not null default '',
  sort int not null default 0
);

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  group_id text not null references public.groups(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  author_name text not null,
  body text not null default '',
  image text,
  poll jsonb,
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  author_name text not null,
  body text not null,
  created_at timestamptz not null default now()
);

create table public.poll_votes (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  choice int not null,
  primary key (post_id, user_id)
);

-- ---------- helpers ----------

create function public.is_organiser() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('organiser', 'admin'))
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

create function public.new_code(prefix text) returns text
language sql volatile as $$
  select prefix || upper(substr(translate(encode(gen_random_bytes(6), 'base64'), '+/=0O1Il', ''), 1, 5))
$$;

-- Football deadlines, in UK time: booking opens Wed 1pm, pay by Thu 11pm, credit if you cancel before Fri 6pm.
create function public.fb_opens(d date) returns timestamptz language sql immutable as $$
  select ((d - 2) + time '13:00') at time zone 'Europe/London' $$;
create function public.fb_pay_by(d date) returns timestamptz language sql immutable as $$
  select ((d - 1) + time '23:00') at time zone 'Europe/London' $$;
create function public.fb_credit_until(d date) returns timestamptz language sql immutable as $$
  select (d + time '18:00') at time zone 'Europe/London' $$;

-- New sign-ups get a profile. The very first one becomes admin.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name, role)
  values (new.id,
          coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1)),
          case when exists (select 1 from profiles where role = 'admin') then 'member' else 'admin' end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- football ----------

-- Removes football bookings that weren't paid by Thursday 11pm. Anyone may call it; it is idempotent.
create function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  update profiles p set kitty_session = null
    from bookings b join events e on e.id = b.event_id
   where b.user_id = p.id and e.kind = 'football' and b.charge = 'kitty'
     and not b.paid and b.status = 'booked' and now() > fb_pay_by(e.day) and p.kitty_session = s;
  delete from bookings b using events e
   where e.id = b.event_id and e.kind = 'football' and not b.paid and b.status = 'booked'
     and now() > fb_pay_by(e.day) and not e.accounts_posted;
  get diagnostics n = row_count;
  return n;
end $$;

create function public.book_football(p_event uuid, p_choice text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  e events; p profiles; fs fund_state; b bookings;
  taken int; v_charge text; v_amount numeric := 0; v_paid boolean := false; v_method text;
begin
  if uid is null then raise exception 'Please sign in to book football.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if now() < fb_opens(e.day) then raise exception 'Booking opens on Wednesday at 1pm.'; end if;
  if now() > ((e.day + e.time) at time zone 'Europe/London') then raise exception 'This game has already started.'; end if;
  perform expire_unpaid();
  if exists (select 1 from bookings where event_id = p_event and user_id = uid and status <> 'cancelled') then
    raise exception 'You are already booked for this game.';
  end if;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and status = 'booked';
  if taken >= e.capacity then raise exception 'All % places are taken.', e.capacity; end if;
  select * into p from profiles where id = uid for update;
  select * into fs from fund_state;

  if p.kitty_session = fs.session_no then
    v_charge := 'covered'; v_paid := true;
  elsif p_choice = 'kitty' then
    v_charge := 'kitty'; v_amount := 15;
    if p.family then v_paid := true; v_method := 'transfer'; end if;
  else
    v_charge := 'payg'; v_amount := 6;
    if p.family then v_paid := true; v_method := 'transfer';
    elsif p.credit >= 6 then v_paid := true; v_method := 'credit';
      update profiles set credit = credit - 6 where id = uid;
    end if;
  end if;

  if not v_paid and now() > fb_pay_by(e.day) then
    raise exception 'The payment deadline (Thursday 11pm) has passed. Message the organiser to be added.';
  end if;
  if v_charge = 'kitty' then update profiles set kitty_session = fs.session_no where id = uid; end if;

  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, code)
  values (p_event, uid, p.name, v_charge, v_amount, v_paid, v_method, new_code('AA-'))
  returning * into b;
  return b;
end $$;

-- ---------- other events ----------

create function public.book_event(p_event uuid, p_places int) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int;
begin
  if uid is null then raise exception 'Please sign in to book.'; end if;
  select * into e from events where id = p_event and kind = 'event';
  if not found then raise exception 'That event no longer exists.'; end if;
  if now() > ((e.day + e.time) at time zone 'Europe/London') then raise exception 'This event has already started.'; end if;
  if exists (select 1 from bookings where event_id = p_event and user_id = uid and status <> 'cancelled') then
    raise exception 'You have already booked this event.';
  end if;
  select * into p from profiles where id = uid;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and status = 'booked';
  insert into bookings (event_id, user_id, display_name, places, charge, amount, paid, status, code)
  values (p_event, uid, p.name, p_places, 'ticket', e.price * p_places, e.price = 0,
          case when taken + p_places > e.capacity then 'waitlist' else 'booked' end, new_code('AA-'))
  returning * into b;
  return b;
end $$;

create function public.guest_book(p_event uuid, p_name text, p_age int, p_email text, p_code text, p_places int)
returns table (id uuid, code text, status text)
language plpgsql security definer set search_path = public as $$
declare e events; inv invites; b bookings; taken int;
begin
  if coalesce(trim(p_name), '') = '' or p_age is null or p_age < 1 or p_email !~ '^\S+@\S+\.\S+$' then
    raise exception 'Enter your full name, age and a valid email address.';
  end if;
  select * into e from events where events.id = p_event and kind = 'event';
  if not found then raise exception 'That event no longer exists.'; end if;
  if e.access <> 'public' then raise exception 'This event is for members only.'; end if;
  select * into inv from invites where invites.code = upper(trim(p_code)) for update;
  if not found then raise exception 'That invite code is not recognised. Ask the member who invited you to check it.'; end if;
  if inv.used_by is not null and lower(inv.used_by) <> lower(trim(p_name)) then
    raise exception 'That invite code has already been used by someone else.';
  end if;
  update invites set used_by = trim(p_name) where invites.code = inv.code;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and bookings.status = 'booked';
  insert into bookings (event_id, display_name, places, charge, amount, paid, status, code)
  values (p_event, trim(p_name), p_places, 'ticket', e.price * p_places, e.price = 0,
          case when taken + p_places > e.capacity then 'waitlist' else 'booked' end, new_code('AA-'))
  returning * into b;
  insert into guests values (b.id, trim(p_name), p_age, trim(p_email), inv.created_by);
  return query select b.id, b.code, b.status;
end $$;

create function public.cancel_booking(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; msg text := 'Removed.'; free int; w bookings;
begin
  select * into b from bookings where id = p_id and status <> 'cancelled';
  if not found then raise exception 'Booking not found.'; end if;
  if b.user_id is distinct from auth.uid() and not is_organiser() then raise exception 'You can only cancel your own booking.'; end if;
  select * into e from events where id = b.event_id;
  if e.kind = 'football' and b.charge = 'payg' and b.paid and b.method <> 'owes' and now() < fb_credit_until(e.day) then
    update profiles set credit = credit + b.amount where id = b.user_id;
    if b.method = 'credit' then
      delete from bookings where id = p_id;           -- the credit simply goes back
    else
      update bookings set status = 'cancelled' where id = p_id;  -- keeps the money in this week's accounts
    end if;
    msg := 'Removed. £' || b.amount || ' added to your credit.';
  else
    if e.kind = 'football' and b.charge = 'kitty' and not b.paid then
      update profiles set kitty_session = null where id = b.user_id;
    end if;
    delete from bookings where id = p_id;
  end if;
  -- move the first waitlisted booking up if it now fits
  if e.kind = 'event' and b.status = 'booked' then
    select e.capacity - coalesce(sum(places), 0) into free from bookings where event_id = e.id and status = 'booked';
    select * into w from bookings where event_id = e.id and status = 'waitlist' order by created_at limit 1;
    if found and w.places <= free then update bookings set status = 'booked' where id = w.id; end if;
  end if;
  return msg;
end $$;

-- Places taken per event, readable by guests too.
create function public.event_places() returns table (event_id uuid, taken bigint)
language sql stable security definer set search_path = public as $$
  select event_id, coalesce(sum(places), 0) from bookings where status = 'booked' group by event_id
$$;

-- Guests see their own ticket by code.
create function public.ticket(p_code text) returns table (code text, status text, display_name text, places int,
  title text, day date, "time" time, location text, checked_in boolean)
language sql stable security definer set search_path = public as $$
  select b.code, b.status, b.display_name, b.places, e.title, e.day, e.time, e.location, b.checked_in
  from bookings b join events e on e.id = b.event_id where b.code = upper(trim(p_code))
$$;

-- ---------- organiser tools ----------

create function public.check_in(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings; e events;
begin
  if not is_organiser() then raise exception 'Only organisers can check people in.'; end if;
  select * into b from bookings where code = upper(trim(p_code));
  if not found then raise exception 'No ticket found with code %.', upper(trim(p_code)); end if;
  select * into e from events where id = b.event_id;
  if b.status = 'waitlist' then return b.display_name || ' is on the waitlist for ' || e.title || ', not booked.'; end if;
  if b.status = 'cancelled' then return b.display_name || ' cancelled this booking.'; end if;
  if b.checked_in then return b.display_name || ' is already checked in.'; end if;
  update bookings set checked_in = true where id = b.id;
  return 'Checked in ' || b.display_name || ', ' || b.places || ' place(s) for ' || e.title || '.';
end $$;

create function public.update_member(p_id uuid, p_role text, p_family boolean, p_credit numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser() then raise exception 'Only organisers can change members.'; end if;
  if p_role is not null and not is_admin() then raise exception 'Only the admin can change roles.'; end if;
  if p_id = auth.uid() and p_role is not null and p_role <> 'admin' then raise exception 'You cannot remove your own admin role.'; end if;
  update profiles set
    role = coalesce(p_role, role),
    family = coalesce(p_family, family),
    credit = coalesce(p_credit, credit)
  where id = p_id;
end $$;

-- Confirms a football game's accounts: records how each player paid, moves the money,
-- and restarts the kitty when the fund drops below £150 or after 5 games.
create function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[]) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and paid and method in ('card', 'transfer', 'cash');
  insert into debts (user_id, amount, reason, on_date)
    select user_id, amount, 'Football ' || d, e.day from bookings
     where event_id = p_event and method = 'owes' and user_id is not null;
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  select * into fs from fund_state for update;
  fs.kitty := fs.kitty + income;
  insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': money received', income, fs.kitty);
  fs.kitty := fs.kitty - coalesce(p_hire, 0);
  insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': pitch hire', -coalesce(p_hire, 0), fs.kitty);
  if coalesce(p_fees, 0) > 0 then
    fs.kitty := fs.kitty - p_fees;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': card fees', -p_fees, fs.kitty);
  end if;
  if v_cleared > 0 then
    fs.events := fs.events + v_cleared;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'events', 'Football ' || d || ': owed money cleared', v_cleared, fs.events);
  end if;
  fs.games_played := fs.games_played + 1;

  if fs.kitty < 150 or fs.games_played >= 5 then
    x := fs.kitty - 100;
    fs.events := fs.events + x; fs.kitty := 100;
    insert into ledger (on_date, fund, what, amount, balance) values
      (e.day, 'kitty', 'Kitty ' || fs.session_no || ' ends: reset to £100', -x, fs.kitty),
      (e.day, 'events', 'Kitty ' || fs.session_no || ' ends: ' || case when x >= 0 then 'excess moved in' else 'top-up to kitty' end, x, fs.events);
    fs.session_no := fs.session_no + 1; fs.games_played := 0;
  end if;

  update fund_state set kitty = fs.kitty, events = fs.events, session_no = fs.session_no, games_played = fs.games_played where id = 1;
  update events set accounts_posted = true where id = p_event;
  insert into accounts_posts (event_id, body, created_by) values (p_event, p_body, auth.uid());
  return fs;
end $$;

-- Organisers can set the starting funds once, e.g. from the last WhatsApp accounts.
create function public.set_funds(p_kitty numeric, p_events numeric, p_session int, p_games int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can set the funds.'; end if;
  update fund_state set kitty = p_kitty, events = p_events, session_no = p_session, games_played = p_games where id = 1;
  insert into ledger (fund, what, amount, balance) values
    ('kitty', 'Opening balance', p_kitty, p_kitty), ('events', 'Opening balance', p_events, p_events);
end $$;

-- ---------- security (row level) ----------

alter table public.profiles enable row level security;
alter table public.fund_state enable row level security;
alter table public.events enable row level security;
alter table public.bookings enable row level security;
alter table public.guests enable row level security;
alter table public.invites enable row level security;
alter table public.debts enable row level security;
alter table public.ledger enable row level security;
alter table public.accounts_posts enable row level security;
alter table public.groups enable row level security;
alter table public.posts enable row level security;
alter table public.comments enable row level security;
alter table public.poll_votes enable row level security;

revoke all on all tables in schema public from anon;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant select on public.events, public.groups to anon;
grant usage, select on all sequences in schema public to authenticated;
revoke update on public.profiles from authenticated;
grant update (name) on public.profiles to authenticated;

create policy "members see members" on public.profiles for select to authenticated using (true);
create policy "edit own name" on public.profiles for update to authenticated using (id = auth.uid());

create policy "members see funds" on public.fund_state for select to authenticated using (true);

create policy "everyone sees events" on public.events for select to anon, authenticated using (true);
create policy "organisers add events" on public.events for insert to authenticated with check (is_organiser());
create policy "organisers edit events" on public.events for update to authenticated using (is_organiser());
create policy "organisers remove events" on public.events for delete to authenticated using (is_organiser());

create policy "members see bookings" on public.bookings for select to authenticated using (true);
create policy "organisers edit bookings" on public.bookings for update to authenticated using (is_organiser());
create policy "organisers remove bookings" on public.bookings for delete to authenticated using (is_organiser());

create policy "organisers see guests" on public.guests for select to authenticated using (is_organiser());

create policy "see own invites" on public.invites for select to authenticated using (created_by = auth.uid() or is_organiser());
create policy "create own invites" on public.invites for insert to authenticated with check (created_by = auth.uid());

create policy "members see debts" on public.debts for select to authenticated using (true);
create policy "organisers edit debts" on public.debts for all to authenticated using (is_organiser()) with check (is_organiser());

create policy "members see ledger" on public.ledger for select to authenticated using (true);
create policy "members see accounts" on public.accounts_posts for select to authenticated using (true);

create policy "everyone sees groups" on public.groups for select to anon, authenticated using (true);
create policy "organisers edit groups" on public.groups for all to authenticated using (is_organiser()) with check (is_organiser());

create policy "members see posts" on public.posts for select to authenticated using (true);
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()));
create policy "organisers pin posts" on public.posts for update to authenticated using (is_organiser());
create policy "remove own posts" on public.posts for delete to authenticated using (user_id = auth.uid() or is_organiser());

create policy "members see comments" on public.comments for select to authenticated using (true);
create policy "members comment" on public.comments for insert to authenticated with check (user_id = auth.uid());
create policy "remove own comments" on public.comments for delete to authenticated using (user_id = auth.uid() or is_organiser());

create policy "members see votes" on public.poll_votes for select to authenticated using (true);
create policy "vote" on public.poll_votes for insert to authenticated with check (user_id = auth.uid());
create policy "change vote" on public.poll_votes for update to authenticated using (user_id = auth.uid());

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.expire_unpaid(), public.event_places(), public.ticket(text),
  public.guest_book(uuid, text, int, text, text, int) to anon, authenticated;
grant execute on function public.is_organiser(), public.is_admin(), public.book_football(uuid, text),
  public.book_event(uuid, int), public.cancel_booking(uuid), public.check_in(text),
  public.update_member(uuid, text, boolean, numeric), public.set_funds(numeric, numeric, int, int),
  public.post_accounts(uuid, text, numeric, numeric, jsonb, uuid[]),
  public.fb_opens(date), public.fb_pay_by(date), public.fb_credit_until(date) to authenticated;

-- ---------- starting content ----------

insert into public.groups (id, name, about, sort) values
  ('hub', 'Al-Ansaar Community Hub', 'The main hub for everyone in the community.', 1),
  ('football', 'Friday Football', 'Teams, lifts, kit and match chat.', 2),
  ('enthusiasts', 'Event Enthusiasts Group', 'A space for people who love our events.', 3);

insert into public.events (kind, title, day, time, location, details, price, capacity, access) values
  ('football', 'Weekly Friday Footie', '2026-10-16', '20:30', 'Goals Beckenham, Elmers End',
   'Weekly 5-a-side every Friday night. All abilities welcome. £6 pay as you play, or £15 for the kitty.', 6, 36, 'members');

-- Lets organisers mark someone as a kitty member for the current kitty (e.g. they paid £15 on WhatsApp).
create or replace function public.set_kitty(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser() then raise exception 'Only organisers can change members.'; end if;
  update profiles set kitty_session = case when p_on then (select session_no from fund_state limit 1) end
  where id = p_id;
end $$;
revoke execute on function public.set_kitty(uuid, boolean) from public, anon;
grant execute on function public.set_kitty(uuid, boolean) to authenticated;

-- Events with the date still to be confirmed can be listed but not booked.

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
