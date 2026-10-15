-- Football accounts follow who actually turned up:
--  * A paid £6 pay-and-play place only counts as money received if the player was ticked as here.
--  * A paid player who didn't turn up isn't refunded: the £6 goes onto their account as credit.
--  * Paying with credit counts as money received in the game where it is used.
--  * The organiser can add someone on the day who wasn't on the list, with a £6 charge.
-- Safe to run more than once.

create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[]) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_cleared numeric; x numeric; k text; v text; d text;
begin
  if not is_organiser() then raise exception 'Only organisers can post accounts.'; end if;
  select * into e from events where id = p_event and kind = 'football' for update;
  if not found then raise exception 'That game no longer exists.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this game were already posted.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and status = 'booked' and checked_in) then
    raise exception 'Tick who turned up under "Who''s turned up" before posting the accounts.';
  end if;
  d := to_char(e.day, 'FMDD Mon');

  for k, v in select * from jsonb_each_text(coalesce(p_methods, '{}')) loop
    update bookings set method = v, paid = (v <> 'owes')
     where id = k::uuid and event_id = p_event and method is distinct from 'credit';
  end loop;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead.
  update profiles p set credit = p.credit + s.amt
    from (select user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and user_id is not null
           group by user_id) s
   where p.id = s.user_id;
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select user_id, amount, 'Football ' || d, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and user_id is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  select * into fs from fund_state where id = 1 for update;
  fs.kitty := fs.kitty + income;
  insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': money received', income, fs.kitty);
  fs.kitty := fs.kitty - coalesce(p_hire, 0);
  insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': pitch hire', -coalesce(p_hire, 0), fs.kitty);
  if coalesce(p_fees, 0) > 0 then
    fs.kitty := fs.kitty - p_fees;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': card fees', -p_fees, fs.kitty);
  end if;
  if v_cleared > 0 then
    fs.events := fs.events + v_cleared;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'events', 'Football ' || d || ': owed money cleared', v_cleared, fs.events);
  end if;
  fs.games_played := fs.games_played + 1;

  if fs.kitty < 150 or fs.games_played >= 5 then
    x := fs.kitty - 100;
    fs.events := fs.events + x; fs.kitty := 100;
    insert into ledger (on_date, fund, what, amount, balance) values
      (e.day, 'kitty', 'Kitty ' || fs.session_no || ' ends: reset to £100', -x, fs.kitty),
      (e.day, 'events', 'Kitty ' || fs.session_no || ' ends: ' || case when x >= 0 then 'excess moved in' else 'top-up to kitty' end, x, fs.events);
    fs.session_no := fs.session_no + 1; fs.games_played := 0;
  end if;

  update fund_state set kitty = fs.kitty, events = fs.events, session_no = fs.session_no, games_played = fs.games_played where id = 1;
  update events set accounts_posted = true where id = p_event;
  insert into accounts_posts (event_id, body, created_by) values (p_event, p_body, auth.uid());
  return fs;
end $$;

-- Add someone on the day who wasn't on the list: marked as here, £6 pay and play
-- (or covered if they're in the current kitty). Pass a member's id, or just a name for a non-member.
create or replace function public.add_walkin(p_event uuid, p_user uuid, p_name text, p_method text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare e events; p profiles; b bookings; fs fund_state;
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
      if p.credit < 6 then raise exception '% doesn''t have £6 of credit.', p.name; end if;
      update profiles set credit = credit - 6 where id = p_user;
    end if;
  elsif coalesce(trim(p_name), '') = '' then raise exception 'Choose a member or type their name.';
  elsif p_method = 'credit' then raise exception 'Only members can pay with credit.';
  end if;
  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, checked_in, code)
  values (p_event, p_user, coalesce(p.name, trim(p_name)), 'payg', 6, p_method <> 'owes', p_method, true, new_code('AA-'))
  returning * into b;
  return b;
end $$;
revoke execute on function public.add_walkin(uuid, uuid, text, text) from public, anon;
grant execute on function public.add_walkin(uuid, uuid, text, text) to authenticated;
