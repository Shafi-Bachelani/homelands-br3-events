-- Fix: Supabase keeps gen_random_bytes out of reach of our functions, which broke booking.
-- Booking codes like AA-7K2QXM: 6 characters from the random part of a UUID, skipping look-alikes (0/O, 1/I/L).
create or replace function public.new_code(prefix text) returns text
language sql volatile as $$
  select prefix || string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', get_byte(b, i) % 31 + 1, 1), '' order by i)
  from (select uuid_send(gen_random_uuid()) as b) x, generate_series(0, 5) as i
$$;
