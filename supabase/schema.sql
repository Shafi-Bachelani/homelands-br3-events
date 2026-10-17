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
  created_at timestamptz not null default now(),
  square_order_id text,                           -- Square checkout order, for card payments
  card_fee numeric(8,2) not null default 0          -- what Square kept from a card payment
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

-- Booking codes like AA-7K2QXM: 6 characters from the random part of a UUID, skipping look-alikes (0/O, 1/I/L).
create or replace function public.new_code(prefix text) returns text
language sql volatile as $$
  select prefix || string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', get_byte(b, i) % 31 + 1, 1), '' order by i)
  from (select uuid_send(gen_random_uuid()) as b) x, generate_series(0, 5) as i
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

-- People whose football place was released for not paying in time; they can't rebook that game.
create table if not exists public.football_removed (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  removed_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.football_removed enable row level security;
drop policy if exists "see own removals" on public.football_removed;
create policy "see own removals" on public.football_removed for select to authenticated using (user_id = auth.uid() or is_organiser());
drop policy if exists "organisers lift removals" on public.football_removed;
create policy "organisers lift removals" on public.football_removed for delete to authenticated using (is_organiser());
grant select, delete on public.football_removed to authenticated;

-- Removes football bookings that weren't paid in time, and remembers who was removed so they can't rebook
-- that game. "In time" is Thursday 11pm, or 30 minutes after booking for anyone who books after that.
-- Anyone may call it; it is idempotent.
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  with x as (
    select b.id, b.event_id, b.user_id, b.charge from bookings b join events e on e.id = b.event_id
     where e.kind = 'football' and not b.paid and b.status = 'booked' and not e.accounts_posted
       and now() > greatest(fb_pay_by(e.day), b.created_at + interval '30 minutes')
  ), k as (
    update profiles p set kitty_session = null from x where x.user_id = p.id and x.charge = 'kitty' and p.kitty_session = s
  ), r as (
    insert into football_removed (event_id, user_id) select event_id, user_id from x where user_id is not null on conflict do nothing
  )
  delete from bookings where id in (select id from x);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.book_football(p_event uuid, p_choice text) returns public.bookings
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
  if exists (select 1 from football_removed where event_id = p_event and user_id = uid) then
    raise exception 'Your place was released because it wasn''t paid in time, so you can''t rebook this game.';
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
  title text, day date, "time" time, location text, checked_in boolean, paid boolean, amount numeric)
language sql stable security definer set search_path = public as $$
  select b.code, b.status, b.display_name, b.places, e.title, e.day, e.time, e.location, b.checked_in, b.paid, b.amount
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
create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[]) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and status = 'booked' and checked_in) then
    raise exception 'Tick who turned up under "Who''s turned up" before posting the accounts.';
  end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead.
  update profiles p set credit = p.credit + s.amt
    from (select user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and user_id is not null
           group by user_id) s
   where p.id = s.user_id;
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select user_id, amount, 'Football ' || d, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and user_id is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  select * into fs from fund_state where id = 1 for update;
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
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin()));
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
  ('announcements', 'Latest Community Announcements', 'News from the admin. Only the admin can post here.', 0),
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
  update profiles set kitty_session = case when p_on then (select session_no from fund_state where id = 1) end
  where id = p_id;
  if p_on then
    update bookings b set charge = 'covered', amount = 0, paid = true, method = null
    from events e
    where e.id = b.event_id and e.kind = 'football' and e.day >= (now() at time zone 'Europe/London')::date
      and b.user_id = p_id and b.status <> 'cancelled' and not b.paid and b.charge in ('payg', 'kitty');
  else
    -- Unticking turns their kitty places for upcoming games back into £6 pay-as-you-play.
    update bookings b set charge = 'payg', amount = 6,
      paid = coalesce((select family from profiles where id = p_id), false),
      method = case when (select family from profiles where id = p_id) then 'transfer' end
    from events e
    where e.id = b.event_id and e.kind = 'football' and e.day >= (now() at time zone 'Europe/London')::date
      and b.user_id = p_id and b.status <> 'cancelled' and b.charge = 'covered';
  end if;
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

-- ---------- weekly Quran target (same as add-quran.sql) ----------
-- Weekly Sunday Quran Recitation Target: a free weekly event that people sign up to,
-- and a members-only chat that only people who signed up (and organisers) can see.
-- Safe to run more than once.

alter table public.groups add column if not exists members_only boolean not null default false;
alter table public.events add column if not exists weekly boolean not null default false;
alter table public.events add column if not exists group_id text references public.groups(id) on delete set null;

