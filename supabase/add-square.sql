-- Card payments through Square: remembers each booking's Square order and the fee Square took.
alter table public.bookings add column if not exists square_order_id text;
alter table public.bookings add column if not exists card_fee numeric(8,2) not null default 0;
create index if not exists bookings_square_order_idx on public.bookings (square_order_id);

-- The ticket now also says whether it's paid and how much is due, so the app can offer "Pay by card".
drop function if exists public.ticket(text);
create function public.ticket(p_code text) returns table (code text, status text, display_name text, places int,
  title text, day date, "time" time, location text, checked_in boolean, paid boolean, amount numeric)
language sql stable security definer set search_path = public as $$
  select b.code, b.status, b.display_name, b.places, e.title, e.day, e.time, e.location, b.checked_in, b.paid, b.amount
  from bookings b join events e on e.id = b.event_id where b.code = upper(trim(p_code))
$$;
revoke execute on function public.ticket(text) from public;
grant execute on function public.ticket(text) to anon, authenticated;
