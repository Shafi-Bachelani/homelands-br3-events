-- =====================================================================
--  Football Awards, new rules (run AFTER add-football-awards.sql).
--   * Four awards: Best Goal (the best goal, not the most goals),
--     Best Assist, Best Overall Player, Best Team Motivator.
--   * One vote per award, no second best. Each vote is 1 point.
--   * A voter must pick a different player for each award, and never
--     themselves. Still only players ticked in on the night, 11pm to 11pm.
--   * Tables: Last game, This kitty (the current run of up to 5 games)
--     and All time, top 6 per award.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

create or replace function public.award_categories() returns text[] language sql immutable as $$
  select array['goal', 'assist', 'overall', 'motivator']
$$;
create or replace function public.award_label(c text) returns text language sql immutable as $$
  select case c when 'goal' then '⚽ Best Goal' when 'assist' then '🎯 Best Assist'
    when 'overall' then '⭐ Best Overall Player' when 'motivator' then '📣 Best Team Motivator' else c end
$$;

-- Votes under the old six awards (nobody has voted yet) are cleared, then one player per voter per game.
delete from public.award_votes where not (category = any(public.award_categories())) or level <> 1;
create unique index if not exists award_votes_one_each on public.award_votes (event_id, voter, pick);

-- Which kitty a game belonged to: the first "Kitty N ends" on or after the game, else the current kitty.
create or replace function public.award_kitty(d date) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select min(substring(what from '^Kitty (\d+) ends')::int) from ledger
      where fund = 'kitty' and what ~ '^Kitty \d+ ends' and on_date >= d),
    (select session_no from fund_state where id = 1))
$$;

-- A game's results: the winner of each award (ties share it), with their votes.
create or replace function public.award_results(p_event uuid) returns json
language sql stable security definer set search_path = public as $$
  with t as (
    select v.category, b.id, b.display_name as name, count(*)::int as votes
    from award_votes v join bookings b on b.id = v.pick
    where v.event_id = p_event group by v.category, b.id, b.display_name
  ),
  r as (select t.*, rank() over (partition by category order by votes desc) as place from t)
  select coalesce(json_agg(json_build_object(
      'category', c.category, 'label', award_label(c.category),
      'best', (select coalesce(json_agg(json_build_object('name', r.name, 'votes', r.votes) order by r.name), '[]') from r where r.category = c.category and r.place = 1),
      'next', '[]'::json
    ) order by c.ord), '[]')
  from unnest(award_categories()) with ordinality as c(category, ord)
$$;
revoke execute on function public.award_results(uuid) from public, anon, authenticated;

-- Save my votes: p_votes is a list of {category, pick}. Replaces any votes I made before.
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
  for r in select x ->> 'category' as category, nullif(x ->> 'pick', '')::uuid as pick
             from jsonb_array_elements(coalesce(p_votes, '[]'::jsonb)) x loop
    if r.pick is null then continue; end if;
    if not (r.category = any(award_categories())) then raise exception 'Unknown award.'; end if;
    if not exists (select 1 from bookings where id = r.pick and event_id = p_event and checked_in and status = 'booked') then
      raise exception 'You can only vote for players who played on the night.';
    end if;
    if exists (select 1 from bookings where id = r.pick and user_id = v_me) then raise exception 'You can''t vote for yourself.'; end if;
    if exists (select 1 from award_votes where event_id = p_event and voter = v_me and pick = r.pick and category <> r.category) then
      raise exception 'Pick a different player for each award.';
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
  v_close := v_open + interval '24 hours';
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
                and now() >= award_opens(day, time) and now() < award_opens(day, time) + interval '24 hours' loop
      insert into notice_done (kind, ref) values ('awards-open', e.id::text) on conflict do nothing;
      if found then
        perform queue_notice(array(select user_id from bookings where event_id = e.id and checked_in and status = 'booked' and user_id is not null),
          'football', '🏆 Vote in the Football Awards', 'Best goal, best assist, best overall player and best team motivator. Voting is open for 24 hours.', '#football', 'awards-' || e.id);
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
      || v_voters || ' player' || case when v_voters = 1 then '' else 's' end || ' voted.' || E'\n';
    for c in select * from json_array_elements(award_results(e.id)) loop
      if json_array_length(c -> 'best') = 0 then continue; end if;
      select string_agg('**' || (x ->> 'name') || '**', ' and ') || ' (' || max((x ->> 'votes')::int) || ' vote'
             || case when max((x ->> 'votes')::int) = 1 then '' else 's' end || case when count(*) > 1 then ' each' else '' end || ')'
        into names from json_array_elements(c -> 'best') x;
      v_body := v_body || E'\n' || (c ->> 'label') || ': ' || names;
    end loop;
    v_body := v_body || E'\n\n' || 'Well played everyone! The awards table is on the Friday Football tab.';
    insert into posts (group_id, user_id, author_name, body) values ('football', null, 'Football Awards', v_body) returning id into v_post;
    update award_posts set post_id = v_post where event_id = e.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- The awards table, top 6 for one award (or all awards if p_category is null), plus the person asking.
-- p_period: 'last' = the latest game whose voting has closed, 'kitty' = the current kitty's games, 'all' = all time.
-- wins = games in the period where they won that award (ties count).
drop function if exists public.award_table(text, text);
create or replace function public.award_table(p_period text, p_category text default null)
returns table (rank int, name text, votes int, wins int, me boolean)
language sql stable security definer set search_path = public as $$
  with closed as (
    select e.id, e.day from events e
     where e.kind = 'football' and e.day is not null and now() >= award_opens(e.day, e.time) + interval '24 hours'
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