create table if not exists public.group_members (
  group_id text not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table public.group_members enable row level security;
drop policy if exists "see memberships" on public.group_members;
create policy "see memberships" on public.group_members for select to authenticated using (user_id = auth.uid() or is_organiser());
drop policy if exists "join groups" on public.group_members;
create policy "join groups" on public.group_members for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "leave groups" on public.group_members;
create policy "leave groups" on public.group_members for delete to authenticated using (user_id = auth.uid() or is_organiser());
grant select, insert, delete on public.group_members to authenticated;

-- Can the signed-in person see this group's posts?
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
$$;
create or replace function public.can_see_post(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select can_see_group((select group_id from posts where id = p))
$$;
grant execute on function public.can_see_group(text), public.can_see_post(uuid) to authenticated;

drop policy if exists "members see posts" on public.posts;
create policy "members see posts" on public.posts for select to authenticated using (can_see_group(group_id));
drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin()) and can_see_group(group_id));

drop policy if exists "members see comments" on public.comments;
create policy "members see comments" on public.comments for select to authenticated using (can_see_post(post_id));
drop policy if exists "members comment" on public.comments;
create policy "members comment" on public.comments for insert to authenticated with check (user_id = auth.uid() and can_see_post(post_id));

insert into public.groups (id, name, about, sort, members_only)
values ('quran', 'Quran Recitation Target', 'Our weekly recitation target. Sign up to the Sunday event to join.', 1, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;

insert into public.events (kind, title, day, time, location, details, price, capacity, access, weekly, group_id)
select 'event', 'Sunday Quran Recitation Target', '2026-10-18', '20:00', 'From your own home',
  'Every Sunday we catch up to our weekly Quran recitation target, each from our own home. Free of charge. Sign up to see the target and join the conversation in Chats.',
  0, 500, 'members', true, 'quran'
where not exists (select 1 from public.events where group_id = 'quran');

-- This week's target, pinned, posted as the admin.
insert into public.posts (group_id, user_id, author_name, body, pinned)
select 'quran', p.id, p.name, $txt$**Week 2/18 of our Pre-Ramadan Quran**

To complete this weeks target  by **Sunday 18th October**

inshaAllah we will pace ourselves at 30-32 pages a week, and speed up nearing Ramadan

**This week to complete to-**

To the top of page 60, having completed verse 77 of Surah Aal-e-Imran:

إِنَّ الَّذِينَ يَشْتَرُونَ بِعَهْدِ اللَّهِ وَأَيْمَانِهِمْ ثَمَنًا قَلِيلًا أُولَٰئِكَ لَا خَلَاقَ لَهُمْ فِي الْآخِرَةِ وَلَا يُكَلِّمُهُمُ اللَّهُ وَلَا يَنظُرُ إِلَيْهِمْ يَوْمَ الْقِيَامَةِ وَلَا يُزَكِّيهِمْ وَلَهُمْ عَذَابٌ أَلِيمٌ

Lo! those who purchase a small gain at the cost of Allah's covenant and their oaths, they have no portion in the Hereafter. Allah will neither speak to them nor look upon them on the Day of Resurrection, nor will He make them grow. Theirs will be a painful doom.

To the start of Verse 78:

وَإِنَّ مِنْهُمْ لَفَرِيقًا يَلْوُونَ أَلْسِنَتَهُم بِالْكِتَابِ لِتَحْسَبُوهُ مِنَ الْكِتَابِ وَمَا هُوَ مِنَ الْكِتَابِ وَيَقُولُونَ هُوَ مِنْ عِندِ اللَّهِ وَمَا هُوَ مِنْ عِندِ اللَّهِ وَيَقُولُونَ عَلَى اللَّهِ الْكَذِبَ وَهُمْ يَعْلَمُونَ

And lo! there is a party of them who distort the Scripture with their tongues, that ye may think that what they say is from the Scripture, when it is not from the Scripture. And they say: It is from Allah, when it is not from Allah; and they speak a lie concerning Allah knowingly.

Pace yourself well for Allah t’ala loves the small acts often done

The bigger deeds are the contemplation and the bringing into action within your lives the precepts that accord with the revelation.

**Fallen Behind**
❤️ this group is all about falling behind and catching right back up.
❤️ it is about encouraging and celebrating that very human spirit of sacrifice that is all heart.

**Remember**
👊 The Quran is literally a Recitation, so recite it loudly, sonorously and with Tarteel. Let the Quran dictate the rhythm.
👊 The Quran is literally a collection of Ayats, a collection of the signs and proofs of God. Therefore give each Ayat its right, and pause between each. If you feel you could improve its recitation that do so before the next one.
👊 Before you start look ahead to where you want to be, set a reasonable day target, and make it happen. If you tire, then rest.
👊 Set a period towards the end of the week when you plan to catch up, remember to factor in Khaf on Fridays.
👊 Sakina the wind literally descends and is attracted by the sonorous Quran. May it envelop and visit each of our houses. Aameen.$txt$, true
from public.profiles p
where p.role = 'admin' and not exists (select 1 from public.posts where group_id = 'quran')
order by p.created_at limit 1;

-- ---------- walk-ins on the day (same as add-attendance-accounts.sql) ----------
-- Add someone on the day who wasn't on the list: marked as here, £6 pay and play
-- (or covered if they're in the current kitty). Pass a member's id, or just a name for a non-member.
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state;
begin
  if not is_organiser() then raise exception 'Only organisers can add players.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game are already posted.'; end if;
  if p_method not in ('card', 'transfer', 'cash', 'owes', 'credit') then raise exception 'Choose how they paid.'; end if;
  if p_user is not null then
    select * into p from profiles where id = p_user for update;
    if not found then raise exception 'Member not found.'; end if;
    select * into b from bookings where event_id = p_event and user_id = p_user and status <> 'cancelled';
    if found then
      update bookings set checked_in = true, status = 'booked' where id = b.id returning * into b;
      return b;
    end if;
    select * into fs from fund_state where id = 1;
    if p.kitty_session = fs.session_no then
      insert into bookings (event_id, user_id, display_name, charge, amount, paid, checked_in, code)
      values (p_event, p_user, p.name, 'covered', 0, true, true, new_code('AA-')) returning * into b;
      return b;
    end if;
    if p_method = 'credit' then
      if p.credit < 6 then raise exception '% doesn''t have £6 of credit.', p.name; end if;
      update profiles set credit = credit - 6 where id = p_user;
    end if;
  elsif coalesce(trim(p_name), '') = '' then raise exception 'Choose a member or type their name.';
  elsif p_method = 'credit' then raise exception 'Only members can pay with credit.';
  end if;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', 6, p_method <> 'owes', p_method, true, new_code('AA-'))
  returning * into b;
  return b;
end $$;
revoke execute on function public.add_walkin(uuid, uuid, text, text) from public, anon;
grant execute on function public.add_walkin(uuid, uuid, text, text) to authenticated;

-- ---------- membership approval (also in add-membership-approval.sql) ----------
-- Membership approval. New members give their postcode when they join, then fill in the
-- Jotform application. Until the admin approves them they can look around but can't book,
-- post, comment, vote, sign up to chats or invite guests. Anyone who hasn't sent the
-- application within 24 hours of joining is removed.
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
          first_admin);
  if pc <> '' then
    insert into member_postcodes (user_id, postcode, miles) values (new.id, pc, round(mi, 1));
  end if;
  return new;
end $$;

-- Jotform applications, recorded by the jotform-webhook Netlify function.
create table if not exists public.applications (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  submitted_at timestamptz not null default now(),
  answers text
);
alter table public.applications enable row level security;
drop policy if exists "own or admin application" on public.applications;
create policy "own or admin application" on public.applications for select to authenticated
  using (user_id = auth.uid() or is_admin());

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

-- Turn down someone waiting for approval: removes their account completely.
create or replace function public.decline_member(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Only the admin can decline members.'; end if;
  if not exists (select 1 from profiles where id = p_id and not approved) then
    raise exception 'Only members waiting for approval can be declined.';
  end if;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.decline_member(uuid) from public, anon;
grant execute on function public.decline_member(uuid) to authenticated;

-- Removes people who joined more than 24 hours ago and still haven't sent the application.
-- Run every hour by the cleanup-applicants Netlify function.
create or replace function public.remove_stale_applicants() returns int
language plpgsql security definer set search_path = public, auth as $$
declare n int;
begin
  with gone as (
    delete from auth.users u using profiles p
     where p.id = u.id and not p.approved and p.role = 'member'
       and p.created_at < now() - interval '24 hours'
       and not exists (select 1 from applications a where a.user_id = p.id)
       and not exists (select 1 from bookings b where b.user_id = p.id)
    returning u.id)
  select count(*) into n from gone;
  return n;
end $$;
revoke execute on function public.remove_stale_applicants() from public, anon, authenticated;
grant execute on function public.remove_stale_applicants() to service_role;

-- Members can only read these two tables (and only their own rows); the server writes them.
revoke insert, update, delete on public.applications, public.member_postcodes from anon, authenticated;
grant select on public.applications, public.member_postcodes to authenticated;

-- Football Accounts: a sign-up chat holding past accounts. Only organisers post there.
insert into public.groups (id, name, about, sort, members_only)
values ('football-accounts', 'Football Accounts', 'Our football accounts, game by game. Only organisers post here.', 2, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;
drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id <> 'football-accounts' or is_organiser()) and can_see_group(group_id));

-- ---------- football accounts access (also in add-football-accounts-access.sql) ----------
-- Every approved member can read the Football Accounts chat without signing up to it.
-- Run after add-membership-approval.sql. Safe to run more than once.
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
    or (g = 'football-accounts' and exists (select 1 from profiles where id = auth.uid() and approved))
$$;
update public.groups set about = 'Our football accounts, game by game. Every approved member can read them; only organisers post.'
 where id = 'football-accounts';

-- ---------- football roster, own risk, friends and family (also in add-roster-friends.sql) ----------

-- Who booked a friend onto the list, and whether the player agreed they play at their own risk.
alter table public.bookings add column if not exists booked_by uuid references public.profiles(id) on delete cascade;
alter table public.bookings add column if not exists risk_ok boolean not null default false;
create unique index if not exists bookings_one_friend_per_member on public.bookings (event_id, booked_by)
  where booked_by is not null and status <> 'cancelled';

-- Family members who took themselves off a game, so they aren't put back on automatically.
create table if not exists public.football_family_out (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  primary key (event_id, user_id)
);
alter table public.football_family_out enable row level security;
drop policy if exists "see own family outs" on public.football_family_out;
create policy "see own family outs" on public.football_family_out for select to authenticated using (user_id = auth.uid() or is_organiser());
grant select on public.football_family_out to authenticated;

-- Once booking opens (Wednesday 1pm), family members go on the list automatically, paid by transfer
-- (or covered by their kitty), unless they've taken themselves off or the list is full.
create or replace function public.add_family_bookings() returns int
language plpgsql security definer set search_path = public as $$
declare e events; fs fund_state; free int; n int := 0; k int;
begin
  select * into fs from fund_state where id = 1;
  for e in select * from events where kind = 'football' and day is not null and not accounts_posted
             and now() >= fb_opens(day) and now() < ((day + time) at time zone 'Europe/London') loop
    select e.capacity - coalesce(sum(places), 0) into free from bookings where event_id = e.id and status = 'booked';
    insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, code, risk_ok)
    select e.id, p.id, p.name,
           case when p.kitty_session = fs.session_no then 'covered' else 'payg' end,
           case when p.kitty_session = fs.session_no then 0 else 6 end,
           true, case when p.kitty_session = fs.session_no then null else 'transfer' end,
           new_code('AA-'), true
      from profiles p
     where p.family and p.approved
       and not exists (select 1 from bookings b where b.event_id = e.id and b.user_id = p.id and b.status <> 'cancelled')
       and not exists (select 1 from football_family_out o where o.event_id = e.id and o.user_id = p.id)
       and not exists (select 1 from football_removed r where r.event_id = e.id and r.user_id = p.id)
     order by p.created_at
     limit greatest(free, 0);
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;
revoke execute on function public.add_family_bookings() from public, anon, authenticated;

