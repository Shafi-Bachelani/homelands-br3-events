-- ---------- third fund: members' credits (also in schema.sql) ----------
-- Money members have paid but not used (paid but didn't play, or cancelled before Friday 6pm) is held
-- in the credits fund. It moves to the kitty fund when they pay for a game from their credit.
alter table public.fund_state add column if not exists credits numeric(10,2) not null default 0;
update public.fund_state set credits = (select coalesce(sum(credit), 0) from public.profiles) where id = 1;
alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits'));
insert into public.ledger (fund, what, amount, balance)
  select 'credits', 'Opening balance: members'' credit', credits, credits from public.fund_state where id = 1;

-- Accounts: what actually came in drives the funds.
--   credits fund: plus pay-and-play money from people who paid but didn't play or cancelled for credit,
--                 minus credit used by people who played (moved to the kitty fund)
--   kitty fund:   money received, less owed money cleared and the money moved into credits,
--                 plus credit used, less pitch hire and card fees
--   events fund:  plus owed money cleared
create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[], p_received numeric, p_images jsonb) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_credit numeric; v_noshow numeric; v_cancel numeric; v_name text;
  v_cleared numeric; x numeric; k text; v text; d text;
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

  -- Moved between funds by this game.
  select coalesce(sum(amount) filter (where status = 'booked' and method = 'credit' and checked_in), 0),
         coalesce(sum(amount) filter (where status = 'booked' and method in ('card', 'transfer', 'cash') and not checked_in
                                        and coalesce(user_id, booked_by) is not null), 0),
         coalesce(sum(amount) filter (where status = 'cancelled' and method in ('card', 'transfer', 'cash')), 0)
    into v_credit, v_noshow, v_cancel
    from bookings where event_id = p_event and charge = 'payg' and paid;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them).
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(amount) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and paid and not checked_in
             and method in ('card', 'transfer', 'cash', 'credit') and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in);
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  -- p_received is what actually came in by Square, transfer, cash or PayPal (not credit).
  if p_received is not null then
    income := p_received - v_cleared - v_noshow - v_cancel + v_credit;
  end if;

  select * into fs from fund_state where id = 1 for update;
  if v_noshow + v_cancel > 0 then
    fs.credits := fs.credits + v_noshow + v_cancel;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'credits', 'Football ' || d || ': paid but didn''t play, now credit', v_noshow + v_cancel, fs.credits);
  end if;
  if v_credit > 0 then
    fs.credits := fs.credits - v_credit;
    insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'credits', 'Football ' || d || ': paid from credit, moved to kitty', -v_credit, fs.credits);
  end if;
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

  update fund_state set kitty = fs.kitty, events = fs.events, credits = fs.credits, session_no = fs.session_no, games_played = fs.games_played where id = 1;
  update events set accounts_posted = true where id = p_event;
  insert into accounts_posts (event_id, body, created_by, images) values (p_event, p_body, auth.uid(), coalesce(p_images, '[]'));
  -- Keep a copy in the Football Accounts chat, with the receipt photos.
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body, image)
    values ('football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), p_body, coalesce(p_images, '[]')->>0);
  insert into posts (group_id, user_id, author_name, body, image)
    select 'football-accounts', auth.uid(), coalesce(v_name, 'Organiser'), 'More receipts for ' || d, img
      from jsonb_array_elements_text(coalesce(p_images, '[]')) with ordinality as t(img, n) where n > 1;
  return fs;
end $$;

-- Changing someone's credit by hand also changes the credits fund, with a line in the fund history.
create or replace function public.update_member(p_id uuid, p_role text, p_family boolean, p_credit numeric) returns void
language plpgsql security definer set search_path = public as $$
declare old numeric; v_name text; bal numeric;
begin
  if not is_organiser() then raise exception 'Only organisers can change members.'; end if;
  if p_role is not null and not is_admin() then raise exception 'Only the admin can change roles.'; end if;
  if p_id = auth.uid() and p_role is not null and p_role <> 'admin' then raise exception 'You cannot remove your own admin role.'; end if;
  select credit, name into old, v_name from profiles where id = p_id for update;
  update profiles set
    role = coalesce(p_role, role),
    family = coalesce(p_family, family),
    credit = coalesce(p_credit, credit)
  where id = p_id;
  if p_credit is not null and p_credit <> old then
    update fund_state set credits = credits + (p_credit - old) where id = 1 returning credits into bal;
    insert into ledger (fund, what, amount, balance) values ('credits', 'Credit changed by hand: ' || coalesce(v_name, 'member'), p_credit - old, bal);
  end if;
end $$;

-- The admin can set all three starting funds.
create or replace function public.set_funds(p_kitty numeric, p_events numeric, p_credits numeric, p_session int, p_games int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can set the funds.'; end if;
  update fund_state set kitty = p_kitty, events = p_events, credits = p_credits, session_no = p_session, games_played = p_games where id = 1;
  insert into ledger (fund, what, amount, balance) values
    ('kitty', 'Opening balance', p_kitty, p_kitty), ('events', 'Opening balance', p_events, p_events),
    ('credits', 'Opening balance', p_credits, p_credits);
end $$;
revoke execute on function public.set_funds(numeric, numeric, numeric, int, int) from public, anon;
grant execute on function public.set_funds(numeric, numeric, numeric, int, int) to authenticated;
