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
  image text,                                     -- picture as a data URL, shrunk on the phone
  link text,                                      -- e.g. the debate's page in Let's Debate
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

-- ---------- members can pay for their friend from their own credit (also in schema.sql) ----------
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; v_name text := trim(coalesce(p_name, ''));
  v_paid boolean := false; v_method text;
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
  select * into p from profiles where id = uid for update;
  -- family pay by transfer; anyone else with enough credit pays for their friend from it
  if p.family then v_paid := true; v_method := 'transfer';
  elsif e.price > 0 and p.credit >= e.price then
    v_paid := true; v_method := 'credit';
    perform set_config('app.credit_reason', 'credit used to book friend ' || v_name || ' for football ' || to_char(e.day, 'FMDD Mon'), true);
    update profiles set credit = credit - e.price where id = uid;
    perform set_config('app.credit_reason', '', true);
  end if;
  insert into bookings (event_id, booked_by, display_name, charge, amount, paid, method, code, risk_ok)
  values (p_event, uid, v_name || ' (' || p.name || ')', 'payg', e.price, v_paid, v_method, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;

-- ---------- members choose to pay for their friend by card or from their credit (also in schema.sql) ----------
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean, p_credit boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; v_name text := trim(coalesce(p_name, ''));
  v_paid boolean := false; v_method text;
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
  select * into p from profiles where id = uid for update;
  -- family pay by transfer; anyone else can choose to pay for their friend from their credit
  if p.family then v_paid := true; v_method := 'transfer';
  elsif coalesce(p_credit, false) and e.price > 0 then
    if p.credit < e.price then raise exception 'You don''t have enough credit. Pay by card instead.'; end if;
    v_paid := true; v_method := 'credit';
    perform set_config('app.credit_reason', 'credit used to book friend ' || v_name || ' for football ' || to_char(e.day, 'FMDD Mon'), true);
    update profiles set credit = credit - e.price where id = uid;
    perform set_config('app.credit_reason', '', true);
  end if;
  insert into bookings (event_id, booked_by, display_name, charge, amount, paid, method, code, risk_ok)
  values (p_event, uid, v_name || ' (' || p.name || ')', 'payg', e.price, v_paid, v_method, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;
revoke execute on function public.book_friend(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.book_friend(uuid, text, boolean, boolean) to authenticated;

-- The older 3-argument version never uses credit (pay by card).
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean) returns public.bookings
language sql security definer set search_path = public as $$ select book_friend(p_event, p_name, p_risk, false) $$;

-- Pay for a friend already on the roster from your credit, instead of by card.
create or replace function public.pay_friend_credit(p_id uuid) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b bookings; e events; p profiles;
begin
  select * into b from bookings where id = p_id and booked_by = uid and status = 'booked' for update;
  if not found then raise exception 'Booking not found.'; end if;
  if b.paid then raise exception 'Your friend is already paid for.'; end if;
  select * into e from events where id = b.event_id;
  select * into p from profiles where id = uid for update;
  if p.credit < b.amount then raise exception 'You don''t have enough credit.'; end if;
  perform set_config('app.credit_reason', 'credit used to book friend ' || split_part(b.display_name, ' (', 1) || ' for football ' || to_char(e.day, 'FMDD Mon'), true);
  update profiles set credit = credit - b.amount where id = uid;
  perform set_config('app.credit_reason', '', true);
  update bookings set paid = true, method = 'credit' where id = p_id returning * into b;
  return b;
end $$;
revoke execute on function public.pay_friend_credit(uuid) from public, anon;
grant execute on function public.pay_friend_credit(uuid) to authenticated;

-- ---------- friends always pay the full £6 pay and play, even when the game has an offer price (also in schema.sql) ----------
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean, p_credit boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; v_name text := trim(coalesce(p_name, ''));
  v_paid boolean := false; v_method text; v_price numeric;
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
  select * into p from profiles where id = uid for update;
  v_price := greatest(e.price, 6); -- launch offers are for members only
  -- family pay by transfer; anyone else can choose to pay for their friend from their credit
  if p.family then v_paid := true; v_method := 'transfer';
  elsif coalesce(p_credit, false) then
    if p.credit < v_price then raise exception 'You don''t have enough credit. Pay by card instead.'; end if;
    v_paid := true; v_method := 'credit';
    perform set_config('app.credit_reason', 'credit used to book friend ' || v_name || ' for football ' || to_char(e.day, 'FMDD Mon'), true);
    update profiles set credit = credit - v_price where id = uid;
    perform set_config('app.credit_reason', '', true);
  end if;
  insert into bookings (event_id, booked_by, display_name, charge, amount, paid, method, code, risk_ok)
  values (p_event, uid, v_name || ' (' || p.name || ')', 'payg', v_price, v_paid, v_method, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;
revoke execute on function public.book_friend(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.book_friend(uuid, text, boolean, boolean) to authenticated;

-- ---------- people added on the day who aren't members pay the full £6, not the members' offer price (also in schema.sql) ----------
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
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
  -- offer prices are for members; anyone else pays the full £6
  v_price := case when p_user is null then greatest(e.price, 6) else e.price end;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', v_price, p_method <> 'owes', p_method, true, new_code('AA-'))
  returning * into b;
  return b;
end $$;

-- ---------- members (family too) can send their friend a payment link instead of paying (also in schema.sql) ----------
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean, p_credit boolean, p_link boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); e events; p profiles; b bookings; taken int; v_name text := trim(coalesce(p_name, ''));
  v_paid boolean := false; v_method text; v_price numeric;
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
  select * into p from profiles where id = uid for update;
  v_price := greatest(e.price, 6); -- launch offers are for members only
  -- family pay by transfer; anyone else can choose to pay for their friend from their credit
  -- sending the friend a payment link leaves the place unpaid until they pay, family included
  if coalesce(p_link, false) then null;
  elsif p.family then v_paid := true; v_method := 'transfer';
  elsif coalesce(p_credit, false) then
    if p.credit < v_price then raise exception 'You don''t have enough credit. Pay by card instead.'; end if;
    v_paid := true; v_method := 'credit';
    perform set_config('app.credit_reason', 'credit used to book friend ' || v_name || ' for football ' || to_char(e.day, 'FMDD Mon'), true);
    update profiles set credit = credit - v_price where id = uid;
    perform set_config('app.credit_reason', '', true);
  end if;
  insert into bookings (event_id, booked_by, display_name, charge, amount, paid, method, code, risk_ok)
  values (p_event, uid, v_name || ' (' || p.name || ')', 'payg', v_price, v_paid, v_method, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;
revoke execute on function public.book_friend(uuid, text, boolean, boolean, boolean) from public, anon;
grant execute on function public.book_friend(uuid, text, boolean, boolean, boolean) to authenticated;

-- The 4-argument version pays as before (no link).
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean, p_credit boolean) returns public.bookings
language sql security definer set search_path = public as $$ select book_friend(p_event, p_name, p_risk, p_credit, false) $$;
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

-- ---------- football check-in by QR code, and payment links for people added at the pitch (also in schema.sql) ----------

-- ---------- organisers do door duty only (also in schema.sql) ----------
-- is_door(): organisers and the admin, for scanning, who's in, ticking people in and adding people at the pitch.
-- is_organiser() now means the admin only, so everything else organisers could do (events, payments,
-- accounts, members, approving guest bookings, pinning posts) is for the admin.
create or replace function public.is_door() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('organiser', 'admin'))
$$;
create or replace function public.is_organiser() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

-- Ticking someone in (or out) on the football page.
create or replace function public.set_here(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_door() then raise exception 'Only organisers can tick people in.'; end if;
  update bookings b set checked_in = p_on from events e
   where b.id = p_id and e.id = b.event_id and not e.accounts_posted;
end $$;
revoke execute on function public.set_here(uuid, boolean) from public, anon;
grant execute on function public.set_here(uuid, boolean) to authenticated;

-- Organisers can see guests' names in the who's-in list.
drop policy if exists "door staff see guests" on public.guests;
create policy "door staff see guests" on public.guests for select to authenticated using (is_door());


-- Anyone who has turned up (checked in) is never released for not paying; they pay or owe on the day.
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  with x as (
    select b.id, b.event_id, b.user_id, b.charge from bookings b join events e on e.id = b.event_id
     where e.kind = 'football' and not b.paid and b.status = 'booked' and not e.accounts_posted and not b.checked_in
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

-- Organisers adding someone at the pitch can also choose 'link': they're marked here, unpaid, and sent a payment link.
alter table public.bookings add column if not exists pitch_link boolean not null default false;
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
begin
  if not is_door() then raise exception 'Only organisers can add players.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game are already posted.'; end if;
  if p_method not in ('card', 'transfer', 'cash', 'owes', 'credit', 'link') then raise exception 'Choose how they paid.'; end if;
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
  -- offer prices are for members; anyone else pays the full £6
  v_price := case when p_user is null then greatest(e.price, 6) else e.price end;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code, pitch_link)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', v_price, p_method not in ('owes', 'link'),
          nullif(p_method, 'link'), true, new_code('AA-'), p_method = 'link')
  returning * into b;
  return b;
end $$;

-- Check-in details also say what kind of event it is, so football shows kitty or pay and play.
create or replace function public.check_in_details(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; g guests; v_by text; v_was boolean;
begin
  if not is_door() then raise exception 'Only organisers can check people in.'; end if;
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
    'id', b.id, 'code', b.code, 'name', b.display_name, 'status', b.status, 'places', b.places,
    'already', v_was, 'paid', b.paid, 'amount', b.amount, 'method', b.method, 'charge', b.charge,
    'age', coalesce(b.age, g.age), 'gender', b.gender, 'parent_ok', b.parent_ok,
    'title', e.title, 'day', e.day, 'time', e.time, 'kind', e.kind, 'event_id', e.id,
    'guest', g.booking_id is not null, 'guest_name', g.full_name, 'booked_by', v_by);
end $$;
revoke execute on function public.check_in_details(text) from public, anon;
grant execute on function public.check_in_details(text) to authenticated;
-- ---------- the admin removes a member (also in schema.sql) ----------
-- Deletes their account so they can no longer sign in. Their past bookings stay in the
-- history under their name, so old accounts still add up. Any credit they held leaves the
-- credits fund with an "account removed" line (the profiles_credit_removed trigger).
create or replace function public.remove_member(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'Only the admin can remove members.'; end if;
  if p_id = auth.uid() then raise exception 'You cannot remove yourself.'; end if;
  if exists (select 1 from profiles where id = p_id and role = 'admin') then
    raise exception 'Change their role from admin first.';
  end if;
  if exists (select 1 from bookings b join events e on e.id = b.event_id
              where (b.user_id = p_id or b.booked_by = p_id)
                and b.status in ('booked', 'waitlist', 'pending')
                and (e.day is null or e.day >= current_date) and not e.accounts_posted) then
    raise exception 'They have upcoming bookings. Remove them from those first, so any payment or credit is sorted out.';
  end if;
  update bookings set user_id = null where user_id = p_id;
  update bookings set booked_by = null where booked_by = p_id;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.remove_member(uuid) from public, anon;
grant execute on function public.remove_member(uuid) to authenticated;

-- ---------- fund transfers and events accounts (also in add-fund-transfers-and-event-accounts.sql) ----------
-- ---------- moving money between the kitty and events funds ----------

-- Every transfer is kept: who made it, when, and why. To undo one, move the money back with a reason.
create table if not exists public.fund_transfers (
  id bigserial primary key,
  on_date date not null default current_date,
  from_fund text not null check (from_fund in ('kitty', 'events')),
  to_fund text not null check (to_fund in ('kitty', 'events')),
  amount numeric(10,2) not null check (amount > 0),
  reason text not null check (length(trim(reason)) > 0),
  made_by uuid references public.profiles(id) on delete set null,
  made_by_name text not null default '',
  accounts_post_id bigint references public.accounts_posts(id) on delete set null,  -- the accounts that first showed it
  created_at timestamptz not null default now(),
  check (from_fund <> to_fund)
);
alter table public.fund_transfers enable row level security;
revoke insert, update, delete on public.fund_transfers from anon, authenticated;
grant select on public.fund_transfers to authenticated;
drop policy if exists "members see transfers" on public.fund_transfers;
create policy "members see transfers" on public.fund_transfers for select to authenticated using (true);

create or replace function public.transfer_funds(p_from text, p_to text, p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; v_name text; r text := trim(coalesce(p_reason, '')); a numeric := round(coalesce(p_amount, 0), 2); held numeric;
begin
  if not is_admin() then raise exception 'Only the admin can move money between funds.'; end if;
  if p_from is null or p_to is null or p_from not in ('kitty', 'events') or p_to not in ('kitty', 'events') or p_from = p_to then
    raise exception 'Choose two different funds: the kitty fund or the events fund.';
  end if;
  if a <= 0 then raise exception 'Enter an amount over £0.'; end if;
  if r = '' then raise exception 'Give a reason for the transfer.'; end if;
  select * into fs from fund_state where id = 1 for update;
  held := case p_from when 'kitty' then fs.kitty else fs.events end;
  if held < a then raise exception 'The % fund only holds £%.', p_from, held; end if;
  if p_from = 'kitty' then fs.kitty := fs.kitty - a; fs.events := fs.events + a;
  else fs.events := fs.events - a; fs.kitty := fs.kitty + a; end if;
  select name into v_name from profiles where id = auth.uid();
  insert into fund_transfers (from_fund, to_fund, amount, reason, made_by, made_by_name)
    values (p_from, p_to, a, r, auth.uid(), coalesce(v_name, 'Admin'));
  insert into ledger (fund, what, amount, balance) values
    (p_from, 'Transfer to ' || initcap(p_to) || ' fund: ' || r, -a, case p_from when 'kitty' then fs.kitty else fs.events end),
    (p_to, 'Transfer from ' || initcap(p_from) || ' fund: ' || r, a, case p_to when 'kitty' then fs.kitty else fs.events end);
  update fund_state set kitty = fs.kitty, events = fs.events where id = 1;
  return fs;
end $$;
revoke execute on function public.transfer_funds(text, text, numeric, text) from public, anon;
grant execute on function public.transfer_funds(text, text, numeric, text) to authenticated;

-- The next accounts posted (football or an event) list the transfers made since the last ones.
create or replace function public.mark_transfers_shown() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update fund_transfers set accounts_post_id = new.id where accounts_post_id is null;
  return new;
end $$;
drop trigger if exists accounts_posts_mark_transfers on public.accounts_posts;
create trigger accounts_posts_mark_transfers after insert on public.accounts_posts
  for each row execute function public.mark_transfers_shown();

-- ---------- events accounts ----------

-- Receipts (money in) and costs (hiring or ancillary) for an event, each with an optional receipt photo.
create table if not exists public.event_account_lines (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  kind text not null check (kind in ('receipt', 'hiring', 'ancillary')),
  what text not null check (length(trim(what)) > 0),
  amount numeric(10,2) not null check (amount > 0),
  photo text,                                     -- receipt photo as a data URL, shrunk on the phone
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists event_account_lines_event on public.event_account_lines (event_id);
alter table public.event_account_lines enable row level security;
grant select, insert, update, delete on public.event_account_lines to authenticated;
drop policy if exists "members see event lines" on public.event_account_lines;
drop policy if exists "admin adds event lines" on public.event_account_lines;
drop policy if exists "admin edits event lines" on public.event_account_lines;
drop policy if exists "admin removes event lines" on public.event_account_lines;
create policy "members see event lines" on public.event_account_lines for select to authenticated using (true);
-- Lines are locked once the event's accounts are posted.
create policy "admin adds event lines" on public.event_account_lines for insert to authenticated
  with check (is_admin() and not coalesce((select accounts_posted from events where id = event_id), true));
create policy "admin edits event lines" on public.event_account_lines for update to authenticated
  using (is_admin() and not coalesce((select accounts_posted from events where id = event_id), true));
create policy "admin removes event lines" on public.event_account_lines for delete to authenticated
  using (is_admin() and not coalesce((select accounts_posted from events where id = event_id), true));

-- What an event's posted accounts did to the funds.
create table if not exists public.event_accounts (
  event_id uuid primary key references public.events(id) on delete cascade,
  receipts numeric(10,2) not null,
  hiring numeric(10,2) not null,
  ancillary numeric(10,2) not null,
  kitty_before numeric(10,2) not null,             -- at the last posted accounts, before the transfers below
  events_before numeric(10,2) not null,
  transfers jsonb not null default '[]',           -- transfers made since the last posted accounts
  kitty_after numeric(10,2) not null,
  events_after numeric(10,2) not null,
  posted_by uuid references public.profiles(id) on delete set null,
  posted_at timestamptz not null default now()
);
alter table public.event_accounts enable row level security;
revoke insert, update, delete on public.event_accounts from anon, authenticated;
grant select on public.event_accounts to authenticated;
drop policy if exists "members see event accounts" on public.event_accounts;
create policy "members see event accounts" on public.event_accounts for select to authenticated using (true);

-- Chat posts can carry several photos, shown inside the post where it says {photo 1}, {photo 2} and so on.
alter table public.posts add column if not exists images jsonb not null default '[]';

-- Events Accounts: a chat every approved member can read. Only the admin posts.
insert into public.groups (id, name, about, sort, members_only)
values ('events-accounts', 'Events Accounts', 'Accounts for our events, with the receipts. Every approved member can read them; only the admin posts.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;

create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
    or (g in ('football-accounts', 'events-accounts') and exists (select 1 from profiles where id = auth.uid() and approved))
$$;

drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id not in ('football-accounts', 'events-accounts') or is_organiser()) and can_see_group(group_id));

-- Posting an event's accounts: the profit goes into (or the loss comes out of) the events fund.
-- The photos go into the Events Accounts post in this order: receipts, then hiring, then ancillary, oldest first.
create or replace function public.post_event_accounts(p_event uuid, p_body text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; v_name text; d text; rec numeric; hire numeric; anc numeric;
  k_net numeric; e_net numeric; v_transfers jsonb; v_photos jsonb;
begin
  if not is_admin() then raise exception 'Only the admin can post accounts.'; end if;
  select * into e from events where id = p_event for update;
  if not found then raise exception 'Event not found.'; end if;
  if e.kind = 'football' then raise exception 'Football accounts are posted from the Football page.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this event were already posted.'; end if;
  if not exists (select 1 from event_account_lines where event_id = p_event) then raise exception 'Add the receipts and costs first.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The accounts are empty.'; end if;

  select coalesce(sum(amount) filter (where kind = 'receipt'), 0), coalesce(sum(amount) filter (where kind = 'hiring'), 0),
         coalesce(sum(amount) filter (where kind = 'ancillary'), 0)
    into rec, hire, anc from event_account_lines where event_id = p_event;
  select coalesce(jsonb_agg(photo order by case kind when 'receipt' then 1 when 'hiring' then 2 else 3 end, created_at, id), '[]')
    into v_photos from event_account_lines where event_id = p_event and photo is not null;

  select * into fs from fund_state where id = 1 for update;
  -- Transfers since the last posted accounts, so the accounts show the funds before them.
  select coalesce(sum(case when to_fund = 'kitty' then amount else -amount end), 0),
         coalesce(sum(case when to_fund = 'events' then amount else -amount end), 0),
         coalesce(jsonb_agg(jsonb_build_object('on_date', on_date, 'from', from_fund, 'to', to_fund, 'amount', amount, 'reason', reason) order by id), '[]')
    into k_net, e_net, v_transfers from fund_transfers where accounts_post_id is null;

  d := e.title || ' ' || coalesce(to_char(e.day, 'FMDD Mon YYYY'), '(date to be confirmed)');
  if rec > 0 then
    fs.events := fs.events + rec;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), 'events', d || ': receipts', rec, fs.events);
  end if;
  if hire > 0 then
    fs.events := fs.events - hire;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), 'events', d || ': hiring costs', -hire, fs.events);
  end if;
  if anc > 0 then
    fs.events := fs.events - anc;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), 'events', d || ': ancillary costs', -anc, fs.events);
  end if;
  update fund_state set events = fs.events where id = 1;
  update events set accounts_posted = true where id = p_event;

  insert into event_accounts (event_id, receipts, hiring, ancillary, kitty_before, events_before, transfers, kitty_after, events_after, posted_by)
    values (p_event, rec, hire, anc, fs.kitty - k_net, fs.events - (rec - hire - anc) - e_net, v_transfers, fs.kitty, fs.events, auth.uid());
  insert into accounts_posts (event_id, body, created_by) values (p_event, p_body, auth.uid());
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body, images)
    values ('events-accounts', auth.uid(), coalesce(v_name, 'Admin'), p_body, v_photos);
  return fs;
