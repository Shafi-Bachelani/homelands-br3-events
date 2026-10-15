-- Ticking someone as a kitty member also covers any football place they have already booked
-- for an upcoming game, so it stops showing as unpaid. Safe to run more than once.
create or replace function public.set_kitty(p_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser() then raise exception 'Only organisers can change members.'; end if;
  update profiles set kitty_session = case when p_on then (select session_no from fund_state where id = 1) end
  where id = p_id;
  if p_on then
    update bookings b set charge = 'covered', amount = 0, paid = true, method = null
    from events e
    where e.id = b.event_id and e.kind = 'football' and e.day >= (now() at time zone 'Europe/London')::date
      and b.user_id = p_id and b.status <> 'cancelled' and not b.paid and b.charge in ('payg', 'kitty');
  end if;
end $$;
revoke execute on function public.set_kitty(uuid, boolean) from public, anon;
grant execute on function public.set_kitty(uuid, boolean) to authenticated;
