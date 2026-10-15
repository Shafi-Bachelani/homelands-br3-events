-- Weekly Sunday Quran Recitation Target: a free weekly event that people sign up to,
-- and a members-only chat that only people who signed up (and organisers) can see.
-- Safe to run more than once.

alter table public.groups add column if not exists members_only boolean not null default false;
alter table public.events add column if not exists weekly boolean not null default false;
alter table public.events add column if not exists group_id text references public.groups(id) on delete set null;

create table if not exists public.group_members (
  group_id text not null references public.groups(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table public.group_members enable row level security;
drop policy if exists "see memberships" on public.group_members;
create policy "see memberships" on public.group_members for select to authenticated using (user_id = auth.uid() or is_organiser());
drop policy if exists "join groups" on public.group_members;
create policy "join groups" on public.group_members for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "leave groups" on public.group_members;
create policy "leave groups" on public.group_members for delete to authenticated using (user_id = auth.uid() or is_organiser());
grant select, insert, delete on public.group_members to authenticated;

-- Can the signed-in person see this group's posts?
create or replace function public.can_see_group(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select not coalesce((select members_only from groups where id = g), false)
    or is_organiser()
    or exists (select 1 from group_members where group_id = g and user_id = auth.uid())
$$;
create or replace function public.can_see_post(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select can_see_group((select group_id from posts where id = p))
$$;
grant execute on function public.can_see_group(text), public.can_see_post(uuid) to authenticated;

drop policy if exists "members see posts" on public.posts;
create policy "members see posts" on public.posts for select to authenticated using (can_see_group(group_id));
drop policy if exists "members post" on public.posts;
create policy "members post" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and (not pinned or is_organiser()) and (group_id <> 'announcements' or is_admin()) and can_see_group(group_id));

drop policy if exists "members see comments" on public.comments;
create policy "members see comments" on public.comments for select to authenticated using (can_see_post(post_id));
drop policy if exists "members comment" on public.comments;
create policy "members comment" on public.comments for insert to authenticated with check (user_id = auth.uid() and can_see_post(post_id));

insert into public.groups (id, name, about, sort, members_only)
values ('quran', 'Quran Recitation Target', 'Our weekly recitation target. Sign up to the Sunday event to join.', 1, true)
on conflict (id) do update set name = excluded.name, about = excluded.about, members_only = true;

insert into public.events (kind, title, day, time, location, details, price, capacity, access, weekly, group_id)
select 'event', 'Sunday Quran Recitation Target', '2026-10-18', '20:00', 'From your own home',
  'Every Sunday we catch up to our weekly Quran recitation target, each from our own home. Free of charge. Sign up to see the target and join the conversation in Chats.',
  0, 500, 'members', true, 'quran'
where not exists (select 1 from public.events where group_id = 'quran');

-- This week's target, pinned, posted as the admin.
insert into public.posts (group_id, user_id, author_name, body, pinned)
select 'quran', p.id, p.name, $txt$**Week 2/18 of our Pre-Ramadan Quran**

To complete this weeks target  by **Sunday 18th October**

inshaAllah we will pace ourselves at 30-32 pages a week, and speed up nearing Ramadan

**This week to complete to-**

To the top of page 60, having completed verse 77 of Surah Aal-e-Imran:

إِنَّ الَّذِينَ يَشْتَرُونَ بِعَهْدِ اللَّهِ وَأَيْمَانِهِمْ ثَمَنًا قَلِيلًا أُولَٰئِكَ لَا خَلَاقَ لَهُمْ فِي الْآخِرَةِ وَلَا يُكَلِّمُهُمُ اللَّهُ وَلَا يَنظُرُ إِلَيْهِمْ يَوْمَ الْقِيَامَةِ وَلَا يُزَكِّيهِمْ وَلَهُمْ عَذَابٌ أَلِيمٌ

Lo! those who purchase a small gain at the cost of Allah's covenant and their oaths, they have no portion in the Hereafter. Allah will neither speak to them nor look upon them on the Day of Resurrection, nor will He make them grow. Theirs will be a painful doom.

To the start of Verse 78:

وَإِنَّ مِنْهُمْ لَفَرِيقًا يَلْوُونَ أَلْسِنَتَهُم بِالْكِتَابِ لِتَحْسَبُوهُ مِنَ الْكِتَابِ وَمَا هُوَ مِنَ الْكِتَابِ وَيَقُولُونَ هُوَ مِنْ عِندِ اللَّهِ وَمَا هُوَ مِنْ عِندِ اللَّهِ وَيَقُولُونَ عَلَى اللَّهِ الْكَذِبَ وَهُمْ يَعْلَمُونَ

And lo! there is a party of them who distort the Scripture with their tongues, that ye may think that what they say is from the Scripture, when it is not from the Scripture. And they say: It is from Allah, when it is not from Allah; and they speak a lie concerning Allah knowingly.

Pace yourself well for Allah t’ala loves the small acts often done

The bigger deeds are the contemplation and the bringing into action within your lives the precepts that accord with the revelation.

**Fallen Behind**
❤️ this group is all about falling behind and catching right back up.
❤️ it is about encouraging and celebrating that very human spirit of sacrifice that is all heart.

**Remember**
👊 The Quran is literally a Recitation, so recite it loudly, sonorously and with Tarteel. Let the Quran dictate the rhythm.
👊 The Quran is literally a collection of Ayats, a collection of the signs and proofs of God. Therefore give each Ayat its right, and pause between each. If you feel you could improve its recitation that do so before the next one.
👊 Before you start look ahead to where you want to be, set a reasonable day target, and make it happen. If you tire, then rest.
👊 Set a period towards the end of the week when you plan to catch up, remember to factor in Khaf on Fridays.
👊 Sakina the wind literally descends and is attracted by the sonorous Quran. May it envelop and visit each of our houses. Aameen.$txt$, true
from public.profiles p
where p.role = 'admin' and not exists (select 1 from public.posts where group_id = 'quran')
order by p.created_at limit 1;
