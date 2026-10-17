-- Football roster: own-risk agreement, one friend per member, family booked automatically.
-- Paste into Supabase → SQL Editor → Run. Safe to run more than once.

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
