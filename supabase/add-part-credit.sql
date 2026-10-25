-- =====================================================================
--  Members choose whether to use their credit, and can use part of it
--  (e.g. £1 credit makes a £6 game £5 by card, or the £15 kitty £14).
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Run it BEFORE the app update goes live.
-- =====================================================================

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
