-- Lets an event have a picture (uploaded from the organiser's phone) and a link,
-- for example to a debate in Let's Debate. Safe to run more than once.
alter table public.events add column if not exists image text;
alter table public.events add column if not exists link text;