end $$;
revoke execute on function public.post_event_accounts(uuid, text) from public, anon;
grant execute on function public.post_event_accounts(uuid, text) to authenticated;

-- ---------- members choose to use (part of) their credit (also in add-part-credit.sql) ----------

-- How much of a booking's price came from the member's credit (all of it when method = 'credit').
alter table public.bookings add column if not exists credit_used numeric(8,2) not null default 0;
update public.bookings set credit_used = amount where method = 'credit' and credit_used = 0 and amount > 0;

-- Booking football with a choice: p_use_credit uses as much credit as they have, up to the price,
-- for pay and play or the kitty. Anything left is paid by card or transfer as usual.
create or replace function public.book_football(p_event uuid, p_choice text, p_risk boolean, p_use_credit boolean) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  e events; p profiles; fs fund_state; b bookings;
  taken int; v_charge text; v_amount numeric := 0; v_paid boolean := false; v_method text; v_used numeric := 0;
begin
  if uid is null then raise exception 'Please sign in to book football.'; end if;
  if not coalesce(p_risk, false) then raise exception 'Please confirm that you play at your own risk.'; end if;
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
  else
    v_charge := case when p_choice = 'kitty' then 'kitty' else 'payg' end;
    v_amount := case when v_charge = 'kitty' then 15 else e.price end;
    if p.family then v_paid := true; v_method := 'transfer';
    elsif coalesce(p_use_credit, false) and p.credit > 0 and v_amount > 0 then
      v_used := least(p.credit, v_amount);
      perform set_config('app.credit_reason', 'credit used for football ' || to_char(e.day, 'FMDD Mon')
        || case when v_charge = 'kitty' then ' (kitty)' else '' end, true);
      update profiles set credit = credit - v_used where id = uid;
      perform set_config('app.credit_reason', '', true);
      if v_used >= v_amount then v_paid := true; v_method := 'credit'; end if;
    end if;
  end if;

  if v_charge = 'kitty' then update profiles set kitty_session = fs.session_no where id = uid; end if;

  insert into bookings (event_id, user_id, display_name, charge, amount, credit_used, paid, method, code, risk_ok)
  values (p_event, uid, p.name, v_charge, v_amount, v_used, v_paid, v_method, new_code('AA-'), true)
  returning * into b;
  return b;
end $$;
revoke execute on function public.book_football(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.book_football(uuid, text, boolean, boolean) to authenticated;

-- Part-paid places that are released for not paying the rest by the deadline get their credit back.
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  perform set_config('app.credit_reason', 'credit returned, place released for not paying', true);
  with x as (
    select b.id, b.event_id, b.user_id, b.charge, b.credit_used from bookings b join events e on e.id = b.event_id
     where e.kind = 'football' and not b.paid and b.status = 'booked' and not e.accounts_posted and not b.checked_in
       and now() > greatest(fb_pay_by(e.day), b.created_at + interval '30 minutes')
  ), k as (
    update profiles p set kitty_session = case when y.kitty and p.kitty_session = s then null else p.kitty_session end,
                          credit = p.credit + y.amt
      from (select user_id, bool_or(charge = 'kitty') kitty, sum(credit_used) amt from x where user_id is not null group by user_id) y
     where y.user_id = p.id
  ), r as (
    insert into football_removed (event_id, user_id) select event_id, user_id from x where user_id is not null on conflict do nothing
  )
  delete from bookings where id in (select id from x);
  get diagnostics n = row_count;
  perform set_config('app.credit_reason', '', true);
  perform add_family_bookings();
  return n;
end $$;

-- Cancelling: a paid pay-and-play place before Friday 6pm still becomes credit (the whole price).
-- A place that isn't fully paid gives back just the credit that went into it.
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
    if not b.paid and b.credit_used > 0 and v_owner is not null then
      perform set_config('app.credit_reason', 'credit returned after removing an unpaid football place', true);
      update profiles set credit = credit + b.credit_used where id = v_owner;
      perform set_config('app.credit_reason', '', true);
      msg := 'Removed. £' || b.credit_used || ' credit given back.';
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

-- Accounts: part-credit places. Credit counts as received (moved to the kitty) for people who played and kitty joiners;
-- only the money part of a no-show or cancelled place goes to credits from the takings; debts are what is left after credit.
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
  -- Credit that went into places that count (people who played, and kitty joiners), whole or part paid.
  select coalesce(sum(case when method = 'credit' then amount else credit_used end), 0) into v_credit
    from bookings where event_id = p_event and status = 'booked' and charge in ('payg', 'kitty')
     and (charge = 'kitty' or checked_in) and (method = 'credit' or credit_used > 0);
  -- Money (not credit) from people who paid but didn't play, or cancelled for credit.
  select coalesce(sum(amount - credit_used) filter (where status = 'booked' and method in ('card', 'transfer', 'cash') and not checked_in
                                        and coalesce(user_id, booked_by) is not null), 0),
         coalesce(sum(amount - credit_used) filter (where status = 'cancelled' and method in ('card', 'transfer', 'cash')), 0)
    into v_noshow, v_cancel
    from bookings where event_id = p_event and charge = 'payg' and paid;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them). The credits fund follows by trigger.
  perform set_config('app.credit_reason', 'paid but didn''t play at football ' || d || ', credit added', true);
  -- Someone who used part of their credit but never paid the rest and didn't play gets that credit back.
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(case when paid then amount else credit_used end) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and not checked_in
             and ((paid and method in ('card', 'transfer', 'cash', 'credit')) or (not paid and credit_used > 0))
             and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  perform set_config('app.credit_reason', '', true);
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount - credit_used, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in) and amount > credit_used;
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

-- ---------- transfers posted to both accounts chats (also in add-transfer-posts.sql) ----------

alter table public.fund_transfers add column if not exists posted boolean not null default false;

-- The chat post for one transfer, with both funds' values straight after it.
create or replace function public.transfer_post_body(t public.fund_transfers, p_kitty numeric, p_events numeric) returns text
language sql immutable set search_path = public as $$
  select '**Transfer between funds**' || chr(10)
    || '£' || to_char(t.amount, 'FM999990.00') || ' from the ' || initcap(t.from_fund) || ' fund to the ' || initcap(t.to_fund) || ' fund' || chr(10)
    || 'Reason: ' || t.reason || chr(10)
    || coalesce('Kitty fund now £' || to_char(p_kitty, 'FM999990.00') || chr(10), '')
    || coalesce('Events fund now £' || to_char(p_events, 'FM999990.00') || chr(10), '')
    || 'By ' || coalesce(nullif(t.made_by_name, ''), 'Admin') || ', ' || to_char(t.on_date, 'FMDy FMDD Mon')
$$;

