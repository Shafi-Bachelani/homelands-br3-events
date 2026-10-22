-- Phone alerts for the admin. When someone joins the app (and is waiting for approval),
-- and again when their Jotform application arrives, a push notification is sent through
-- ntfy (https://ntfy.sh). The admin installs the free ntfy app and subscribes to the topic
-- saved in alert_settings. The topic is kept out of this public repo: set it with the
-- insert at the bottom. Alerts never block a sign-up. Safe to run more than once.

create extension if not exists pg_net;

-- Single row holding the private ntfy topic. No policies, so only the database can read it.
create table if not exists public.alert_settings (
  id int primary key default 1 check (id = 1),
  ntfy_topic text not null
);
alter table public.alert_settings enable row level security;

create or replace function public.send_admin_alert(p_title text, p_message text) returns void
language plpgsql security definer set search_path = public as $$
declare
  t text := (select ntfy_topic from alert_settings where id = 1);
begin
  if coalesce(t, '') = '' then return; end if;
  perform net.http_post(
    url := 'https://ntfy.sh/',
    body := jsonb_build_object(
      'topic', t,
      'title', p_title,
      'message', p_message,
      'tags', jsonb_build_array('bust_in_silhouette'),
      'click', 'https://br3-mens.ourhomelands.co.uk/'
    )
  );
exception when others then
  null; -- an alert that fails must never stop a sign-up
end $$;
revoke execute on function public.send_admin_alert(text, text) from public, anon, authenticated;

-- Runs after on_auth_user_created (triggers fire in name order), so the profile and
-- postcode already exist.
create or replace function public.alert_new_member() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p profiles;
  mi numeric;
begin
  select * into p from profiles where id = new.id;
  if p.id is null or p.approved then return new; end if;
  select miles into mi from member_postcodes where user_id = new.id;
  perform send_admin_alert(
    'New BR3 member waiting',
    p.name || ' just joined' ||
      case when mi is not null then ' (' || mi || ' miles away)' else '' end ||
      '. Approve them in Organiser tools.'
  );
  return new;
end $$;

drop trigger if exists zz_alert_new_member on auth.users;
create trigger zz_alert_new_member after insert on auth.users
  for each row execute function public.alert_new_member();

create or replace function public.alert_new_application() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  p profiles;
begin
  select * into p from profiles where id = new.user_id;
  if p.id is null then return new; end if;
  perform send_admin_alert(
    'BR3 application received',
    p.name || ' sent their membership application' ||
      case when p.approved then '.' else ' and is waiting for approval.' end
  );
  return new;
end $$;

drop trigger if exists alert_new_application on public.applications;
create trigger alert_new_application after insert on public.applications
  for each row execute function public.alert_new_application();

-- Set the private topic (replace the text, keep the quotes):
-- insert into public.alert_settings (id, ntfy_topic) values (1, 'your-secret-topic')
--   on conflict (id) do update set ntfy_topic = excluded.ntfy_topic;
