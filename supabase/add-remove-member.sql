-- ---------- the admin removes a member (also in schema.sql) ----------
-- Deletes their account so they can no longer sign in. Their past bookings stay in the
-- history under their name, so old accounts still add up. Any credit they held leaves the
-- credits fund with an "account removed" line (the profiles_credit_removed trigger).
create or replace function public.remove_member(p_id uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
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
  update bookings set user_id = null where user_id = p_id;
  update bookings set booked_by = null where booked_by = p_id;
  delete from auth.users where id = p_id;
end $$;
revoke execute on function public.remove_member(uuid) from public, anon;
grant execute on function public.remove_member(uuid) to authenticated;
