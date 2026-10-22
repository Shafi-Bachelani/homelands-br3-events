-- Sends the admin's join alerts (add-join-alerts.sql) to Telegram as well as, or instead of,
-- ntfy. The admin makes a private bot with @BotFather and gets their chat id from
-- @userinfobot, then saves both with the update at the bottom. They are kept out of this
-- public repo. Safe to run more than once.

alter table public.alert_settings alter column ntfy_topic drop not null;
alter table public.alert_settings add column if not exists telegram_token text;
alter table public.alert_settings add column if not exists telegram_chat_id text;
insert into public.alert_settings (id) values (1) on conflict (id) do nothing;

create or replace function public.send_admin_alert(p_title text, p_message text) returns void
language plpgsql security definer set search_path = public as $$
declare
  s alert_settings;
begin
  select * into s from alert_settings where id = 1;
  if coalesce(s.telegram_token, '') <> '' and coalesce(s.telegram_chat_id, '') <> '' then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || s.telegram_token || '/sendMessage',
      body := jsonb_build_object(
        'chat_id', s.telegram_chat_id,
        'text', p_title || E'\n' || p_message || E'\nhttps://br3-mens.ourhomelands.co.uk/',
        'disable_web_page_preview', true
      )
    );
  end if;
  if coalesce(s.ntfy_topic, '') <> '' then
    perform net.http_post(
      url := 'https://ntfy.sh/',
      body := jsonb_build_object(
        'topic', s.ntfy_topic,
        'title', p_title,
        'message', p_message,
        'tags', jsonb_build_array('bust_in_silhouette'),
        'click', 'https://br3-mens.ourhomelands.co.uk/'
      )
    );
  end if;
exception when others then
  null; -- an alert that fails must never stop a sign-up
end $$;
revoke execute on function public.send_admin_alert(text, text) from public, anon, authenticated;

-- Save the bot token and chat id (replace the text, keep the quotes). Setting ntfy_topic
-- to null stops the ntfy alerts:
-- update public.alert_settings
--   set telegram_token = '123456:ABC...', telegram_chat_id = '123456789', ntfy_topic = null
--   where id = 1;
