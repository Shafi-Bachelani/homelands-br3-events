-- =====================================================================
--  Football Awards: the chat post shows the full results.
--  When voting closes, the Friday Football chat gets every player who got
--  a vote in each award, with their votes, winners in bold. (The winners
--  show on the Friday Football tab as soon as voting closes.)
--  Run after update-football-awards.sql. Safe to run more than once.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
-- =====================================================================

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

