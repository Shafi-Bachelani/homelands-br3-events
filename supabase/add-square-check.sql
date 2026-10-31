-- =====================================================================
--  Square check, the BR3 Family Events fund and where the money is held
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
--
--  * Every Square payment is kept with what was paid, Square's fee and the net,
--    matched to its booking or to the Family Events subscription.
--  * A fourth fund, BR3 Family Events. Each weekly subscription payment goes in
--    by itself as a receipt, with Square's fee taken off.
--  * Cash in hand and money in the bank (Starling) are tracked until they are
--    moved into Square, so the Square balance can be checked against all funds.
-- =====================================================================

-- ---------- the Family Events fund and the money held outside Square ----------

alter table public.fund_state add column if not exists family numeric(10,2) not null default 0;
alter table public.fund_state add column if not exists held_cash numeric(10,2) not null default 0;   -- cash taken and not yet paid into Square
alter table public.fund_state add column if not exists held_bank numeric(10,2) not null default 0;   -- transfers in the bank (Starling), not yet moved into Square
alter table public.fund_state add column if not exists square_balance numeric(10,2);                 -- the Square balance, as last typed in
alter table public.fund_state add column if not exists square_balance_at timestamptz;
alter table public.fund_state add column if not exists square_from date not null default date '2026-10-23';  -- games and events from this day count as "not yet in accounts"

alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits', 'family'));

-- ---------- Square payments ----------

create table if not exists public.square_payments (
  id text primary key,                            -- Square payment id
  paid_at timestamptz not null,
  status text not null,
  gross numeric(10,2) not null default 0,         -- what the person paid
  fee numeric(10,2) not null default 0,           -- what Square kept
  refunded numeric(10,2) not null default 0,
  order_id text,
  note text not null default '',
  source text not null default '',                -- CARD, WALLET, CASH, EXTERNAL ...
  kind text not null default 'other' check (kind in ('booking', 'subscription', 'other')),
  booking_id uuid references public.bookings(id) on delete set null,
  label text not null default '',                 -- who or what it was for
  posted_gross numeric(10,2) not null default 0,  -- what has gone into the Family Events fund so far
  posted_fee numeric(10,2) not null default 0,
  updated_at timestamptz not null default now()
);
create index if not exists square_payments_paid_at on public.square_payments (paid_at);
create index if not exists square_payments_order on public.square_payments (order_id);
alter table public.square_payments enable row level security;
revoke insert, update, delete on public.square_payments from anon, authenticated;
grant select on public.square_payments to authenticated;
drop policy if exists "door sees square payments" on public.square_payments;
create policy "door sees square payments" on public.square_payments for select to authenticated using (is_door());

-- Which Square orders belong to a subscription, so its payments are known without asking Square again.
create table if not exists public.square_sub_orders (
  order_id text primary key,
  invoice_id text,
  subscription_id text,
  label text not null default ''
);
alter table public.square_sub_orders enable row level security;
revoke all on public.square_sub_orders from anon, authenticated;

-- Records a payment from Square (called by the server only). Subscription payments go into the
-- Family Events fund: the amount paid as a receipt, then Square's fee once Square reports it.
create or replace function public.apply_square_payment(p jsonb) returns public.square_payments
language plpgsql security definer set search_path = public as $$
declare r square_payments; fs fund_state; dg numeric; df numeric; v_ok boolean;
begin
  insert into square_payments (id, paid_at, status, gross, fee, refunded, order_id, note, source, kind, booking_id, label, updated_at)
  values (p->>'id', (p->>'paid_at')::timestamptz, p->>'status', coalesce((p->>'gross')::numeric, 0), coalesce((p->>'fee')::numeric, 0),
          coalesce((p->>'refunded')::numeric, 0), p->>'order_id', coalesce(p->>'note', ''), coalesce(p->>'source', ''),
          coalesce(p->>'kind', 'other'), nullif(p->>'booking_id', '')::uuid, coalesce(p->>'label', ''), now())
  on conflict (id) do update set status = excluded.status, gross = excluded.gross, fee = excluded.fee, refunded = excluded.refunded,
    order_id = excluded.order_id, note = excluded.note, source = excluded.source, kind = excluded.kind,
    booking_id = coalesce(excluded.booking_id, square_payments.booking_id), label = excluded.label, updated_at = now()
  returning * into r;

  if r.kind = 'subscription' then
    v_ok := r.status = 'COMPLETED';
    dg := case when v_ok then r.gross - r.refunded else 0 end - r.posted_gross;
    df := case when v_ok then r.fee else 0 end - r.posted_fee;
    if dg <> 0 or df <> 0 then
      select * into fs from fund_state where id = 1 for update;
      if dg <> 0 then
        fs.family := fs.family + dg;
        insert into ledger (on_date, fund, what, amount, balance)
          values ((r.paid_at at time zone 'Europe/London')::date, 'family', r.label || case when dg > 0 then ': paid' else ': refunded or cancelled' end, dg, fs.family);
      end if;
      if df <> 0 then
        fs.family := fs.family - df;
        insert into ledger (on_date, fund, what, amount, balance)
          values ((r.paid_at at time zone 'Europe/London')::date, 'family', r.label || ': Square fee', -df, fs.family);
      end if;
      update fund_state set family = fs.family where id = 1;
      update square_payments set posted_gross = posted_gross + dg, posted_fee = posted_fee + df where id = r.id returning * into r;
    end if;
  end if;
  return r;
