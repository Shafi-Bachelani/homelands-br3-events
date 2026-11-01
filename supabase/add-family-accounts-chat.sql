-- =====================================================================
--  Family Events Accounts chat (on the Joined events tab).
--  Every approved member can read it; only the admin posts. It keeps the
--  Family Events fund's history: each week's subscriptions (posted by the
--  Saturday morning pull), and any money in or spent recorded on the Funds page.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

insert into public.groups (id, name, about, sort, members_only)
values ('family-accounts', 'Family Events Accounts',
        'The BR3 Family Events fund: the weekly Individual, Concessionary and Family subscriptions, and money spent on family events. Every approved member can read it; only the admin posts.', 3, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;

create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
    or (g in ('football-accounts', 'events-accounts', 'family-accounts') and exists (select 1 from profiles where id = auth.uid() and approved))
$$;

drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin())
              and (group_id not in ('football-accounts', 'events-accounts', 'family-accounts') or is_organiser()) and can_see_group(group_id));

-- Money in or spent recorded on the Funds page is also posted to the chat.
create or replace function public.family_entry(p_amount numeric, p_reason text) returns public.fund_state
language plpgsql security definer set search_path = public as $$
declare fs fund_state; a numeric := round(coalesce(p_amount, 0), 2); r text := trim(coalesce(p_reason, '')); v_name text;
begin
  if not is_admin() then raise exception 'Only the admin can change the Family Events fund.'; end if;
  if a = 0 then raise exception 'Enter an amount.'; end if;
  if r = '' then raise exception 'Give a reason.'; end if;
  select * into fs from fund_state where id = 1 for update;
  fs.family := fs.family + a;
  insert into ledger (fund, what, amount, balance) values ('family', r, a, fs.family);
  update fund_state set family = fs.family where id = 1;
  select name into v_name from profiles where id = auth.uid();
  insert into posts (group_id, user_id, author_name, body)
  values ('family-accounts', auth.uid(), coalesce(v_name, 'Admin'),
          'Family Events fund · ' || to_char(now() at time zone 'Europe/London', 'FMDD Mon YYYY') || chr(10)
          || case when a > 0 then 'Money in £' else 'Spent £' end || to_char(abs(a), 'FM999990.00') || ': ' || r || chr(10)
          || 'Family Events fund now £' || to_char(fs.family, 'FM999990.00'));
  return fs;
end $$;
revoke execute on function public.family_entry(numeric, text) from public, anon;
grant execute on function public.family_entry(numeric, text) to authenticated;

-- Each week's subscriptions, posted once per week by the Saturday morning pull (or by the admin).
-- The week is the 7 days before p_end (UK dates): Saturday to Friday when run on a Saturday.
create table if not exists public.family_week_posts (
  week_end date primary key,
  post_id uuid references public.posts(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.family_week_posts enable row level security;
revoke all on public.family_week_posts from anon, authenticated;

create or replace function public.post_family_week(p_end date) returns text
language plpgsql security definer set search_path = public as $$
declare v_start date := p_end - 7; body text; r record; n int := 0; tg numeric := 0; tf numeric := 0; v_post uuid; v_name text; fam numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not is_admin() then raise exception 'Only the admin can post this.'; end if;
  if exists (select 1 from family_week_posts where week_end = p_end) then return null; end if;
  body := 'Family Events subscriptions · ' || to_char(v_start, 'FMDD Mon') || ' to ' || to_char(p_end - 1, 'FMDD Mon YYYY');
  for r in
    select regexp_replace(coalesce(nullif(label, ''), 'Subscription'), '\s*\(.*\)\s*$', '') as plan,
           count(*) as cnt, sum(gross - refunded) as g, sum(fee) as f
      from square_payments
     where kind = 'subscription' and status = 'COMPLETED'
       and (paid_at at time zone 'Europe/London')::date >= v_start and (paid_at at time zone 'Europe/London')::date < p_end
     group by 1 order by 1
  loop
    body := body || chr(10) || r.plan || ': ' || r.cnt || ' paid £' || to_char(r.g, 'FM999990.00')
            || ', Square fee (£' || to_char(r.f, 'FM999990.00') || '), net £' || to_char(r.g - r.f, 'FM999990.00');
    n := n + r.cnt; tg := tg + r.g; tf := tf + r.f;
  end loop;
  if n = 0 then return null; end if;
  select family into fam from fund_state where id = 1;
  body := body || chr(10) || 'Total: ' || n || ' paid £' || to_char(tg, 'FM999990.00') || ', fees (£' || to_char(tf, 'FM999990.00')
          || '), net £' || to_char(tg - tf, 'FM999990.00') || chr(10) || 'Family Events fund now £' || to_char(fam, 'FM999990.00');
  select id, name into r from profiles where role = 'admin' order by created_at limit 1;
  insert into posts (group_id, user_id, author_name, body) values ('family-accounts', r.id, coalesce(r.name, 'Admin'), body)
  returning id into v_post;
  insert into family_week_posts (week_end, post_id) values (p_end, v_post);
  return body;
end $$;
revoke execute on function public.post_family_week(date) from public, anon;
grant execute on function public.post_family_week(date) to authenticated, service_role;
