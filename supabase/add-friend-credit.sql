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
