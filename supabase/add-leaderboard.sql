-- ---------- leaderboard: the members who take part most in the app (also in schema.sql) ----------
-- Needs add-welcome-and-members.sql first. Safe to run more than once.
-- Points: 1 per day they open the app, 3 per booking (any event, friends included), 3 per post,
-- 2 per comment, 1 per reaction or poll vote. Posts in the accounts chats and announcements don't count.
-- p_period: 'month' = this calendar month so far, 'all' = all time.
-- Returns the top 10, plus the person asking if they're not in the top 10 (me = true).
create or replace function public.leaderboard(p_period text) returns table (
  rank int, user_id uuid, name text, score int, days int, bookings int, posts int, comments int, reactions int, me boolean)
language sql stable security definer set search_path = public as $$
  with since as (
    select case when p_period = 'all' then timestamptz '2000-01-01'
                else (date_trunc('month', now() at time zone 'Europe/London') at time zone 'Europe/London') end as t
  ),
  quiet as (select unnest(array['announcements', 'football-accounts', 'events-accounts', 'family-accounts']) as g),
  acts as (
    select d.user_id, 'days' as k from member_days d, since where d.day >= (since.t at time zone 'Europe/London')::date
    union all
    select coalesce(b.booked_by, b.user_id), 'bookings' from bookings b, since
     where coalesce(b.booked_by, b.user_id) is not null and b.status not in ('cancelled', 'declined') and b.created_at >= since.t
    union all
    select x.user_id, 'posts' from posts x, since where x.created_at >= since.t and x.group_id not in (select g from quiet)
    union all
    select c.user_id, 'comments' from comments c join posts x on x.id = c.post_id, since
     where c.created_at >= since.t and x.group_id not in (select g from quiet)
    union all
    select r.user_id, 'reactions' from post_reactions r join posts x on x.id = r.post_id, since
     where r.created_at >= since.t and x.group_id not in (select g from quiet)
    union all
    select v.user_id, 'reactions' from poll_votes v join posts x on x.id = v.post_id, since
     where x.created_at >= since.t and x.group_id not in (select g from quiet)
  ),
  totals as (
    select a.user_id,
      count(*) filter (where k = 'days')::int as days, count(*) filter (where k = 'bookings')::int as bookings,
      count(*) filter (where k = 'posts')::int as posts, count(*) filter (where k = 'comments')::int as comments,
      count(*) filter (where k = 'reactions')::int as reactions
    from acts a join profiles p on p.id = a.user_id and p.approved
    group by a.user_id
  ),
  ranked as (
    select t.*, t.days + 3 * t.bookings + 3 * t.posts + 2 * t.comments + t.reactions as score,
      rank() over (order by t.days + 3 * t.bookings + 3 * t.posts + 2 * t.comments + t.reactions desc)::int as rk,
      row_number() over (order by t.days + 3 * t.bookings + 3 * t.posts + 2 * t.comments + t.reactions desc, t.user_id) as rn
    from totals t
  )
  select r.rk, r.user_id, p.name, r.score::int, r.days, r.bookings, r.posts, r.comments, r.reactions, r.user_id = auth.uid()
    from ranked r join profiles p on p.id = r.user_id
   where auth.uid() is not null and (r.rn <= 10 or r.user_id = auth.uid())
   order by r.rn
$$;
revoke execute on function public.leaderboard(text) from public, anon;
grant execute on function public.leaderboard(text) to authenticated;
