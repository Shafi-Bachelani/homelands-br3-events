-- =====================================================================
--  One Accounts chat: football accounts, events accounts and transfers
--  all post to a single chat, and that chat is the only place posted
--  accounts are kept.
--  Paste this whole file into Supabase → SQL Editor → New query → Run.
--  Safe to run more than once.
-- =====================================================================

-- The Football Accounts chat becomes the Accounts chat, for every approved member.
update public.groups set name = 'Accounts',
  about = 'All our posted accounts: Friday football, events, and money moved between funds, with the receipts. Every approved member can read them; only the admin posts.'
 where id = 'football-accounts';

-- Anything still posted to Events Accounts goes to the Accounts chat instead. Transfers used to be posted
-- to both chats, and football money into the events fund got a one-line pointer, so those are dropped.
create or replace function public.one_accounts_chat() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.group_id <> 'events-accounts' then return new; end if;
  if new.body like '%See the Football Accounts chat for details.%' then return null; end if;
  if exists (select 1 from posts where group_id = 'football-accounts' and body = new.body
              and created_at > now() - interval '1 minute') then return null; end if;
  new.group_id := 'football-accounts';
  return new;
end $$;
revoke execute on function public.one_accounts_chat() from public, anon, authenticated;
drop trigger if exists posts_one_accounts_chat on public.posts;
create trigger posts_one_accounts_chat before insert on public.posts
  for each row execute function public.one_accounts_chat();

-- Move what's already in Events Accounts, leaving out the copies and pointers.
delete from public.posts p
 where p.group_id = 'events-accounts'
   and (p.body like '%See the Football Accounts chat for details.%'
        or exists (select 1 from public.posts f where f.group_id = 'football-accounts' and f.body = p.body));
update public.posts set group_id = 'football-accounts' where group_id = 'events-accounts';

-- The empty Events Accounts chat is taken away.
delete from public.group_members where group_id = 'events-accounts';
delete from public.groups where id = 'events-accounts';
