-- =====================================================================
--  Yahya's £6 for Friday 30 October (Square payment "yahya elmi", now the
--  account named yahya touré): keep his place as paid but not played, add
--  the £6 to his credit, and match his Square payment to it.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================
do $$
declare p profiles; e events; sp square_payments; b bookings;
begin
  select * into p from profiles where id = '4f185be2-9b90-40ef-a01e-67ec31c2422d';
  if not found then raise notice 'Yahya''s account wasn''t found, so nothing was changed. Tell Claude.'; return; end if;
  select * into e from events where id = '62e1d680-cbb2-4907-ab32-b17ae5fc873f';
  if not found then raise notice 'The 30 October game wasn''t found, so nothing was changed. Tell Claude.'; return; end if;
  select * into sp from square_payments where id = 'iQ8eidcXaZex4plg5SWw8gc1GHCZY';
  if not found then raise notice 'His Square payment isn''t in the app. Tap Sync from Square, then run this again.'; return; end if;
  if sp.booking_id is not null then raise notice 'His Square payment is already matched, so nothing was changed.'; return; end if;

  select * into b from bookings where event_id = e.id and user_id = p.id;
  if found then raise notice '% already has a place for 30 October, so nothing was changed. Tell Claude.', p.name; return; end if;

  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, card_fee, status, checked_in, code, risk_ok)
  values (e.id, p.id, p.name, 'payg', sp.gross, true, 'card', sp.fee, 'cancelled', false, new_code('AA-'), true)
  returning * into b;
  update bookings set amount = sp.gross, intro_cover = 0 where id = b.id;  -- he paid the full price
  update square_payments set kind = 'booking', booking_id = b.id, label = p.name, updated_at = now() where id = sp.id;
  perform set_config('app.credit_reason', 'paid for football 30 Oct but didn''t play, credit added', true);
  update profiles set credit = credit + sp.gross where id = p.id;
  perform set_config('app.credit_reason', '', true);
  raise notice '£% added to %''s credit, and his Square payment is matched.', sp.gross, p.name;
end $$;
