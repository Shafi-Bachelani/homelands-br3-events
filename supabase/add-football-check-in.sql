-- ---------- football check-in by QR code, and payment links for people added at the pitch (also in schema.sql) ----------

-- Anyone who has turned up (checked in) is never released for not paying; they pay or owe on the day.
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  with x as (
    select b.id, b.event_id, b.user_id, b.charge from bookings b join events e on e.id = b.event_id
     where e.kind = 'football' and not b.paid and b.status = 'booked' and not e.accounts_posted and not b.checked_in
       and now() > greatest(fb_pay_by(e.day), b.created_at + interval '30 minutes')
  ), k as (
    update profiles p set kitty_session = null from x where x.user_id = p.id and x.charge = 'kitty' and p.kitty_session = s
  ), r as (
    insert into football_removed (event_id, user_id) select event_id, user_id from x where user_id is not null on conflict do nothing
  )
  delete from bookings where id in (select id from x);
  get diagnostics n = row_count;
  perform add_family_bookings();
  return n;
end $$;

-- Organisers adding someone at the pitch can also choose 'link': they're marked here, unpaid, and sent a payment link.
alter table public.bookings add column if not exists pitch_link boolean not null default false;
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
begin
  if not is_organiser() then raise exception 'Only organisers can add players.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game are already posted.'; end if;
  if p_method not in ('card', 'transfer', 'cash', 'owes', 'credit', 'link') then raise exception 'Choose how they paid.'; end if;
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
  -- offer prices are for members; anyone else pays the full £6
  v_price := case when p_user is null then greatest(e.price, 6) else e.price end;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code, pitch_link)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', v_price, p_method not in ('owes', 'link'),
          nullif(p_method, 'link'), true, new_code('AA-'), p_method = 'link')
  returning * into b;
  return b;
end $$;

-- Check-in details also say what kind of event it is, so football shows kitty or pay and play.
create or replace function public.check_in_details(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare b bookings; e events; g guests; v_by text; v_was boolean;
begin
  if not is_organiser() then raise exception 'Only organisers can check people in.'; end if;
  select * into b from bookings where code = upper(trim(p_code));
  if not found then raise exception 'No ticket found with code %.', upper(trim(p_code)); end if;
  select * into e from events where id = b.event_id;
  select * into g from guests where booking_id = b.id;
  select name into v_by from profiles where id = coalesce(g.invited_by, b.booked_by);
  v_was := b.checked_in;
  if b.status = 'booked' and not b.checked_in then
    update bookings set checked_in = true where id = b.id;
  end if;
  return json_build_object(
    'id', b.id, 'code', b.code, 'name', b.display_name, 'status', b.status, 'places', b.places,
    'already', v_was, 'paid', b.paid, 'amount', b.amount, 'method', b.method, 'charge', b.charge,
    'age', coalesce(b.age, g.age), 'gender', b.gender, 'parent_ok', b.parent_ok,
    'title', e.title, 'day', e.day, 'time', e.time, 'kind', e.kind, 'event_id', e.id,
    'guest', g.booking_id is not null, 'guest_name', g.full_name, 'booked_by', v_by);
end $$;
revoke execute on function public.check_in_details(text) from public, anon;
grant execute on function public.check_in_details(text) to authenticated;
