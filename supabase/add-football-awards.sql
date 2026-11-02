-- =====================================================================
--  Friday Football Awards: players vote for the night's best players.
--   * Only players ticked in (checked in) on the night can vote, and only
--     for other players ticked in that night. No voting for yourself.
--   * Voting opens at 11pm on match day and stays open for 24 hours.
--   * Six awards: top goal scorer, best attacker, best playmaker,
--     best defender, best goalie, most improved.
--   * Each vote has two levels: best (2 points) and next best (1 point).
--     You can skip an award you're not sure about.
--   * Results stay hidden until voting closes, then go to the
--     Friday Football chat. A season table (from 1 August) shows the top 10.
--   * Separate from the community leaderboard.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- The awards, in the order they're shown.
create or replace function public.award_categories() returns text[] language sql immutable as $$
  select array['scorer', 'attacker', 'playmaker', 'defender', 'goalie', 'improved']
$$;
create or replace function public.award_label(c text) returns text language sql immutable as $$
  select case c when 'scorer' then '⚽ Top goal scorer' when 'attacker' then '🔥 Best attacker'
    when 'playmaker' then '🎯 Best playmaker' when 'defender' then '🛡️ Best defender'
    when 'goalie' then '🧤 Best goalie' when 'improved' then '📈 Most improved' else c end
$$;

-- Voting opens at 11pm on match day (or an hour after kick-off if that's later), for 24 hours.
create or replace function public.award_opens(d date, t time) returns timestamptz language sql immutable as $$
  select greatest(d + time '23:00', (d + t) + interval '1 hour') at time zone 'Europe/London'
$$;

-- Is this person a footballer? (Same as add-football-chats.sql.)
create or replace function public.is_footballer(u uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = u and (football or family))
$$;

-- One row per vote. pick is the booking of the player voted for, so friends and walk-ins can win too.
create table if not exists public.award_votes (
  event_id uuid not null references public.events(id) on delete cascade,
  voter uuid not null references public.profiles(id) on delete cascade,
  category text not null,
  level smallint not null check (level in (1, 2)), -- 1 = best (2 points), 2 = next best (1 point)
  pick uuid not null references public.bookings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, voter, category, level)
);
alter table public.award_votes enable row level security;
revoke all on public.award_votes from anon, authenticated;

