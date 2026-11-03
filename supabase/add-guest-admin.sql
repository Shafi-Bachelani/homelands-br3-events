-- =====================================================================
--  Guests in Admin: one record per guest, report, strikes, block, delete
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Run add-guest-chat.sql first. Safe to run more than once. (Also in schema.sql.)
--
--  A guest is a phone: the random code the app keeps on it (stored only as a hash,
--  guest_key). Chat posts and comments carry it, and from now on so do event
--  bookings made on that phone. Older guest bookings are grouped by email instead.
-- =====================================================================

alter table public.bookings add column if not exists guest_key text;
create index if not exists bookings_guest_key on public.bookings (guest_key) where guest_key is not null;
create index if not exists posts_guest_key on public.posts (guest_key) where guest_key is not null;
create index if not exists comments_guest_key on public.comments (guest_key) where guest_key is not null;

-- What only the admin sees about a guest: strikes, a note, and whether they're blocked.
create table if not exists public.guest_admin (
  key text primary key,
  name text not null default '',
  strikes int not null default 0 check (strikes between 0 and 9),
  note text not null default '',
  blocked_at timestamptz,
  emails text[] not null default '{}',   -- kept only while blocked, so they can't book again
  updated_at timestamptz not null default now()
);
alter table public.guest_admin enable row level security;
revoke all on public.guest_admin from anon, authenticated;

-- Right after a guest books on a phone, the app links the booking to that phone.
-- A blocked guest's booking is declined there and then.
create or replace function public.guest_link_booking(p_code text, p_token text) returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; b bookings;
begin
  if length(coalesce(p_token, '')) < 16 then return 'ok'; end if;
  v_key := md5(p_token);
  select * into b from bookings where code = upper(trim(p_code)) and user_id is null and guest_key is null
     and created_at > now() - interval '1 hour';
  if not found then return 'ok'; end if;
  update bookings set guest_key = v_key where id = b.id;
  if exists (select 1 from guest_admin where key = v_key and blocked_at is not null) then
    update bookings set status = 'declined' where id = b.id;
    return 'blocked';
  end if;
  return 'ok';
end $$;
revoke execute on function public.guest_link_booking(text, text) from public;
grant execute on function public.guest_link_booking(text, text) to anon, authenticated;

-- A blocked guest's email can't be used to book.
create or replace function public.guest_email_not_blocked() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from guest_admin where blocked_at is not null and lower(trim(new.email)) = any(emails)) then
    raise exception 'Sorry, we can''t take a booking from you. Please contact the organiser.';
  end if;
  return new;
end $$;
revoke execute on function public.guest_email_not_blocked() from public, anon, authenticated;
drop trigger if exists guests_not_blocked on public.guests;
create trigger guests_not_blocked before insert on public.guests
  for each row execute function public.guest_email_not_blocked();