-- Runs whenever the football page opens or someone books: removes unpaid places, then adds family.
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  with x as (
    select b.id, b.event_id, b.user_id, b.charge from bookings b join events e on e.id = b.event_id
     where e.kind = 'football' and not b.paid and b.status = 'booked' and not e.accounts_posted
       and now() > greatest(fb_pay_by(e.day), b.created_at + interval '30 minutes')
  ), k as (
    update profiles p set kitty_session = null from x where x.user_id = p.id and x.charge = 'kitty' and p.kitty_session = s
  ), r as (
    insert into football_removed (event_id, user_id) select event_id, user_id from x where user_id is not null on conflict do nothing
  )
  delete from bookings where id in (select id from x);
  get diagnostics n = row_count;
  perform add_family_bookings();
  return n;
end $$;

-- Booking now needs the player to agree they play at their own risk.
create or replace function public.book_football(p_event uuid, p_choice text, p_risk boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if not coalesce(p_risk, false) then raise exception 'Please confirm that you play at your own risk.'; end if;
  b := book_football(p_event, p_choice);
  update bookings set risk_ok = true where id = b.id returning * into b;
  return b;
end $$;
revoke execute on function public.book_football(uuid, text, boolean) from public, anon;
grant execute on function public.book_football(uuid, text, boolean) to authenticated;

-- Each member can add one friend per game, shown as "Friend (Member)". The member pays the £6.
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; v_name text := trim(coalesce(p_name, ''));
begin
  if uid is null then raise exception 'Please sign in to add a friend.'; end if;
  if v_name = '' or length(v_name) > 40 then raise exception 'Enter your friend''s name.'; end if;
  if not coalesce(p_risk, false) then raise exception 'Please confirm your friend is 16 or over and plays at their own risk.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if now() < fb_opens(e.day) then raise exception 'Booking opens on Wednesday at 1pm.'; end if;
  if now() > ((e.day + e.time) at time zone 'Europe/London') then raise exception 'This game has already started.'; end if;
  perform expire_unpaid();
  if exists (select 1 from bookings where event_id = p_event and booked_by = uid and status <> 'cancelled') then
    raise exception 'You can add one friend per game.';
  end if;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and status = 'booked';
  if taken >= e.capacity then raise exception 'All % places are taken.', e.capacity; end if;
  select * into p from profiles where id = uid;
  insert into bookings (event_id, booked_by, display_name, charge, amount, paid, method, code, risk_ok)
  values (p_event, uid, v_name || ' (' || p.name || ')', 'payg', 6, p.family, case when p.family then 'transfer' end, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;
revoke execute on function public.book_friend(uuid, text, boolean) from public, anon;
grant execute on function public.book_friend(uuid, text, boolean) to authenticated;

-- Removing a booking: members can remove themselves or the friend they added. Everyone below moves up.
-- Family members who remove themselves get no credit (they pay by transfer) and aren't added back.
create or replace function public.cancel_booking(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; msg text := 'Removed.'; free int; w bookings; v_family boolean; v_owner uuid;
begin
  select * into b from bookings where id = p_id and status <> 'cancelled';
  if not found then raise exception 'Booking not found.'; end if;
  if b.user_id is distinct from auth.uid() and b.booked_by is distinct from auth.uid() and not is_organiser() then
    raise exception 'You can only cancel your own booking.';
  end if;
  select * into e from events where id = b.event_id;
  v_owner := coalesce(b.user_id, b.booked_by);
  select family into v_family from profiles where id = v_owner;
  v_family := coalesce(v_family, false);
  if e.kind = 'football' and b.user_id is not null and v_family then
    insert into football_family_out (event_id, user_id) values (b.event_id, b.user_id) on conflict do nothing;
  end if;
  if e.kind = 'football' and b.charge = 'payg' and b.paid and b.method <> 'owes' and now() < fb_credit_until(e.day)
     and v_owner is not null and not (v_family and b.method = 'transfer') then
    update profiles set credit = credit + b.amount where id = v_owner;
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

-- Accounts: a friend's unused £6 becomes credit for, and a friend's unpaid £6 is owed by, the member who added them.
create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[]) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and status = 'booked' and checked_in) then
    raise exception 'Tick who turned up under "Who''s turned up" before posting the accounts.';
  end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them).
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  select * into fs from fund_state where id = 1 for update;
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

