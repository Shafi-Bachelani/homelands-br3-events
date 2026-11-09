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
