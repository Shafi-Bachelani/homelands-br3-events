-- =====================================================================
--  One file that puts the accounts set-up right, then adds Starling.
--  add-accounts-tab.sql hadn't gone in, so the old "one Accounts chat"
--  rule was still sending Footballing Events posts to Friday Football
--  Accounts. This file:
--   1. runs add-accounts-tab.sql (Accounts Reconciliation chat, the
--      weekly reconciliation, and each fund in its own chat),
--   2. tidies what the old rule did this morning: removes the doubled
--      transfer posts in Friday Football Accounts and moves the
--      "Received £x from the football kitty" notes back,
--   3. runs fill-events-accounts-chat.sql again so Footballing Events
--      Accounts gets its transfers,
--   4. runs add-starling.sql.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- ===== 1. add-accounts-tab.sql =====
-- =====================================================================
--  Accounts tab: each fund's accounts in its own chat, plus one
--  Accounts Reconciliation chat where the weekly Square check is pinned.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- ---------- the accounts chats ----------
insert into public.groups (id, name, about, sort, members_only) values
  ('accounts-reconciliation', 'Accounts Reconciliation',
   'All our funds together, checked against the Square account each week. Every approved member can read it; only the admin posts.', 1, true),
  ('events-accounts', 'Footballing Events Accounts',
   'Accounts for events paid from the events fund, with the receipts, and money moved between the kitty and events funds. Every approved member can read them; only the admin posts.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;
update public.groups set name = 'Friday Football Accounts', members_only = true, sort = 2,
  about = 'Our Friday football accounts, game by game, and money moved between the kitty and events funds. Every approved member can read them; only the admin posts.'
 where id = 'football-accounts';
update public.groups set name = 'BR3 Family Events Accounts', members_only = true, sort = 4,
  about = 'The BR3 Family Events fund: weekly subscriptions, money in and money spent. Every approved member can read it; only the admin posts.'
 where id = 'family-accounts';

-- Events accounts were redirected into the one Accounts chat (add-accounts-chat.sql). Each fund has its own chat again,
-- so posts to Footballing Events Accounts stay there. Earlier posts stay where they are.
drop trigger if exists posts_one_accounts_chat on public.posts;

-- ---------- who reads and who posts ----------
-- Every approved member reads all the accounts chats. Same rule as before otherwise (add-football-chats.sql).
alter table public.groups add column if not exists football_only boolean not null default false;
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when coalesce((select football_only from groups where id = g), false)
      then is_organiser() or is_footballer(auth.uid())
    else not coalesce((select members_only from groups where id = g), false)
      or is_organiser()
      or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
      or (g in ('football-accounts', 'events-accounts', 'family-accounts', 'accounts-reconciliation') and exists (select 1 from profiles where id = auth.uid() and approved))
  end
$$;
do $$ begin
  if exists (select 1 from pg_proc where proname = 'user_sees_group' and pronamespace = 'public'::regnamespace) then
    execute $f$
      create or replace function public.user_sees_group(u uuid, g text) returns boolean
      language sql stable security definer set search_path = public as $q$
        select case
          when coalesce((select football_only from groups where id = g), false)
            then exists (select 1 from profiles where id = u and (role in ('organiser', 'admin') or football or family))
          else not coalesce((select members_only from groups where id = g), false)
            or exists (select 1 from profiles where id = u and role = 'admin')
            or exists (select 1 from group_members where group_id = g and user_id = u)
            or (g in ('football-accounts', 'events-accounts', 'family-accounts', 'accounts-reconciliation') and exists (select 1 from profiles where id = u and approved))
        end
      $q$;
    $f$;
  end if;
end $$;
drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id not in ('football-accounts', 'events-accounts', 'family-accounts', 'accounts-reconciliation') or is_organiser())
              and can_see_group(group_id));

-- ---------- the weekly reconciliation ----------
-- One row per posted reconciliation: the funds, what was outside Square, what Square should show and did show.
-- The latest row is "last week" for the next one.
create table if not exists public.reconciliations (
  id bigserial primary key,
  posted_at timestamptz not null default now(),
  kitty numeric(10,2) not null,
  events numeric(10,2) not null,
  family numeric(10,2) not null,
  credits numeric(10,2) not null,
  unclaimed numeric(10,2) not null default 0,
  held numeric(10,2) not null,        -- cash and transfers not yet in Square
  advance numeric(10,2) not null,     -- paid for games and events not yet in accounts, less Square's fees
  square_expected numeric(10,2) not null,
  square_actual numeric(10,2) not null,
  why text,
  fix text,
  post_id uuid references public.posts(id) on delete set null,
  posted_by uuid references public.profiles(id) on delete set null
);
alter table public.reconciliations enable row level security;
drop policy if exists "members read reconciliations" on public.reconciliations;
create policy "members read reconciliations" on public.reconciliations for select to authenticated
  using (exists (select 1 from profiles where id = auth.uid() and approved));