-- ---------- accounts with actual takings and receipt photos (also in add-accounts-and-offer.sql) ----------
alter table public.accounts_posts add column if not exists images jsonb not null default '[]';

create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[], p_received numeric, p_images jsonb) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_credit numeric; v_noshow numeric; v_name text; v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and status = 'booked' and checked_in) then
    raise exception 'Tick who turned up under "Who''s turned up" before posting the accounts.';
  end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them).
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  -- When the organiser enters what actually came in (Square + transfers + cash/PayPal), that drives the
  -- kitty fund: plus account credit used, minus £6s from no-shows (now held as their credit), minus
  -- owed money cleared (which goes to the events fund).
  if p_received is not null then
    select coalesce(sum(amount) filter (where method = 'credit' and checked_in), 0),
           coalesce(sum(amount) filter (where method in ('card', 'transfer', 'cash') and not checked_in), 0)
      into v_credit, v_noshow
      from bookings where event_id = p_event and status = 'booked' and charge = 'payg' and paid;
    income := p_received + v_credit - v_noshow - v_cleared;
  end if;

  select * into fs from fund_state where id = 1 for update;
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
  insert into accounts_posts (event_id, body, created_by, images) values (p_event, p_body, auth.uid(), coalesce(p_images, '[]'));
  -- Keep a copy in the Football Accounts chat, with the receipt photos.
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body, image)
    values ('football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), p_body, coalesce(p_images, '[]')->>0);
  insert into posts (group_id, user_id, author_name, body, image)
    select 'football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), 'More receipts for ' || d, img
      from jsonb_array_elements_text(coalesce(p_images, '[]')) with ordinality as t(img, n) where n > 1;
  return fs;
end $$;
revoke execute on function public.post_accounts(uuid, text, numeric, numeric, jsonb, uuid[], numeric, jsonb) from public, anon;
grant execute on function public.post_accounts(uuid, text, numeric, numeric, jsonb, uuid[], numeric, jsonb) to authenticated;

-- ---------- pay-and-play price comes from the game (so a game can be offered at £1) ----------
create or replace function public.book_football(p_event uuid, p_choice text) returns public.bookings
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
  if exists (select 1 from football_removed where event_id = p_event and user_id = uid) then
    raise exception 'Your place was released because it wasn''t paid in time, so you can''t rebook this game.';
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
    v_charge := 'payg'; v_amount := e.price;
    if p.family then v_paid := true; v_method := 'transfer';
    elsif p.credit >= e.price then v_paid := true; v_method := 'credit';
      update profiles set credit = credit - e.price where id = uid;
    end if;
  end if;

  if v_charge = 'kitty' then update profiles set kitty_session = fs.session_no where id = uid; end if;

  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, code)
  values (p_event, uid, p.name, v_charge, v_amount, v_paid, v_method, new_code('AA-'))
  returning * into b;
  return b;