create or replace function public.transfer_funds(p_from text, p_to text, p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; t fund_transfers; v_name text; r text := trim(coalesce(p_reason, '')); a numeric := round(coalesce(p_amount, 0), 2); held numeric;
begin
  if not is_admin() then raise exception 'Only the admin can move money between funds.'; end if;
  if p_from is null or p_to is null or p_from not in ('kitty', 'events') or p_to not in ('kitty', 'events') or p_from = p_to then
    raise exception 'Choose two different funds: the kitty fund or the events fund.';
  end if;
  if a <= 0 then raise exception 'Enter an amount over £0.'; end if;
  if r = '' then raise exception 'Give a reason for the transfer.'; end if;
  select * into fs from fund_state where id = 1 for update;
  held := case p_from when 'kitty' then fs.kitty else fs.events end;
  if held < a then raise exception 'The % fund only holds £%.', p_from, held; end if;
  if p_from = 'kitty' then fs.kitty := fs.kitty - a; fs.events := fs.events + a;
  else fs.events := fs.events - a; fs.kitty := fs.kitty + a; end if;
  select name into v_name from profiles where id = auth.uid();
  insert into fund_transfers (from_fund, to_fund, amount, reason, made_by, made_by_name, posted)
    values (p_from, p_to, a, r, auth.uid(), coalesce(v_name, 'Admin'), true) returning * into t;
  insert into ledger (fund, what, amount, balance) values
    (p_from, 'Transfer to ' || initcap(p_to) || ' fund: ' || r, -a, case p_from when 'kitty' then fs.kitty else fs.events end),
    (p_to, 'Transfer from ' || initcap(p_from) || ' fund: ' || r, a, case p_to when 'kitty' then fs.kitty else fs.events end);
  update fund_state set kitty = fs.kitty, events = fs.events where id = 1;
  -- Everyone sees it in both accounts chats.
  insert into posts (group_id, user_id, author_name, body)
    select g, auth.uid(), coalesce(v_name, 'Admin'), transfer_post_body(t, fs.kitty, fs.events)
      from unnest(array['football-accounts', 'events-accounts']) g;
  return fs;
end $$;
revoke execute on function public.transfer_funds(text, text, numeric, text) from public, anon;
grant execute on function public.transfer_funds(text, text, numeric, text) to authenticated;

-- Post the transfers made before this, dated when they were made, with the fund values the ledger recorded then.
insert into public.posts (group_id, user_id, author_name, body, created_at)
  select g, t.made_by, coalesce(nullif(t.made_by_name, ''), 'Admin'),
         transfer_post_body(t,
           (select l.balance from ledger l where l.fund = 'kitty' and l.created_at = t.created_at and l.what = case when l.fund = t.from_fund
             then 'Transfer to ' || initcap(t.to_fund) || ' fund: ' || t.reason else 'Transfer from ' || initcap(t.from_fund) || ' fund: ' || t.reason end order by l.id desc limit 1),
           (select l.balance from ledger l where l.fund = 'events' and l.created_at = t.created_at and l.what = case when l.fund = t.from_fund
             then 'Transfer to ' || initcap(t.to_fund) || ' fund: ' || t.reason else 'Transfer from ' || initcap(t.from_fund) || ' fund: ' || t.reason end order by l.id desc limit 1)),
         t.created_at
    from public.fund_transfers t cross join unnest(array['football-accounts', 'events-accounts']) g
   where not t.posted;
update public.fund_transfers set posted = true where not posted;

-- ---------- football money into the events fund summarised in Events Accounts (also in add-football-to-events-posts.sql) ----------

create or replace function public.post_football_to_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events; amt numeric; bal numeric; v_name text;
begin
  select * into e from events where id = new.event_id;
  if not found or e.kind <> 'football' then return new; end if;
  -- post_accounts writes its ledger rows earlier in the same transaction, so they share this timestamp.
  select coalesce(sum(amount), 0) into amt from ledger
   where fund = 'events' and created_at = now() and what not like 'Transfer %';
  if amt = 0 then return new; end if;
  select events into bal from fund_state where id = 1;
  select name into v_name from profiles where id = new.created_by;
  insert into posts (group_id, user_id, author_name, body) values ('events-accounts', new.created_by, coalesce(v_name, 'Admin'),
    case when amt > 0 then 'Received £' || to_char(amt, 'FM999990.00') || ' from the football kitty account'
         else 'Paid £' || to_char(-amt, 'FM999990.00') || ' to the football kitty account' end
    || ' (Football ' || to_char(e.day, 'FMDD Mon') || ').' || chr(10)
    || 'Events fund now £' || to_char(bal, 'FM999990.00') || chr(10)
    || 'See the Football Accounts chat for details.');
  return new;
end $$;
revoke execute on function public.post_football_to_events() from public, anon, authenticated;
drop trigger if exists accounts_posts_football_to_events on public.accounts_posts;
create trigger accounts_posts_football_to_events after insert on public.accounts_posts
  for each row execute function public.post_football_to_events();

-- ---------- new member offer (also in add-intro-offer.sql) ----------
-- The switch, and from when new members count (from the app's launch, so everyone who hasn't played yet).
-- Only switched on the first time this file runs.
do $$ begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fund_state' and column_name = 'intro_offer') then
    alter table public.fund_state add column intro_offer boolean not null default false;
    alter table public.fund_state add column intro_since timestamptz;
    update public.fund_state set intro_offer = true, intro_since = '2026-10-01' where id = 1;
  end if;
end $$;

-- How much of a £1 first game the events fund pays (the normal price less the £1).
alter table public.bookings add column if not exists intro_cover numeric(8,2) not null default 0;

-- Gets the offer: joined since it was switched on, and hasn't played a game yet (and isn't booked on one now).
-- Someone who booked but didn't turn up, or cancelled, still gets it next time.
create or replace function public.intro_offer_for(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(fs.intro_offer and p.created_at >= fs.intro_since, false)
     and not exists (select 1 from bookings b join events e on e.id = b.event_id
                      where e.kind = 'football' and b.user_id = p.id and b.status = 'booked'
                        and (b.checked_in or not e.accounts_posted))
    from fund_state fs, profiles p where fs.id = 1 and p.id = p_user
$$;
revoke execute on function public.intro_offer_for(uuid) from public, anon, authenticated;

-- For the booking screen: does the signed-in member get the £1 first game?
create or replace function public.my_intro_offer() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(intro_offer_for(auth.uid()), false)
$$;
revoke execute on function public.my_intro_offer() from public, anon;
grant execute on function public.my_intro_offer() to authenticated;

-- Every way a member gets a pay-and-play place (booking, added on the day, family) goes through here.
-- Friends and non-members never get it: they always pay the full price.
create or replace function public.apply_intro_offer() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events; spent numeric; keep numeric;
begin
  if new.user_id is null or new.booked_by is not null or new.charge <> 'payg' then return new; end if;
  select * into e from events where id = new.event_id;
  if not found or e.kind <> 'football' or e.price <= 1 or new.amount <> e.price then return new; end if;
  if not intro_offer_for(new.user_id) then return new; end if;
  -- credit already taken for the full price: keep £1 of it at most and give the rest back
  spent := case when new.method = 'credit' then new.amount else coalesce(new.credit_used, 0) end;
  new.intro_cover := new.amount - 1;
  new.amount := 1;
  if spent > 0 then
    keep := least(spent, 1);
    if spent > keep then
      perform set_config('app.credit_reason', 'credit given back, first game is £1 (new member offer)', true);
      update profiles set credit = credit + (spent - keep) where id = new.user_id;
      perform set_config('app.credit_reason', '', true);
    end if;
    new.credit_used := keep;
    if keep >= 1 then new.paid := true; new.method := 'credit'; end if;
  end if;
  return new;
end $$;
revoke execute on function public.apply_intro_offer() from public, anon, authenticated;
drop trigger if exists bookings_intro_offer on public.bookings;
create trigger bookings_intro_offer before insert on public.bookings
  for each row execute function public.apply_intro_offer();

-- The admin's on/off switch. Switching it back on starts again from that moment.
create or replace function public.set_intro_offer(p_on boolean) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state;
begin
  if not is_admin() then raise exception 'Only the admin can change the new member offer.'; end if;
  update fund_state set intro_since = case when p_on and not intro_offer then now() else intro_since end,
                        intro_offer = coalesce(p_on, false)
   where id = 1 returning * into fs;
  return fs;
end $$;
revoke execute on function public.set_intro_offer(boolean) from public, anon;
grant execute on function public.set_intro_offer(boolean) to authenticated;

-- Accounts: same as add-part-credit.sql, plus the events fund paying the rest of new members' £1 first games.
create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[], p_received numeric, p_images jsonb) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_credit numeric; v_noshow numeric; v_cancel numeric; v_name text;
  v_cleared numeric; x numeric; k text; v text; d text; v_intro numeric; v_intro_n int;
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
  -- Credit that went into places that count (people who played, and kitty joiners), whole or part paid.
  select coalesce(sum(case when method = 'credit' then amount else credit_used end), 0) into v_credit
    from bookings where event_id = p_event and status = 'booked' and charge in ('payg', 'kitty')
     and (charge = 'kitty' or checked_in) and (method = 'credit' or credit_used > 0);
  -- Money (not credit) from people who paid but didn't play, or cancelled for credit.
  select coalesce(sum(amount - credit_used) filter (where status = 'booked' and method in ('card', 'transfer', 'cash') and not checked_in
                                        and coalesce(user_id, booked_by) is not null), 0),
         coalesce(sum(amount - credit_used) filter (where status = 'cancelled' and method in ('card', 'transfer', 'cash')), 0)
    into v_noshow, v_cancel
    from bookings where event_id = p_event and charge = 'payg' and paid;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them). The credits fund follows by trigger.
  perform set_config('app.credit_reason', 'paid but didn''t play at football ' || d || ', credit added', true);
  -- Someone who used part of their credit but never paid the rest and didn't play gets that credit back.
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(case when paid then amount else credit_used end) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and not checked_in
             and ((paid and method in ('card', 'transfer', 'cash', 'credit')) or (not paid and credit_used > 0))
             and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  perform set_config('app.credit_reason', '', true);
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount - credit_used, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in) and amount > credit_used;
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  -- p_received is what actually came in by Square, transfer, cash or PayPal (not credit).
  if p_received is not null then
    income := p_received - v_cleared - v_noshow - v_cancel + v_credit;
  end if;

  select * into fs from fund_state where id = 1 for update;
  fs.kitty := fs.kitty + income;
  insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': money received', income, fs.kitty);
  -- New members who played their first game for £1: the events fund pays the rest of the price into the kitty.
  select coalesce(sum(intro_cover), 0), count(*) into v_intro, v_intro_n from bookings
   where event_id = p_event and status = 'booked' and charge = 'payg' and checked_in and intro_cover > 0;
  if v_intro > 0 then
    fs.kitty := fs.kitty + v_intro;
    fs.events := fs.events - v_intro;
    insert into ledger (on_date, fund, what, amount, balance) values
      (e.day, 'kitty', 'Football ' || d || ': new member offer paid by the events fund (' || v_intro_n || ')', v_intro, fs.kitty),
      (e.day, 'events', 'Football ' || d || ': new member offer, first game for ' || v_intro_n || ' new member' || case when v_intro_n = 1 then '' else 's' end, -v_intro, fs.events);
  end if;
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
-- Events Accounts chat: the new member offer gets its own line, apart from other football money.
create or replace function public.post_football_to_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events; amt numeric; intro numeric; n int; bal numeric; v_name text; body text := '';
begin
  select * into e from events where id = new.event_id;
  if not found or e.kind <> 'football' then return new; end if;
  -- post_accounts writes its ledger rows earlier in the same transaction, so they share this timestamp.
  select coalesce(sum(amount) filter (where what not like '%new member offer%'), 0),
         coalesce(-sum(amount) filter (where what like '%new member offer%'), 0)
    into amt, intro from ledger
   where fund = 'events' and created_at = now() and what not like 'Transfer %';
  if amt = 0 and intro = 0 then return new; end if;
  select events into bal from fund_state where id = 1;
  select name into v_name from profiles where id = new.created_by;
  if amt <> 0 then
    body := case when amt > 0 then 'Received £' || to_char(amt, 'FM999990.00') || ' from the football kitty account'
                 else 'Paid £' || to_char(-amt, 'FM999990.00') || ' to the football kitty account' end
            || ' (Football ' || to_char(e.day, 'FMDD Mon') || ').' || chr(10);
  end if;
  if intro > 0 then
    select count(*) into n from bookings where event_id = e.id and status = 'booked' and checked_in and intro_cover > 0;
    body := body || 'Paid £' || to_char(intro, 'FM999990.00') || ' to the football kitty account for the new member offer: '
            || n || ' new member' || case when n = 1 then '' else 's' end || ' played their first game for £1 (Football '
            || to_char(e.day, 'FMDD Mon') || ').' || chr(10);
  end if;
  insert into posts (group_id, user_id, author_name, body) values ('events-accounts', new.created_by, coalesce(v_name, 'Admin'),
    body || 'Events fund now £' || to_char(bal, 'FM999990.00') || chr(10) || 'See the Football Accounts chat for details.');
  return new;
end $$;
revoke execute on function public.post_football_to_events() from public, anon, authenticated;
drop trigger if exists accounts_posts_football_to_events on public.accounts_posts;
create trigger accounts_posts_football_to_events after insert on public.accounts_posts
  for each row execute function public.post_football_to_events();

-- ===== add-kitty-topup.sql =====
-- Kitty top-up at the pitch. An organiser adding someone can choose £6 pay and play, £15 to join the kitty,
-- or a top-up for a member already on the list who paid pay and play: they pay the rest (£9 on a £6 place)
-- and their place becomes a kitty place. What they paid first stays with its own method; the top-up keeps its own.
-- Run in the Supabase SQL editor. The app keeps working on the old version until the update is published.
alter table public.bookings add column if not exists topup numeric(8,2) not null default 0;
alter table public.bookings add column if not exists topup_method text;

create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text, p_choice text)
returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
begin
  if not is_door() then raise exception 'Only organisers can add players.'; end if;
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
      if p_method in ('owes', 'link', 'credit') then raise exception 'A top-up can be paid by card, transfer or cash.'; end if;
      if not b.paid or b.method in ('owes', 'credit') then
        -- nothing paid yet, or paid from credit: that credit stays as credit used, and the rest is paid now
        update bookings set charge = 'kitty', amount = 15, intro_cover = 0, method = p_method, paid = true,
                            credit_used = case when b.paid and b.method = 'credit' then b.amount else b.credit_used end,
                            checked_in = true, status = 'booked', pitch_link = false where id = b.id returning * into b;
      else
        update bookings set charge = 'kitty', amount = 15, intro_cover = 0, topup = 15 - b.amount, topup_method = p_method,
                            checked_in = true, status = 'booked' where id = b.id returning * into b;
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
-- =====================================================================
--  Square check, the BR3 Family Events fund and where the money is held
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
--
--  * Every Square payment is kept with what was paid, Square's fee and the net,
--    matched to its booking or to the Family Events subscription.
--  * A fourth fund, BR3 Family Events. Each weekly subscription payment goes in
--    by itself as a receipt, with Square's fee taken off.
--  * Cash in hand and money in the bank (Starling) are tracked until they are
--    moved into Square, so the Square balance can be checked against all funds.
-- =====================================================================

-- ---------- the Family Events fund and the money held outside Square ----------

alter table public.fund_state add column if not exists family numeric(10,2) not null default 0;
alter table public.fund_state add column if not exists held_cash numeric(10,2) not null default 0;   -- cash taken and not yet paid into Square
alter table public.fund_state add column if not exists held_bank numeric(10,2) not null default 0;   -- transfers in the bank (Starling), not yet moved into Square
alter table public.fund_state add column if not exists square_balance numeric(10,2);                 -- the Square balance, as last typed in
alter table public.fund_state add column if not exists square_balance_at timestamptz;
alter table public.fund_state add column if not exists square_from date not null default date '2026-10-23';  -- games and events from this day count as "not yet in accounts"

alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits', 'family'));

-- ---------- Square payments ----------

create table if not exists public.square_payments (
  id text primary key,                            -- Square payment id
  paid_at timestamptz not null,
  status text not null,
  gross numeric(10,2) not null default 0,         -- what the person paid
  fee numeric(10,2) not null default 0,           -- what Square kept
  refunded numeric(10,2) not null default 0,
  order_id text,
  note text not null default '',
  source text not null default '',                -- CARD, WALLET, CASH, EXTERNAL ...
  kind text not null default 'other' check (kind in ('booking', 'subscription', 'other')),
  booking_id uuid references public.bookings(id) on delete set null,
  label text not null default '',                 -- who or what it was for
  posted_gross numeric(10,2) not null default 0,  -- what has gone into the Family Events fund so far
  posted_fee numeric(10,2) not null default 0,
  updated_at timestamptz not null default now()
);
create index if not exists square_payments_paid_at on public.square_payments (paid_at);
create index if not exists square_payments_order on public.square_payments (order_id);
alter table public.square_payments enable row level security;
revoke insert, update, delete on public.square_payments from anon, authenticated;
grant select on public.square_payments to authenticated;
drop policy if exists "door sees square payments" on public.square_payments;
create policy "door sees square payments" on public.square_payments for select to authenticated using (is_door());

-- Which Square orders belong to a subscription, so its payments are known without asking Square again.
create table if not exists public.square_sub_orders (
  order_id text primary key,
  invoice_id text,
  subscription_id text,
  label text not null default ''
);
alter table public.square_sub_orders enable row level security;
revoke all on public.square_sub_orders from anon, authenticated;

-- Records a payment from Square (called by the server only). Subscription payments go into the
-- Family Events fund: the amount paid as a receipt, then Square's fee once Square reports it.
create or replace function public.apply_square_payment(p jsonb) returns public.square_payments
language plpgsql security definer set search_path = public as $$
declare r square_payments; fs fund_state; dg numeric; df numeric; v_ok boolean;
begin
  insert into square_payments (id, paid_at, status, gross, fee, refunded, order_id, note, source, kind, booking_id, label, updated_at)
  values (p->>'id', (p->>'paid_at')::timestamptz, p->>'status', coalesce((p->>'gross')::numeric, 0), coalesce((p->>'fee')::numeric, 0),
          coalesce((p->>'refunded')::numeric, 0), p->>'order_id', coalesce(p->>'note', ''), coalesce(p->>'source', ''),
          coalesce(p->>'kind', 'other'), nullif(p->>'booking_id', '')::uuid, coalesce(p->>'label', ''), now())
  on conflict (id) do update set status = excluded.status, gross = excluded.gross, fee = excluded.fee, refunded = excluded.refunded,
    order_id = excluded.order_id, note = excluded.note, source = excluded.source, kind = excluded.kind,
    booking_id = coalesce(excluded.booking_id, square_payments.booking_id), label = excluded.label, updated_at = now()
  returning * into r;

  if r.kind = 'subscription' then
    v_ok := r.status = 'COMPLETED';
    dg := case when v_ok then r.gross - r.refunded else 0 end - r.posted_gross;
    df := case when v_ok then r.fee else 0 end - r.posted_fee;
    if dg <> 0 or df <> 0 then
      select * into fs from fund_state where id = 1 for update;
      if dg <> 0 then
        fs.family := fs.family + dg;
        insert into ledger (on_date, fund, what, amount, balance)
          values ((r.paid_at at time zone 'Europe/London')::date, 'family', r.label || case when dg > 0 then ': paid' else ': refunded or cancelled' end, dg, fs.family);
      end if;
      if df <> 0 then
        fs.family := fs.family - df;
        insert into ledger (on_date, fund, what, amount, balance)
          values ((r.paid_at at time zone 'Europe/London')::date, 'family', r.label || ': Square fee', -df, fs.family);
      end if;
      update fund_state set family = fs.family where id = 1;
      update square_payments set posted_gross = posted_gross + dg, posted_fee = posted_fee + df where id = r.id returning * into r;
    end if;
  end if;
  return r;
end $$;
revoke execute on function public.apply_square_payment(jsonb) from public, anon, authenticated;
grant execute on function public.apply_square_payment(jsonb) to service_role;

-- ---------- Family Events fund: money in and out by hand ----------

