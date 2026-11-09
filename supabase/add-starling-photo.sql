-- =====================================================================
--  A second balance photo: the Starling BR3 Funds Space, next to the
--  Square one (Funds page and the Accounts Reconciliation chat).
--  Photo 1 is Square, photo 2 is Starling. Each new upload replaces the last.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================
alter table public.square_statement drop constraint if exists square_statement_id_check;
alter table public.square_statement add constraint square_statement_id_check check (id in (1, 2));

-- As in add-starling.sql, and the post carries this week's Square and Starling balance photos
-- (photo 1 Square, photo 2 Starling), so each week's proof stays with that week's reconciliation.
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
  insert into posts (group_id, user_id, author_name, body, pinned, images)
    values ('accounts-reconciliation', auth.uid(), coalesce(v_name, 'Admin'), p_body, true,
            coalesce((select jsonb_agg(file order by id) from square_statement where file like 'data:image/%'), '[]'::jsonb))
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
