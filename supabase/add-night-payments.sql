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