-- A positive amount is money in (or the opening balance), a negative amount is money spent.
create or replace function public.family_entry(p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; a numeric := round(coalesce(p_amount, 0), 2); r text := trim(coalesce(p_reason, ''));
begin
  if not is_admin() then raise exception 'Only the admin can change the Family Events fund.'; end if;
  if a = 0 then raise exception 'Enter an amount.'; end if;
  if r = '' then raise exception 'Give a reason.'; end if;
  select * into fs from fund_state where id = 1 for update;
  fs.family := fs.family + a;
  insert into ledger (fund, what, amount, balance) values ('family', r, a, fs.family);
  update fund_state set family = fs.family where id = 1;
  return fs;
end $$;
revoke execute on function public.family_entry(numeric, text) from public, anon;
grant execute on function public.family_entry(numeric, text) to authenticated;

-- ---------- where the money is: cash in hand, bank (Starling), Square ----------

create table if not exists public.money_moves (
  id bigserial primary key,
  on_date date not null default current_date,
  from_place text not null check (from_place in ('cash', 'bank', 'square', 'count')),
  to_place text not null check (to_place in ('cash', 'bank', 'square')),
  amount numeric(10,2) not null,
  reason text not null default '',
  made_by_name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.money_moves enable row level security;
revoke insert, update, delete on public.money_moves from anon, authenticated;
grant select on public.money_moves to authenticated;
drop policy if exists "members see money moves" on public.money_moves;
create policy "members see money moves" on public.money_moves for select to authenticated using (true);

-- Cash and transfer payments are counted as held outside Square the moment they are marked paid.
-- Card and credit payments are not: card money is already in Square, and credit was paid earlier.
create or replace function public.booking_held(b bookings, out cash numeric, out bank numeric)
language plpgsql immutable as $$
declare base numeric;
begin
  cash := 0; bank := 0;
  if b.id is null then return; end if;
  base := coalesce(b.amount, 0) - coalesce(b.topup, 0) - coalesce(b.credit_used, 0) - coalesce(b.intro_cover, 0);
  if b.paid and base > 0 then
    if b.method = 'cash' then cash := cash + base; elsif b.method = 'transfer' then bank := bank + base; end if;
  end if;
  if coalesce(b.topup, 0) > 0 then
    if b.topup_method = 'cash' then cash := cash + b.topup; elsif b.topup_method = 'transfer' then bank := bank + b.topup; end if;
  end if;
end $$;

create or replace function public.track_held_money() returns trigger
language plpgsql security definer set search_path = public as $$
declare n record; o record; dc numeric; db numeric;
begin
  -- new is empty when a booking is deleted, and old is empty when one is added
  select * into n from booking_held(new);
  select * into o from booking_held(old);
  dc := n.cash - o.cash; db := n.bank - o.bank;
  if dc <> 0 or db <> 0 then
    update fund_state set held_cash = held_cash + dc, held_bank = held_bank + db where id = 1;
  end if;
  return null;
end $$;
drop trigger if exists bookings_track_held on public.bookings;
create trigger bookings_track_held after insert or update or delete on public.bookings
  for each row execute function public.track_held_money();

-- Moving money between places (e.g. cash paid into Square, Starling to Square), or setting
-- cash in hand / the bank to a counted figure (from 'count').
create or replace function public.move_money(p_from text, p_to text, p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; a numeric := round(coalesce(p_amount, 0), 2); v_name text; held numeric;
begin
  if not is_admin() then raise exception 'Only the admin can record where the money is.'; end if;
  if p_to not in ('cash', 'bank', 'square') or p_from not in ('cash', 'bank', 'square', 'count') or p_from = p_to then
    raise exception 'Choose where the money came from and where it went.';
  end if;
  select * into fs from fund_state where id = 1 for update;
  if p_from = 'count' then
    if p_to = 'square' then raise exception 'Type the Square balance in instead.'; end if;
    if a < 0 then raise exception 'Enter £0 or more.'; end if;
    held := case p_to when 'cash' then fs.held_cash else fs.held_bank end;
    if p_to = 'cash' then fs.held_cash := a; else fs.held_bank := a; end if;
    a := a - held;  -- the change, for the history
  else
    if a <= 0 then raise exception 'Enter an amount over £0.'; end if;
    if p_from = 'cash' then fs.held_cash := fs.held_cash - a; elsif p_from = 'bank' then fs.held_bank := fs.held_bank - a; end if;
    if p_to = 'cash' then fs.held_cash := fs.held_cash + a; elsif p_to = 'bank' then fs.held_bank := fs.held_bank + a; end if;
  end if;
  select name into v_name from profiles where id = auth.uid();
  insert into money_moves (from_place, to_place, amount, reason, made_by_name) values (p_from, p_to, a, trim(coalesce(p_reason, '')), coalesce(v_name, 'Admin'));
  update fund_state set held_cash = fs.held_cash, held_bank = fs.held_bank where id = 1;
  return fs;
end $$;
revoke execute on function public.move_money(text, text, numeric, text) from public, anon;
grant execute on function public.move_money(text, text, numeric, text) to authenticated;

create or replace function public.set_square_balance(p_amount numeric) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state;
begin
  if not is_door() then raise exception 'Only organisers can enter the Square balance.'; end if;
  if p_amount is null then raise exception 'Enter the Square balance.'; end if;
  update fund_state set square_balance = round(p_amount, 2), square_balance_at = now() where id = 1 returning * into fs;
  return fs;
end $$;
revoke execute on function public.set_square_balance(numeric) from public, anon;
grant execute on function public.set_square_balance(numeric) to authenticated;

-- What Square should hold: all four funds, plus money paid for games and events whose accounts
-- aren't posted yet (less Square's fees on it), less what is still held as cash or in the bank.
create or replace function public.square_expected() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fs fund_state; v_pending jsonb; v_in numeric; v_fees numeric;
begin
  if not is_door() then raise exception 'Only organisers can see the Square check.'; end if;
  select * into fs from fund_state where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('event', x.id, 'title', x.title, 'day', x.day, 'paid', x.paid, 'fees', x.fees) order by x.day nulls last), '[]'),
         coalesce(sum(x.paid), 0), coalesce(sum(x.fees), 0)
    into v_pending, v_in, v_fees
    from (select e.id, e.title, e.day,
                 sum(b.amount - b.intro_cover) filter (where b.paid) as paid,
                 sum(b.card_fee) as fees
            from events e join bookings b on b.event_id = e.id
           where not e.accounts_posted and (e.day is null or e.day >= fs.square_from)
             and b.status = 'booked' and (b.paid or b.card_fee > 0)
           group by e.id, e.title, e.day) x
   where coalesce(x.paid, 0) <> 0 or coalesce(x.fees, 0) <> 0;
  return jsonb_build_object(
    'funds', fs.kitty + fs.events + fs.credits + fs.family,
    'pending', v_pending, 'pending_in', v_in, 'pending_fees', v_fees,
    'held_cash', fs.held_cash, 'held_bank', fs.held_bank,
    'expected', fs.kitty + fs.events + fs.credits + fs.family + v_in - v_fees - fs.held_cash - fs.held_bank,
    'square_balance', fs.square_balance, 'square_balance_at', fs.square_balance_at);
end $$;
revoke execute on function public.square_expected() from public, anon;
grant execute on function public.square_expected() to authenticated;
-- =====================================================================
--  One Accounts chat: football accounts, events accounts and transfers
--  all post to a single chat, and that chat is the only place posted
--  accounts are kept.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- The Football Accounts chat becomes the Accounts chat, for every approved member.
update public.groups set name = 'Accounts',
  about = 'All our posted accounts: Friday football, events, and money moved between funds, with the receipts. Every approved member can read them; only the admin posts.'
 where id = 'football-accounts';

-- Anything still posted to Events Accounts goes to the Accounts chat instead. Transfers used to be posted
-- to both chats, and football money into the events fund got a one-line pointer, so those are dropped.
create or replace function public.one_accounts_chat() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.group_id <> 'events-accounts' then return new; end if;
  if new.body like '%See the Football Accounts chat for details.%' then return null; end if;
  if exists (select 1 from posts where group_id = 'football-accounts' and body = new.body
              and created_at > now() - interval '1 minute') then return null; end if;
  new.group_id := 'football-accounts';
  return new;
end $$;
revoke execute on function public.one_accounts_chat() from public, anon, authenticated;
drop trigger if exists posts_one_accounts_chat on public.posts;
create trigger posts_one_accounts_chat before insert on public.posts
  for each row execute function public.one_accounts_chat();

-- Move what's already in Events Accounts, leaving out the copies and pointers.
delete from public.posts p
 where p.group_id = 'events-accounts'
   and (p.body like '%See the Football Accounts chat for details.%'
        or exists (select 1 from public.posts f where f.group_id = 'football-accounts' and f.body = p.body));
update public.posts set group_id = 'football-accounts' where group_id = 'events-accounts';

-- The empty Events Accounts chat is taken away.
delete from public.group_members where group_id = 'events-accounts';
delete from public.groups where id = 'events-accounts';

-- =====================================================================
--  On the night: own-risk confirmation for people added at the pitch,
--  and matching a Square payment to a booking by hand.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- A kitty top-up at the pitch can be paid by card with the QR. Until Square confirms it, the top-up
-- shows as 'link' (not yet paid); then it becomes 'card', with Square's fee for it kept in topup_fee.
alter table public.bookings add column if not exists topup_fee numeric(8,2) not null default 0;

create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text, p_choice text)
returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
begin
  if not is_door() then raise exception 'Only organisers can add players.'; end if;
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

-- The Square check counts a QR top-up only once it's paid, and its Square fee.
create or replace function public.square_expected() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fs fund_state; v_pending jsonb; v_in numeric; v_fees numeric;
begin
  if not is_door() then raise exception 'Only organisers can see the Square check.'; end if;
  select * into fs from fund_state where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('event', x.id, 'title', x.title, 'day', x.day, 'paid', x.paid, 'fees', x.fees) order by x.day nulls last), '[]'),
         coalesce(sum(x.paid), 0), coalesce(sum(x.fees), 0)
    into v_pending, v_in, v_fees
    from (select e.id, e.title, e.day,
                 sum(b.amount - b.intro_cover - case when b.topup_method = 'link' then b.topup else 0 end) filter (where b.paid) as paid,
                 sum(b.card_fee + b.topup_fee) as fees
            from events e join bookings b on b.event_id = e.id
           where not e.accounts_posted and (e.day is null or e.day >= fs.square_from)
             and b.status = 'booked' and (b.paid or b.card_fee > 0 or b.topup_fee > 0)
           group by e.id, e.title, e.day) x
   where coalesce(x.paid, 0) <> 0 or coalesce(x.fees, 0) <> 0;
  return jsonb_build_object(
    'funds', fs.kitty + fs.events + fs.credits + fs.family,
    'pending', v_pending, 'pending_in', v_in, 'pending_fees', v_fees,
    'held_cash', fs.held_cash, 'held_bank', fs.held_bank,
    'expected', fs.kitty + fs.events + fs.credits + fs.family + v_in - v_fees - fs.held_cash - fs.held_bank,
    'square_balance', fs.square_balance, 'square_balance_at', fs.square_balance_at);
end $$;
revoke execute on function public.square_expected() from public, anon;
grant execute on function public.square_expected() to authenticated;

-- An organiser records that someone added at the pitch has confirmed they play at their own risk.
create or replace function public.set_risk(p_id uuid) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if not is_door() then raise exception 'Only organisers can record this.'; end if;
  update bookings set risk_ok = true where id = p_id returning * into b;
  if not found then raise exception 'Booking not found.'; end if;
  return b;
end $$;
revoke execute on function public.set_risk(uuid) from public, anon;
grant execute on function public.set_risk(uuid) to authenticated;

-- A Square payment the app couldn't match by itself (for example taken on the Square app at the pitch,
-- not through the app's QR) is matched to its booking by the admin. The booking becomes paid by card,
-- with Square's fee.
create or replace function public.link_square_payment(p_payment text, p_booking uuid) returns public.square_payments
language plpgsql security definer set search_path = public as $$
declare sp square_payments; b bookings;
begin
  if not is_admin() then raise exception 'Only the admin can match payments.'; end if;
  select * into sp from square_payments where id = p_payment for update;
  if not found then raise exception 'Square payment not found. Tap Sync from Square first.'; end if;
  if sp.kind = 'subscription' then raise exception 'That payment is the Family Events subscription.'; end if;
  select * into b from bookings where id = p_booking for update;
  if not found then raise exception 'Booking not found.'; end if;
  if b.topup_method = 'link' then
    update bookings set topup_method = 'card', topup_fee = sp.fee where id = b.id;   -- the QR top-up was paid
  else
    update bookings set paid = true, method = 'card', card_fee = sp.fee where id = b.id;
  end if;
  update square_payments set kind = 'booking', booking_id = b.id, label = b.display_name, updated_at = now()
   where id = sp.id returning * into sp;
  return sp;
end $$;
revoke execute on function public.link_square_payment(text, uuid) from public, anon;
grant execute on function public.link_square_payment(text, uuid) to authenticated;

-- A later Sync from Square doesn't undo a match made by hand.
create or replace function public.keep_payment_match() returns trigger
language plpgsql as $$
begin
  if old.booking_id is not null and new.kind = 'other' then
    new.kind := old.kind; new.label := old.label;
  end if;
  return new;
end $$;
drop trigger if exists square_payments_keep_match on public.square_payments;
create trigger square_payments_keep_match before update on public.square_payments
  for each row execute function public.keep_payment_match();