grant select on public.reconciliations to authenticated;

-- Posts the reconciliation to the Accounts Reconciliation chat, pinned (the earlier one is unpinned),
-- records the Square balance, and keeps the figures for next week.
create or replace function public.post_reconciliation(p_body text, p_square numeric, p_why text, p_fix text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  fs fund_state; x jsonb; v_name text; v_post uuid; v_id bigint; v_exp numeric; v_held numeric; v_adv numeric;
begin
  if not is_admin() then raise exception 'Only the admin can post the reconciliation.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The reconciliation is empty.'; end if;
  if p_square is null then raise exception 'Enter the Square balance.'; end if;
  update fund_state set square_balance = round(p_square, 2), square_balance_at = now() where id = 1 returning * into fs;
  x := square_expected();
  v_exp := round((x->>'expected')::numeric, 2);
  v_held := coalesce((x->>'held_cash')::numeric, 0) + coalesce((x->>'held_bank')::numeric, 0);
  v_adv := coalesce((x->>'pending_in')::numeric, 0) - coalesce((x->>'pending_fees')::numeric, 0);
  if round(p_square, 2) <> v_exp and (trim(coalesce(p_why, '')) = '' or trim(coalesce(p_fix, '')) = '') then
    raise exception 'Square doesn''t match the funds: say why, and how and when it will be corrected.';
  end if;
  select name into v_name from profiles where id = auth.uid();
  update posts set pinned = false where group_id = 'accounts-reconciliation' and pinned;
  insert into posts (group_id, user_id, author_name, body, pinned)
    values ('accounts-reconciliation', auth.uid(), coalesce(v_name, 'Admin'), p_body, true)
    returning id into v_post;
  insert into reconciliations (kitty, events, family, credits, unclaimed, held, advance, square_expected, square_actual, why, fix, post_id, posted_by)
    values (fs.kitty, fs.events, coalesce(fs.family, 0), coalesce(fs.credits, 0), coalesce((to_jsonb(fs)->>'unclaimed')::numeric, 0),
            v_held, v_adv, v_exp, round(p_square, 2), nullif(trim(p_why), ''), nullif(trim(p_fix), ''), v_post, auth.uid())
    returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.post_reconciliation(text, numeric, text, text) from public, anon;
grant execute on function public.post_reconciliation(text, numeric, text, text) to authenticated;

-- ===== 2. Tidy up after the old one-chat rule =====
do $$ begin
  if exists (select 1 from pg_trigger where tgname = 'zz_notify_new_post') then
    execute 'alter table public.posts disable trigger zz_notify_new_post';
  end if;
end $$;
delete from public.posts p
 where p.group_id = 'football-accounts' and p.body like '**Transfer between funds**%'
   and exists (select 1 from public.posts o where o.group_id = 'football-accounts' and o.body = p.body
                 and (o.created_at, o.id::text) < (p.created_at, p.id::text));
update public.posts set group_id = 'events-accounts'
 where group_id = 'football-accounts' and body like '% the football kitty account (Football %';
do $$ begin
  if exists (select 1 from pg_trigger where tgname = 'zz_notify_new_post') then
    execute 'alter table public.posts enable trigger zz_notify_new_post';
  end if;
end $$;

-- ===== 3. fill-events-accounts-chat.sql =====
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

-- ===== 4. add-starling.sql =====
-- =====================================================================
--  Starling as the money hub. Square pays its takings into Starling every
--  day, family transfers and cash go into Starling, and pitches are paid
--  from Starling. Every Saturday morning (and when the admin taps Pull
--  from Starling) the app reads Starling's balance and transactions,
--  read-only, so the reconciliation checks the funds against Square and
--  Starling together without any figures typed in.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

alter table public.fund_state add column if not exists starling_balance numeric(10,2);
alter table public.fund_state add column if not exists starling_balance_at timestamptz;
alter table public.fund_state add column if not exists starling_name text;   -- which account or Space is read

-- Starling transactions, as Starling reports them (amounts in pounds, out is negative).
create table if not exists public.starling_txns (
  id text primary key,                 -- Starling's feed item id
  at timestamptz not null,
  amount numeric(10,2) not null,
  counterparty text not null default '',
  reference text not null default '',
  status text not null default '',
  source text not null default '',
  category text not null default '',
  raw jsonb,
  synced_at timestamptz not null default now()
);
create index if not exists starling_txns_at on public.starling_txns (at);
alter table public.starling_txns enable row level security;
revoke insert, update, delete on public.starling_txns from anon, authenticated;
grant select on public.starling_txns to authenticated;
drop policy if exists "admin reads starling" on public.starling_txns;
create policy "admin reads starling" on public.starling_txns for select to authenticated using (is_admin());

-- The Square check: once Starling is connected, the bank figure is Starling's real balance,
-- not the running total of money recorded by hand.
create or replace function public.square_expected() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fs fund_state; v_pending jsonb; v_in numeric; v_fees numeric; v_all numeric; v_bank numeric;
begin
  if not is_door() then raise exception 'Only organisers can see the Square check.'; end if;
  select * into fs from fund_state where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('event', x.id, 'title', x.title, 'day', x.day, 'paid', x.paid, 'fees', x.fees) order by x.day nulls last), '[]'),
         coalesce(sum(x.paid), 0), coalesce(sum(x.fees), 0)
    into v_pending, v_in, v_fees
    from (select e.id, e.title, e.day,
                 sum(b.amount - b.intro_cover - case when b.topup_method = 'link' then b.topup else 0 end) filter (where b.paid) as paid,
                 sum(b.card_fee + b.topup_fee) as fees
            from events e join bookings b on b.event_id = e.id
           where not e.accounts_posted and (e.day is null or e.day >= fs.square_from)
             and b.status = 'booked' and (b.paid or b.card_fee > 0 or b.topup_fee > 0)
           group by e.id, e.title, e.day) x
   where coalesce(x.paid, 0) <> 0 or coalesce(x.fees, 0) <> 0;
  v_all := fs.kitty + fs.events + fs.credits + fs.family + fs.unclaimed;
  v_bank := case when fs.starling_balance_at is not null then fs.starling_balance else fs.held_bank end;
  return jsonb_build_object(
    'funds', v_all, 'unclaimed', fs.unclaimed,
    'pending', v_pending, 'pending_in', v_in, 'pending_fees', v_fees,
    'held_cash', fs.held_cash, 'held_bank', v_bank,
    'starling', fs.starling_balance, 'starling_at', fs.starling_balance_at, 'starling_name', fs.starling_name,
    'expected', v_all + v_in - v_fees - fs.held_cash - v_bank,
    'square_balance', fs.square_balance, 'square_balance_at', fs.square_balance_at);