-- A blocked guest can't post or comment.
create or replace function public.guest_say(p_group text, p_post uuid, p_name text, p_token text, p_body text) returns void
language plpgsql security definer set search_path = public as $$
declare
  g groups;
  v_name text := left(regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'), 40);
  v_body text := left(trim(coalesce(p_body, '')), 1500);
  v_key text;
begin
  select * into g from groups where id = p_group and guests_allowed;
  if not found then raise exception 'This chat is for members only.'; end if;
  if length(v_name) < 2 then raise exception 'Please add your name.'; end if;
  if v_body = '' then raise exception 'Please write something first.'; end if;
  if length(coalesce(p_token, '')) < 16 then raise exception 'Please reload the page and try again.'; end if;
  v_key := md5(p_token);
  if exists (select 1 from guest_admin where key = v_key and blocked_at is not null) then
    raise exception 'Sorry, you can no longer post in this chat.';
  end if;
  if (select count(*) from posts where guest_key = v_key and created_at > now() - interval '10 minutes')
     + (select count(*) from comments where guest_key = v_key and created_at > now() - interval '10 minutes') >= 6
     or (select count(*) from posts where guest_key = v_key and created_at > now() - interval '1 day')
     + (select count(*) from comments where guest_key = v_key and created_at > now() - interval '1 day') >= 40 then
    raise exception 'You''ve sent a lot of messages. Please wait a little and try again.';
  end if;
  if (select count(*) from posts where guest_key is not null and created_at > now() - interval '10 minutes')
     + (select count(*) from comments where guest_key is not null and created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'The chat is very busy. Please try again in a few minutes.';
  end if;
  perform set_config('app.guest_say', '1', true);
  if p_post is null then
    insert into posts (group_id, user_id, author_name, body, guest_key)
    values (g.id, null, v_name || ' (guest)', v_body, v_key);
  else
    if not exists (select 1 from posts where id = p_post and group_id = g.id) then
      raise exception 'That post has been removed.';
    end if;
    insert into comments (post_id, user_id, author_name, body, guest_key)
    values (p_post, null, v_name || ' (guest)', v_body, v_key);
  end if;
  perform set_config('app.guest_say', '', true);
end $$;

-- One row per guest for the admin, most active first.
-- Activity over the last 90 days: 3 per booking, 3 per post, 2 per comment.
create or replace function public.guest_report() returns json
language plpgsql stable security definer set search_path = public as $$
declare since timestamptz := now() - interval '90 days';
begin
  if not is_admin() then raise exception 'Only the admin can see guests.'; end if;
  return coalesce((
    with bk as (
      select coalesce(b.guest_key, 'email:' || lower(trim(gu.email))) as key, b.*, gu.full_name, gu.email, gu.age as guest_age
        from bookings b left join guests gu on gu.booking_id = b.id
       where b.user_id is null and b.booked_by is null and (b.guest_key is not null or gu.booking_id is not null)
    ),
    acts as (
      select guest_key as key, author_name as name, created_at, 'post' as what from posts where guest_key is not null
      union all select guest_key, author_name, created_at, 'comment' from comments where guest_key is not null
      union all select key, coalesce(full_name, display_name), created_at, 'booking' from bk
    ),
    keys as (select key from acts union select key from guest_admin)
    select json_agg(r order by r.score desc, r.last_active desc nulls last) from (
      select k.key,
        coalesce((select regexp_replace(a.name, ' \(guest\)$', '') from acts a where a.key = k.key and a.name <> 'Guest (details removed)' order by a.created_at desc limit 1),
                 nullif(ga.name, ''), 'Guest') as name,
        (select x.email from bk x where x.key = k.key and x.email is not null order by x.created_at desc limit 1) as email,
        (select min(created_at) from acts a where a.key = k.key) as first_seen,
        (select max(created_at) from acts a where a.key = k.key) as last_active,
        (select count(*) from acts a where a.key = k.key and a.what = 'post' and a.created_at >= since)::int as posts_90,
        (select count(*) from acts a where a.key = k.key and a.what = 'comment' and a.created_at >= since)::int as comments_90,
        (select count(*) from acts a where a.key = k.key and a.what = 'booking' and a.created_at >= since)::int as bookings_90,
        (select 3 * count(*) filter (where a.what in ('post', 'booking')) + 2 * count(*) filter (where a.what = 'comment')
           from acts a where a.key = k.key and a.created_at >= since)::int as score,
        coalesce((select json_agg(json_build_object('id', x.id, 'title', e.title, 'day', e.day, 'status', x.status, 'places', x.places,
                    'age', coalesce(x.age, x.guest_age), 'paid', x.paid, 'amount', x.amount, 'checked_in', x.checked_in) order by e.day desc nulls first)
                    from bk x join events e on e.id = x.event_id where x.key = k.key), '[]'::json) as bookings,
        coalesce(ga.strikes, 0) as strikes, coalesce(ga.note, '') as note, ga.blocked_at
      from keys k left join guest_admin ga on ga.key = k.key
    ) r), '[]'::json);
end $$;
revoke execute on function public.guest_report() from public, anon;
grant execute on function public.guest_report() to authenticated;

-- Strikes for a guest, like members' two strike rule.
create or replace function public.set_guest_strikes(p_key text, p_strikes int, p_note text, p_name text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can give strikes.'; end if;
  if p_strikes < 0 or p_strikes > 9 then raise exception 'Strikes go from 0 to 9.'; end if;
  insert into guest_admin (key, name, strikes, note) values (p_key, coalesce(p_name, ''), p_strikes, coalesce(p_note, ''))
  on conflict (key) do update set strikes = excluded.strikes, note = excluded.note,
    name = coalesce(nullif(excluded.name, ''), guest_admin.name), updated_at = now();
end $$;
revoke execute on function public.set_guest_strikes(text, int, text, text) from public, anon;
grant execute on function public.set_guest_strikes(text, int, text, text) to authenticated;

-- Block (or unblock) a guest: they can't post, comment or book from that phone or their emails.
create or replace function public.block_guest(p_key text, p_on boolean, p_name text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v_emails text[];
begin
  if not is_admin() then raise exception 'Only the admin can block guests.'; end if;
  select coalesce(array_agg(distinct lower(trim(gu.email))), '{}') into v_emails
    from guests gu join bookings b on b.id = gu.booking_id
   where coalesce(b.guest_key, 'email:' || lower(trim(gu.email))) = p_key;
  if p_key like 'email:%' then v_emails := array(select distinct unnest(v_emails || substr(p_key, 7))); end if;
  insert into guest_admin (key, name, blocked_at, emails) values (p_key, coalesce(p_name, ''), case when p_on then now() end, case when p_on then v_emails else '{}' end)
  on conflict (key) do update set blocked_at = case when p_on then coalesce(guest_admin.blocked_at, now()) end,
    emails = case when p_on then array(select distinct unnest(guest_admin.emails || excluded.emails)) else '{}' end,
    name = coalesce(nullif(excluded.name, ''), guest_admin.name), updated_at = now();
  if p_on then  -- anything still waiting for approval is declined
    update bookings set status = 'declined' where status = 'pending' and user_id is null
       and (guest_key = p_key or id in (select booking_id from guests where 'email:' || lower(trim(email)) = p_key));
  end if;
end $$;
revoke execute on function public.block_guest(text, boolean, text) from public, anon;
grant execute on function public.block_guest(text, boolean, text) to authenticated;

-- Delete a guest: their chat posts and comments, and their personal details. Bookings for
-- events still to come are cancelled; past ones stay as "Guest (details removed)" for the head
-- count. If they're blocked, the block (and their email, so they can't book again) is kept.
create or replace function public.delete_guest(p_key text) returns void
language plpgsql security definer set search_path = public as $$
declare ids uuid[];
begin
  if not is_admin() then raise exception 'Only the admin can delete guests.'; end if;
  select coalesce(array_agg(b.id), '{}') into ids from bookings b left join guests gu on gu.booking_id = b.id
   where b.user_id is null and b.booked_by is null
     and (b.guest_key = p_key or 'email:' || lower(trim(gu.email)) = p_key);
  delete from comments where guest_key = p_key;
  delete from posts where guest_key = p_key;
  update bookings b set status = 'cancelled' from events e
   where b.id = any(ids) and e.id = b.event_id and (e.day is null or e.day >= current_date) and b.status in ('booked', 'waitlist', 'pending');
  delete from guests where booking_id = any(ids);
  update bookings set display_name = 'Guest (details removed)', age = null, gender = null, parent_ok = null,
    guest_key = case when exists (select 1 from guest_admin where key = p_key and blocked_at is not null) then guest_key end
   where id = any(ids);
  delete from guest_admin where key = p_key and blocked_at is null;
end $$;
revoke execute on function public.delete_guest(text) from public, anon;
grant execute on function public.delete_guest(text) to authenticated;