-- =====================================================================
--  Removing a paid player always gives them credit.
--  When an organiser or the admin removes someone who paid for pay and play
--  (for example they didn't turn up), what they paid becomes credit on their
--  account at any time, and the payment stays in that game's takings.
--  Also gives Yahya Elmi back the credit he lost on Friday 30 October.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

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
  -- Before Friday 6pm a paid place becomes credit. When an organiser or the admin removes someone
  -- (for example they didn't turn up), it always becomes credit, whatever the time.
  if e.kind = 'football' and b.charge = 'payg' and b.paid and b.method <> 'owes'
     and (now() < fb_credit_until(e.day) or is_door())
     and v_owner is not null and not (v_family and b.method = 'transfer') then
    perform set_config('app.credit_reason', 'removed from football ' || to_char(e.day, 'FMDD Mon') || ', paid place kept as credit', true);
    update profiles set credit = credit + b.amount where id = v_owner;
    perform set_config('app.credit_reason', '', true);
    if b.method = 'credit' then
      delete from bookings where id = p_id;           -- the credit simply goes back
    else
      update bookings set status = 'cancelled' where id = p_id;  -- keeps the money in this week's accounts
    end if;
    msg := 'Removed. £' || b.amount || ' added to ' || case when v_owner = auth.uid() then 'your' else 'their' end || ' credit.';
  else
    if e.kind = 'football' and b.charge = 'kitty' and not b.paid then
      update profiles set kitty_session = null where id = b.user_id;
    end if;
    if not b.paid and b.credit_used > 0 and v_owner is not null then
      perform set_config('app.credit_reason', 'credit returned after removing an unpaid football place', true);
      update profiles set credit = credit + b.credit_used where id = v_owner;
      perform set_config('app.credit_reason', '', true);
      msg := 'Removed. £' || b.credit_used || ' credit given back.';
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

-- Yahya Elmi paid by card for Friday 30 October and was removed on the night, which deleted his place
-- with no credit. Put his place back as a cancelled paid place (so his payment stays in that game's
-- takings) and add what he paid to his credit. Done only once.
do $$
declare p profiles; e events; sp square_payments; n int; amt numeric; b bookings;
begin
  select count(*) into n from profiles where name ilike '%yahya%' and name ilike '%elmi%';
  if n <> 1 then raise notice 'Yahya Elmi: found % accounts with that name, so nothing was changed. Tell Claude.', n; return; end if;
  select * into p from profiles where name ilike '%yahya%' and name ilike '%elmi%';
  select * into e from events where kind = 'football' and day = date '2026-10-30';
  if not found then raise notice 'No football game on 30 October found, so nothing was changed. Tell Claude.'; return; end if;
  if exists (select 1 from bookings where event_id = e.id and user_id = p.id) then
    raise notice 'Yahya Elmi already has a place for 30 October in the app, so nothing was changed.'; return;
  end if;
  -- his Square payment, if the Square check has it
  select * into sp from square_payments
   where status = 'COMPLETED' and (label ilike '%yahya%' or note ilike '%yahya%')
     and paid_at >= timestamptz '2026-10-27' and paid_at < timestamptz '2026-10-31'
   order by paid_at desc limit 1;
  amt := coalesce(sp.gross, e.price);
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, card_fee, status, checked_in, code, risk_ok)
  values (e.id, p.id, p.name, 'payg', amt, true, 'card', coalesce(sp.fee, 0), 'cancelled', false, new_code('AA-'), true)
  returning * into b;
  -- he paid the full price, so no new-member offer applies to this place
  update bookings set amount = amt, intro_cover = 0 where id = b.id returning * into b;
  if sp.id is not null then
    update square_payments set kind = 'booking', booking_id = b.id, label = p.name, updated_at = now() where id = sp.id;
  end if;
  perform set_config('app.credit_reason', 'removed from football 30 Oct, paid place kept as credit', true);
  update profiles set credit = credit + amt where id = p.id;
  perform set_config('app.credit_reason', '', true);
  raise notice 'Yahya Elmi: £% added to his credit.%', amt,
    case when e.accounts_posted then ' The 30 October accounts were already posted, so they are not changed.' else '' end;
end $$;

-- =====================================================================
--  Fixes for the 30 October accounts. Safe to run more than once, and fine
--  if fix-remove-credit.sql was run before (this file includes it).
--  1. Removing a paid player always gives them credit (as fix-remove-credit.sql).
--  2. Yahya Elmi: his place for 30 October is kept as a paid place he didn't
--     play, his £6 is his credit, and his Square payment is matched to it.
--  3. The £5 BR3 Family Subscription paid on Thursday 29 October goes into
--     the Family Events fund, with Square's fee taken off.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
-- =====================================================================

-- 1. Removing a paid player always gives them credit.
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
  -- Before Friday 6pm a paid place becomes credit. When an organiser or the admin removes someone
  -- (for example they didn't turn up), it always becomes credit, whatever the time.
  if e.kind = 'football' and b.charge = 'payg' and b.paid and b.method <> 'owes'
     and (now() < fb_credit_until(e.day) or is_door())
     and v_owner is not null and not (v_family and b.method = 'transfer') then
    perform set_config('app.credit_reason', 'removed from football ' || to_char(e.day, 'FMDD Mon') || ', paid place kept as credit', true);
    update profiles set credit = credit + b.amount where id = v_owner;
    perform set_config('app.credit_reason', '', true);
    if b.method = 'credit' then
      delete from bookings where id = p_id;           -- the credit simply goes back
    else
      update bookings set status = 'cancelled' where id = p_id;  -- keeps the money in this week's accounts
    end if;
    msg := 'Removed. £' || b.amount || ' added to ' || case when v_owner = auth.uid() then 'your' else 'their' end || ' credit.';
  else
    if e.kind = 'football' and b.charge = 'kitty' and not b.paid then
      update profiles set kitty_session = null where id = b.user_id;
    end if;
    if not b.paid and b.credit_used > 0 and v_owner is not null then
      perform set_config('app.credit_reason', 'credit returned after removing an unpaid football place', true);
      update profiles set credit = credit + b.credit_used where id = v_owner;
      perform set_config('app.credit_reason', '', true);
      msg := 'Removed. £' || b.credit_used || ' credit given back.';
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

-- A Square payment matched to a booking, or put in the Family Events fund, stays that way when Sync runs again.
create or replace function public.keep_payment_match() returns trigger
language plpgsql as $$
begin
  if new.kind = 'other' and (old.booking_id is not null or old.kind = 'subscription') then
    new.kind := old.kind; new.label := old.label;
  end if;
  return new;
end $$;

-- 2. Yahya Elmi.
do $$
declare p profiles; e events; sp square_payments; n int; amt numeric; b bookings;
begin
  select count(*) into n from profiles where name ilike '%yahya%' and name ilike '%elmi%';
  if n <> 1 then raise notice 'Yahya Elmi: found % accounts with that name, so nothing was changed for him. Tell Claude.', n; return; end if;
  select * into p from profiles where name ilike '%yahya%' and name ilike '%elmi%';
  select * into e from events where kind = 'football' and day = date '2026-10-30';
  if not found then raise notice 'No football game on 30 October found, so nothing was changed for Yahya. Tell Claude.'; return; end if;
  -- his Square payment
  select * into sp from square_payments
   where status = 'COMPLETED' and (label ilike '%yahya%' or note ilike '%yahya%')
     and paid_at >= timestamptz '2026-10-27' and paid_at < timestamptz '2026-10-31'
   order by paid_at desc limit 1;
  select * into b from bookings where event_id = e.id and user_id = p.id;
  if not found then
    -- his place was deleted when he was removed: put it back as a paid place he didn't play, and give him the credit
    amt := coalesce(sp.gross, e.price);
    insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, card_fee, status, checked_in, code, risk_ok)
    values (e.id, p.id, p.name, 'payg', amt, true, 'card', coalesce(sp.fee, 0), 'cancelled', false, new_code('AA-'), true)
    returning * into b;
    update bookings set amount = amt, intro_cover = 0 where id = b.id returning * into b;  -- he paid the full price
    perform set_config('app.credit_reason', 'removed from football 30 Oct, paid place kept as credit', true);
    update profiles set credit = credit + amt where id = p.id;
    perform set_config('app.credit_reason', '', true);
    raise notice 'Yahya Elmi: £% added to his credit.', amt;
  else
    raise notice 'Yahya Elmi already has his place for 30 October, so his credit is not added again.';
  end if;
  if sp.id is null then
    raise notice 'Yahya''s Square payment isn''t in the app yet. Tap Sync from Square, then run this file again.';
  elsif sp.booking_id is not null and sp.booking_id <> b.id then
    raise notice 'Yahya''s Square payment was matched to another booking, so it was left alone. Tell Claude.';
  elsif sp.booking_id is distinct from b.id then
    update bookings set card_fee = sp.fee where id = b.id;
    update square_payments set kind = 'booking', booking_id = b.id, label = p.name, updated_at = now() where id = sp.id;
    raise notice 'Yahya''s £% Square payment is matched to his place.', sp.gross;
  end if;
end $$;

-- 3. The £5 BR3 Family Subscription on Thursday 29 October.
do $$
declare sp square_payments;
begin
  select * into sp from square_payments
   where status = 'COMPLETED' and kind = 'other' and booking_id is null and gross = 5
     and (paid_at at time zone 'Europe/London')::date = date '2026-10-29';
  if not found then
    if exists (select 1 from square_payments where kind = 'subscription' and (paid_at at time zone 'Europe/London')::date = date '2026-10-29') then
      raise notice 'The £5 on 29 October is already in the Family Events fund.';
    else
      raise notice 'Couldn''t find one unmatched £5 payment on 29 October, so nothing was changed for it. Tell Claude.';
    end if;
    return;
  end if;
  perform apply_square_payment(to_jsonb(sp) || jsonb_build_object('kind', 'subscription', 'label', 'BR3 Family Subscription'));
  raise notice 'The £5 BR3 Family Subscription is in the Family Events fund, less Square''s £% fee.', sp.fee;
end $$;

-- =====================================================================
--  Yahya's £6 for Friday 30 October (Square payment "yahya elmi", now the
--  account named yahya touré): keep his place as paid but not played, add
--  the £6 to his credit, and match his Square payment to it.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================
do $$
declare p profiles; e events; sp square_payments; b bookings;
begin
  select * into p from profiles where id = '4f185be2-9b90-40ef-a01e-67ec31c2422d';
  if not found then raise notice 'Yahya''s account wasn''t found, so nothing was changed. Tell Claude.'; return; end if;
  select * into e from events where id = '62e1d680-cbb2-4907-ab32-b17ae5fc873f';
  if not found then raise notice 'The 30 October game wasn''t found, so nothing was changed. Tell Claude.'; return; end if;
  select * into sp from square_payments where id = 'iQ8eidcXaZex4plg5SWw8gc1GHCZY';
  if not found then raise notice 'His Square payment isn''t in the app. Tap Sync from Square, then run this again.'; return; end if;
  if sp.booking_id is not null then raise notice 'His Square payment is already matched, so nothing was changed.'; return; end if;

  select * into b from bookings where event_id = e.id and user_id = p.id;
  if found then raise notice '% already has a place for 30 October, so nothing was changed. Tell Claude.', p.name; return; end if;

  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, card_fee, status, checked_in, code, risk_ok)
  values (e.id, p.id, p.name, 'payg', sp.gross, true, 'card', sp.fee, 'cancelled', false, new_code('AA-'), true)
  returning * into b;
  update bookings set amount = sp.gross, intro_cover = 0 where id = b.id;  -- he paid the full price
  update square_payments set kind = 'booking', booking_id = b.id, label = p.name, updated_at = now() where id = sp.id;
  perform set_config('app.credit_reason', 'paid for football 30 Oct but didn''t play, credit added', true);
  update profiles set credit = credit + sp.gross where id = p.id;
  perform set_config('app.credit_reason', '', true);
  raise notice '£% added to %''s credit, and his Square payment is matched.', sp.gross, p.name;
end $$;

-- =====================================================================
--  Cancelling a paid place always gives credit.
--  A member who removes themselves from Friday football after they've paid
--  gets what they paid as credit at any time, even after Friday 6pm, the
--  same as a no-show. The place is kept (as cancelled) so the payment stays
--  in that game's accounts. Once a game's accounts are posted, places on it
--  can't be cancelled any more.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

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
  if e.kind = 'football' and e.accounts_posted then raise exception 'The accounts for this game are already posted.'; end if;
  v_owner := coalesce(b.user_id, b.booked_by);
  select family into v_family from profiles where id = v_owner;
  v_family := coalesce(v_family, false);
  if e.kind = 'football' and b.user_id is not null and v_family then
    insert into football_family_out (event_id, user_id) values (b.event_id, b.user_id) on conflict do nothing;
  end if;
  -- A paid pay-and-play place always becomes credit when it's cancelled, whenever and by whoever:
  -- the same as a paid no-show, who gets credit when the accounts are posted.
  if e.kind = 'football' and b.charge = 'payg' and b.paid and b.method <> 'owes'
     and v_owner is not null and not (v_family and b.method = 'transfer') then
    perform set_config('app.credit_reason', 'cancelled football ' || to_char(e.day, 'FMDD Mon') || ', paid place kept as credit', true);
    update profiles set credit = credit + b.amount where id = v_owner;
    perform set_config('app.credit_reason', '', true);
    if b.method = 'credit' then
      delete from bookings where id = p_id;           -- the credit simply goes back
    else
      update bookings set status = 'cancelled' where id = p_id;  -- keeps the money in this week's accounts
    end if;
    msg := 'Removed. £' || b.amount || ' added to ' || case when v_owner = auth.uid() then 'your' else 'their' end || ' credit.';
  else
    if e.kind = 'football' and b.charge = 'kitty' and not b.paid then
      update profiles set kitty_session = null where id = b.user_id;
    end if;
    if not b.paid and b.credit_used > 0 and v_owner is not null then
      perform set_config('app.credit_reason', 'credit returned after removing an unpaid football place', true);
      update profiles set credit = credit + b.credit_used where id = v_owner;
      perform set_config('app.credit_reason', '', true);
      msg := 'Removed. £' || b.credit_used || ' credit given back.';
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

-- =====================================================================
--  Family Events Accounts chat (on the Joined events tab).
--  Every approved member can read it; only the admin posts. It keeps the
--  Family Events fund's history: each week's subscriptions (posted by the
--  Saturday morning pull), and any money in or spent recorded on the Funds page.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

insert into public.groups (id, name, about, sort, members_only)
values ('family-accounts', 'Family Events Accounts',
        'The BR3 Family Events fund: the weekly Individual, Concessionary and Family subscriptions, and money spent on family events. Every approved member can read it; only the admin posts.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;

create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
    or (g in ('football-accounts', 'events-accounts', 'family-accounts') and exists (select 1 from profiles where id = auth.uid() and approved))
$$;

drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id not in ('football-accounts', 'events-accounts', 'family-accounts') or is_organiser()) and can_see_group(group_id));

-- Money in or spent recorded on the Funds page is also posted to the chat.
create or replace function public.family_entry(p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; a numeric := round(coalesce(p_amount, 0), 2); r text := trim(coalesce(p_reason, '')); v_name text;
begin
  if not is_admin() then raise exception 'Only the admin can change the Family Events fund.'; end if;
  if a = 0 then raise exception 'Enter an amount.'; end if;
  if r = '' then raise exception 'Give a reason.'; end if;
  select * into fs from fund_state where id = 1 for update;
  fs.family := fs.family + a;
  insert into ledger (fund, what, amount, balance) values ('family', r, a, fs.family);
  update fund_state set family = fs.family where id = 1;
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body)
  values ('family-accounts', auth.uid(), coalesce(v_name, 'Admin'),
          'Family Events fund · ' || to_char(now() at time zone 'Europe/London', 'FMDD Mon YYYY') || chr(10)
          || case when a > 0 then 'Money in £' else 'Spent £' end || to_char(abs(a), 'FM999990.00') || ': ' || r || chr(10)
          || 'Family Events fund now £' || to_char(fs.family, 'FM999990.00'));
  return fs;
end $$;
revoke execute on function public.family_entry(numeric, text) from public, anon;
grant execute on function public.family_entry(numeric, text) to authenticated;

-- Each week's subscriptions, posted once per week by the Saturday morning pull (or by the admin).
-- The week is the 7 days before p_end (UK dates): Saturday to Friday when run on a Saturday.
create table if not exists public.family_week_posts (
  week_end date primary key,
  post_id uuid references public.posts(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.family_week_posts enable row level security;
revoke all on public.family_week_posts from anon, authenticated;

create or replace function public.post_family_week(p_end date) returns text
language plpgsql security definer set search_path = public as $$
declare v_start date := p_end - 7; body text; r record; n int := 0; tg numeric := 0; tf numeric := 0; v_post uuid; v_name text; fam numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not is_admin() then raise exception 'Only the admin can post this.'; end if;
  if exists (select 1 from family_week_posts where week_end = p_end) then return null; end if;
  body := 'Family Events subscriptions · ' || to_char(v_start, 'FMDD Mon') || ' to ' || to_char(p_end - 1, 'FMDD Mon YYYY');
  for r in
    select regexp_replace(coalesce(nullif(label, ''), 'Subscription'), '\s*\(.*\)\s*$', '') as plan,
           count(*) as cnt, sum(gross - refunded) as g, sum(fee) as f
      from square_payments
     where kind = 'subscription' and status = 'COMPLETED'
       and (paid_at at time zone 'Europe/London')::date >= v_start and (paid_at at time zone 'Europe/London')::date < p_end
     group by 1 order by 1
  loop
    body := body || chr(10) || r.plan || ': ' || r.cnt || ' paid £' || to_char(r.g, 'FM999990.00')
            || ', Square fee (£' || to_char(r.f, 'FM999990.00') || '), net £' || to_char(r.g - r.f, 'FM999990.00');
    n := n + r.cnt; tg := tg + r.g; tf := tf + r.f;
  end loop;
  if n = 0 then return null; end if;
  select family into fam from fund_state where id = 1;
  body := body || chr(10) || 'Total: ' || n || ' paid £' || to_char(tg, 'FM999990.00') || ', fees (£' || to_char(tf, 'FM999990.00')
          || '), net £' || to_char(tg - tf, 'FM999990.00') || chr(10) || 'Family Events fund now £' || to_char(fam, 'FM999990.00');
  select id, name into r from profiles where role = 'admin' order by created_at limit 1;
  insert into posts (group_id, user_id, author_name, body) values ('family-accounts', r.id, coalesce(r.name, 'Admin'), body)
  returning id into v_post;
  insert into family_week_posts (week_end, post_id) values (p_end, v_post);
  return body;
end $$;
revoke execute on function public.post_family_week(date) from public, anon;
grant execute on function public.post_family_week(date) to authenticated, service_role;

-- ===== add-event-fund.sql =====
-- Each event is linked to a fund: its profit goes into that fund and its loss comes out of it.
-- Events fund by default; the Family Events fund for family events.
alter table public.events add column if not exists fund text not null default 'events';
alter table public.events drop constraint if exists events_fund_check;
alter table public.events add constraint events_fund_check check (fund in ('events', 'family'));

alter table public.event_accounts add column if not exists fund text not null default 'events';
alter table public.event_accounts add column if not exists fund_before numeric;
alter table public.event_accounts add column if not exists fund_after numeric;

create or replace function public.post_event_accounts(p_event uuid, p_body text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; v_name text; d text; rec numeric; hire numeric; anc numeric;
  k_net numeric; e_net numeric; v_transfers jsonb; v_photos jsonb; v_fund text; v_bal numeric; v_before numeric;
begin
  if not is_admin() then raise exception 'Only the admin can post accounts.'; end if;
  select * into e from events where id = p_event for update;
  if not found then raise exception 'Event not found.'; end if;
  if e.kind = 'football' then raise exception 'Football accounts are posted from the Football page.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this event were already posted.'; end if;
  if not exists (select 1 from event_account_lines where event_id = p_event) then raise exception 'Add the receipts and costs first.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The accounts are empty.'; end if;
  v_fund := coalesce(e.fund, 'events');

  select coalesce(sum(amount) filter (where kind = 'receipt'), 0), coalesce(sum(amount) filter (where kind = 'hiring'), 0),
         coalesce(sum(amount) filter (where kind = 'ancillary'), 0)
    into rec, hire, anc from event_account_lines where event_id = p_event;
  select coalesce(jsonb_agg(photo order by case kind when 'receipt' then 1 when 'hiring' then 2 else 3 end, created_at, id), '[]')
    into v_photos from event_account_lines where event_id = p_event and photo is not null;

  select * into fs from fund_state where id = 1 for update;
  -- Transfers since the last posted accounts, so the accounts show the funds before them.
  select coalesce(sum(case when to_fund = 'kitty' then amount else -amount end), 0),
         coalesce(sum(case when to_fund = 'events' then amount else -amount end), 0),
         coalesce(jsonb_agg(jsonb_build_object('on_date', on_date, 'from', from_fund, 'to', to_fund, 'amount', amount, 'reason', reason) order by id), '[]')
    into k_net, e_net, v_transfers from fund_transfers where accounts_post_id is null;

  v_before := case v_fund when 'family' then coalesce(fs.family, 0) else fs.events end;
  v_bal := v_before;
  d := e.title || ' ' || coalesce(to_char(e.day, 'FMDD Mon YYYY'), '(date to be confirmed)');
  if rec > 0 then
    v_bal := v_bal + rec;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), v_fund, d || ': receipts', rec, v_bal);
  end if;
  if hire > 0 then
    v_bal := v_bal - hire;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), v_fund, d || ': hiring costs', -hire, v_bal);
  end if;
  if anc > 0 then
    v_bal := v_bal - anc;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), v_fund, d || ': ancillary costs', -anc, v_bal);
  end if;
  if v_fund = 'family' then
    fs.family := v_bal; update fund_state set family = v_bal where id = 1;
  else
    fs.events := v_bal; update fund_state set events = v_bal where id = 1;
  end if;
  update events set accounts_posted = true where id = p_event;

  insert into event_accounts (event_id, receipts, hiring, ancillary, kitty_before, events_before, transfers, kitty_after, events_after, posted_by, fund, fund_before, fund_after)
    values (p_event, rec, hire, anc, fs.kitty - k_net,
            fs.events - (case when v_fund = 'events' then rec - hire - anc else 0 end) - e_net,
            v_transfers, fs.kitty, fs.events, auth.uid(), v_fund,
            case when v_fund = 'events' then v_before - e_net else v_before end, v_bal);
  insert into accounts_posts (event_id, body, created_by) values (p_event, p_body, auth.uid());
  select name into v_name from profiles where id = auth.uid();
  -- Family events go to the Family Events Accounts chat; the rest to the Accounts chat.
  insert into posts (group_id, user_id, author_name, body, images)
    values (case v_fund when 'family' then 'family-accounts' else 'events-accounts' end, auth.uid(), coalesce(v_name, 'Admin'), p_body, v_photos);
  return fs;
