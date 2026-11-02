-- ---------- welcome agreement, strikes, member search, unclaimed credit, shared reactions, chat stars (also in schema.sql) ----------
-- Safe to run more than once. Run it in Supabase, SQL Editor, before the app update goes live.

-- ===== 1. The welcome agreement =====
-- When a member ticked "I agree" to the welcome and friends agreement. Empty = not agreed yet.
alter table public.profiles add column if not exists agreed_at timestamptz;

-- People who tick "I agree" on the Join form: the tick travels with the sign-up and is copied here.
create or replace function public.agreed_on_join() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.agreed_at is null and exists (select 1 from auth.users where id = new.id and raw_user_meta_data->>'agreed' = 'yes') then
    new.agreed_at := now();
  end if;
  return new;
end $$;
revoke execute on function public.agreed_on_join() from public, anon, authenticated;
drop trigger if exists profiles_agreed_on_join on public.profiles;
create trigger profiles_agreed_on_join before insert on public.profiles
  for each row execute function public.agreed_on_join();

-- Members who joined before the agreement was in the app agree once, when they next open it.
create or replace function public.agree_welcome() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare t timestamptz;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update profiles set agreed_at = coalesce(agreed_at, now()) where id = auth.uid() returning agreed_at into t;
  return t;
end $$;
revoke execute on function public.agree_welcome() from public, anon;
grant execute on function public.agree_welcome() to authenticated;