end $$;

create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; v_name text := trim(coalesce(p_name, ''));
begin
  if uid is null then raise exception 'Please sign in to add a friend.'; end if;
  if v_name = '' or length(v_name) > 40 then raise exception 'Enter your friend''s name.'; end if;
  if not coalesce(p_risk, false) then raise exception 'Please confirm your friend is 16 or over and plays at their own risk.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if now() < fb_opens(e.day) then raise exception 'Booking opens on Wednesday at 1pm.'; end if;
  if now() > ((e.day + e.time) at time zone 'Europe/London') then raise exception 'This game has already started.'; end if;
  perform expire_unpaid();
  if exists (select 1 from bookings where event_id = p_event and booked_by = uid and status <> 'cancelled') then
    raise exception 'You can add one friend per game.';
  end if;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and status = 'booked';
  if taken >= e.capacity then raise exception 'All % places are taken.', e.capacity; end if;
  select * into p from profiles where id = uid;
  insert into bookings (event_id, booked_by, display_name, charge, amount, paid, method, code, risk_ok)
  values (p_event, uid, v_name || ' (' || p.name || ')', 'payg', e.price, p.family, case when p.family then 'transfer' end, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;

create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state;
begin
  if not is_organiser() then raise exception 'Only organisers can add players.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game are already posted.'; end if;
  if p_method not in ('card', 'transfer', 'cash', 'owes', 'credit') then raise exception 'Choose how they paid.'; end if;
  if p_user is not null then
    select * into p from profiles where id = p_user for update;
    if not found then raise exception 'Member not found.'; end if;
    select * into b from bookings where event_id = p_event and user_id = p_user and status <> 'cancelled';
    if found then
      update bookings set checked_in = true, status = 'booked' where id = b.id returning * into b;
      return b;
    end if;
    select * into fs from fund_state where id = 1;
    if p.kitty_session = fs.session_no then
      insert into bookings (event_id, user_id, display_name, charge, amount, paid, checked_in, code)
      values (p_event, p_user, p.name, 'covered', 0, true, true, new_code('AA-')) returning * into b;
      return b;
    end if;
    if p_method = 'credit' then
      if p.credit < e.price then raise exception '% doesn''t have enough credit.', p.name; end if;
      update profiles set credit = credit - e.price where id = p_user;
    end if;
  elsif coalesce(trim(p_name), '') = '' then raise exception 'Choose a member or type their name.';
  elsif p_method = 'credit' then raise exception 'Only members can pay with credit.';
  end if;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', e.price, p_method <> 'owes', p_method, true, new_code('AA-'))
  returning * into b;
  return b;
end $$;

create or replace function public.add_family_bookings() returns int
language plpgsql security definer set search_path = public as $$
declare e events; fs fund_state; free int; n int := 0; k int;
begin
  select * into fs from fund_state where id = 1;
  for e in select * from events where kind = 'football' and day is not null and not accounts_posted
             and now() >= fb_opens(day) and now() < ((day + time) at time zone 'Europe/London') loop
    select e.capacity - coalesce(sum(places), 0) into free from bookings where event_id = e.id and status = 'booked';
    insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, code, risk_ok)
    select e.id, p.id, p.name,
           case when p.kitty_session = fs.session_no then 'covered' else 'payg' end,
           case when p.kitty_session = fs.session_no then 0 else e.price end,
           true, case when p.kitty_session = fs.session_no then null else 'transfer' end,
           new_code('AA-'), true
      from profiles p
     where p.family and p.approved
       and not exists (select 1 from bookings b where b.event_id = e.id and b.user_id = p.id and b.status <> 'cancelled')
       and not exists (select 1 from football_family_out o where o.event_id = e.id and o.user_id = p.id)
       and not exists (select 1 from football_removed r where r.event_id = e.id and r.user_id = p.id)
     order by p.created_at
     limit greatest(free, 0);
    get diagnostics k = row_count; n := n + k;
  end loop;
  return n;
