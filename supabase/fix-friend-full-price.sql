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

-- Friends already on a roster but not yet paid move to the full price (a fresh payment link is made).
update public.bookings set amount = 6, square_order_id = null
 where booked_by is not null and status = 'booked' and not paid and amount < 6;
