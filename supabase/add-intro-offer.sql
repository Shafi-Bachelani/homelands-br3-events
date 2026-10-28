-- =====================================================================
--  New member offer: while it's switched on, anyone who joins the app
--  pays just £1 for their first football game (pay and play), and the
--  events fund pays the other £5 into the kitty when the accounts are posted.
--  The admin switches it on or off on the Football page (Organiser).
--  This file switches it ON, for people who join from the moment you run it.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Run add-part-credit.sql first. Safe to run more than once.
-- =====================================================================

-- The switch, and from when new members count. Only switched on the first time this file runs.
do $$ begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fund_state' and column_name = 'intro_offer') then
    alter table public.fund_state add column intro_offer boolean not null default false;
    alter table public.fund_state add column intro_since timestamptz;
    update public.fund_state set intro_offer = true, intro_since = now() where id = 1;
  end if;
end $$;

-- How much of a £1 first game the events fund pays (the normal price less the £1).
alter table public.bookings add column if not exists intro_cover numeric(8,2) not null default 0;

-- Gets the offer: joined since it was switched on, and hasn't played a game yet (and isn't booked on one now).
-- Someone who booked but didn't turn up, or cancelled, still gets it next time.
create or replace function public.intro_offer_for(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(fs.intro_offer and p.created_at >= fs.intro_since, false)
     and not exists (select 1 from bookings b join events e on e.id = b.event_id
                      where e.kind = 'football' and b.user_id = p.id and b.status = 'booked'
                        and (b.checked_in or not e.accounts_posted))
    from fund_state fs, profiles p where fs.id = 1 and p.id = p_user
$$;
revoke execute on function public.intro_offer_for(uuid) from public, anon, authenticated;

-- For the booking screen: does the signed-in member get the £1 first game?
create or replace function public.my_intro_offer() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(intro_offer_for(auth.uid()), false)
$$;
revoke execute on function public.my_intro_offer() from public, anon;
grant execute on function public.my_intro_offer() to authenticated;

-- Every way a member gets a pay-and-play place (booking, added on the day, family) goes through here.
-- Friends and non-members never get it: they always pay the full price.
create or replace function public.apply_intro_offer() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events; spent numeric; keep numeric;
begin
  if new.user_id is null or new.booked_by is not null or new.charge <> 'payg' then return new; end if;
  select * into e from events where id = new.event_id;
  if not found or e.kind <> 'football' or e.price <= 1 or new.amount <> e.price then return new; end if;
  if not intro_offer_for(new.user_id) then return new; end if;
  -- credit already taken for the full price: keep £1 of it at most and give the rest back
  spent := case when new.method = 'credit' then new.amount else coalesce(new.credit_used, 0) end;
  new.intro_cover := new.amount - 1;
  new.amount := 1;
  if spent > 0 then
    keep := least(spent, 1);
    if spent > keep then
      perform set_config('app.credit_reason', 'credit given back, first game is £1 (new member offer)', true);
      update profiles set credit = credit + (spent - keep) where id = new.user_id;
      perform set_config('app.credit_reason', '', true);
    end if;
    new.credit_used := keep;
    if keep >= 1 then new.paid := true; new.method := 'credit'; end if;
  end if;
  return new;
end $$;
revoke execute on function public.apply_intro_offer() from public, anon, authenticated;
drop trigger if exists bookings_intro_offer on public.bookings;
create trigger bookings_intro_offer before insert on public.bookings
  for each row execute function public.apply_intro_offer();

-- The admin's on/off switch. Switching it back on starts again from that moment.
create or replace function public.set_intro_offer(p_on boolean) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state;
begin
  if not is_admin() then raise exception 'Only the admin can change the new member offer.'; end if;
  update fund_state set intro_since = case when p_on and not intro_offer then now() else intro_since end,
                        intro_offer = coalesce(p_on, false)
   where id = 1 returning * into fs;
  return fs;
end $$;
revoke execute on function public.set_intro_offer(boolean) from public, anon;
grant execute on function public.set_intro_offer(boolean) to authenticated;

-- Accounts: same as add-part-credit.sql, plus the events fund paying the rest of new members' £1 first games.
create or replace function public.post_accounts(p_event uuid, p_body text, p_hire numeric, p_fees numeric,
  p_methods jsonb, p_cleared uuid[], p_received numeric, p_images jsonb) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; income numeric; v_credit numeric; v_noshow numeric; v_cancel numeric; v_name text;
  v_cleared numeric; x numeric; k text; v text; d text; v_intro numeric; v_intro_n int;
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
  -- Credit that went into places that count (people who played, and kitty joiners), whole or part paid.
  select coalesce(sum(case when method = 'credit' then amount else credit_used end), 0) into v_credit
    from bookings where event_id = p_event and status = 'booked' and charge in ('payg', 'kitty')
     and (charge = 'kitty' or checked_in) and (method = 'credit' or credit_used > 0);
  -- Money (not credit) from people who paid but didn't play, or cancelled for credit.
  select coalesce(sum(amount - credit_used) filter (where status = 'booked' and method in ('card', 'transfer', 'cash') and not checked_in
                                        and coalesce(user_id, booked_by) is not null), 0),
         coalesce(sum(amount - credit_used) filter (where status = 'cancelled' and method in ('card', 'transfer', 'cash')), 0)
    into v_noshow, v_cancel
    from bookings where event_id = p_event and charge = 'payg' and paid;

  -- Money received: kitty payments, and pay-and-play only for people who played (credit included).
  select coalesce(sum(amount), 0) into income from bookings
   where event_id = p_event and status = 'booked' and paid
     and method in ('card', 'transfer', 'cash', 'credit')
     and (charge = 'kitty' or checked_in);
  -- Paid but didn't turn up: the money becomes credit on their account instead
  -- (for a friend, on the account of the member who booked them). The credits fund follows by trigger.
  perform set_config('app.credit_reason', 'paid but didn''t play at football ' || d || ', credit added', true);
  -- Someone who used part of their credit but never paid the rest and didn't play gets that credit back.
  update profiles p set credit = p.credit + s.amt
    from (select coalesce(user_id, booked_by) user_id, sum(case when paid then amount else credit_used end) amt from bookings
           where event_id = p_event and status = 'booked' and charge = 'payg' and not checked_in
             and ((paid and method in ('card', 'transfer', 'cash', 'credit')) or (not paid and credit_used > 0))
             and coalesce(user_id, booked_by) is not null
           group by coalesce(user_id, booked_by)) s
   where p.id = s.user_id;
  perform set_config('app.credit_reason', '', true);
  -- Only people who played (or joined the kitty) can owe.
  insert into debts (user_id, amount, reason, on_date)
    select coalesce(user_id, booked_by), amount - credit_used, 'Football ' || d || case when user_id is null then ' (friend: ' || display_name || ')' else '' end, e.day from bookings
     where event_id = p_event and status = 'booked' and method = 'owes' and coalesce(user_id, booked_by) is not null
       and (charge = 'kitty' or checked_in) and amount > credit_used;
  select coalesce(sum(amount), 0) into v_cleared from debts where id = any(coalesce(p_cleared, '{}')) and not debts.cleared;
  update debts set cleared = true where id = any(coalesce(p_cleared, '{}'));

  -- p_received is what actually came in by Square, transfer, cash or PayPal (not credit).
  if p_received is not null then
    income := p_received - v_cleared - v_noshow - v_cancel + v_credit;
  end if;

  select * into fs from fund_state where id = 1 for update;
  fs.kitty := fs.kitty + income;
  insert into ledger (on_date, fund, what, amount, balance) values (e.day, 'kitty', 'Football ' || d || ': money received', income, fs.kitty);
  -- New members who played their first game for £1: the events fund pays the rest of the price into the kitty.
  select coalesce(sum(intro_cover), 0), count(*) into v_intro, v_intro_n from bookings
   where event_id = p_event and status = 'booked' and charge = 'payg' and checked_in and intro_cover > 0;
  if v_intro > 0 then
    fs.kitty := fs.kitty + v_intro;
    fs.events := fs.events - v_intro;
    insert into ledger (on_date, fund, what, amount, balance) values
      (e.day, 'kitty', 'Football ' || d || ': new member offer paid by the events fund (' || v_intro_n || ')', v_intro, fs.kitty),
      (e.day, 'events', 'Football ' || d || ': new member offer, first game for ' || v_intro_n || ' new member' || case when v_intro_n = 1 then '' else 's' end, -v_intro, fs.events);
  end if;
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

  update fund_state set kitty = fs.kitty, events = fs.events, session_no = fs.session_no, games_played = fs.games_played,
    credits_posted = credits, posted_at = now() where id = 1;
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
-- Events Accounts chat: the new member offer gets its own line, apart from other football money.
create or replace function public.post_football_to_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events; amt numeric; intro numeric; n int; bal numeric; v_name text; body text := '';
begin
  select * into e from events where id = new.event_id;
  if not found or e.kind <> 'football' then return new; end if;
  -- post_accounts writes its ledger rows earlier in the same transaction, so they share this timestamp.
  select coalesce(sum(amount) filter (where what not like '%new member offer%'), 0),
         coalesce(-sum(amount) filter (where what like '%new member offer%'), 0)
    into amt, intro from ledger
   where fund = 'events' and created_at = now() and what not like 'Transfer %';
  if amt = 0 and intro = 0 then return new; end if;
  select events into bal from fund_state where id = 1;
  select name into v_name from profiles where id = new.created_by;
  if amt <> 0 then
    body := case when amt > 0 then 'Received £' || to_char(amt, 'FM999990.00') || ' from the football kitty account'
                 else 'Paid £' || to_char(-amt, 'FM999990.00') || ' to the football kitty account' end
            || ' (Football ' || to_char(e.day, 'FMDD Mon') || ').' || chr(10);
  end if;
  if intro > 0 then
    select count(*) into n from bookings where event_id = e.id and status = 'booked' and checked_in and intro_cover > 0;
    body := body || 'Paid £' || to_char(intro, 'FM999990.00') || ' to the football kitty account for the new member offer: '
            || n || ' new member' || case when n = 1 then '' else 's' end || ' played their first game for £1 (Football '
            || to_char(e.day, 'FMDD Mon') || ').' || chr(10);
  end if;
  insert into posts (group_id, user_id, author_name, body) values ('events-accounts', new.created_by, coalesce(v_name, 'Admin'),
    body || 'Events fund now £' || to_char(bal, 'FM999990.00') || chr(10) || 'See the Football Accounts chat for details.');
  return new;
end $$;
revoke execute on function public.post_football_to_events() from public, anon, authenticated;
drop trigger if exists accounts_posts_football_to_events on public.accounts_posts;
create trigger accounts_posts_football_to_events after insert on public.accounts_posts
  for each row execute function public.post_football_to_events();
