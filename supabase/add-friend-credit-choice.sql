-- ---------- members choose to pay for their friend by card or from their credit (also in schema.sql) ----------
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean, p_credit boolean) returns public.bookings
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
  -- family pay by transfer; anyone else can choose to pay for their friend from their credit
  if p.family then v_paid := true; v_method := 'transfer';
  elsif coalesce(p_credit, false) and e.price > 0 then
    if p.credit < e.price then raise exception 'You don''t have enough credit. Pay by card instead.'; end if;
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
revoke execute on function public.book_friend(uuid, text, boolean, boolean) from public, anon;
grant execute on function public.book_friend(uuid, text, boolean, boolean) to authenticated;

-- The older 3-argument version never uses credit (pay by card).
create or replace function public.book_friend(p_event uuid, p_name text, p_risk boolean) returns public.bookings
language sql security definer set search_path = public as $$ select book_friend(p_event, p_name, p_risk, false) $$;

-- Pay for a friend already on the roster from your credit, instead of by card.
create or replace function public.pay_friend_credit(p_id uuid) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b bookings; e events; p profiles;
begin
  select * into b from bookings where id = p_id and booked_by = uid and status = 'booked' for update;
  if not found then raise exception 'Booking not found.'; end if;
  if b.paid then raise exception 'Your friend is already paid for.'; end if;
  select * into e from events where id = b.event_id;
  select * into p from profiles where id = uid for update;
  if p.credit < b.amount then raise exception 'You don''t have enough credit.'; end if;
  perform set_config('app.credit_reason', 'credit used to book friend ' || split_part(b.display_name, ' (', 1) || ' for football ' || to_char(e.day, 'FMDD Mon'), true);
  update profiles set credit = credit - b.amount where id = uid;
  perform set_config('app.credit_reason', '', true);
  update bookings set paid = true, method = 'credit' where id = p_id returning * into b;
  return b;
end $$;
revoke execute on function public.pay_friend_credit(uuid) from public, anon;
grant execute on function public.pay_friend_credit(uuid) to authenticated;
