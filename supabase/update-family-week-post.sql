-- =====================================================================
--  BR3 Family Events Accounts: the weekly subscriptions post now shows
--  the fund before, Individual / Concessionary / Family (always all three,
--  with no. of subs, £/sub, received, card costs, net received), the
--  total, any other money in or spent, and the fund after.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

create or replace function public.post_family_week(p_end date) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_start date := p_end - 7; body text; r record; n int := 0; tg numeric := 0; tf numeric := 0; tn numeric := 0;
  v_post uuid; fam numeric; prior numeric; other numeric;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not is_admin() then raise exception 'Only the admin can post this.'; end if;
  if exists (select 1 from family_week_posts where week_end = p_end) then return null; end if;
  select coalesce(family, 0) into fam from fund_state where id = 1;
  -- The fund before: today's value less everything that went in or out of it since the week began.
  select fam - coalesce(sum(amount), 0) into prior from ledger where fund = 'family' and on_date >= v_start;
  body := 'BR3 FAMILY EVENTS · ' || to_char(v_start, 'FMDy FMDD Mon') || ' to ' || to_char(p_end - 1, 'FMDy FMDD Mon YYYY') || chr(10)
       || 'Prior fund £' || to_char(prior, 'FM999990.00') || chr(10) || chr(10)
       || 'Weekly subscriptions for BR3 Family Events' || chr(10)
       || 'Type - no. - £/sub - received - less card costs - net received';
  for r in
    with t(plan, ord) as (values ('Individual', 1), ('Concessionary', 2), ('Family', 3)),
    s as (
      select case when lower(coalesce(label, '')) like '%famil%' then 'Family'
                  when lower(coalesce(label, '')) like '%conces%' then 'Concessionary'
                  else 'Individual' end as plan,
             gross, fee, coalesce(refunded, 0) as refunded
        from square_payments
       where kind = 'subscription' and status = 'COMPLETED'
         and (paid_at at time zone 'Europe/London')::date >= v_start and (paid_at at time zone 'Europe/London')::date < p_end)
    select t.plan, count(s.plan) as cnt, coalesce(sum(s.gross), 0) as g, coalesce(sum(s.fee), 0) as f,
           coalesce(sum(s.gross - s.fee - s.refunded), 0) as net
      from t left join s on s.plan = t.plan group by t.plan, t.ord order by t.ord
  loop
    body := body || chr(10) || r.plan || ' - ' || r.cnt || ' - '
         || case when r.cnt > 0 then '£' || to_char(r.g / r.cnt, 'FM999990.00') else '-' end
         || ' - £' || to_char(r.g, 'FM999990.00') || ' - (£' || to_char(r.f, 'FM999990.00') || ') - £' || to_char(r.net, 'FM999990.00');
    n := n + r.cnt; tg := tg + r.g; tf := tf + r.f; tn := tn + r.net;
  end loop;
  body := body || chr(10) || 'Total - ' || n || ' - - £' || to_char(tg, 'FM999990.00') || ' - (£' || to_char(tf, 'FM999990.00')
       || ') - £' || to_char(tn, 'FM999990.00');
  other := round(fam - prior - tn, 2);
  if other <> 0 then
    body := body || chr(10) || 'Other money ' || case when other > 0 then 'in £' || to_char(other, 'FM999990.00')
                                                      else 'spent (£' || to_char(-other, 'FM999990.00') || ')' end;
  end if;
  body := body || chr(10) || chr(10) || 'Updated fund £' || to_char(fam, 'FM999990.00');
  select id, name into r from profiles where role = 'admin' order by created_at limit 1;
  insert into posts (group_id, user_id, author_name, body) values ('family-accounts', r.id, coalesce(r.name, 'Admin'), body)
  returning id into v_post;
  insert into family_week_posts (week_end, post_id) values (p_end, v_post);
  return body;
end $$;
revoke execute on function public.post_family_week(date) from public, anon;
grant execute on function public.post_family_week(date) to authenticated, service_role;
