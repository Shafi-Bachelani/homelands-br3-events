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
