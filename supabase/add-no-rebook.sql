-- Unpaid football places: people removed at Thursday 11pm can't rebook that game;
-- people booking after Thursday 11pm get 30 minutes to pay.
-- People whose football place was released for not paying in time; they can't rebook that game.
create table if not exists public.football_removed (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  removed_at timestamptz not null default now(),
  primary key (event_id, user_id)
);
alter table public.football_removed enable row level security;
drop policy if exists "see own removals" on public.football_removed;
create policy "see own removals" on public.football_removed for select to authenticated using (user_id = auth.uid() or is_organiser());
drop policy if exists "organisers lift removals" on public.football_removed;
create policy "organisers lift removals" on public.football_removed for delete to authenticated using (is_organiser());
grant select, delete on public.football_removed to authenticated;

-- Removes football bookings that weren't paid in time, and remembers who was removed so they can't rebook
-- that game. "In time" is Thursday 11pm, or 30 minutes after booking for anyone who books after that.
-- Anyone may call it; it is idempotent.
create or replace function public.expire_unpaid() returns int
language plpgsql security definer set search_path = public as $$
declare n int; s int;
begin
  select session_no into s from fund_state;
  with x as (
    select b.id, b.event_id, b.user_id, b.charge from bookings b join events e on e.id = b.event_id
     where e.kind = 'football' and not b.paid and b.status = 'booked' and not e.accounts_posted
       and now() > greatest(fb_pay_by(e.day), b.created_at + interval '30 minutes')
  ), k as (
    update profiles p set kitty_session = null from x where x.user_id = p.id and x.charge = 'kitty' and p.kitty_session = s
  ), r as (
    insert into football_removed (event_id, user_id) select event_id, user_id from x where user_id is not null on conflict do nothing
  )
  delete from bookings where id in (select id from x);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.book_football(p_event uuid, p_choice text) returns public.bookings
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  e events; p profiles; fs fund_state; b bookings;
  taken int; v_charge text; v_amount numeric := 0; v_paid boolean := false; v_method text;
begin
  if uid is null then raise exception 'Please sign in to book football.'; end if;
  select * into e from events where id = p_event and kind = 'football';
  if not found then raise exception 'That game no longer exists.'; end if;
  if now() < fb_opens(e.day) then raise exception 'Booking opens on Wednesday at 1pm.'; end if;
  if now() > ((e.day + e.time) at time zone 'Europe/London') then raise exception 'This game has already started.'; end if;
  perform expire_unpaid();
  if exists (select 1 from bookings where event_id = p_event and user_id = uid and status <> 'cancelled') then
    raise exception 'You are already booked for this game.';
  end if;
  if exists (select 1 from football_removed where event_id = p_event and user_id = uid) then
    raise exception 'Your place was released because it wasn''t paid in time, so you can''t rebook this game.';
  end if;
  select coalesce(sum(places), 0) into taken from bookings where event_id = p_event and status = 'booked';
  if taken >= e.capacity then raise exception 'All % places are taken.', e.capacity; end if;
  select * into p from profiles where id = uid for update;
  select * into fs from fund_state;

  if p.kitty_session = fs.session_no then
    v_charge := 'covered'; v_paid := true;
  elsif p_choice = 'kitty' then
    v_charge := 'kitty'; v_amount := 15;
    if p.family then v_paid := true; v_method := 'transfer'; end if;
  else
    v_charge := 'payg'; v_amount := 6;
    if p.family then v_paid := true; v_method := 'transfer';
    elsif p.credit >= 6 then v_paid := true; v_method := 'credit';
      update profiles set credit = credit - 6 where id = uid;
    end if;
  end if;

  if v_charge = 'kitty' then update profiles set kitty_session = fs.session_no where id = uid; end if;

  insert into bookings (event_id, user_id, display_name, charge, amount, paid, method, code)
  values (p_event, uid, p.name, v_charge, v_amount, v_paid, v_method, new_code('AA-'))
  returning * into b;
  return b;
end $$;