end $$;
revoke execute on function public.post_event_accounts(uuid, text) from public, anon;
grant execute on function public.post_event_accounts(uuid, text) to authenticated;

-- ===== add-square-statement.sql =====
-- One Square balance photo (or PDF) on the Funds page, to compare with "All funds together".
-- Only the latest is kept: uploading a new one replaces it.
create table if not exists public.square_statement (
  id int primary key default 1 check (id = 1),
  file text not null,                -- data URL: a photo (image/jpeg etc.) or a PDF
  file_name text,
  uploaded_at timestamptz not null default now(),
  uploaded_by uuid references public.profiles(id) on delete set null
);
alter table public.square_statement enable row level security;
drop policy if exists "members read statement" on public.square_statement;
create policy "members read statement" on public.square_statement for select to authenticated
  using (exists (select 1 from profiles where id = auth.uid() and approved));
drop policy if exists "admin writes statement" on public.square_statement;
create policy "admin writes statement" on public.square_statement for all to authenticated
  using (is_admin()) with check (is_admin() and (file like 'data:application/pdf;base64,%' or file like 'data:image/%') and length(file) < 8000000);
grant select, insert, update, delete on public.square_statement to authenticated;

-- ===== add-welcome-and-members.sql =====
-- Safe to run more than once. Run it in Supabase, SQL Editor, before the app update goes live.

-- ===== 1. The welcome agreement =====
-- When a member ticked "I agree" to the welcome and friends agreement. Empty = not agreed yet.
alter table public.profiles add column if not exists agreed_at timestamptz;

-- People who tick "I agree" on the Join form: the tick travels with the sign-up and is copied here.
create or replace function public.agreed_on_join() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.agreed_at is null and exists (select 1 from auth.users where id = new.id and raw_user_meta_data->>'agreed' = 'yes') then
    new.agreed_at := now();
  end if;
  return new;
end $$;
revoke execute on function public.agreed_on_join() from public, anon, authenticated;
drop trigger if exists profiles_agreed_on_join on public.profiles;
create trigger profiles_agreed_on_join before insert on public.profiles
  for each row execute function public.agreed_on_join();

-- Members who joined before the agreement was in the app agree once, when they next open it.
create or replace function public.agree_welcome() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare t timestamptz;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update profiles set agreed_at = coalesce(agreed_at, now()) where id = auth.uid() returning agreed_at into t;
  return t;
end $$;
revoke execute on function public.agree_welcome() from public, anon;
grant execute on function public.agree_welcome() to authenticated;

-- ===== 2. Strikes (two strike rule), seen only by the admin =====
create table if not exists public.member_strikes (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  strikes int not null default 0 check (strikes between 0 and 9),
  note text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.member_strikes enable row level security;
drop policy if exists "admin reads strikes" on public.member_strikes;
create policy "admin reads strikes" on public.member_strikes for select to authenticated using (is_admin());
grant select on public.member_strikes to authenticated;

create or replace function public.set_strikes(p_id uuid, p_strikes int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can give strikes.'; end if;
  if p_strikes < 0 or p_strikes > 9 then raise exception 'Strikes go from 0 to 9.'; end if;
  insert into member_strikes (user_id, strikes, note, updated_at) values (p_id, p_strikes, coalesce(p_note, ''), now())
  on conflict (user_id) do update set strikes = excluded.strikes, note = excluded.note, updated_at = now();
end $$;
revoke execute on function public.set_strikes(uuid, int, text) from public, anon;
grant execute on function public.set_strikes(uuid, int, text) to authenticated;

-- ===== 3. Friends play only on a game the member is booked on =====
create or replace function public.friend_needs_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.booked_by is not null and new.status <> 'cancelled'
     and not exists (select 1 from bookings where event_id = new.event_id and user_id = new.booked_by and status = 'booked') then
    raise exception 'Book your own place first. Friends can only come to a game you are booked on and coming to.';
  end if;
  return new;
end $$;
revoke execute on function public.friend_needs_member() from public, anon, authenticated;
drop trigger if exists bookings_friend_needs_member on public.bookings;
create trigger bookings_friend_needs_member before insert on public.bookings
  for each row execute function public.friend_needs_member();

-- ===== 4. Activity: days each member opened the app, and shared reactions =====
create table if not exists public.member_days (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  primary key (user_id, day)
);
alter table public.member_days enable row level security; -- written and read only through the functions below

create or replace function public.i_was_here() returns void
language sql security definer set search_path = public as $$
  insert into member_days (user_id, day)
  select auth.uid(), (now() at time zone 'Europe/London')::date where auth.uid() is not null
  on conflict do nothing
$$;
revoke execute on function public.i_was_here() from public, anon;
grant execute on function public.i_was_here() to authenticated;

-- Reactions (and the thumbs up) were kept on each phone. Now everyone sees them, and they count as activity.
create table if not exists public.post_reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('👍', '❤️', '😂', '👏', '🙏', '🔥', '🎉', '😮', '😢')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);
alter table public.post_reactions enable row level security;
drop policy if exists "members see reactions" on public.post_reactions;
create policy "members see reactions" on public.post_reactions for select to authenticated using (can_see_post(post_id));
drop policy if exists "members react" on public.post_reactions;
create policy "members react" on public.post_reactions for insert to authenticated
  with check (user_id = auth.uid() and can_see_post(post_id));
drop policy if exists "members unreact" on public.post_reactions;
create policy "members unreact" on public.post_reactions for delete to authenticated using (user_id = auth.uid());
grant select, insert, delete on public.post_reactions to authenticated;
drop trigger if exists require_approved on public.post_reactions;
create trigger require_approved before insert on public.post_reactions for each row execute function public.require_approved();

-- ===== 5. Member search for the admin =====
-- One row per member: who they are, when they were last here, their last football, and an activity
-- score over the last 90 days that counts everything they do in the app:
--   1 per day they opened the app, 3 per booking (any event, friends included), 3 per post,
--   2 per comment, 1 per reaction or poll vote.
create or replace function public.member_report() returns table (
  id uuid, name text, role text, football boolean, family boolean, approved boolean, joined timestamptz,
  agreed_at timestamptz, credit numeric, strikes int, strike_note text,
  last_seen date, last_football date, last_active date,
  days_90 int, bookings_90 int, posts_90 int, comments_90 int, reactions_90 int, score int)
language plpgsql stable security definer set search_path = public, auth as $$
declare since timestamptz := now() - interval '90 days';
begin
  if not is_admin() then raise exception 'Only the admin can see the member search.'; end if;
  return query
  with s as (
    select p.id, p.name, p.role, p.football, p.family, p.approved, p.created_at as joined, p.agreed_at, p.credit,
      coalesce(ms.strikes, 0) as strikes, coalesce(ms.note, '') as strike_note,
      greatest((select max(d.day) from member_days d where d.user_id = p.id),
               (select (u.last_sign_in_at at time zone 'Europe/London')::date from auth.users u where u.id = p.id)) as last_seen,
      (select max(e.day) from bookings b join events e on e.id = b.event_id
        where b.user_id = p.id and e.kind = 'football' and b.status = 'booked') as last_football,
      (select count(*)::int from member_days d where d.user_id = p.id and d.day >= since::date) as days_90,
      (select count(*)::int from bookings b where (b.user_id = p.id or b.booked_by = p.id) and b.status <> 'cancelled' and b.created_at >= since) as bookings_90,
      (select count(*)::int from posts x where x.user_id = p.id and x.created_at >= since) as posts_90,
      (select count(*)::int from comments c where c.user_id = p.id and c.created_at >= since) as comments_90,
      (select count(*)::int from post_reactions r where r.user_id = p.id and r.created_at >= since)
        + (select count(*)::int from poll_votes v join posts x on x.id = v.post_id where v.user_id = p.id and x.created_at >= since) as reactions_90,
      greatest((select max(b.created_at) from bookings b where b.user_id = p.id or b.booked_by = p.id),
               (select max(x.created_at) from posts x where x.user_id = p.id),
               (select max(c.created_at) from comments c where c.user_id = p.id),
               (select max(r.created_at) from post_reactions r where r.user_id = p.id)) as last_did
    from profiles p left join member_strikes ms on ms.user_id = p.id
  )
  select s.id, s.name, s.role, s.football, s.family, s.approved, s.joined, s.agreed_at, s.credit, s.strikes, s.strike_note,
    s.last_seen, s.last_football,
    greatest(s.last_seen, (s.last_did at time zone 'Europe/London')::date) as last_active,
    s.days_90, s.bookings_90, s.posts_90, s.comments_90, s.reactions_90,
    s.days_90 + 3 * s.bookings_90 + 3 * s.posts_90 + 2 * s.comments_90 + s.reactions_90 as score
  from s order by s.name;
end $$;
revoke execute on function public.member_report() from public, anon;
grant execute on function public.member_report() to authenticated;

-- ===== 6. Most active in the chats, last month and this month so far =====
-- Counts posts (3), comments (2) and reactions (1) in the ordinary chats; the accounts chats and
-- announcements don't count. Everyone signed in can see the top three.
create or replace function public.chat_stars() returns table (period text, user_id uuid, name text, score int)
language sql stable security definer set search_path = public as $$
  with m as (select date_trunc('month', now() at time zone 'Europe/London') as this_m),
  acts as (
    select x.user_id, x.created_at, 3 as pts from posts x
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
    union all
    select c.user_id, c.created_at, 2 from comments c join posts x on x.id = c.post_id
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
    union all
    select r.user_id, r.created_at, 1 from post_reactions r join posts x on x.id = r.post_id
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
  ),
  tagged as (
    select a.user_id, a.pts,
      case when (a.created_at at time zone 'Europe/London') >= m.this_m then 'this'
           when (a.created_at at time zone 'Europe/London') >= m.this_m - interval '1 month' then 'last' end as period
    from acts a, m where a.user_id is not null
  ),
  totals as (
    select t.period, t.user_id, sum(t.pts)::int as score,
      row_number() over (partition by t.period order by sum(t.pts) desc, t.user_id) as rk
    from tagged t where t.period is not null group by t.period, t.user_id
  )
  select t.period, t.user_id, p.name, t.score from totals t join profiles p on p.id = t.user_id
   where t.rk <= 3 and auth.uid() is not null
   order by t.period, t.score desc
$$;
revoke execute on function public.chat_stars() from public, anon;
grant execute on function public.chat_stars() to authenticated;

-- ===== 7. Credit left on removed accounts: claimable for 12 months, then to charity =====
-- It moves out of the credits fund into its own "Unclaimed credit" fund, so all the funds still add up
-- to what Square holds. The admin then marks it paid back (by bank transfer, with their consent)
-- or, after 12 months, given to charity on their behalf, with the receipt kept here.
alter table public.fund_state add column if not exists unclaimed numeric(10,2) not null default 0;
alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits', 'family', 'unclaimed'));

create table if not exists public.unclaimed_credit (
  id bigserial primary key,
  name text not null,
  email text,
  amount numeric(8,2) not null check (amount > 0),
  removed_at timestamptz not null default now(),
  claim_by date not null,
  status text not null default 'held' check (status in ('held', 'paid', 'charity')),
  settled_at timestamptz,
  settled_note text,
  receipt text,                                   -- photo or PDF of the charity receipt, as a data URL
  settled_by uuid references public.profiles(id) on delete set null
);
alter table public.unclaimed_credit enable row level security;
drop policy if exists "admin reads unclaimed" on public.unclaimed_credit;
create policy "admin reads unclaimed" on public.unclaimed_credit for select to authenticated using (is_admin());
grant select on public.unclaimed_credit to authenticated;

create or replace function public.remove_member(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare p profiles; v_email text; v_by date; bal numeric;
begin
  if not is_admin() then raise exception 'Only the admin can remove members.'; end if;
  if p_id = auth.uid() then raise exception 'You cannot remove yourself.'; end if;
  if exists (select 1 from profiles where id = p_id and role = 'admin') then
    raise exception 'Change their role from admin first.';
  end if;
  if exists (select 1 from bookings b join events e on e.id = b.event_id
              where (b.user_id = p_id or b.booked_by = p_id)
                and b.status in ('booked', 'waitlist', 'pending')
                and (e.day is null or e.day >= current_date) and not e.accounts_posted) then
    raise exception 'They have upcoming bookings. Remove them from those first, so any payment or credit is sorted out.';
  end if;
  select * into p from profiles where id = p_id;
  select email into v_email from auth.users where id = p_id;
  -- Their credit leaves the credits fund (the profiles_credit_removed trigger) and is held here.
  if p.id is not null and p.credit > 0 then
    v_by := ((now() at time zone 'Europe/London')::date + interval '12 months')::date;
    insert into unclaimed_credit (name, email, amount, claim_by) values (p.name, v_email, p.credit, v_by);
    update fund_state set unclaimed = unclaimed + p.credit where id = 1 returning unclaimed into bal;
    insert into ledger (fund, what, amount, balance)
      values ('unclaimed', p.name || ': credit held after their account was removed, claimable until ' || to_char(v_by, 'FMDD Mon YYYY'), p.credit, bal);
  end if;
  update bookings set user_id = null where user_id = p_id;
  update bookings set booked_by = null where booked_by = p_id;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.remove_member(uuid) from public, anon;
grant execute on function public.remove_member(uuid) to authenticated;

create or replace function public.settle_unclaimed(p_id bigint, p_how text, p_note text, p_receipt text) returns void
language plpgsql security definer set search_path = public as $$
declare u unclaimed_credit; bal numeric;
begin
  if not is_admin() then raise exception 'Only the admin can do this.'; end if;
  select * into u from unclaimed_credit where id = p_id for update;
  if not found or u.status <> 'held' then raise exception 'That credit has already been sorted out.'; end if;
  if p_how not in ('paid', 'charity') then raise exception 'Choose paid back or given to charity.'; end if;
  if p_how = 'charity' and coalesce(p_receipt, '') = '' then raise exception 'Add a photo of the charity receipt.'; end if;
  if p_receipt is not null and not (p_receipt like 'data:image/%' or p_receipt like 'data:application/pdf;base64,%') then
    raise exception 'The receipt should be a photo or a PDF.';
  end if;
  update unclaimed_credit set status = p_how, settled_at = now(), settled_note = nullif(trim(coalesce(p_note, '')), ''),
         receipt = p_receipt, settled_by = auth.uid() where id = p_id;
  update fund_state set unclaimed = unclaimed - u.amount where id = 1 returning unclaimed into bal;
  insert into ledger (fund, what, amount, balance)
    values ('unclaimed', u.name || ': ' || case p_how when 'paid' then 'credit paid back to them' else 'unclaimed credit given to charity on their behalf' end
            || coalesce(' (' || nullif(trim(coalesce(p_note, '')), '') || ')', ''), -u.amount, bal);
end $$;
revoke execute on function public.settle_unclaimed(bigint, text, text, text) from public, anon;
grant execute on function public.settle_unclaimed(bigint, text, text, text) to authenticated;

-- The Square check counts the unclaimed credit too, since it's still in Square.
create or replace function public.square_expected() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fs fund_state; v_pending jsonb; v_in numeric; v_fees numeric; v_all numeric;
begin
  if not is_door() then raise exception 'Only organisers can see the Square check.'; end if;
  select * into fs from fund_state where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('event', x.id, 'title', x.title, 'day', x.day, 'paid', x.paid, 'fees', x.fees) order by x.day nulls last), '[]'),
         coalesce(sum(x.paid), 0), coalesce(sum(x.fees), 0)
    into v_pending, v_in, v_fees
    from (select e.id, e.title, e.day,
                 sum(b.amount - b.intro_cover - case when b.topup_method = 'link' then b.topup else 0 end) filter (where b.paid) as paid,
                 sum(b.card_fee + b.topup_fee) as fees
            from events e join bookings b on b.event_id = e.id
           where not e.accounts_posted and (e.day is null or e.day >= fs.square_from)
             and b.status = 'booked' and (b.paid or b.card_fee > 0 or b.topup_fee > 0)
           group by e.id, e.title, e.day) x
   where coalesce(x.paid, 0) <> 0 or coalesce(x.fees, 0) <> 0;
  v_all := fs.kitty + fs.events + fs.credits + fs.family + fs.unclaimed;
  return jsonb_build_object(
    'funds', v_all, 'unclaimed', fs.unclaimed,
    'pending', v_pending, 'pending_in', v_in, 'pending_fees', v_fees,
    'held_cash', fs.held_cash, 'held_bank', fs.held_bank,
    'expected', v_all + v_in - v_fees - fs.held_cash - fs.held_bank,
    'square_balance', fs.square_balance, 'square_balance_at', fs.square_balance_at);
