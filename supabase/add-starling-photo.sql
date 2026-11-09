-- =====================================================================
--  A second balance photo: the Starling BR3 Funds Space, next to the
--  Square one (Funds page and the Accounts Reconciliation chat).
--  Photo 1 is Square, photo 2 is Starling. Each new upload replaces the last.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================
alter table public.square_statement drop constraint if exists square_statement_id_check;
alter table public.square_statement add constraint square_statement_id_check check (id in (1, 2));