-- Games whose results have been posted to the chat, so each posts once.
create table if not exists public.award_posts (
  event_id uuid primary key references public.events(id) on delete cascade,
  post_id uuid references public.posts(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.award_posts enable row level security;
revoke all on public.award_posts from anon, authenticated;

-- A game's results: for each award, the best and next best (ties share a place).
create or replace function public.award_results(p_event uuid) returns json
language sql stable security definer set search_path = public as $$
  with t as (
    select v.category, b.id, b.display_name as name,
      sum(case when v.level = 1 then 2 else 1 end)::int as points,
      count(*) filter (where v.level = 1)::int as firsts
    from award_votes v join bookings b on b.id = v.pick
    where v.event_id = p_event group by v.category, b.id, b.display_name
  ),
  r as (select t.*, dense_rank() over (partition by category order by points desc, firsts desc) as place from t)
  select coalesce(json_agg(json_build_object(
      'category', c.category, 'label', award_label(c.category),
      'best', (select coalesce(json_agg(json_build_object('name', r.name, 'points', r.points) order by r.name), '[]') from r where r.category = c.category and r.place = 1),
      'next', (select coalesce(json_agg(json_build_object('name', r.name, 'points', r.points) order by r.name), '[]') from r where r.category = c.category and r.place = 2)
    ) order by c.ord), '[]')
  from unnest(award_categories()) with ordinality as c(category, ord)
$$;
revoke execute on function public.award_results(uuid) from public, anon, authenticated;

-- What the Friday Football tab shows: the latest game's awards.
--   state 'soon' (match day, voting not open yet), 'open' or 'closed' (with the results).
create or replace function public.award_ballot() returns json
language plpgsql stable security definer set search_path = public as $$
declare e events; v_me uuid := auth.uid(); v_open timestamptz; v_close timestamptz; v_state text; v_can boolean;
begin
  if v_me is null or not (is_footballer(v_me) or exists (select 1 from profiles where id = v_me and role in ('organiser', 'admin'))) then return null; end if;
  select * into e from events
   where kind = 'football' and day is not null and award_opens(day, time) - interval '12 hours' <= now()
   order by day desc, time desc limit 1;
  if not found then return null; end if;
  v_open := award_opens(e.day, e.time);
  v_close := v_open + interval '24 hours';
  v_state := case when now() < v_open then 'soon' when now() < v_close then 'open' else 'closed' end;
  v_can := exists (select 1 from bookings where event_id = e.id and user_id = v_me and checked_in and status = 'booked');
  return json_build_object(
    'event_id', e.id, 'day', e.day, 'title', e.title, 'opens', v_open, 'closes', v_close, 'state', v_state, 'can_vote', v_can,
    'voters', (select count(distinct voter) from award_votes where event_id = e.id),
    'players', case when v_can and v_state = 'open' then
      (select coalesce(json_agg(json_build_object('id', b.id, 'name', b.display_name) order by lower(b.display_name)), '[]')
         from bookings b where b.event_id = e.id and b.checked_in and b.status = 'booked' and b.user_id is distinct from v_me) end,
    'mine', (select coalesce(json_agg(json_build_object('category', category, 'level', level, 'pick', pick)), '[]')
               from award_votes where event_id = e.id and voter = v_me),
    'results', case when v_state = 'closed' then award_results(e.id) end);
end $$;
revoke execute on function public.award_ballot() from public, anon;
grant execute on function public.award_ballot() to authenticated;

-- Save my votes for a game: p_votes is a list of {category, level, pick}. Replaces any votes I made before.
create or replace function public.cast_award_votes(p_event uuid, p_votes jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare e events; v_me uuid := auth.uid(); r record; n int := 0;
begin
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if now() < award_opens(e.day, e.time) then raise exception 'Voting opens at 11pm after the game.'; end if;
  if now() >= award_opens(e.day, e.time) + interval '24 hours' then raise exception 'Voting for this game has closed.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and user_id = v_me and checked_in and status = 'booked') then
    raise exception 'Only players ticked in on the night can vote.';
  end if;
  delete from award_votes where event_id = p_event and voter = v_me;
  for r in select x ->> 'category' as category, (x ->> 'level')::smallint as level, nullif(x ->> 'pick', '')::uuid as pick
             from jsonb_array_elements(coalesce(p_votes, '[]'::jsonb)) x loop
    if r.pick is null then continue; end if;
    if not (r.category = any(award_categories())) or r.level not in (1, 2) then raise exception 'Unknown award.'; end if;
    if not exists (select 1 from bookings where id = r.pick and event_id = p_event and checked_in and status = 'booked') then
      raise exception 'You can only vote for players who played on the night.';
    end if;
    if exists (select 1 from bookings where id = r.pick and user_id = v_me) then raise exception 'You can''t vote for yourself.'; end if;
    insert into award_votes (event_id, voter, category, level, pick) values (p_event, v_me, r.category, r.level, r.pick)
    on conflict (event_id, voter, category, level) do update set pick = excluded.pick, created_at = now();
    n := n + 1;
  end loop;
  if exists (select 1 from award_votes where event_id = p_event and voter = v_me group by category having count(distinct pick) < count(*)) then
    raise exception 'Pick two different players for best and next best.';
  end if;
  return n;
end $$;
revoke execute on function public.cast_award_votes(uuid, jsonb) from public, anon;
grant execute on function public.cast_award_votes(uuid, jsonb) to authenticated;

-- Runs every hour (Netlify) and when someone opens the Friday Football tab:
--   * when voting opens, tells the players who were ticked in (if phone notifications are set up);
--   * when voting closes, posts the results to the Friday Football chat, once.
create or replace function public.post_due_awards() returns int
language plpgsql security definer set search_path = public as $$
declare e record; c json; v_body text; v_voters int; v_post uuid; n int := 0;
  names text;
begin
  if to_regclass('public.notice_done') is not null and to_regprocedure('public.queue_notice(uuid[],text,text,text,text,text)') is not null then
    for e in select * from events
              where kind = 'football' and day is not null and day >= current_date - 3
                and now() >= award_opens(day, time) and now() < award_opens(day, time) + interval '24 hours' loop
      insert into notice_done (kind, ref) values ('awards-open', e.id::text) on conflict do nothing;
      if found then
        perform queue_notice(array(select user_id from bookings where event_id = e.id and checked_in and status = 'booked' and user_id is not null),
          'football', '🏆 Vote in the Football Awards', 'Who were tonight''s best players? Voting is open for 24 hours.', '#football', 'awards-' || e.id);
      end if;
    end loop;
  end if;

  for e in select * from events
            where kind = 'football' and day is not null and day >= current_date - 14
              and now() >= award_opens(day, time) + interval '24 hours'
              and not exists (select 1 from award_posts a where a.event_id = events.id) loop
    insert into award_posts (event_id) values (e.id) on conflict do nothing;
    if not found then continue; end if;
    select count(distinct voter) into v_voters from award_votes where event_id = e.id;
    if v_voters = 0 then continue; end if;
    v_body := '🏆 **Friday Football Awards · ' || to_char(e.day, 'FMDay FMDD FMMonth') || '**' || E'\n'
      || v_voters || ' player' || case when v_voters = 1 then '' else 's' end || ' voted. Best = 2 points, next best = 1 point.' || E'\n';
    for c in select * from json_array_elements(award_results(e.id)) loop
      if json_array_length(c -> 'best') = 0 then continue; end if;
      select string_agg('**' || (x ->> 'name') || '**', ' and ') || ' (' || max((x ->> 'points')::int) || ' pts)' into names
        from json_array_elements(c -> 'best') x;
      v_body := v_body || E'\n' || (c ->> 'label') || ': ' || names;
      if json_array_length(c -> 'next') > 0 then
        select string_agg(x ->> 'name', ' and ') || ' (' || max((x ->> 'points')::int) || ')' into names
          from json_array_elements(c -> 'next') x;
        v_body := v_body || ', next best ' || names;
      end if;
    end loop;
    v_body := v_body || E'\n\n' || 'Well played everyone! The season table is on the Friday Football tab.';
    insert into posts (group_id, user_id, author_name, body) values ('football', null, 'Football Awards', v_body) returning id into v_post;
    update award_posts set post_id = v_post where event_id = e.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.post_due_awards() from public, anon;
grant execute on function public.post_due_awards() to authenticated, service_role;

-- The awards table: points from every game whose voting has closed.
-- p_period: 'season' = since 1 August, 'all' = all time. p_category: one award, or null for all of them.
-- Returns the top 10, plus the person asking if they're not in the top 10 (me = true).
create or replace function public.award_table(p_period text, p_category text default null)
returns table (rank int, name text, points int, firsts int, me boolean)
language sql stable security definer set search_path = public as $$
  with since as (
    select case when p_period = 'all' then date '2000-01-01'
      else make_date(extract(year from (now() at time zone 'Europe/London')::date - interval '7 months')::int, 8, 1) end as d
  ),
  t as (
    select coalesce(b.user_id::text, 'guest:' || lower(b.display_name)) as k, b.user_id,
      max(b.display_name) as dn,
      sum(case when v.level = 1 then 2 else 1 end)::int as points,
      count(*) filter (where v.level = 1)::int as firsts
    from award_votes v join bookings b on b.id = v.pick join events e on e.id = v.event_id, since
    where e.day >= since.d and now() >= award_opens(e.day, e.time) + interval '24 hours'
      and (p_category is null or v.category = p_category)
    group by 1, 2
  ),
  r as (
    select t.*, rank() over (order by t.points desc, t.firsts desc)::int as rk,
      row_number() over (order by t.points desc, t.firsts desc, t.k) as rn
    from t
  )
  select r.rk, coalesce(p.name, r.dn), r.points, r.firsts, coalesce(r.user_id = auth.uid(), false)
    from r left join profiles p on p.id = r.user_id
   where auth.uid() is not null
     and (is_footballer(auth.uid()) or exists (select 1 from profiles where id = auth.uid() and role in ('organiser', 'admin')))
     and (r.rn <= 10 or r.user_id = auth.uid())
   order by r.rn
$$;
revoke execute on function public.award_table(text, text) from public, anon;
grant execute on function public.award_table(text, text) to authenticated;
