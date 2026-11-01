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
