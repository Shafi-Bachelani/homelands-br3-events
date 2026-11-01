-- Each event is linked to a fund: its profit goes into that fund and its loss comes out of it.
-- Events fund by default; the Family Events fund for family events.
alter table public.events add column if not exists fund text not null default 'events';
alter table public.events drop constraint if exists events_fund_check;
alter table public.events add constraint events_fund_check check (fund in ('events', 'family'));

alter table public.event_accounts add column if not exists fund text not null default 'events';
alter table public.event_accounts add column if not exists fund_before numeric;
alter table public.event_accounts add column if not exists fund_after numeric;

create or replace function public.post_event_accounts(p_event uuid, p_body text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; v_name text; d text; rec numeric; hire numeric; anc numeric;
  k_net numeric; e_net numeric; v_transfers jsonb; v_photos jsonb; v_fund text; v_bal numeric; v_before numeric;
begin
  if not is_admin() then raise exception 'Only the admin can post accounts.'; end if;
  select * into e from events where id = p_event for update;
  if not found then raise exception 'Event not found.'; end if;
  if e.kind = 'football' then raise exception 'Football accounts are posted from the Football page.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this event were already posted.'; end if;
  if not exists (select 1 from event_account_lines where event_id = p_event) then raise exception 'Add the receipts and costs first.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The accounts are empty.'; end if;
  v_fund := coalesce(e.fund, 'events');

  select coalesce(sum(amount) filter (where kind = 'receipt'), 0), coalesce(sum(amount) filter (where kind = 'hiring'), 0),
         coalesce(sum(amount) filter (where kind = 'ancillary'), 0)
    into rec, hire, anc from event_account_lines where event_id = p_event;
  select coalesce(jsonb_agg(photo order by case kind when 'receipt' then 1 when 'hiring' then 2 else 3 end, created_at, id), '[]')
    into v_photos from event_account_lines where event_id = p_event and photo is not null;

  select * into fs from fund_state where id = 1 for update;
  -- Transfers since the last posted accounts, so the accounts show the funds before them.
  select coalesce(sum(case when to_fund = 'kitty' then amount else -amount end), 0),
         coalesce(sum(case when to_fund = 'events' then amount else -amount end), 0),
         coalesce(jsonb_agg(jsonb_build_object('on_date', on_date, 'from', from_fund, 'to', to_fund, 'amount', amount, 'reason', reason) order by id), '[]')
    into k_net, e_net, v_transfers from fund_transfers where accounts_post_id is null;

  v_before := case v_fund when 'family' then coalesce(fs.family, 0) else fs.events end;
  v_bal := v_before;
  d := e.title || ' ' || coalesce(to_char(e.day, 'FMDD Mon YYYY'), '(date to be confirmed)');
  if rec > 0 then
    v_bal := v_bal + rec;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), v_fund, d || ': receipts', rec, v_bal);
  end if;
  if hire > 0 then
    v_bal := v_bal - hire;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), v_fund, d || ': hiring costs', -hire, v_bal);
  end if;
  if anc > 0 then
    v_bal := v_bal - anc;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), v_fund, d || ': ancillary costs', -anc, v_bal);
  end if;
  if v_fund = 'family' then
    fs.family := v_bal; update fund_state set family = v_bal where id = 1;
  else
    fs.events := v_bal; update fund_state set events = v_bal where id = 1;
  end if;
  update events set accounts_posted = true where id = p_event;

  insert into event_accounts (event_id, receipts, hiring, ancillary, kitty_before, events_before, transfers, kitty_after, events_after, posted_by, fund, fund_before, fund_after)
    values (p_event, rec, hire, anc, fs.kitty - k_net,
            fs.events - (case when v_fund = 'events' then rec - hire - anc else 0 end) - e_net,
            v_transfers, fs.kitty, fs.events, auth.uid(), v_fund,
            case when v_fund = 'events' then v_before - e_net else v_before end, v_bal);
  insert into accounts_posts (event_id, body, created_by) values (p_event, p_body, auth.uid());
  select name into v_name from profiles where id = auth.uid();
  -- Family events go to the Family Events Accounts chat; the rest to the Accounts chat.
  insert into posts (group_id, user_id, author_name, body, images)
    values (case v_fund when 'family' then 'family-accounts' else 'events-accounts' end, auth.uid(), coalesce(v_name, 'Admin'), p_body, v_photos);
  return fs;
end $$;
revoke execute on function public.post_event_accounts(uuid, text) from public, anon;
grant execute on function public.post_event_accounts(uuid, text) to authenticated;