end $$;

-- Launch offer: the Friday 23 October 2026 game is £1 pay and play when booked in the app.
update public.events set price = 1, time = '21:15' where kind = 'football' and day = '2026-10-23';
insert into public.events (kind, title, day, time, location, details, price, capacity, access)
select 'football', 'Weekly Friday Footie', '2026-10-23', '21:15', 'Goals Beckenham, Elmers End',
  'Launch offer: £1 pay and play when you book in the app. Kitty £15 as usual.', 1, 36, 'members'
where not exists (select 1 from public.events where kind = 'football' and day = '2026-10-23');

-- ---------- third fund: members' credits (also in schema.sql) ----------
-- Money members have paid but not used (paid but didn't play, or cancelled before Friday 6pm) is held
-- in the credits fund. It moves to the kitty fund when they pay for a game from their credit.
alter table public.fund_state add column if not exists credits numeric(10,2) not null default 0;
update public.fund_state set credits = (select coalesce(sum(credit), 0) from public.profiles) where id = 1;
alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits'));
insert into public.ledger (fund, what, amount, balance)
  select 'credits', 'Opening balance: members'' credit', credits, credits from public.fund_state where id = 1;

-- Accounts: what actually came in drives the funds.
--   credits fund: plus pay-and-play money from people who paid but didn't play or cancelled for credit,
--                 minus credit used by people who played (moved to the kitty fund)
--   kitty fund:   money received, less owed money cleared and the money moved into credits,
--                 plus credit used, less pitch hire and card fees
--   events fund:  plus owed money cleared
create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[], p_received numeric, p_images jsonb) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_credit numeric; v_noshow numeric; v_cancel numeric; v_name text;
  v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and status = 'booked' and checked_in) then
    raise exception 'Tick who turned up under "Who''s turned up" before posting the accounts.';
  end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  -- Moved between funds by this game.
  select coalesce(sum(amount) filter (where status = 'booked' and method = 'credit' and checked_in), 0),
         coalesce(sum(amount) filter (where status = 'booked' and method in ('card', 'transfer', 'cash') and not checked_in
                                        and coalesce(user_id, booked_by) is not null), 0),
         coalesce(sum(amount) filter (where status = 'cancelled' and method in ('card', 'transfer', 'cash')), 0)
    into v_credit, v_noshow, v_cancel
    from bookings where event_id = p_event and charge = 'payg' and paid;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them).
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  -- p_received is what actually came in by Square, transfer, cash or PayPal (not credit).
  if p_received is not null then
    income := p_received - v_cleared - v_noshow - v_cancel + v_credit;
  end if;

  select * into fs from fund_state where id = 1 for update;
  if v_noshow + v_cancel > 0 then
    fs.credits := fs.credits + v_noshow + v_cancel;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'credits', 'Football ' || d || ': paid but didn''t play, now credit', v_noshow + v_cancel, fs.credits);
  end if;
  if v_credit > 0 then
    fs.credits := fs.credits - v_credit;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'credits', 'Football ' || d || ': paid from credit, moved to kitty', -v_credit, fs.credits);
  end if;
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

  update fund_state set kitty = fs.kitty, events = fs.events, credits = fs.credits, session_no = fs.session_no, games_played = fs.games_played where id = 1;
  update events set accounts_posted = true where id = p_event;
  insert into accounts_posts (event_id, body, created_by, images) values (p_event, p_body, auth.uid(), coalesce(p_images, '[]'));
  -- Keep a copy in the Football Accounts chat, with the receipt photos.
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body, image)
    values ('football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), p_body, coalesce(p_images, '[]')->>0);
  insert into posts (group_id, user_id, author_name, body, image)
    select 'football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), 'More receipts for ' || d, img
      from jsonb_array_elements_text(coalesce(p_images, '[]')) with ordinality as t(img, n) where n > 1;
  return fs;
end $$;

-- Changing someone's credit by hand also changes the credits fund, with a line in the fund history.
create or replace function public.update_member(p_id uuid, p_role text, p_family boolean, p_credit numeric) returns void
language plpgsql security definer set search_path = public as $$
declare old numeric; v_name text; bal numeric;
begin
  if not is_organiser() then raise exception 'Only organisers can change members.'; end if;
  if p_role is not null and not is_admin() then raise exception 'Only the admin can change roles.'; end if;
  if p_id = auth.uid() and p_role is not null and p_role <> 'admin' then raise exception 'You cannot remove your own admin role.'; end if;
  select credit, name into old, v_name from profiles where id = p_id for update;
  update profiles set
    role = coalesce(p_role, role),
    family = coalesce(p_family, family),
    credit = coalesce(p_credit, credit)
  where id = p_id;
  if p_credit is not null and p_credit <> old then
    update fund_state set credits = credits + (p_credit - old) where id = 1 returning credits into bal;
    insert into ledger (fund, what, amount, balance) values ('credits', 'Credit changed by hand: ' || coalesce(v_name, 'member'), p_credit - old, bal);
  end if;
end $$;

-- The admin can set all three starting funds.
create or replace function public.set_funds(p_kitty numeric, p_events numeric, p_credits numeric, p_session int, p_games int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can set the funds.'; end if;
  update fund_state set kitty = p_kitty, events = p_events, credits = p_credits, session_no = p_session, games_played = p_games where id = 1;
  insert into ledger (fund, what, amount, balance) values
    ('kitty', 'Opening balance', p_kitty, p_kitty), ('events', 'Opening balance', p_events, p_events),
    ('credits', 'Opening balance', p_credits, p_credits);
end $$;
revoke execute on function public.set_funds(numeric, numeric, numeric, int, int) from public, anon;
grant execute on function public.set_funds(numeric, numeric, numeric, int, int) to authenticated;

-- ---------- credits tally: the credits fund always equals the credit on members' accounts (also in schema.sql) ----------
-- Safe to run whether or not add-credits-fund.sql was run before.
alter table public.fund_state add column if not exists credits numeric(10,2) not null default 0;
alter table public.fund_state add column if not exists credits_posted numeric(10,2) not null default 0;  -- credits at the last accounts
alter table public.fund_state add column if not exists posted_at timestamptz not null default now();       -- when the last accounts were posted
alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits'));
update public.fund_state set credits = t.total, credits_posted = t.total, posted_at = now()
  from (select coalesce(sum(credit), 0) total from public.profiles) t where id = 1;
delete from public.ledger where fund = 'credits';
insert into public.ledger (fund, what, amount, balance)
  select 'credits', 'Opening balance: credit on members'' accounts', credits, credits from public.fund_state where id = 1;

-- Every change to someone's credit is recorded in the credits fund, with a reason.
create or replace function public.credit_moved() returns trigger
language plpgsql security definer set search_path = public as $$
declare delta numeric; r text; d date; bal numeric; who text;
begin
  if tg_op = 'DELETE' then delta := -old.credit; who := old.name; r := 'account removed';
  else delta := new.credit - old.credit; who := new.name; r := nullif(current_setting('app.credit_reason', true), '');
  end if;
  if delta = 0 then return null; end if;
  if r is null then
    select day into d from events where kind = 'football' and day is not null and not accounts_posted
     order by day < current_date, day limit 1;
    r := case when delta < 0 then 'credit used to book football' else 'credit added after cancelling football' end
      || coalesce(' ' || to_char(d, 'FMDD Mon'), '');
  end if;
  update fund_state set credits = credits + delta where id = 1 returning credits into bal;
  insert into ledger (fund, what, amount, balance) values ('credits', coalesce(who, 'Member') || ': ' || r, delta, bal);
  return null;
end $$;
revoke execute on function public.credit_moved() from public, anon, authenticated;
drop trigger if exists profiles_credit_moved on public.profiles;
create trigger profiles_credit_moved after update of credit on public.profiles
  for each row when (old.credit is distinct from new.credit) execute function public.credit_moved();
drop trigger if exists profiles_credit_removed on public.profiles;
create trigger profiles_credit_removed after delete on public.profiles
  for each row when (old.credit <> 0) execute function public.credit_moved();

create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[], p_received numeric, p_images jsonb) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_credit numeric; v_noshow numeric; v_cancel numeric; v_name text;
  v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and status = 'booked' and checked_in) then
    raise exception 'Tick who turned up under "Who''s turned up" before posting the accounts.';
  end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  -- Moved between funds by this game.
  select coalesce(sum(amount) filter (where status = 'booked' and method = 'credit' and checked_in), 0),
         coalesce(sum(amount) filter (where status = 'booked' and method in ('card', 'transfer', 'cash') and not checked_in
                                        and coalesce(user_id, booked_by) is not null), 0),
         coalesce(sum(amount) filter (where status = 'cancelled' and method in ('card', 'transfer', 'cash')), 0)
    into v_credit, v_noshow, v_cancel
    from bookings where event_id = p_event and charge = 'payg' and paid;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them). The credits fund follows by trigger.
  perform set_config('app.credit_reason', 'paid but didn''t play at football ' || d || ', credit added', true);
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  perform set_config('app.credit_reason', '', true);
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  -- p_received is what actually came in by Square, transfer, cash or PayPal (not credit).
  if p_received is not null then
    income := p_received - v_cleared - v_noshow - v_cancel + v_credit;
  end if;

  select * into fs from fund_state where id = 1 for update;
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

  update fund_state set kitty = fs.kitty, events = fs.events, session_no = fs.session_no, games_played = fs.games_played,
    credits_posted = credits, posted_at = now() where id = 1;
  update events set accounts_posted = true where id = p_event;
  insert into accounts_posts (event_id, body, created_by, images) values (p_event, p_body, auth.uid(), coalesce(p_images, '[]'));
  -- Keep a copy in the Football Accounts chat, with the receipt photos.
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body, image)
    values ('football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), p_body, coalesce(p_images, '[]')->>0);
  insert into posts (group_id, user_id, author_name, body, image)
    select 'football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), 'More receipts for ' || d, img
      from jsonb_array_elements_text(coalesce(p_images, '[]')) with ordinality as t(img, n) where n > 1;
  return fs;
end $$;

-- Changing someone's credit by hand is recorded (by the trigger) as a hand change.
create or replace function public.update_member(p_id uuid, p_role text, p_family boolean, p_credit numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser() then raise exception 'Only organisers can change members.'; end if;
  if p_role is not null and not is_admin() then raise exception 'Only the admin can change roles.'; end if;
  if p_id = auth.uid() and p_role is not null and p_role <> 'admin' then raise exception 'You cannot remove your own admin role.'; end if;
  perform set_config('app.credit_reason', 'credit changed by hand', true);
  update profiles set
    role = coalesce(p_role, role),
    family = coalesce(p_family, family),
    credit = coalesce(p_credit, credit)
  where id = p_id;
  perform set_config('app.credit_reason', '', true);
end $$;

-- Starting funds: kitty and events only. Credits always come from members' accounts.
create or replace function public.set_funds(p_kitty numeric, p_events numeric, p_credits numeric, p_session int, p_games int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can set the funds.'; end if;
  update fund_state set kitty = p_kitty, events = p_events, session_no = p_session, games_played = p_games where id = 1;
  insert into ledger (fund, what, amount, balance) values
    ('kitty', 'Opening balance', p_kitty, p_kitty), ('events', 'Opening balance', p_events, p_events);
end $$;
revoke execute on function public.set_funds(numeric, numeric, numeric, int, int) from public, anon;
grant execute on function public.set_funds(numeric, numeric, numeric, int, int) to authenticated;