end $$;
revoke execute on function public.square_expected() from public, anon;
grant execute on function public.square_expected() to authenticated;

-- ===== add-leaderboard.sql =====
-- Needs add-welcome-and-members.sql first. Safe to run more than once.
-- Points: 1 per day they open the app, 3 per booking (any event, friends included), 3 per post,
-- 2 per comment, 1 per reaction or poll vote. Posts in the accounts chats and announcements don't count.
-- Only members are ranked: organisers and the admin are left out.
-- p_period: 'month' = this calendar month so far, 'all' = all time.
-- Returns the top 10, plus the person asking if they're not in the top 10 (me = true).
create or replace function public.leaderboard(p_period text) returns table (
  rank int, user_id uuid, name text, score int, days int, bookings int, posts int, comments int, reactions int, me boolean)
language sql stable security definer set search_path = public as $$
  with since as (
    select case when p_period = 'all' then timestamptz '2000-01-01'
                else (date_trunc('month', now() at time zone 'Europe/London') at time zone 'Europe/London') end as t
  ),
  quiet as (select unnest(array['announcements', 'football-accounts', 'events-accounts', 'family-accounts']) as g),
  acts as (
    select d.user_id, 'days' as k from member_days d, since where d.day >= (since.t at time zone 'Europe/London')::date
    union all
    select coalesce(b.booked_by, b.user_id), 'bookings' from bookings b, since
     where coalesce(b.booked_by, b.user_id) is not null and b.status not in ('cancelled', 'declined') and b.created_at >= since.t
    union all
    select x.user_id, 'posts' from posts x, since where x.created_at >= since.t and x.group_id not in (select g from quiet)
    union all
    select c.user_id, 'comments' from comments c join posts x on x.id = c.post_id, since
     where c.created_at >= since.t and x.group_id not in (select g from quiet)
    union all
    select r.user_id, 'reactions' from post_reactions r join posts x on x.id = r.post_id, since
     where r.created_at >= since.t and x.group_id not in (select g from quiet)
    union all
    select v.user_id, 'reactions' from poll_votes v join posts x on x.id = v.post_id, since
     where x.created_at >= since.t and x.group_id not in (select g from quiet)
  ),
  totals as (
    select a.user_id,
      count(*) filter (where k = 'days')::int as days, count(*) filter (where k = 'bookings')::int as bookings,
      count(*) filter (where k = 'posts')::int as posts, count(*) filter (where k = 'comments')::int as comments,
      count(*) filter (where k = 'reactions')::int as reactions
    from acts a join profiles p on p.id = a.user_id and p.approved and p.role = 'member' -- organisers and the admin run things, so they're left out
    group by a.user_id
  ),
  ranked as (
    select t.*, t.days + 3 * t.bookings + 3 * t.posts + 2 * t.comments + t.reactions as score,
      rank() over (order by t.days + 3 * t.bookings + 3 * t.posts + 2 * t.comments + t.reactions desc)::int as rk,
      row_number() over (order by t.days + 3 * t.bookings + 3 * t.posts + 2 * t.comments + t.reactions desc, t.user_id) as rn
    from totals t
  )
  select r.rk, r.user_id, p.name, r.score::int, r.days, r.bookings, r.posts, r.comments, r.reactions, r.user_id = auth.uid()
    from ranked r join profiles p on p.id = r.user_id
   where auth.uid() is not null and (r.rn <= 10 or r.user_id = auth.uid())
   order by r.rn
$$;
revoke execute on function public.leaderboard(text) from public, anon;
grant execute on function public.leaderboard(text) to authenticated;

-- The chats' monthly 🏅 badge leaves out organisers and the admin too.
create or replace function public.chat_stars() returns table (period text, user_id uuid, name text, score int)
language sql stable security definer set search_path = public as $$
  with m as (select date_trunc('month', now() at time zone 'Europe/London') as this_m),
  acts as (
    select x.user_id, x.created_at, 3 as pts from posts x
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
    union all
    select c.user_id, c.created_at, 2 from comments c join posts x on x.id = c.post_id
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
    union all
    select r.user_id, r.created_at, 1 from post_reactions r join posts x on x.id = r.post_id
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
  ),
  tagged as (
    select a.user_id, a.pts,
      case when (a.created_at at time zone 'Europe/London') >= m.this_m then 'this'
           when (a.created_at at time zone 'Europe/London') >= m.this_m - interval '1 month' then 'last' end as period
    from acts a, m where a.user_id is not null
  ),
  totals as (
    select t.period, t.user_id, sum(t.pts)::int as score,
      row_number() over (partition by t.period order by sum(t.pts) desc, t.user_id) as rk
    from tagged t join profiles p on p.id = t.user_id and p.role = 'member'
    where t.period is not null group by t.period, t.user_id
  )
  select t.period, t.user_id, p.name, t.score from totals t join profiles p on p.id = t.user_id
   where t.rk <= 3 and auth.uid() is not null
   order by t.period, t.score desc
$$;
revoke execute on function public.chat_stars() from public, anon;
grant execute on function public.chat_stars() to authenticated;

-- =====================================================================
--  Guests in the Quran Recitation chat, and Telegram alerts for guests
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. (Also in schema.sql.)
--
--  People who open the Quran event from a shared link or QR code, without
--  being members (or while still waiting for approval), can read the chat,
--  see the pinned weekly target, comment and post, after giving their name.
--  Nothing is held for approval. The admin can delete any post or comment,
--  and gets a Telegram alert for each guest message and each guest booking.
-- =====================================================================

-- Which chats guests may read and write in. Only the Quran chat for now.
alter table public.groups add column if not exists guests_allowed boolean not null default false;
update public.groups set guests_allowed = true where id = 'quran' and not guests_allowed;

-- Guest messages have no member behind them (user_id is null). guest_key is a hash of a
-- random code kept on the guest's phone, used to limit how often one phone can post.
alter table public.posts add column if not exists guest_key text;
alter table public.comments add column if not exists guest_key text;

-- Members waiting for approval can't post as members, but can still join in as a guest.
create or replace function public.require_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.guest_say', true), '') = '1' then return new; end if;
  if auth.uid() is not null and exists (select 1 from profiles where id = auth.uid() and not approved) then
    raise exception 'Your membership is waiting for the admin to approve it.';
  end if;
  return new;
end $$;

-- What a guest sees: the chat's newest 60 posts (pinned target first) and their comments.
create or replace function public.guest_chat(p_group text) returns json
language plpgsql stable security definer set search_path = public as $$
declare g groups;
begin
  select * into g from groups where id = p_group and guests_allowed;
  if not found then raise exception 'This chat is for members only.'; end if;
  return json_build_object(
    'group', json_build_object('id', g.id, 'name', g.name, 'about', g.about),
    'posts', coalesce((select json_agg(x order by x.pinned desc, x.created_at desc) from (
        select p.id, p.author_name, p.body, p.image, p.images, p.poll, p.pinned, p.created_at, p.user_id is null as guest
          from posts p where p.group_id = g.id
         order by p.pinned desc, p.created_at desc limit 60) x), '[]'::json),
    'comments', coalesce((select json_agg(c order by c.created_at) from (
        select c.id, c.post_id, c.author_name, c.body, c.created_at, c.user_id is null as guest
          from comments c join posts p on p.id = c.post_id
         where p.group_id = g.id) c), '[]'::json));
end $$;
revoke execute on function public.guest_chat(text) from public;
grant execute on function public.guest_chat(text) to anon, authenticated;

-- A guest posts in the chat (p_post null) or comments on a post. Shows as "Name (guest)".
create or replace function public.guest_say(p_group text, p_post uuid, p_name text, p_token text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare
  g groups;
  v_name text := left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 40);
  v_body text := left(trim(coalesce(p_body, '')), 1500);
  v_key text;
