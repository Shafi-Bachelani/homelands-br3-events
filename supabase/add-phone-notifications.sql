-- Phone notifications (web push) for every member, like WhatsApp's.
-- Members turn them on in the app (Notifications, the bell at the top). On an iPhone the app has
-- to be added to the home screen first. Each member chooses what they get:
--   announcements  new posts in Announcements                      (on to start with)
--   events         a new event, or a date set for one              (on)
--   football       Friday football booking has opened              (on, football members only)
--   reminders      the day before an event or game you've booked   (on)
--   replies        comments on your posts, or posts you commented on (on)
--   mygroups       posts in chats you've signed up to, like Quran  (on)
--   chats          every other chat post, accounts included        (off, it would be a lot)
-- Every notification also shows in the app under the bell.
-- The Netlify function /.netlify/functions/push does the sending. It makes its own keys the first
-- time it runs, so nothing secret goes in this file. A notification can never stop a post,
-- comment or event being saved. Safe to run more than once.

create extension if not exists pg_net;

-- ---------- settings, kept away from the app (no policies) ----------
create table if not exists public.push_settings (
  id int primary key default 1 check (id = 1),
  send_url text not null,
  subject text not null default 'https://br3-mens.ourhomelands.co.uk',
  public_key text,
  private_key text
);
alter table public.push_settings enable row level security;
revoke all on public.push_settings from anon, authenticated;
insert into public.push_settings (id, send_url)
values (1, 'https://ourhomelandsbr3.netlify.app/.netlify/functions/push')
on conflict (id) do nothing;

-- ---------- each phone that has notifications on ----------
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  device text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;
grant select on public.push_subscriptions to authenticated;
drop policy if exists "see own phones" on public.push_subscriptions;
create policy "see own phones" on public.push_subscriptions for select to authenticated using (user_id = auth.uid());

-- ---------- what each member wants (no row = the defaults above) ----------
create table if not exists public.push_prefs (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  announcements boolean not null default true,
  events boolean not null default true,
  football boolean not null default true,
  reminders boolean not null default true,
  replies boolean not null default true,
  mygroups boolean not null default true,
  chats boolean not null default false
);
alter table public.push_prefs enable row level security;
revoke all on public.push_prefs from anon;
grant select, insert, update on public.push_prefs to authenticated;
drop policy if exists "own prefs" on public.push_prefs;
create policy "own prefs" on public.push_prefs for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- the notifications themselves (also the list under the bell) ----------
create table if not exists public.notices (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null default '',
  url text not null default '',
  tag text not null default '',
  created_at timestamptz not null default now(),
  pushed_at timestamptz,
  read_at timestamptz
);
create index if not exists notices_user on public.notices (user_id, id desc);
create index if not exists notices_waiting on public.notices (id) where pushed_at is null;
alter table public.notices enable row level security;
revoke all on public.notices from anon, authenticated;
grant select on public.notices to authenticated;
drop policy if exists "own notices" on public.notices;
create policy "own notices" on public.notices for select to authenticated using (user_id = auth.uid());

-- Timed notifications that have gone out, so each one goes once.
create table if not exists public.notice_done (
  kind text not null,
  ref text not null,
  done_at timestamptz not null default now(),
  primary key (kind, ref)
);
alter table public.notice_done enable row level security;
revoke all on public.notice_done from anon, authenticated;

-- ---------- helpers ----------
-- Short text for a notification: no **bold** marks, one line, at most 140 characters.
create or replace function public.notice_text(t text) returns text language sql immutable as $$
  select case when length(x) > 140 then left(x, 137) || '…' else x end
    from (select btrim(regexp_replace(replace(coalesce(t, ''), '**', ''), '\s+', ' ', 'g')) as x) s
$$;

-- Asks the Netlify function to send what's waiting. It runs after this change is saved.
create or replace function public.push_now() returns void
language plpgsql security definer set search_path = public as $$
declare u text := (select send_url from push_settings where id = 1);
begin
  if coalesce(u, '') = '' then return; end if;
  perform net.http_post(url := u, body := '{}'::jsonb);
exception when others then null;
end $$;

-- Writes one notification for each of these people who is approved and wants this kind.
create or replace function public.queue_notice(p_users uuid[], p_kind text, p_title text, p_body text, p_url text, p_tag text default '')
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into notices (user_id, kind, title, body, url, tag)
  select p.id, p_kind, notice_text(p_title), notice_text(p_body), coalesce(p_url, ''), coalesce(p_tag, '')
    from profiles p
    left join push_prefs pr on pr.user_id = p.id
   where p.id = any(p_users) and p.approved
     and coalesce((to_jsonb(pr) ->> p_kind)::boolean, p_kind <> 'chats');
  get diagnostics n = row_count;
  if n > 0 then perform push_now(); end if;
  return n;
end $$;

