-- =====================================================================
--  Every transfer between funds is also posted to the Football Accounts
--  and Events Accounts chats, including the transfers already made.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Run after add-fund-transfers-and-event-accounts.sql. Safe to run more than once.
-- =====================================================================

alter table public.fund_transfers add column if not exists posted boolean not null default false;

-- The chat post for one transfer, with both funds' values straight after it.
create or replace function public.transfer_post_body(t public.fund_transfers, p_kitty numeric, p_events numeric) returns text
language sql immutable set search_path = public as $$
  select '**Transfer between funds**' || chr(10)
    || '£' || to_char(t.amount, 'FM999990.00') || ' from the ' || initcap(t.from_fund) || ' fund to the ' || initcap(t.to_fund) || ' fund' || chr(10)
    || 'Reason: ' || t.reason || chr(10)
    || coalesce('Kitty fund now £' || to_char(p_kitty, 'FM999990.00') || chr(10), '')
    || coalesce('Events fund now £' || to_char(p_events, 'FM999990.00') || chr(10), '')
    || 'By ' || coalesce(nullif(t.made_by_name, ''), 'Admin') || ', ' || to_char(t.on_date, 'FMDy FMDD Mon')
$$;

create or replace function public.transfer_funds(p_from text, p_to text, p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; t fund_transfers; v_name text; r text := trim(coalesce(p_reason, '')); a numeric := round(coalesce(p_amount, 0), 2); held numeric;
begin
  if not is_admin() then raise exception 'Only the admin can move money between funds.'; end if;
  if p_from is null or p_to is null or p_from not in ('kitty', 'events') or p_to not in ('kitty', 'events') or p_from = p_to then
    raise exception 'Choose two different funds: the kitty fund or the events fund.';
  end if;
  if a <= 0 then raise exception 'Enter an amount over £0.'; end if;
  if r = '' then raise exception 'Give a reason for the transfer.'; end if;
  select * into fs from fund_state where id = 1 for update;
  held := case p_from when 'kitty' then fs.kitty else fs.events end;
  if held < a then raise exception 'The % fund only holds £%.', p_from, held; end if;
  if p_from = 'kitty' then fs.kitty := fs.kitty - a; fs.events := fs.events + a;
  else fs.events := fs.events - a; fs.kitty := fs.kitty + a; end if;
  select name into v_name from profiles where id = auth.uid();
  insert into fund_transfers (from_fund, to_fund, amount, reason, made_by, made_by_name, posted)
    values (p_from, p_to, a, r, auth.uid(), coalesce(v_name, 'Admin'), true) returning * into t;
  insert into ledger (fund, what, amount, balance) values
    (p_from, 'Transfer to ' || initcap(p_to) || ' fund: ' || r, -a, case p_from when 'kitty' then fs.kitty else fs.events end),
    (p_to, 'Transfer from ' || initcap(p_from) || ' fund: ' || r, a, case p_to when 'kitty' then fs.kitty else fs.events end);
  update fund_state set kitty = fs.kitty, events = fs.events where id = 1;
  -- Everyone sees it in both accounts chats.
  insert into posts (group_id, user_id, author_name, body)
    select g, auth.uid(), coalesce(v_name, 'Admin'), transfer_post_body(t, fs.kitty, fs.events)
      from unnest(array['football-accounts', 'events-accounts']) g;
  return fs;
end $$;
revoke execute on function public.transfer_funds(text, text, numeric, text) from public, anon;
grant execute on function public.transfer_funds(text, text, numeric, text) to authenticated;

-- Post the transfers made before this, dated when they were made, with the fund values the ledger recorded then.
insert into public.posts (group_id, user_id, author_name, body, created_at)
  select g, t.made_by, coalesce(nullif(t.made_by_name, ''), 'Admin'),
         transfer_post_body(t,
           (select l.balance from ledger l where l.fund = 'kitty' and l.created_at = t.created_at and l.what = case when l.fund = t.from_fund
             then 'Transfer to ' || initcap(t.to_fund) || ' fund: ' || t.reason else 'Transfer from ' || initcap(t.from_fund) || ' fund: ' || t.reason end order by l.id desc limit 1),
           (select l.balance from ledger l where l.fund = 'events' and l.created_at = t.created_at and l.what = case when l.fund = t.from_fund
             then 'Transfer to ' || initcap(t.to_fund) || ' fund: ' || t.reason else 'Transfer from ' || initcap(t.from_fund) || ' fund: ' || t.reason end order by l.id desc limit 1)),
         t.created_at
    from public.fund_transfers t cross join unnest(array['football-accounts', 'events-accounts']) g
   where not t.posted;
update public.fund_transfers set posted = true where not posted;