end $$;
revoke execute on function public.apply_square_payment(jsonb) from public, anon, authenticated;
grant execute on function public.apply_square_payment(jsonb) to service_role;

-- ---------- Family Events fund: money in and out by hand ----------

-- A positive amount is money in (or the opening balance), a negative amount is money spent.
create or replace function public.family_entry(p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; a numeric := round(coalesce(p_amount, 0), 2); r text := trim(coalesce(p_reason, ''));
begin
  if not is_admin() then raise exception 'Only the admin can change the Family Events fund.'; end if;
  if a = 0 then raise exception 'Enter an amount.'; end if;
  if r = '' then raise exception 'Give a reason.'; end if;
  select * into fs from fund_state where id = 1 for update;
  fs.family := fs.family + a;
  insert into ledger (fund, what, amount, balance) values ('family', r, a, fs.family);
  update fund_state set family = fs.family where id = 1;
  return fs;
end $$;
revoke execute on function public.family_entry(numeric, text) from public, anon;
grant execute on function public.family_entry(numeric, text) to authenticated;

-- ---------- where the money is: cash in hand, bank (Starling), Square ----------

create table if not exists public.money_moves (
  id bigserial primary key,
  on_date date not null default current_date,
  from_place text not null check (from_place in ('cash', 'bank', 'square', 'count')),
  to_place text not null check (to_place in ('cash', 'bank', 'square')),
  amount numeric(10,2) not null,
  reason text not null default '',
  made_by_name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.money_moves enable row level security;
revoke insert, update, delete on public.money_moves from anon, authenticated;
grant select on public.money_moves to authenticated;
drop policy if exists "members see money moves" on public.money_moves;
create policy "members see money moves" on public.money_moves for select to authenticated using (true);

-- Cash and transfer payments are counted as held outside Square the moment they are marked paid.
-- Card and credit payments are not: card money is already in Square, and credit was paid earlier.
create or replace function public.booking_held(b bookings, out cash numeric, out bank numeric)
language plpgsql immutable as $$
declare base numeric;
begin
  cash := 0; bank := 0;
  if b.id is null then return; end if;
  base := coalesce(b.amount, 0) - coalesce(b.topup, 0) - coalesce(b.credit_used, 0) - coalesce(b.intro_cover, 0);
  if b.paid and base > 0 then
    if b.method = 'cash' then cash := cash + base; elsif b.method = 'transfer' then bank := bank + base; end if;
  end if;
  if coalesce(b.topup, 0) > 0 then
    if b.topup_method = 'cash' then cash := cash + b.topup; elsif b.topup_method = 'transfer' then bank := bank + b.topup; end if;
  end if;
end $$;

create or replace function public.track_held_money() returns trigger
language plpgsql security definer set search_path = public as $$
declare n record; o record; dc numeric; db numeric;
begin
  -- new is empty when a booking is deleted, and old is empty when one is added
  select * into n from booking_held(new);
  select * into o from booking_held(old);
  dc := n.cash - o.cash; db := n.bank - o.bank;
  if dc <> 0 or db <> 0 then
    update fund_state set held_cash = held_cash + dc, held_bank = held_bank + db where id = 1;
  end if;
  return null;
end $$;
drop trigger if exists bookings_track_held on public.bookings;
create trigger bookings_track_held after insert or update or delete on public.bookings
  for each row execute function public.track_held_money();

-- Moving money between places (e.g. cash paid into Square, Starling to Square), or setting
-- cash in hand / the bank to a counted figure (from 'count').
create or replace function public.move_money(p_from text, p_to text, p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; a numeric := round(coalesce(p_amount, 0), 2); v_name text; held numeric;
begin
  if not is_admin() then raise exception 'Only the admin can record where the money is.'; end if;
  if p_to not in ('cash', 'bank', 'square') or p_from not in ('cash', 'bank', 'square', 'count') or p_from = p_to then
    raise exception 'Choose where the money came from and where it went.';
  end if;
  select * into fs from fund_state where id = 1 for update;
  if p_from = 'count' then
    if p_to = 'square' then raise exception 'Type the Square balance in instead.'; end if;
    if a < 0 then raise exception 'Enter £0 or more.'; end if;
    held := case p_to when 'cash' then fs.held_cash else fs.held_bank end;
    if p_to = 'cash' then fs.held_cash := a; else fs.held_bank := a; end if;
    a := a - held;  -- the change, for the history
  else
    if a <= 0 then raise exception 'Enter an amount over £0.'; end if;
    if p_from = 'cash' then fs.held_cash := fs.held_cash - a; elsif p_from = 'bank' then fs.held_bank := fs.held_bank - a; end if;
    if p_to = 'cash' then fs.held_cash := fs.held_cash + a; elsif p_to = 'bank' then fs.held_bank := fs.held_bank + a; end if;
  end if;
  select name into v_name from profiles where id = auth.uid();
  insert into money_moves (from_place, to_place, amount, reason, made_by_name) values (p_from, p_to, a, trim(coalesce(p_reason, '')), coalesce(v_name, 'Admin'));
  update fund_state set held_cash = fs.held_cash, held_bank = fs.held_bank where id = 1;
  return fs;
end $$;
revoke execute on function public.move_money(text, text, numeric, text) from public, anon;
grant execute on function public.move_money(text, text, numeric, text) to authenticated;

create or replace function public.set_square_balance(p_amount numeric) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state;
begin
  if not is_door() then raise exception 'Only organisers can enter the Square balance.'; end if;
  if p_amount is null then raise exception 'Enter the Square balance.'; end if;
  update fund_state set square_balance = round(p_amount, 2), square_balance_at = now() where id = 1 returning * into fs;
  return fs;
end $$;
revoke execute on function public.set_square_balance(numeric) from public, anon;
grant execute on function public.set_square_balance(numeric) to authenticated;

-- What Square should hold: all four funds, plus money paid for games and events whose accounts
-- aren't posted yet (less Square's fees on it), less what is still held as cash or in the bank.
create or replace function public.square_expected() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fs fund_state; v_pending jsonb; v_in numeric; v_fees numeric;
begin
  if not is_door() then raise exception 'Only organisers can see the Square check.'; end if;
  select * into fs from fund_state where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('event', x.id, 'title', x.title, 'day', x.day, 'paid', x.paid, 'fees', x.fees) order by x.day nulls last), '[]'),
         coalesce(sum(x.paid), 0), coalesce(sum(x.fees), 0)
    into v_pending, v_in, v_fees
    from (select e.id, e.title, e.day,
                 sum(b.amount - b.intro_cover) filter (where b.paid) as paid,
                 sum(b.card_fee) as fees
            from events e join bookings b on b.event_id = e.id
           where not e.accounts_posted and (e.day is null or e.day >= fs.square_from)
             and b.status = 'booked' and (b.paid or b.card_fee > 0)
           group by e.id, e.title, e.day) x
   where coalesce(x.paid, 0) <> 0 or coalesce(x.fees, 0) <> 0;
  return jsonb_build_object(
    'funds', fs.kitty + fs.events + fs.credits + fs.family,
    'pending', v_pending, 'pending_in', v_in, 'pending_fees', v_fees,
    'held_cash', fs.held_cash, 'held_bank', fs.held_bank,
    'expected', fs.kitty + fs.events + fs.credits + fs.family + v_in - v_fees - fs.held_cash - fs.held_bank,
    'square_balance', fs.square_balance, 'square_balance_at', fs.square_balance_at);
end $$;
revoke execute on function public.square_expected() from public, anon;
grant execute on function public.square_expected() to authenticated;