-- ===== 2. Strikes (two strike rule), seen only by the admin =====
create table if not exists public.member_strikes (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  strikes int not null default 0 check (strikes between 0 and 9),
  note text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.member_strikes enable row level security;
drop policy if exists "admin reads strikes" on public.member_strikes;
create policy "admin reads strikes" on public.member_strikes for select to authenticated using (is_admin());
grant select on public.member_strikes to authenticated;

create or replace function public.set_strikes(p_id uuid, p_strikes int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can give strikes.'; end if;
  if p_strikes < 0 or p_strikes > 9 then raise exception 'Strikes go from 0 to 9.'; end if;
  insert into member_strikes (user_id, strikes, note, updated_at) values (p_id, p_strikes, coalesce(p_note, ''), now())
  on conflict (user_id) do update set strikes = excluded.strikes, note = excluded.note, updated_at = now();
end $$;
revoke execute on function public.set_strikes(uuid, int, text) from public, anon;
grant execute on function public.set_strikes(uuid, int, text) to authenticated;

-- ===== 3. Friends play only on a game the member is booked on =====
create or replace function public.friend_needs_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.booked_by is not null and new.status <> 'cancelled'
     and not exists (select 1 from bookings where event_id = new.event_id and user_id = new.booked_by and status = 'booked') then
    raise exception 'Book your own place first. Friends can only come to a game you are booked on and coming to.';
  end if;
  return new;
end $$;
revoke execute on function public.friend_needs_member() from public, anon, authenticated;
drop trigger if exists bookings_friend_needs_member on public.bookings;
create trigger bookings_friend_needs_member before insert on public.bookings
  for each row execute function public.friend_needs_member();

-- ===== 4. Activity: days each member opened the app, and shared reactions =====
create table if not exists public.member_days (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  primary key (user_id, day)
);
alter table public.member_days enable row level security; -- written and read only through the functions below

create or replace function public.i_was_here() returns void
language sql security definer set search_path = public as $$
  insert into member_days (user_id, day)
  select auth.uid(), (now() at time zone 'Europe/London')::date where auth.uid() is not null
  on conflict do nothing
$$;
revoke execute on function public.i_was_here() from public, anon;
grant execute on function public.i_was_here() to authenticated;

-- Reactions (and the thumbs up) were kept on each phone. Now everyone sees them, and they count as activity.
create table if not exists public.post_reactions (
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('👍', '❤️', '😂', '👏', '🙏', '🔥', '🎉', '😮', '😢')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);
alter table public.post_reactions enable row level security;
drop policy if exists "members see reactions" on public.post_reactions;
create policy "members see reactions" on public.post_reactions for select to authenticated using (can_see_post(post_id));
drop policy if exists "members react" on public.post_reactions;
create policy "members react" on public.post_reactions for insert to authenticated
  with check (user_id = auth.uid() and can_see_post(post_id));
drop policy if exists "members unreact" on public.post_reactions;
create policy "members unreact" on public.post_reactions for delete to authenticated using (user_id = auth.uid());
grant select, insert, delete on public.post_reactions to authenticated;
drop trigger if exists require_approved on public.post_reactions;
create trigger require_approved before insert on public.post_reactions for each row execute function public.require_approved();

-- ===== 5. Member search for the admin =====
-- One row per member: who they are, when they were last here, their last football, and an activity
-- score over the last 90 days that counts everything they do in the app:
--   1 per day they opened the app, 3 per booking (any event, friends included), 3 per post,
--   2 per comment, 1 per reaction or poll vote.
create or replace function public.member_report() returns table (
  id uuid, name text, role text, football boolean, family boolean, approved boolean, joined timestamptz,
  agreed_at timestamptz, credit numeric, strikes int, strike_note text,
  last_seen date, last_football date, last_active date,
  days_90 int, bookings_90 int, posts_90 int, comments_90 int, reactions_90 int, score int)
language plpgsql stable security definer set search_path = public, auth as $$
declare since timestamptz := now() - interval '90 days';
begin
  if not is_admin() then raise exception 'Only the admin can see the member search.'; end if;
  return query
  with s as (
    select p.id, p.name, p.role, p.football, p.family, p.approved, p.created_at as joined, p.agreed_at, p.credit,
      coalesce(ms.strikes, 0) as strikes, coalesce(ms.note, '') as strike_note,
      greatest((select max(d.day) from member_days d where d.user_id = p.id),
               (select (u.last_sign_in_at at time zone 'Europe/London')::date from auth.users u where u.id = p.id)) as last_seen,
      (select max(e.day) from bookings b join events e on e.id = b.event_id
        where b.user_id = p.id and e.kind = 'football' and b.status = 'booked') as last_football,
      (select count(*)::int from member_days d where d.user_id = p.id and d.day >= since::date) as days_90,
      (select count(*)::int from bookings b where (b.user_id = p.id or b.booked_by = p.id) and b.status <> 'cancelled' and b.created_at >= since) as bookings_90,
      (select count(*)::int from posts x where x.user_id = p.id and x.created_at >= since) as posts_90,
      (select count(*)::int from comments c where c.user_id = p.id and c.created_at >= since) as comments_90,
      (select count(*)::int from post_reactions r where r.user_id = p.id and r.created_at >= since)
        + (select count(*)::int from poll_votes v join posts x on x.id = v.post_id where v.user_id = p.id and x.created_at >= since) as reactions_90,
      greatest((select max(b.created_at) from bookings b where b.user_id = p.id or b.booked_by = p.id),
               (select max(x.created_at) from posts x where x.user_id = p.id),
               (select max(c.created_at) from comments c where c.user_id = p.id),
               (select max(r.created_at) from post_reactions r where r.user_id = p.id)) as last_did
    from profiles p left join member_strikes ms on ms.user_id = p.id
  )
  select s.id, s.name, s.role, s.football, s.family, s.approved, s.joined, s.agreed_at, s.credit, s.strikes, s.strike_note,
    s.last_seen, s.last_football,
    greatest(s.last_seen, (s.last_did at time zone 'Europe/London')::date) as last_active,
    s.days_90, s.bookings_90, s.posts_90, s.comments_90, s.reactions_90,
    s.days_90 + 3 * s.bookings_90 + 3 * s.posts_90 + 2 * s.comments_90 + s.reactions_90 as score
  from s order by s.name;
end $$;
revoke execute on function public.member_report() from public, anon;
grant execute on function public.member_report() to authenticated;

-- ===== 6. Most active in the chats, last month and this month so far =====
-- Counts posts (3), comments (2) and reactions (1) in the ordinary chats; the accounts chats and
-- announcements don't count. Everyone signed in can see the top three.
create or replace function public.chat_stars() returns table (period text, user_id uuid, name text, score int)
language sql stable security definer set search_path = public as $$
  with m as (select date_trunc('month', now() at time zone 'Europe/London') as this_m),
  acts as (
    select x.user_id, x.created_at, 3 as pts from posts x
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
    union all
    select c.user_id, c.created_at, 2 from comments c join posts x on x.id = c.post_id
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
    union all
    select r.user_id, r.created_at, 1 from post_reactions r join posts x on x.id = r.post_id
     where x.group_id not in ('announcements', 'football-accounts', 'events-accounts', 'family-accounts')
  ),
  tagged as (
    select a.user_id, a.pts,
      case when (a.created_at at time zone 'Europe/London') >= m.this_m then 'this'
           when (a.created_at at time zone 'Europe/London') >= m.this_m - interval '1 month' then 'last' end as period
    from acts a, m where a.user_id is not null
  ),
  totals as (
    select t.period, t.user_id, sum(t.pts)::int as score,
      row_number() over (partition by t.period order by sum(t.pts) desc, t.user_id) as rk
    from tagged t where t.period is not null group by t.period, t.user_id
  )
  select t.period, t.user_id, p.name, t.score from totals t join profiles p on p.id = t.user_id
   where t.rk <= 3 and auth.uid() is not null
   order by t.period, t.score desc
$$;
revoke execute on function public.chat_stars() from public, anon;
grant execute on function public.chat_stars() to authenticated;

-- ===== 7. Credit left on removed accounts: claimable for 12 months, then to charity =====
-- It moves out of the credits fund into its own "Unclaimed credit" fund, so all the funds still add up
-- to what Square holds. The admin then marks it paid back (by bank transfer, with their consent)
-- or, after 12 months, given to charity on their behalf, with the receipt kept here.
alter table public.fund_state add column if not exists unclaimed numeric(10,2) not null default 0;
alter table public.ledger drop constraint if exists ledger_fund_check;
alter table public.ledger add constraint ledger_fund_check check (fund in ('kitty', 'events', 'credits', 'family', 'unclaimed'));

create table if not exists public.unclaimed_credit (
  id bigserial primary key,
  name text not null,
  email text,
  amount numeric(8,2) not null check (amount > 0),
  removed_at timestamptz not null default now(),
  claim_by date not null,
  status text not null default 'held' check (status in ('held', 'paid', 'charity')),
  settled_at timestamptz,
  settled_note text,
  receipt text,                                   -- photo or PDF of the charity receipt, as a data URL
  settled_by uuid references public.profiles(id) on delete set null
);
alter table public.unclaimed_credit enable row level security;
drop policy if exists "admin reads unclaimed" on public.unclaimed_credit;
create policy "admin reads unclaimed" on public.unclaimed_credit for select to authenticated using (is_admin());
grant select on public.unclaimed_credit to authenticated;

create or replace function public.remove_member(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare p profiles; v_email text; v_by date; bal numeric;
begin
  if not is_admin() then raise exception 'Only the admin can remove members.'; end if;
  if p_id = auth.uid() then raise exception 'You cannot remove yourself.'; end if;
  if exists (select 1 from profiles where id = p_id and role = 'admin') then
    raise exception 'Change their role from admin first.';
  end if;
  if exists (select 1 from bookings b join events e on e.id = b.event_id
              where (b.user_id = p_id or b.booked_by = p_id)
                and b.status in ('booked', 'waitlist', 'pending')
                and (e.day is null or e.day >= current_date) and not e.accounts_posted) then
    raise exception 'They have upcoming bookings. Remove them from those first, so any payment or credit is sorted out.';
  end if;
  select * into p from profiles where id = p_id;
  select email into v_email from auth.users where id = p_id;
  -- Their credit leaves the credits fund (the profiles_credit_removed trigger) and is held here.
  if p.id is not null and p.credit > 0 then
    v_by := ((now() at time zone 'Europe/London')::date + interval '12 months')::date;
    insert into unclaimed_credit (name, email, amount, claim_by) values (p.name, v_email, p.credit, v_by);
    update fund_state set unclaimed = unclaimed + p.credit where id = 1 returning unclaimed into bal;
    insert into ledger (fund, what, amount, balance)
      values ('unclaimed', p.name || ': credit held after their account was removed, claimable until ' || to_char(v_by, 'FMDD Mon YYYY'), p.credit, bal);
  end if;
  update bookings set user_id = null where user_id = p_id;
  update bookings set booked_by = null where booked_by = p_id;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.remove_member(uuid) from public, anon;
grant execute on function public.remove_member(uuid) to authenticated;

create or replace function public.settle_unclaimed(p_id bigint, p_how text, p_note text, p_receipt text) returns void
language plpgsql security definer set search_path = public as $$
declare u unclaimed_credit; bal numeric;
begin
  if not is_admin() then raise exception 'Only the admin can do this.'; end if;
  select * into u from unclaimed_credit where id = p_id for update;
  if not found or u.status <> 'held' then raise exception 'That credit has already been sorted out.'; end if;
  if p_how not in ('paid', 'charity') then raise exception 'Choose paid back or given to charity.'; end if;
  if p_how = 'charity' and coalesce(p_receipt, '') = '' then raise exception 'Add a photo of the charity receipt.'; end if;
  if p_receipt is not null and not (p_receipt like 'data:image/%' or p_receipt like 'data:application/pdf;base64,%') then
    raise exception 'The receipt should be a photo or a PDF.';
  end if;
  update unclaimed_credit set status = p_how, settled_at = now(), settled_note = nullif(trim(coalesce(p_note, '')), ''),
         receipt = p_receipt, settled_by = auth.uid() where id = p_id;
  update fund_state set unclaimed = unclaimed - u.amount where id = 1 returning unclaimed into bal;
  insert into ledger (fund, what, amount, balance)
    values ('unclaimed', u.name || ': ' || case p_how when 'paid' then 'credit paid back to them' else 'unclaimed credit given to charity on their behalf' end
            || coalesce(' (' || nullif(trim(coalesce(p_note, '')), '') || ')', ''), -u.amount, bal);
end $$;
revoke execute on function public.settle_unclaimed(bigint, text, text, text) from public, anon;
grant execute on function public.settle_unclaimed(bigint, text, text, text) to authenticated;

-- The Square check counts the unclaimed credit too, since it's still in Square.
create or replace function public.square_expected() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fs fund_state; v_pending jsonb; v_in numeric; v_fees numeric; v_all numeric;
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
  return jsonb_build_object(
    'funds', v_all, 'unclaimed', fs.unclaimed,
    'pending', v_pending, 'pending_in', v_in, 'pending_fees', v_fees,
    'held_cash', fs.held_cash, 'held_bank', fs.held_bank,
    'expected', v_all + v_in - v_fees - fs.held_cash - fs.held_bank,
    'square_balance', fs.square_balance, 'square_balance_at', fs.square_balance_at);
end $$;
revoke execute on function public.square_expected() from public, anon;
grant execute on function public.square_expected() to authenticated;