begin
  select * into g from groups where id = p_group and guests_allowed;
  if not found then raise exception 'This chat is for members only.'; end if;
  if length(v_name) < 2 then raise exception 'Please add your name.'; end if;
  if v_body = '' then raise exception 'Please write something first.'; end if;
  if length(coalesce(p_token, '')) < 16 then raise exception 'Please reload the page and try again.'; end if;
  v_key := md5(p_token);
  -- At most 6 messages in 10 minutes and 40 a day from one phone, and 60 in 10 minutes from all guests.
  if (select count(*) from posts where guest_key = v_key and created_at > now() - interval '10 minutes')
     + (select count(*) from comments where guest_key = v_key and created_at > now() - interval '10 minutes') >= 6
     or (select count(*) from posts where guest_key = v_key and created_at > now() - interval '1 day')
     + (select count(*) from comments where guest_key = v_key and created_at > now() - interval '1 day') >= 40 then
    raise exception 'You''ve sent a lot of messages. Please wait a little and try again.';
  end if;
  if (select count(*) from posts where guest_key is not null and created_at > now() - interval '10 minutes')
     + (select count(*) from comments where guest_key is not null and created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'The chat is very busy. Please try again in a few minutes.';
  end if;
  perform set_config('app.guest_say', '1', true);
  if p_post is null then
    insert into posts (group_id, user_id, author_name, body, guest_key)
    values (g.id, null, v_name || ' (guest)', v_body, v_key);
  else
    if not exists (select 1 from posts where id = p_post and group_id = g.id) then
      raise exception 'That post has been removed.';
    end if;
    insert into comments (post_id, user_id, author_name, body, guest_key)
    values (p_post, null, v_name || ' (guest)', v_body, v_key);
  end if;
  perform set_config('app.guest_say', '', true);
end $$;
revoke execute on function public.guest_say(text, uuid, text, text, text) from public;
grant execute on function public.guest_say(text, uuid, text, text, text) to anon, authenticated;

-- ---------- Telegram alerts to the admin ----------
-- Each guest post or comment, so the admin can delete anything unsuitable.
create or replace function public.alert_guest_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare gname text;
begin
  if new.guest_key is null then return new; end if;
  if tg_table_name = 'posts' then
    select name into gname from groups where id = new.group_id;
  else
    select gr.name into gname from posts p join groups gr on gr.id = p.group_id where p.id = new.post_id;
  end if;
  perform send_admin_alert(
    '💬 Guest ' || case when tg_table_name = 'posts' then 'post' else 'comment' end || ' in ' || coalesce(gname, 'a chat'),
    new.author_name || ': ' || left(new.body, 300) || E'\nYou can delete it in the chat (••• on a post, × on a comment).');
  return new;
exception when others then
  return new; -- an alert problem must never stop the message
end $$;
revoke execute on function public.alert_guest_message() from public, anon, authenticated;
drop trigger if exists zz_alert_guest_post on public.posts;
create trigger zz_alert_guest_post after insert on public.posts
  for each row execute function public.alert_guest_message();
drop trigger if exists zz_alert_guest_comment on public.comments;
create trigger zz_alert_guest_comment after insert on public.comments
  for each row execute function public.alert_guest_message();

-- Each non-member booking or booking request for an event.
create or replace function public.alert_guest_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare b bookings; e events;
begin
  select * into b from bookings where id = new.booking_id;
  select * into e from events where id = b.event_id;
  perform send_admin_alert(
    case when b.status = 'pending' then '🎟️ Guest asking to book: ' else '🎟️ Guest booked: ' end || coalesce(e.title, 'an event'),
    new.full_name || ', age ' || coalesce(new.age::text, '?') || ', ' || coalesce(b.places, 1) || ' place' || case when coalesce(b.places, 1) > 1 then 's' else '' end
      || case when b.status = 'pending' then E'\nApprove or decline it in Admin → Events and bookings.'
              when b.status = 'waitlist' then E'\nThe event is full, so they are on the waitlist.' else '' end);
  return new;
exception when others then
  return new;
end $$;
revoke execute on function public.alert_guest_booking() from public, anon, authenticated;
drop trigger if exists zz_alert_guest_booking on public.guests;
create trigger zz_alert_guest_booking after insert on public.guests
  for each row execute function public.alert_guest_booking();

-- =====================================================================
--  Guests in Admin: one record per guest, report, strikes, block, delete
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Run add-guest-chat.sql first. Safe to run more than once. (Also in schema.sql.)
--
--  A guest is a phone: the random code the app keeps on it (stored only as a hash,
--  guest_key). Chat posts and comments carry it, and from now on so do event
--  bookings made on that phone. Older guest bookings are grouped by email instead.
-- =====================================================================

alter table public.bookings add column if not exists guest_key text;
create index if not exists bookings_guest_key on public.bookings (guest_key) where guest_key is not null;
create index if not exists posts_guest_key on public.posts (guest_key) where guest_key is not null;
create index if not exists comments_guest_key on public.comments (guest_key) where guest_key is not null;

-- What only the admin sees about a guest: strikes, a note, and whether they're blocked.
create table if not exists public.guest_admin (
  key text primary key,
  name text not null default '',
  strikes int not null default 0 check (strikes between 0 and 9),
  note text not null default '',
  blocked_at timestamptz,
  emails text[] not null default '{}',   -- kept only while blocked, so they can't book again
  updated_at timestamptz not null default now()
);
alter table public.guest_admin enable row level security;
revoke all on public.guest_admin from anon, authenticated;

-- Right after a guest books on a phone, the app links the booking to that phone.
-- A blocked guest's booking is declined there and then.
create or replace function public.guest_link_booking(p_code text, p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; b bookings;
begin
  if length(coalesce(p_token, '')) < 16 then return 'ok'; end if;
  v_key := md5(p_token);
  select * into b from bookings where code = upper(trim(p_code)) and user_id is null and guest_key is null
     and created_at > now() - interval '1 hour';
  if not found then return 'ok'; end if;
  update bookings set guest_key = v_key where id = b.id;
  if exists (select 1 from guest_admin where key = v_key and blocked_at is not null) then
    update bookings set status = 'declined' where id = b.id;
    return 'blocked';
  end if;
  return 'ok';
end $$;
revoke execute on function public.guest_link_booking(text, text) from public;
grant execute on function public.guest_link_booking(text, text) to anon, authenticated;

-- A blocked guest's email can't be used to book.
create or replace function public.guest_email_not_blocked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from guest_admin where blocked_at is not null and lower(trim(new.email)) = any(emails)) then
    raise exception 'Sorry, we can''t take a booking from you. Please contact the organiser.';
  end if;
  return new;
end $$;
revoke execute on function public.guest_email_not_blocked() from public, anon, authenticated;
drop trigger if exists guests_not_blocked on public.guests;
create trigger guests_not_blocked before insert on public.guests
  for each row execute function public.guest_email_not_blocked();

-- A blocked guest can't post or comment.
create or replace function public.guest_say(p_group text, p_post uuid, p_name text, p_token text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare
  g groups;
  v_name text := left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 40);
  v_body text := left(trim(coalesce(p_body, '')), 1500);
  v_key text;
begin
  select * into g from groups where id = p_group and guests_allowed;
  if not found then raise exception 'This chat is for members only.'; end if;
  if length(v_name) < 2 then raise exception 'Please add your name.'; end if;
  if v_body = '' then raise exception 'Please write something first.'; end if;
  if length(coalesce(p_token, '')) < 16 then raise exception 'Please reload the page and try again.'; end if;
  v_key := md5(p_token);
  if exists (select 1 from guest_admin where key = v_key and blocked_at is not null) then
    raise exception 'Sorry, you can no longer post in this chat.';
  end if;
  if (select count(*) from posts where guest_key = v_key and created_at > now() - interval '10 minutes')
     + (select count(*) from comments where guest_key = v_key and created_at > now() - interval '10 minutes') >= 6
     or (select count(*) from posts where guest_key = v_key and created_at > now() - interval '1 day')
     + (select count(*) from comments where guest_key = v_key and created_at > now() - interval '1 day') >= 40 then
    raise exception 'You''ve sent a lot of messages. Please wait a little and try again.';
  end if;
  if (select count(*) from posts where guest_key is not null and created_at > now() - interval '10 minutes')
     + (select count(*) from comments where guest_key is not null and created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'The chat is very busy. Please try again in a few minutes.';
  end if;
  perform set_config('app.guest_say', '1', true);
  if p_post is null then
    insert into posts (group_id, user_id, author_name, body, guest_key)
    values (g.id, null, v_name || ' (guest)', v_body, v_key);
  else
    if not exists (select 1 from posts where id = p_post and group_id = g.id) then
      raise exception 'That post has been removed.';
    end if;
    insert into comments (post_id, user_id, author_name, body, guest_key)
    values (p_post, null, v_name || ' (guest)', v_body, v_key);
  end if;
  perform set_config('app.guest_say', '', true);
end $$;

-- One row per guest for the admin, most active first.
-- Activity over the last 90 days: 3 per booking, 3 per post, 2 per comment.
create or replace function public.guest_report() returns json
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - interval '90 days';
begin
  if not is_admin() then raise exception 'Only the admin can see guests.'; end if;
  return coalesce((
    with bk as (
      select coalesce(b.guest_key, 'email:' || lower(trim(gu.email))) as key, b.*, gu.full_name, gu.email, gu.age as guest_age
        from bookings b left join guests gu on gu.booking_id = b.id
       where b.user_id is null and b.booked_by is null and (b.guest_key is not null or gu.booking_id is not null)
    ),
    acts as (
      select guest_key as key, author_name as name, created_at, 'post' as what from posts where guest_key is not null
      union all select guest_key, author_name, created_at, 'comment' from comments where guest_key is not null
      union all select key, coalesce(full_name, display_name), created_at, 'booking' from bk
    ),
    keys as (select key from acts union select key from guest_admin)
    select json_agg(r order by r.score desc, r.last_active desc nulls last) from (
      select k.key,
        coalesce((select regexp_replace(a.name, ' \(guest\)$', '') from acts a where a.key = k.key and a.name <> 'Guest (details removed)' order by a.created_at desc limit 1),
                 nullif(ga.name, ''), 'Guest') as name,
        (select x.email from bk x where x.key = k.key and x.email is not null order by x.created_at desc limit 1) as email,
        (select min(created_at) from acts a where a.key = k.key) as first_seen,
        (select max(created_at) from acts a where a.key = k.key) as last_active,
        (select count(*) from acts a where a.key = k.key and a.what = 'post' and a.created_at >= since)::int as posts_90,
        (select count(*) from acts a where a.key = k.key and a.what = 'comment' and a.created_at >= since)::int as comments_90,
        (select count(*) from acts a where a.key = k.key and a.what = 'booking' and a.created_at >= since)::int as bookings_90,
        (select 3 * count(*) filter (where a.what in ('post', 'booking')) + 2 * count(*) filter (where a.what = 'comment')
           from acts a where a.key = k.key and a.created_at >= since)::int as score,
        coalesce((select json_agg(json_build_object('id', x.id, 'title', e.title, 'day', e.day, 'status', x.status, 'places', x.places,
                    'age', coalesce(x.age, x.guest_age), 'paid', x.paid, 'amount', x.amount, 'checked_in', x.checked_in) order by e.day desc nulls first)
                    from bk x join events e on e.id = x.event_id where x.key = k.key), '[]'::json) as bookings,
        coalesce(ga.strikes, 0) as strikes, coalesce(ga.note, '') as note, ga.blocked_at
      from keys k left join guest_admin ga on ga.key = k.key
    ) r), '[]'::json);
end $$;
revoke execute on function public.guest_report() from public, anon;
grant execute on function public.guest_report() to authenticated;

-- Strikes for a guest, like members' two strike rule.
create or replace function public.set_guest_strikes(p_key text, p_strikes int, p_note text, p_name text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can give strikes.'; end if;
  if p_strikes < 0 or p_strikes > 9 then raise exception 'Strikes go from 0 to 9.'; end if;
  insert into guest_admin (key, name, strikes, note) values (p_key, coalesce(p_name, ''), p_strikes, coalesce(p_note, ''))
  on conflict (key) do update set strikes = excluded.strikes, note = excluded.note,
    name = coalesce(nullif(excluded.name, ''), guest_admin.name), updated_at = now();
end $$;
revoke execute on function public.set_guest_strikes(text, int, text, text) from public, anon;
grant execute on function public.set_guest_strikes(text, int, text, text) to authenticated;

-- Block (or unblock) a guest: they can't post, comment or book from that phone or their emails.
create or replace function public.block_guest(p_key text, p_on boolean, p_name text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v_emails text[];
begin
  if not is_admin() then raise exception 'Only the admin can block guests.'; end if;
  select coalesce(array_agg(distinct lower(trim(gu.email))), '{}') into v_emails
    from guests gu join bookings b on b.id = gu.booking_id
   where coalesce(b.guest_key, 'email:' || lower(trim(gu.email))) = p_key;
  if p_key like 'email:%' then v_emails := array(select distinct unnest(v_emails || substr(p_key, 7))); end if;
  insert into guest_admin (key, name, blocked_at, emails) values (p_key, coalesce(p_name, ''), case when p_on then now() end, case when p_on then v_emails else '{}' end)
  on conflict (key) do update set blocked_at = case when p_on then coalesce(guest_admin.blocked_at, now()) end,
    emails = case when p_on then array(select distinct unnest(guest_admin.emails || excluded.emails)) else '{}' end,
    name = coalesce(nullif(excluded.name, ''), guest_admin.name), updated_at = now();
  if p_on then  -- anything still waiting for approval is declined
    update bookings set status = 'declined' where status = 'pending' and user_id is null
       and (guest_key = p_key or id in (select booking_id from guests where 'email:' || lower(trim(email)) = p_key));
  end if;
end $$;
revoke execute on function public.block_guest(text, boolean, text) from public, anon;
grant execute on function public.block_guest(text, boolean, text) to authenticated;

-- Delete a guest: their chat posts and comments, and their personal details. Bookings for
-- events still to come are cancelled; past ones stay as "Guest (details removed)" for the head
-- count. If they're blocked, the block (and their email, so they can't book again) is kept.
create or replace function public.delete_guest(p_key text) returns void
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  if not is_admin() then raise exception 'Only the admin can delete guests.'; end if;
  select coalesce(array_agg(b.id), '{}') into ids from bookings b left join guests gu on gu.booking_id = b.id
   where b.user_id is null and b.booked_by is null
     and (b.guest_key = p_key or 'email:' || lower(trim(gu.email)) = p_key);
  delete from comments where guest_key = p_key;
  delete from posts where guest_key = p_key;
  update bookings b set status = 'cancelled' from events e
   where b.id = any(ids) and e.id = b.event_id and (e.day is null or e.day >= current_date) and b.status in ('booked', 'waitlist', 'pending');
  delete from guests where booking_id = any(ids);
  update bookings set display_name = 'Guest (details removed)', age = null, gender = null, parent_ok = null,
    guest_key = case when exists (select 1 from guest_admin where key = p_key and blocked_at is not null) then guest_key end
   where id = any(ids);
  delete from guest_admin where key = p_key and blocked_at is null;
end $$;
revoke execute on function public.delete_guest(text) from public, anon;
grant execute on function public.delete_guest(text) to authenticated;

-- ===== add-accounts-tab.sql =====
-- =====================================================================
--  Accounts tab: each fund's accounts in its own chat, plus one
--  Accounts Reconciliation chat where the weekly Square check is pinned.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- ---------- the accounts chats ----------
insert into public.groups (id, name, about, sort, members_only) values
  ('accounts-reconciliation', 'Accounts Reconciliation',
   'All our funds together, checked against the Square account each week. Every approved member can read it; only the admin posts.', 1, true),
  ('events-accounts', 'Footballing Events Accounts',
   'Accounts for events paid from the events fund, with the receipts, and money moved between the kitty and events funds. Every approved member can read them; only the admin posts.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;
update public.groups set name = 'Friday Football Accounts', members_only = true, sort = 2,
  about = 'Our Friday football accounts, game by game, and money moved between the kitty and events funds. Every approved member can read them; only the admin posts.'
 where id = 'football-accounts';
update public.groups set name = 'BR3 Family Events Accounts', members_only = true, sort = 4,
  about = 'The BR3 Family Events fund: weekly subscriptions, money in and money spent. Every approved member can read it; only the admin posts.'
 where id = 'family-accounts';

-- Events accounts were redirected into the one Accounts chat (add-accounts-chat.sql). Each fund has its own chat again,
-- so posts to Footballing Events Accounts stay there. Earlier posts stay where they are.
drop trigger if exists posts_one_accounts_chat on public.posts;

-- ---------- who reads and who posts ----------
-- Every approved member reads all the accounts chats. Same rule as before otherwise (add-football-chats.sql).
alter table public.groups add column if not exists football_only boolean not null default false;
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when coalesce((select football_only from groups where id = g), false)
      then is_organiser() or is_footballer(auth.uid())
    else not coalesce((select members_only from groups where id = g), false)
      or is_organiser()
      or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
      or (g in ('football-accounts', 'events-accounts', 'family-accounts', 'accounts-reconciliation') and exists (select 1 from profiles where id = auth.uid() and approved))
  end
$$;
do $$ begin
  if exists (select 1 from pg_proc where proname = 'user_sees_group' and pronamespace = 'public'::regnamespace) then
    execute $f$
      create or replace function public.user_sees_group(u uuid, g text) returns boolean
      language sql stable security definer set search_path = public as $q$
        select case
          when coalesce((select football_only from groups where id = g), false)
            then exists (select 1 from profiles where id = u and (role in ('organiser', 'admin') or football or family))
          else not coalesce((select members_only from groups where id = g), false)
            or exists (select 1 from profiles where id = u and role = 'admin')
            or exists (select 1 from group_members where group_id = g and user_id = u)
            or (g in ('football-accounts', 'events-accounts', 'family-accounts', 'accounts-reconciliation') and exists (select 1 from profiles where id = u and approved))
        end
      $q$;
    $f$;
  end if;
end $$;
drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id not in ('football-accounts', 'events-accounts', 'family-accounts', 'accounts-reconciliation') or is_organiser())
              and can_see_group(group_id));

-- ---------- the weekly reconciliation ----------
-- One row per posted reconciliation: the funds, what was outside Square, what Square should show and did show.
-- The latest row is "last week" for the next one.
create table if not exists public.reconciliations (
  id bigserial primary key,
  posted_at timestamptz not null default now(),
  kitty numeric(10,2) not null,
  events numeric(10,2) not null,
  family numeric(10,2) not null,
  credits numeric(10,2) not null,
  unclaimed numeric(10,2) not null default 0,
  held numeric(10,2) not null,        -- cash and transfers not yet in Square
  advance numeric(10,2) not null,     -- paid for games and events not yet in accounts, less Square's fees
  square_expected numeric(10,2) not null,
  square_actual numeric(10,2) not null,
  why text,
  fix text,
  post_id uuid references public.posts(id) on delete set null,
  posted_by uuid references public.profiles(id) on delete set null
);
alter table public.reconciliations enable row level security;
drop policy if exists "members read reconciliations" on public.reconciliations;
create policy "members read reconciliations" on public.reconciliations for select to authenticated
  using (exists (select 1 from profiles where id = auth.uid() and approved));
grant select on public.reconciliations to authenticated;

-- Posts the reconciliation to the Accounts Reconciliation chat, pinned (the earlier one is unpinned),
-- records the Square balance, and keeps the figures for next week.
create or replace function public.post_reconciliation(p_body text, p_square numeric, p_why text, p_fix text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  fs fund_state; x jsonb; v_name text; v_post uuid; v_id bigint; v_exp numeric; v_held numeric; v_adv numeric;
begin
  if not is_admin() then raise exception 'Only the admin can post the reconciliation.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The reconciliation is empty.'; end if;
  if p_square is null then raise exception 'Enter the Square balance.'; end if;
  update fund_state set square_balance = round(p_square, 2), square_balance_at = now() where id = 1 returning * into fs;
  x := square_expected();
  v_exp := round((x->>'expected')::numeric, 2);
  v_held := coalesce((x->>'held_cash')::numeric, 0) + coalesce((x->>'held_bank')::numeric, 0);
  v_adv := coalesce((x->>'pending_in')::numeric, 0) - coalesce((x->>'pending_fees')::numeric, 0);
  if round(p_square, 2) <> v_exp and (trim(coalesce(p_why, '')) = '' or trim(coalesce(p_fix, '')) = '') then
    raise exception 'Square doesn''t match the funds: say why, and how and when it will be corrected.';
  end if;
  select name into v_name from profiles where id = auth.uid();
  update posts set pinned = false where group_id = 'accounts-reconciliation' and pinned;
  insert into posts (group_id, user_id, author_name, body, pinned)
    values ('accounts-reconciliation', auth.uid(), coalesce(v_name, 'Admin'), p_body, true)
    returning id into v_post;
  insert into reconciliations (kitty, events, family, credits, unclaimed, held, advance, square_expected, square_actual, why, fix, post_id, posted_by)
    values (fs.kitty, fs.events, coalesce(fs.family, 0), coalesce(fs.credits, 0), coalesce((to_jsonb(fs)->>'unclaimed')::numeric, 0),
            v_held, v_adv, v_exp, round(p_square, 2), nullif(trim(p_why), ''), nullif(trim(p_fix), ''), v_post, auth.uid())
    returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.post_reconciliation(text, numeric, text, text) from public, anon;
grant execute on function public.post_reconciliation(text, numeric, text, text) to authenticated;
