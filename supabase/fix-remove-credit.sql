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