-- Can this person read this chat? The same rule as can_see_group, for someone other than the signed-in person.
-- Football-only chats (add-football-chats.sql) are for football and family members, so either file can run first.
alter table public.groups add column if not exists football_only boolean not null default false;
create or replace function public.user_sees_group(u uuid, g text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when coalesce((select football_only from groups where id = g), false)
    then exists (select 1 from profiles where id = u and (role in ('organiser', 'admin') or football or family))
    else not coalesce((select members_only from groups where id = g), false)
      or exists (select 1 from profiles where id = u and role = 'admin')
      or exists (select 1 from group_members where group_id = g and user_id = u)
      or (g in ('football-accounts', 'events-accounts', 'family-accounts') and exists (select 1 from profiles where id = u and approved))
  end
$$;

-- ---------- new posts ----------
create or replace function public.notify_new_post() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  gname text := coalesce((select name from groups where id = new.group_id), 'Chats');
  what text := coalesce(nullif(btrim(new.body), ''),
                        case when new.poll is not null then 'Started a poll' when new.image is not null then 'Shared a photo' else 'New post' end);
  joined uuid[];
  others uuid[];
begin
  if new.group_id = 'announcements' then
    perform queue_notice(array(select id from profiles where id is distinct from new.user_id),
      'announcements', '📢 ' || gname, what, '#groups', 'announcements');
    return new;
  end if;
  -- People who signed up to this chat (members-only chats like Quran)
  select array_agg(user_id) into joined from group_members
   where group_id = new.group_id and user_id is distinct from new.user_id
     and coalesce((select members_only from groups where id = new.group_id), false);
  -- Everyone else who can read it
  select array_agg(p.id) into others from profiles p
   where p.id is distinct from new.user_id and not (p.id = any(coalesce(joined, '{}')))
     and user_sees_group(p.id, new.group_id);
  if joined is not null then
    perform queue_notice(joined, 'mygroups', new.author_name || ' · ' || gname, what, '#chat:' || new.group_id, 'chat-' || new.group_id);
  end if;
  if others is not null then
    perform queue_notice(others, 'chats', new.author_name || ' · ' || gname, what, '#chat:' || new.group_id, 'chat-' || new.group_id);
  end if;
  return new;
exception when others then
  return new; -- never stop a post being saved
end $$;
drop trigger if exists zz_notify_new_post on public.posts;
create trigger zz_notify_new_post after insert on public.posts
  for each row execute function public.notify_new_post();

-- ---------- new comments: to the post's author and anyone else who has commented ----------
create or replace function public.notify_new_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p posts;
  who uuid[];
begin
  select * into p from posts where id = new.post_id;
  if p.id is null then return new; end if;
  select array_agg(distinct u) into who from (
    select p.user_id as u
    union select user_id from comments where post_id = new.post_id
  ) x where u is not null and u is distinct from new.user_id and user_sees_group(u, p.group_id);
  if who is not null then
    perform queue_notice(who, 'replies', '💬 ' || new.author_name || ' commented', new.body,
      case when p.group_id = 'announcements' then '#groups' else '#chat:' || p.group_id end, 'post-' || p.id);
  end if;
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zz_notify_new_comment on public.comments;
create trigger zz_notify_new_comment after insert on public.comments
  for each row execute function public.notify_new_comment();

-- ---------- new events, or a date set for one (football has its own "booking is open" notice) ----------
create or replace function public.notify_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  head text;
  line text;
begin
  if new.kind <> 'event' then return new; end if;
  if tg_op = 'UPDATE' and not (old.day is null and new.day is not null) then return new; end if;
  head := case when tg_op = 'INSERT' then '📅 New event: ' else '📅 Date set: ' end || new.title;
  line := case when new.day is null then 'Date to be confirmed'
               else to_char(new.day, 'FMDay FMDD FMMonth') || ' at ' || to_char(new.time, 'HH24:MI') end
          || case when new.location <> '' then ', ' || new.location else '' end
          || case when new.price > 0 then ' · £' || replace(to_char(new.price, 'FM999990.00'), '.00', '') else ' · Free' end;
  perform queue_notice(array(select id from profiles), 'events', head, line, '#events', 'event-' || new.id);
  return new;
exception when others then
  return new;
end $$;
drop trigger if exists zz_notify_event on public.events;
create trigger zz_notify_event after insert or update of day on public.events
  for each row execute function public.notify_event();

-- ---------- timed: run every hour by the Netlify function push-hourly ----------
create or replace function public.queue_due_notices() returns int
language plpgsql security definer set search_path = public as $$
declare
  e record;
  b record;
  n int := 0;
  starts timestamptz;
  local_day date := (now() at time zone 'Europe/London')::date;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the server runs this.'; end if;

  -- Football booking has opened (Wednesday 1pm): to football members who haven't booked yet.
  for e in select * from events
            where kind = 'football' and day >= local_day
              and now() >= fb_opens(day) and now() < fb_opens(day) + interval '6 hours' loop
    insert into notice_done (kind, ref) values ('football-open', e.id::text) on conflict do nothing;
    if found then
      n := n + queue_notice(array(
          select p.id from profiles p
           where (p.football or p.family)
             and not exists (select 1 from bookings x where x.event_id = e.id and x.user_id = p.id and x.status <> 'cancelled')),
        'football', '⚽ Football booking is open',
        'Book your place for ' || to_char(e.day, 'FMDay FMDD FMMonth') || ' at ' || to_char(e.time, 'HH24:MI') || '.',
        '#football', 'football-' || e.id);
    end if;
  end loop;

  -- Reminders, about a day before, to people booked in (not weekly sign-ups like Quran).
  for e in select * from events
            where day is not null and not weekly
              and (day + time) at time zone 'Europe/London' between now() + interval '2 hours' and now() + interval '24 hours' loop
    insert into notice_done (kind, ref) values ('reminder', e.id::text) on conflict do nothing;
    if not found then continue; end if;
    starts := (e.day + e.time) at time zone 'Europe/London';
    for b in select distinct on (user_id) user_id, paid, amount from bookings
              where event_id = e.id and user_id is not null and status = 'booked' and created_at < now() - interval '3 hours'
              order by user_id, paid loop
      n := n + queue_notice(array[b.user_id], 'reminders',
        '⏰ ' || e.title || case when e.day = local_day then ' today' else ' tomorrow' end,
        'At ' || to_char(e.time, 'HH24:MI') || case when e.location <> '' then ', ' || e.location else '' end || '.'
          || case when e.kind = 'football' and not b.paid and b.amount > 0 and now() < fb_pay_by(e.day)
                  then ' You haven''t paid yet: please pay by ' || to_char(fb_pay_by(e.day) at time zone 'Europe/London', 'FMHH12am') || ' ' ||
                       case when (fb_pay_by(e.day) at time zone 'Europe/London')::date = local_day then 'tonight' else to_char(fb_pay_by(e.day) at time zone 'Europe/London', 'FMDay') end || '.'
                  else '' end,
        case when e.kind = 'football' then '#football' else '#schedule' end, 'remind-' || e.id);
    end loop;
  end loop;

  -- Tidy up old ones.
  delete from notices where created_at < now() - interval '60 days';
  delete from notice_done where done_at < now() - interval '120 days';
  return n;
end $$;

-- ---------- for the Netlify function (server only) ----------
-- Marks a batch as sent and returns it with every phone each person has, ready to send.
create or replace function public.claim_push_batch(p_limit int default 200)
returns table (notice_id bigint, endpoint text, p256dh text, auth text, title text, body text, url text, tag text)
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the server runs this.'; end if;
  return query
  with c as (
    update notices n set pushed_at = now()
     where n.id in (select w.id from notices w
                     where w.pushed_at is null and w.created_at > now() - interval '1 day'
                     order by w.id limit p_limit for update skip locked)
    returning n.id, n.user_id, n.title, n.body, n.url, n.tag
  )
  select c.id, s.endpoint, s.p256dh, s.auth, c.title, c.body, c.url, c.tag
    from c join push_subscriptions s on s.user_id = c.user_id;
end $$;

-- Phones that have switched notifications off at their end.
create or replace function public.forget_push_endpoints(p_endpoints text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'Only the server runs this.'; end if;
  delete from push_subscriptions where endpoint = any(p_endpoints);
end $$;

-- ---------- for the app ----------
-- Saves this phone for the signed-in member (taking it over if someone else used it before).
create or replace function public.save_push(p_endpoint text, p_p256dh text, p_auth text, p_device text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth, device)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(coalesce(p_device, ''), 60))
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, device = excluded.device;
end $$;

-- Turns notifications off on this phone (also when signing out).
create or replace function public.forget_push(p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
end $$;

-- Sends a test notification to the signed-in member's own phones.
create or replace function public.test_push() returns int
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  insert into notices (user_id, kind, title, body, url, tag)
  values (auth.uid(), 'test', '🔔 Notifications are working', 'This is how messages from the app will look.', '#notifications', 'test');
  perform push_now();
  return (select count(*) from push_subscriptions where user_id = auth.uid());
end $$;

create or replace function public.read_notices() returns void
language sql security definer set search_path = public as $$
  update notices set read_at = now() where user_id = auth.uid() and read_at is null
$$;

-- For the admin: how many approved members have notifications on, to see how the move from WhatsApp is going.
create or replace function public.push_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Only the admin can see this.'; end if;
  return jsonb_build_object(
    'members', (select count(*) from profiles where approved),
    'on', (select count(distinct s.user_id) from push_subscriptions s join profiles p on p.id = s.user_id where p.approved),
    'phones', (select count(*) from push_subscriptions));
end $$;

revoke execute on function public.notice_text(text), public.push_now(), public.queue_notice(uuid[], text, text, text, text, text),
  public.user_sees_group(uuid, text), public.notify_new_post(), public.notify_new_comment(), public.notify_event(),
  public.queue_due_notices(), public.claim_push_batch(int), public.forget_push_endpoints(text[]),
  public.save_push(text, text, text, text), public.forget_push(text), public.test_push(), public.read_notices(), public.push_stats()
  from public, anon, authenticated;
grant execute on function public.queue_due_notices(), public.claim_push_batch(int), public.forget_push_endpoints(text[]) to service_role;
grant execute on function public.save_push(text, text, text, text), public.forget_push(text), public.test_push(),
  public.read_notices(), public.push_stats() to authenticated;
