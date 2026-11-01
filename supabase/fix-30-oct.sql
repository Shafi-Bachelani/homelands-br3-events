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
