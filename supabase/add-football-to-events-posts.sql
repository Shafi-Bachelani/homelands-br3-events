-- =====================================================================
--  When a football game's accounts move money into (or out of) the events fund
--  (owed money cleared, or the kitty's excess at a reset), the Events Accounts
--  chat gets a one-line summary pointing to Football Accounts for the details.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Run after add-fund-transfers-and-event-accounts.sql. Safe to run more than once.
-- =====================================================================

create or replace function public.post_football_to_events() returns trigger
language plpgsql security definer set search_path = public as $$
declare e events; amt numeric; bal numeric; v_name text;
begin
  select * into e from events where id = new.event_id;
  if not found or e.kind <> 'football' then return new; end if;
  -- post_accounts writes its ledger rows earlier in the same transaction, so they share this timestamp.
  select coalesce(sum(amount), 0) into amt from ledger
   where fund = 'events' and created_at = now() and what not like 'Transfer %';
  if amt = 0 then return new; end if;
  select events into bal from fund_state where id = 1;
  select name into v_name from profiles where id = new.created_by;
  insert into posts (group_id, user_id, author_name, body) values ('events-accounts', new.created_by, coalesce(v_name, 'Admin'),
    case when amt > 0 then 'Received £' || to_char(amt, 'FM999990.00') || ' from the football kitty account'
         else 'Paid £' || to_char(-amt, 'FM999990.00') || ' to the football kitty account' end
    || ' (Football ' || to_char(e.day, 'FMDD Mon') || ').' || chr(10)
    || 'Events fund now £' || to_char(bal, 'FM999990.00') || chr(10)
    || 'See the Football Accounts chat for details.');
  return new;
end $$;
revoke execute on function public.post_football_to_events() from public, anon, authenticated;
drop trigger if exists accounts_posts_football_to_events on public.accounts_posts;
create trigger accounts_posts_football_to_events after insert on public.accounts_posts
  for each row execute function public.post_football_to_events();
