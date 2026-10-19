-- ---------- people added on the day who aren't members pay the full £6, not the members' offer price (also in schema.sql) ----------
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state; v_price numeric;
begin
  if not is_organiser() then raise exception 'Only organisers can add players.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game are already posted.'; end if;
  if p_method not in ('card', 'transfer', 'cash', 'owes', 'credit') then raise exception 'Choose how they paid.'; end if;
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
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', v_price, p_method <> 'owes', p_method, true, new_code('AA-'))
  returning * into b;
  return b;
end $$;
