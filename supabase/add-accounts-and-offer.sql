-- Football accounts with what actually came in and receipt photos; game-priced pay and play; £1 launch offer for 23 Oct.
-- Paste into Supabase → SQL Editor → Run, after add-roster-friends.sql. Safe to run more than once.

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