end $$;
revoke execute on function public.square_expected() from public, anon;
grant execute on function public.square_expected() to authenticated;

-- Each weekly reconciliation keeps the Starling balance it used.
alter table public.reconciliations add column if not exists starling numeric(10,2);

-- Same as before (add-accounts-tab.sql), and keeps the Starling balance too.
-- Posts the reconciliation to the Accounts Reconciliation chat, pinned (the earlier one is unpinned),
-- records the Square balance, and keeps the figures for next week.
create or replace function public.post_reconciliation(p_body text, p_square numeric, p_why text, p_fix text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  fs fund_state; x jsonb; v_name text; v_post uuid; v_id bigint; v_exp numeric; v_held numeric; v_adv numeric;
begin
  if not is_admin() then raise exception 'Only the admin can post the reconciliation.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The reconciliation is empty.'; end if;
  if p_square is null then raise exception 'Enter the Square balance.'; end if;
  update fund_state set square_balance = round(p_square, 2), square_balance_at = now() where id = 1 returning * into fs;
  x := square_expected();
  v_exp := round((x->>'expected')::numeric, 2);
  v_held := coalesce((x->>'held_cash')::numeric, 0) + coalesce((x->>'held_bank')::numeric, 0);
  v_adv := coalesce((x->>'pending_in')::numeric, 0) - coalesce((x->>'pending_fees')::numeric, 0);
  if round(p_square, 2) <> v_exp and (trim(coalesce(p_why, '')) = '' or trim(coalesce(p_fix, '')) = '') then
    raise exception 'Square doesn''t match the funds: say why, and how and when it will be corrected.';
  end if;
  select name into v_name from profiles where id = auth.uid();
  update posts set pinned = false where group_id = 'accounts-reconciliation' and pinned;
  insert into posts (group_id, user_id, author_name, body, pinned)
    values ('accounts-reconciliation', auth.uid(), coalesce(v_name, 'Admin'), p_body, true)
    returning id into v_post;
  insert into reconciliations (kitty, events, family, credits, unclaimed, held, advance, square_expected, square_actual, why, fix, post_id, posted_by, starling)
    values (fs.kitty, fs.events, coalesce(fs.family, 0), coalesce(fs.credits, 0), coalesce((to_jsonb(fs)->>'unclaimed')::numeric, 0),
            v_held, v_adv, v_exp, round(p_square, 2), nullif(trim(p_why), ''), nullif(trim(p_fix), ''), v_post, auth.uid(),
            case when fs.starling_balance_at is not null then fs.starling_balance end)
    returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.post_reconciliation(text, numeric, text, text) from public, anon;
grant execute on function public.post_reconciliation(text, numeric, text, text) to authenticated;
