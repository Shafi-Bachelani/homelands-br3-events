-- Kitty top-up at the pitch. An organiser adding someone can choose £6 pay and play, £15 to join the kitty,
-- or a top-up for a member already on the list who paid pay and play: they pay the rest (£9 on a £6 place)
-- and their place becomes a kitty place. What they paid first stays with its own method; the top-up keeps its own.
-- Run in the Supabase SQL editor. The app keeps working on the old version until the update is published.
alter table public.bookings add column if not exists topup numeric(8,2) not null default 0;
alter table public.bookings add column if not exists topup_method text;

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
      if p_method in ('owes', 'link', 'credit') then raise exception 'A top-up can be paid by card, transfer or cash.'; end if;
      if not b.paid or b.method in ('owes', 'credit') then
        -- nothing paid yet, or paid from credit: that credit stays as credit used, and the rest is paid now
        update bookings set charge = 'kitty', amount = 15, intro_cover = 0, method = p_method, paid = true,
                            credit_used = case when b.paid and b.method = 'credit' then b.amount else b.credit_used end,
                            checked_in = true, status = 'booked', pitch_link = false where id = b.id returning * into b;
      else
        update bookings set charge = 'kitty', amount = 15, intro_cover = 0, topup = 15 - b.amount, topup_method = p_method,
                            checked_in = true, status = 'booked' where id = b.id returning * into b;
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
