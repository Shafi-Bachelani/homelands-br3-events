-- =====================================================================
--  Guests in the Quran Recitation chat, and Telegram alerts for guests
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. (Also in schema.sql.)
--
--  People who open the Quran event from a shared link or QR code, without
--  being members (or while still waiting for approval), can read the chat,
--  see the pinned weekly target, comment and post, after giving their name.
--  Nothing is held for approval. The admin can delete any post or comment,
--  and gets a Telegram alert for each guest message and each guest booking.
-- =====================================================================

-- Which chats guests may read and write in. Only the Quran chat for now.
alter table public.groups add column if not exists guests_allowed boolean not null default false;
update public.groups set guests_allowed = true where id = 'quran' and not guests_allowed;

-- Guest messages have no member behind them (user_id is null). guest_key is a hash of a
-- random code kept on the guest's phone, used to limit how often one phone can post.
alter table public.posts add column if not exists guest_key text;
alter table public.comments add column if not exists guest_key text;

-- Members waiting for approval can't post as members, but can still join in as a guest.
create or replace function public.require_approved() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.guest_say', true), '') = '1' then return new; end if;
  if auth.uid() is not null and exists (select 1 from profiles where id = auth.uid() and not approved) then
    raise exception 'Your membership is waiting for the admin to approve it.';
  end if;
  return new;
end $$;

-- What a guest sees: the chat's newest 60 posts (pinned target first) and their comments.
create or replace function public.guest_chat(p_group text) returns json
language plpgsql stable security definer set search_path = public as $$
declare g groups;
begin
  select * into g from groups where id = p_group and guests_allowed;
  if not found then raise exception 'This chat is for members only.'; end if;
  return json_build_object(
    'group', json_build_object('id', g.id, 'name', g.name, 'about', g.about),
    'posts', coalesce((select json_agg(x order by x.pinned desc, x.created_at desc) from (
        select p.id, p.author_name, p.body, p.image, p.images, p.poll, p.pinned, p.created_at, p.user_id is null as guest
          from posts p where p.group_id = g.id
         order by p.pinned desc, p.created_at desc limit 60) x), '[]'::json),
    'comments', coalesce((select json_agg(c order by c.created_at) from (
        select c.id, c.post_id, c.author_name, c.body, c.created_at, c.user_id is null as guest
          from comments c join posts p on p.id = c.post_id
         where p.group_id = g.id) c), '[]'::json));
end $$;
revoke execute on function public.guest_chat(text) from public;
grant execute on function public.guest_chat(text) to anon, authenticated;

-- A guest posts in the chat (p_post null) or comments on a post. Shows as "Name (guest)".
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
  -- At most 6 messages in 10 minutes and 40 a day from one phone, and 60 in 10 minutes from all guests.
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
revoke execute on function public.guest_say(text, uuid, text, text, text) from public;
grant execute on function public.guest_say(text, uuid, text, text, text) to anon, authenticated;

-- ---------- Telegram alerts to the admin ----------
-- Each guest post or comment, so the admin can delete anything unsuitable.
create or replace function public.alert_guest_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare gname text;
begin
  if new.guest_key is null then return new; end if;
  if tg_table_name = 'posts' then
    select name into gname from groups where id = new.group_id;
  else
    select gr.name into gname from posts p join groups gr on gr.id = p.group_id where p.id = new.post_id;
  end if;
  perform send_admin_alert(
    '💬 Guest ' || case when tg_table_name = 'posts' then 'post' else 'comment' end || ' in ' || coalesce(gname, 'a chat'),
    new.author_name || ': ' || left(new.body, 300) || E'\nYou can delete it in the chat (••• on a post, × on a comment).');
  return new;
exception when others then
  return new; -- an alert problem must never stop the message
end $$;
revoke execute on function public.alert_guest_message() from public, anon, authenticated;
drop trigger if exists zz_alert_guest_post on public.posts;
create trigger zz_alert_guest_post after insert on public.posts
  for each row execute function public.alert_guest_message();
drop trigger if exists zz_alert_guest_comment on public.comments;
create trigger zz_alert_guest_comment after insert on public.comments
  for each row execute function public.alert_guest_message();

-- Each non-member booking or booking request for an event.
create or replace function public.alert_guest_booking() returns trigger
language plpgsql security definer set search_path = public as $$
declare b bookings; e events;
begin
  select * into b from bookings where id = new.booking_id;
  select * into e from events where id = b.event_id;
  perform send_admin_alert(
    case when b.status = 'pending' then '🎟️ Guest asking to book: ' else '🎟️ Guest booked: ' end || coalesce(e.title, 'an event'),
    new.full_name || ', age ' || coalesce(new.age::text, '?') || ', ' || coalesce(b.places, 1) || ' place' || case when coalesce(b.places, 1) > 1 then 's' else '' end
      || case when b.status = 'pending' then E'\nApprove or decline it in Admin → Events and bookings.'
              when b.status = 'waitlist' then E'\nThe event is full, so they are on the waitlist.' else '' end);
  return new;
exception when others then
  return new;
end $$;
revoke execute on function public.alert_guest_booking() from public, anon, authenticated;
drop trigger if exists zz_alert_guest_booking on public.guests;
create trigger zz_alert_guest_booking after insert on public.guests
  for each row execute function public.alert_guest_booking();
