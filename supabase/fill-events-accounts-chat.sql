-- =====================================================================
--  Footballing Events Accounts chat: fill it with its own history.
--   * Makes sure the chat is there (on the Accounts tab).
--   * Events accounts that were moved into the one Accounts chat (now
--     Friday Football Accounts) move back to Footballing Events Accounts.
--   * Every transfer between the kitty and events funds shows in BOTH
--     chats, with the same date, so the two sets of accounts marry up.
--   * Each football game that paid money into (or took it out of) the
--     events fund gets its one-line note in Footballing Events Accounts.
--   * Nobody gets a phone notification for these older posts.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

insert into public.groups (id, name, about, sort, members_only) values
  ('events-accounts', 'Footballing Events Accounts',
   'Accounts for events paid from the events fund, with the receipts, and money moved between the kitty and events funds. Every approved member can read them; only the admin posts.', 3, true)
on conflict (id) do update set members_only = true;

-- Old posts shouldn't buzz everyone's phone.
do $$ begin
  if exists (select 1 from pg_trigger where tgname = 'zz_notify_new_post') then
    execute 'alter table public.posts disable trigger zz_notify_new_post';
  end if;
end $$;

-- 1. Events accounts (not football, not family) back to their own chat.
update public.posts p set group_id = 'events-accounts'
 where p.group_id = 'football-accounts'
   and exists (select 1 from public.accounts_posts a join public.events e on e.id = a.event_id
                where a.body = p.body and e.kind <> 'football');

-- 2. Transfers between funds: a copy in Footballing Events Accounts for each one in Friday Football Accounts.
insert into public.posts (group_id, user_id, author_name, body, created_at)
select 'events-accounts', p.user_id, p.author_name, p.body, p.created_at
  from public.posts p
 where p.group_id = 'football-accounts' and p.body like '**Transfer between funds**%'
   and not exists (select 1 from public.posts x where x.group_id = 'events-accounts' and x.body = p.body);
-- ...and the other way round.
insert into public.posts (group_id, user_id, author_name, body, created_at)
select 'football-accounts', p.user_id, p.author_name, p.body, p.created_at
  from public.posts p
 where p.group_id = 'events-accounts' and p.body like '**Transfer between funds**%'
   and not exists (select 1 from public.posts x where x.group_id = 'football-accounts' and x.body = p.body);

-- 3. Football games that moved money into or out of the events fund (owed money, kitty reset excess).
create or replace function public.football_to_events_body(p_amt numeric, p_bal numeric, p_day date) returns text
language sql immutable as $$
  select case when p_amt > 0 then 'Received £' || to_char(p_amt, 'FM999990.00') || ' from the football kitty account'
              else 'Paid £' || to_char(-p_amt, 'FM999990.00') || ' to the football kitty account' end
      || ' (Football ' || to_char(p_day, 'FMDD Mon') || ').' || chr(10)
      || 'Events fund now £' || to_char(p_bal, 'FM999990.00') || chr(10)
      || 'See the Friday Football Accounts chat for details.'
$$;

insert into public.posts (group_id, user_id, author_name, body, created_at)
select 'events-accounts', a.created_by, coalesce(nullif(pr.name, ''), 'Admin'),
       football_to_events_body(m.amt, m.bal, e.day), a.created_at
  from public.accounts_posts a
  join public.events e on e.id = a.event_id and e.kind = 'football'
  left join public.profiles pr on pr.id = a.created_by
  cross join lateral (
    select sum(l.amount) as amt,
           (select l2.balance from public.ledger l2 where l2.fund = 'events' and l2.created_at = a.created_at
             and l2.what not like 'Transfer %' order by l2.id desc limit 1) as bal
      from public.ledger l
     where l.fund = 'events' and l.created_at = a.created_at and l.what not like 'Transfer %') m
 where coalesce(m.amt, 0) <> 0
   and not exists (select 1 from public.posts x where x.group_id = 'events-accounts' and x.created_at = a.created_at
                     and x.body like '% the football kitty account (Football %');

-- From now on: the same note, naming the renamed chat.
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
  insert into posts (group_id, user_id, author_name, body)
    values ('events-accounts', new.created_by, coalesce(v_name, 'Admin'), football_to_events_body(amt, bal, e.day));
  return new;
end $$;
revoke execute on function public.post_football_to_events() from public, anon, authenticated;
drop trigger if exists accounts_posts_football_to_events on public.accounts_posts;
create trigger accounts_posts_football_to_events after insert on public.accounts_posts
  for each row execute function public.post_football_to_events();

do $$ begin
  if exists (select 1 from pg_trigger where tgname = 'zz_notify_new_post') then
    execute 'alter table public.posts enable trigger zz_notify_new_post';
  end if;
end $$;
