-- =====================================================================
--  Fund transfers and events accounts
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- ---------- moving money between the kitty and events funds ----------

-- Every transfer is kept: who made it, when, and why. To undo one, move the money back with a reason.
create table if not exists public.fund_transfers (
  id bigserial primary key,
  on_date date not null default current_date,
  from_fund text not null check (from_fund in ('kitty', 'events')),
  to_fund text not null check (to_fund in ('kitty', 'events')),
  amount numeric(10,2) not null check (amount > 0),
  reason text not null check (length(trim(reason)) > 0),
  made_by uuid references public.profiles(id) on delete set null,
  made_by_name text not null default '',
  accounts_post_id bigint references public.accounts_posts(id) on delete set null,  -- the accounts that first showed it
  created_at timestamptz not null default now(),
  check (from_fund <> to_fund)
);
alter table public.fund_transfers enable row level security;
revoke insert, update, delete on public.fund_transfers from anon, authenticated;
grant select on public.fund_transfers to authenticated;
drop policy if exists "members see transfers" on public.fund_transfers;
create policy "members see transfers" on public.fund_transfers for select to authenticated using (true);

create or replace function public.transfer_funds(p_from text, p_to text, p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; v_name text; r text := trim(coalesce(p_reason, '')); a numeric := round(coalesce(p_amount, 0), 2); held numeric;
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
  insert into fund_transfers (from_fund, to_fund, amount, reason, made_by, made_by_name)
    values (p_from, p_to, a, r, auth.uid(), coalesce(v_name, 'Admin'));
  insert into ledger (fund, what, amount, balance) values
    (p_from, 'Transfer to ' || initcap(p_to) || ' fund: ' || r, -a, case p_from when 'kitty' then fs.kitty else fs.events end),
    (p_to, 'Transfer from ' || initcap(p_from) || ' fund: ' || r, a, case p_to when 'kitty' then fs.kitty else fs.events end);
  update fund_state set kitty = fs.kitty, events = fs.events where id = 1;
  return fs;
end $$;
revoke execute on function public.transfer_funds(text, text, numeric, text) from public, anon;
grant execute on function public.transfer_funds(text, text, numeric, text) to authenticated;

-- The next accounts posted (football or an event) list the transfers made since the last ones.
create or replace function public.mark_transfers_shown() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update fund_transfers set accounts_post_id = new.id where accounts_post_id is null;
  return new;
end $$;
drop trigger if exists accounts_posts_mark_transfers on public.accounts_posts;
create trigger accounts_posts_mark_transfers after insert on public.accounts_posts
  for each row execute function public.mark_transfers_shown();

-- ---------- events accounts ----------

-- Receipts (money in) and costs (hiring or ancillary) for an event, each with an optional receipt photo.
create table if not exists public.event_account_lines (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  kind text not null check (kind in ('receipt', 'hiring', 'ancillary')),
  what text not null check (length(trim(what)) > 0),
  amount numeric(10,2) not null check (amount > 0),
  photo text,                                     -- receipt photo as a data URL, shrunk on the phone
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists event_account_lines_event on public.event_account_lines (event_id);
alter table public.event_account_lines enable row level security;
grant select, insert, update, delete on public.event_account_lines to authenticated;
drop policy if exists "members see event lines" on public.event_account_lines;
drop policy if exists "admin adds event lines" on public.event_account_lines;
drop policy if exists "admin edits event lines" on public.event_account_lines;
drop policy if exists "admin removes event lines" on public.event_account_lines;
create policy "members see event lines" on public.event_account_lines for select to authenticated using (true);
-- Lines are locked once the event's accounts are posted.
create policy "admin adds event lines" on public.event_account_lines for insert to authenticated
  with check (is_admin() and not coalesce((select accounts_posted from events where id = event_id), true));
create policy "admin edits event lines" on public.event_account_lines for update to authenticated
  using (is_admin() and not coalesce((select accounts_posted from events where id = event_id), true));
create policy "admin removes event lines" on public.event_account_lines for delete to authenticated
  using (is_admin() and not coalesce((select accounts_posted from events where id = event_id), true));

-- What an event's posted accounts did to the funds.
create table if not exists public.event_accounts (
  event_id uuid primary key references public.events(id) on delete cascade,
  receipts numeric(10,2) not null,
  hiring numeric(10,2) not null,
  ancillary numeric(10,2) not null,
  kitty_before numeric(10,2) not null,             -- at the last posted accounts, before the transfers below
  events_before numeric(10,2) not null,
  transfers jsonb not null default '[]',           -- transfers made since the last posted accounts
  kitty_after numeric(10,2) not null,
  events_after numeric(10,2) not null,
  posted_by uuid references public.profiles(id) on delete set null,
  posted_at timestamptz not null default now()
);
alter table public.event_accounts enable row level security;
revoke insert, update, delete on public.event_accounts from anon, authenticated;
grant select on public.event_accounts to authenticated;
drop policy if exists "members see event accounts" on public.event_accounts;
create policy "members see event accounts" on public.event_accounts for select to authenticated using (true);

-- Chat posts can carry several photos, shown inside the post where it says {photo 1}, {photo 2} and so on.
alter table public.posts add column if not exists images jsonb not null default '[]';

-- Events Accounts: a chat every approved member can read. Only the admin posts.
insert into public.groups (id, name, about, sort, members_only)
values ('events-accounts', 'Events Accounts', 'Accounts for our events, with the receipts. Every approved member can read them; only the admin posts.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;

create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
    or (g in ('football-accounts', 'events-accounts') and exists (select 1 from profiles where id = auth.uid() and approved))
$$;

drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id not in ('football-accounts', 'events-accounts') or is_organiser()) and can_see_group(group_id));

-- Posting an event's accounts: the profit goes into (or the loss comes out of) the events fund.
-- The photos go into the Events Accounts post in this order: receipts, then hiring, then ancillary, oldest first.
create or replace function public.post_event_accounts(p_event uuid, p_body text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare
  e events; fs fund_state; v_name text; d text; rec numeric; hire numeric; anc numeric;
  k_net numeric; e_net numeric; v_transfers jsonb; v_photos jsonb;
begin
  if not is_admin() then raise exception 'Only the admin can post accounts.'; end if;
  select * into e from events where id = p_event for update;
  if not found then raise exception 'Event not found.'; end if;
  if e.kind = 'football' then raise exception 'Football accounts are posted from the Football page.'; end if;
  if e.accounts_posted then raise exception 'Accounts for this event were already posted.'; end if;
  if not exists (select 1 from event_account_lines where event_id = p_event) then raise exception 'Add the receipts and costs first.'; end if;
  if trim(coalesce(p_body, '')) = '' then raise exception 'The accounts are empty.'; end if;

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

  d := e.title || ' ' || coalesce(to_char(e.day, 'FMDD Mon YYYY'), '(date to be confirmed)');
  if rec > 0 then
    fs.events := fs.events + rec;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), 'events', d || ': receipts', rec, fs.events);
  end if;
  if hire > 0 then
    fs.events := fs.events - hire;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), 'events', d || ': hiring costs', -hire, fs.events);
  end if;
  if anc > 0 then
    fs.events := fs.events - anc;
    insert into ledger (on_date, fund, what, amount, balance) values (coalesce(e.day, current_date), 'events', d || ': ancillary costs', -anc, fs.events);
  end if;
  update fund_state set events = fs.events where id = 1;
  update events set accounts_posted = true where id = p_event;

  insert into event_accounts (event_id, receipts, hiring, ancillary, kitty_before, events_before, transfers, kitty_after, events_after, posted_by)
    values (p_event, rec, hire, anc, fs.kitty - k_net, fs.events - (rec - hire - anc) - e_net, v_transfers, fs.kitty, fs.events, auth.uid());
  insert into accounts_posts (event_id, body, created_by) values (p_event, p_body, auth.uid());
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body, images)
    values ('events-accounts', auth.uid(), coalesce(v_name, 'Admin'), p_body, v_photos);
  return fs;
end $$;
revoke execute on function public.post_event_accounts(uuid, text) from public, anon;
grant execute on function public.post_event_accounts(uuid, text) to authenticated;
