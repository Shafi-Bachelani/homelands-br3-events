-- =====================================================================
--  Football Awards: Man of the Match, and voting can be extended.
--   * "Best Overall Player" is now "Man of the Match". A voter can give it
--     to anyone who played, even someone they picked for another award.
--     Best Goal, Best Assist and Best Team Motivator still need a
--     different player each. Nobody can vote for themselves.
--   * Voting normally closes 24 hours after it opens. A game can be given
--     a later closing time (below: Fri 6 Nov's game closes Sun 8 Nov 11pm).
--  Run after update-football-awards-full-results.sql. Safe to run more than once.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
-- =====================================================================

create or replace function public.award_label(c text) returns text language sql immutable as $$
  select case c when 'goal' then '⚽ Best Goal' when 'assist' then '🎯 Best Assist'
    when 'overall' then '🏅 Man of the Match' when 'motivator' then '📣 Best Team Motivator' else c end
$$;

-- The same player can now be picked twice by one voter, but only when one of the two is Man of the Match.
drop index if exists public.award_votes_one_each;
create unique index if not exists award_votes_one_each_but_motm on public.award_votes (event_id, voter, pick) where category <> 'overall';

-- Later closing times for particular games.
create table if not exists public.award_close_override (
  event_id uuid primary key references public.events(id) on delete cascade,
  closes timestamptz not null
);
alter table public.award_close_override enable row level security;
revoke all on public.award_close_override from anon, authenticated;

create or replace function public.award_closes(p_event uuid, d date, t time) returns timestamptz
language sql stable security definer set search_path = public as $$
  select coalesce((select closes from award_close_override where event_id = p_event), award_opens(d, t) + interval '24 hours')
$$;

-- This week: Fri 6 Nov 2026's game closes Sun 8 Nov at 11pm, so Man of the Match can be voted on.
insert into public.award_close_override (event_id, closes)
select id, timestamp '2026-11-08 23:00' at time zone 'Europe/London' from public.events
 where kind = 'football' and day = date '2026-11-06'
on conflict (event_id) do update set closes = excluded.closes;

-- Save my votes: p_votes is a list of {category, pick}. Replaces any votes I made before.
create or replace function public.cast_award_votes(p_event uuid, p_votes jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare e events; v_me uuid := auth.uid(); r record; n int := 0;
begin
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if now() < award_opens(e.day, e.time) then raise exception 'Voting opens at 11pm after the game.'; end if;
  if now() >= award_closes(e.id, e.day, e.time) then raise exception 'Voting for this game has closed.'; end if;
  if not exists (select 1 from bookings where event_id = p_event and user_id = v_me and checked_in and status = 'booked') then
    raise exception 'Only players ticked in on the night can vote.';
  end if;
  delete from award_votes where event_id = p_event and voter = v_me;
  for r in select x ->> 'category' as category, nullif(x ->> 'pick', '')::uuid as pick
             from jsonb_array_elements(coalesce(p_votes, '[]'::jsonb)) x loop
    if r.pick is null then continue; end if;
    if not (r.category = any(award_categories())) then raise exception 'Unknown award.'; end if;
    if not exists (select 1 from bookings where id = r.pick and event_id = p_event and checked_in and status = 'booked') then
      raise exception 'You can only vote for players who played on the night.';
    end if;
    if exists (select 1 from bookings where id = r.pick and user_id = v_me) then raise exception 'You can''t vote for yourself.'; end if;
    -- Man of the Match can go to anyone who played; the other three awards need a different player each.
    if r.category <> 'overall' and exists (select 1 from award_votes where event_id = p_event and voter = v_me and pick = r.pick
                                           and category <> r.category and category <> 'overall') then
      raise exception 'Pick a different player for Best Goal, Best Assist and Best Team Motivator.';
    end if;
    insert into award_votes (event_id, voter, category, level, pick) values (p_event, v_me, r.category, 1, r.pick)
    on conflict (event_id, voter, category, level) do update set pick = excluded.pick, created_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.cast_award_votes(uuid, jsonb) from public, anon;
grant execute on function public.cast_award_votes(uuid, jsonb) to authenticated;

-- The ballot also says which kitty is current, for the table's "This kitty" tab.
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
  v_close := award_closes(e.id, e.day, e.time);
  v_state := case when now() < v_open then 'soon' when now() < v_close then 'open' else 'closed' end;
  v_can := exists (select 1 from bookings where event_id = e.id and user_id = v_me and checked_in and status = 'booked');
  return json_build_object(
    'event_id', e.id, 'day', e.day, 'title', e.title, 'opens', v_open, 'closes', v_close, 'state', v_state, 'can_vote', v_can,
    'kitty', award_kitty(e.day),
    'voters', (select count(distinct voter) from award_votes where event_id = e.id),
    'players', case when v_can and v_state = 'open' then
      (select coalesce(json_agg(json_build_object('id', b.id, 'name', b.display_name) order by lower(b.display_name)), '[]')
         from bookings b where b.event_id = e.id and b.checked_in and b.status = 'booked' and b.user_id is distinct from v_me) end,
    'mine', (select coalesce(json_agg(json_build_object('category', category, 'pick', pick)), '[]')
               from award_votes where event_id = e.id and voter = v_me),
    'results', case when v_state = 'closed' then award_results(e.id) end);
end $$;

-- Posts each game's winners to the Friday Football chat once voting closes (and tells players when it opens).
create or replace function public.post_due_awards() returns int
language plpgsql security definer set search_path = public as $$
declare e record; c json; v_body text; v_voters int; v_post uuid; n int := 0; names text;
begin
  if to_regclass('public.notice_done') is not null and to_regprocedure('public.queue_notice(uuid[],text,text,text,text,text)') is not null then
    for e in select * from events
              where kind = 'football' and day is not null and day >= current_date - 3
                and now() >= award_opens(day, time) and now() < award_closes(id, day, time) loop
      insert into notice_done (kind, ref) values ('awards-open', e.id::text) on conflict do nothing;
      if found then
        perform queue_notice(array(select user_id from bookings where event_id = e.id and checked_in and status = 'booked' and user_id is not null),
          'football', '🏆 Vote in the Football Awards', 'Best Goal, Best Assist, Best Team Motivator and Man of the Match. Vote now in the app.', '#football', 'awards-' || e.id);
      end if;
    end loop;
  end if;

  for e in select * from events
            where kind = 'football' and day is not null and day >= current_date - 14
              and now() >= award_closes(id, day, time)
              and not exists (select 1 from award_posts a where a.event_id = events.id) loop
    insert into award_posts (event_id) values (e.id) on conflict do nothing;
    if not found then continue; end if;
    select count(distinct voter) into v_voters from award_votes where event_id = e.id;
    if v_voters = 0 then continue; end if;
    v_body := '🏆 **Friday Football Awards · ' || to_char(e.day, 'FMDay FMDD FMMonth') || '**' || E'\n'
      || v_voters || ' player' || case when v_voters = 1 then '' else 's' end || ' voted. Votes for each player, winners in bold:';
    -- Full results: every player who got a vote in each award, most votes first, winners in bold.
    for c in select json_build_object('label', award_label(k.category), 'category', k.category) from unnest(award_categories()) with ordinality k(category, ord) order by k.ord loop
      select string_agg(case when t.place = 1 then '**' || t.name || '**' else t.name end || ' ' || t.votes, ', ' order by t.votes desc, t.name)
        into names
        from (select b.display_name as name, count(*)::int as votes, rank() over (order by count(*) desc) as place
                from award_votes v join bookings b on b.id = v.pick
               where v.event_id = e.id and v.category = c ->> 'category' group by b.id, b.display_name) t;
      if names is null then continue; end if;
      v_body := v_body || E'\n\n' || (c ->> 'label') || E'\n' || names;
    end loop;
    v_body := v_body || E'\n\n' || 'Well played everyone! The winners and the awards table are on the Friday Football tab.';
    insert into posts (group_id, user_id, author_name, body) values ('football', null, 'Football Awards', v_body) returning id into v_post;
    update award_posts set post_id = v_post where event_id = e.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- The awards table, top 6 for one award (or all awards if p_category is null), plus the person asking.
-- p_period: 'last' = the latest game whose voting has closed, 'kitty' = the current kitty's games, 'all' = all time.
-- wins = games in the period where they won that award (ties count).
create or replace function public.award_table(p_period text, p_category text default null)
returns table (rank int, name text, votes int, wins int, me boolean)
language sql stable security definer set search_path = public as $$
  with closed as (
    select e.id, e.day from events e
     where e.kind = 'football' and e.day is not null and now() >= award_closes(e.id, e.day, e.time)
       and exists (select 1 from award_votes v where v.event_id = e.id)
  ),
  latest as (select id, day from closed order by day desc limit 1),
  games as (
    select c.id from closed c
     where p_period = 'all'
        or (p_period = 'last' and c.id = (select id from latest))
        or (p_period = 'kitty' and award_kitty(c.day) = award_kitty(coalesce((select day from latest), current_date)))
  ),
  per as (
    select v.event_id, v.category, coalesce(b.user_id::text, 'guest:' || lower(b.display_name)) as k, b.user_id,
      max(b.display_name) as dn, count(*)::int as votes
    from award_votes v join bookings b on b.id = v.pick
    where v.event_id in (select id from games) and (p_category is null or v.category = p_category)
    group by v.event_id, v.category, 3, b.user_id
  ),
  won as (select per.*, rank() over (partition by event_id, category order by votes desc) = 1 as won from per),
  t as (select k, user_id, max(dn) as dn, sum(votes)::int as votes, count(*) filter (where won)::int as wins from won group by k, user_id),
  r as (
    select t.*, rank() over (order by t.votes desc, t.wins desc)::int as rk,
      row_number() over (order by t.votes desc, t.wins desc, t.k) as rn
    from t
  )
  select r.rk, coalesce(p.name, r.dn), r.votes, r.wins, coalesce(r.user_id = auth.uid(), false)
    from r left join profiles p on p.id = r.user_id
   where auth.uid() is not null
     and (is_footballer(auth.uid()) or exists (select 1 from profiles where id = auth.uid() and role in ('organiser', 'admin')))
     and (r.rn <= 6 or r.user_id = auth.uid())
   order by r.rn
$$;
revoke execute on function public.award_table(text, text) from public, anon;
grant execute on function public.award_table(text, text) to authenticated;
