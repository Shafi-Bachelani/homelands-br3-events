-- =====================================================================
--  On the night: own-risk confirmation for people added at the pitch,
--  and matching a Square payment to a booking by hand.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

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
  update bookings set paid = true, method = 'card', card_fee = sp.fee where id = b.id;
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
