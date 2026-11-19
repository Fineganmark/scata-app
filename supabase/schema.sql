-- Scata database. Paste this whole file into Supabase > SQL Editor and click Run.
-- Safe to run again: it only creates what is missing and replaces functions and policies.
-- It runs as one transaction: if anything fails, nothing changes.
-- To undo the 19 Nov 2026 allocation change, see supabase/rollback/2026-11-19-allocation-rollback.sql.

begin;

create extension if not exists pgcrypto;
-- Functions may refer to ones defined further down the file.
set check_function_bodies = off;

-- ---------- tables ----------

-- A hub is anything families travel to together: a school, a sports club, or a group a parent sets up.
create table if not exists public.hubs (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  kind text not null default 'school' check (kind in ('school', 'sport', 'other')),
  name text not null,
  address text not null,
  size text,
  open_time text not null default '08:30-09:30',
  close_time text not null default '14:15-15:00',
  days smallint[] not null default '{0,1,2,3,4}' check (days <@ '{0,1,2,3,4,5,6}' and cardinality(days) > 0),
  lat double precision,
  lng double precision,
  created_by uuid references auth.users on delete set null,
  created_at timestamptz not null default now()
);
-- A sports club group is one trip (a match, a blitz, a gala): the day it happens. Schools and other groups leave it empty and run every week.
alter table public.hubs add column if not exists trip_date date;
-- Who can join. 'approval': anyone with the code or link can ask, and an admin approves them (people the admin invited by email go straight in).
-- 'invite': invite only. Only the emails the admin invited can join; the code or link does nothing for anyone else.
-- 'open': anyone with the code or link joins straight away (how every group worked before).
-- Groups that existed before this setting keep working as they did ('open'). New groups default to 'approval'.
alter table public.hubs add column if not exists join_policy text not null default 'open';
alter table public.hubs alter column join_policy set default 'approval';
alter table public.hubs drop constraint if exists hubs_join_policy_check;
alter table public.hubs add constraint hubs_join_policy_check check (join_policy in ('open', 'approval', 'invite'));

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  first_name text not null,
  last_name text not null,
  plus boolean not null default false,
  created_at timestamptz not null default now()
);
-- Scata admins (the people who run Scata) see and manage everything from the admin panel.
-- Nobody can give this to themselves from the app; it is set in the SQL Editor (see README).
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- Who belongs to each hub. Admins (the school, the coach, or the parent who set it up) manage it.
create table if not exists public.hub_members (
  hub_id uuid not null references public.hubs on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (hub_id, user_id)
);
-- Someone who joins with the code or link asks to join: they wait as 'pending' until an admin approves them.
-- Everyone already in a group stays 'active'.
alter table public.hub_members add column if not exists status text not null default 'active' check (status in ('active', 'pending'));

create table if not exists public.children (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid not null references public.profiles on delete cascade,
  name text not null,
  dob date not null,
  created_at timestamptz not null default now()
);

-- One commute per parent per hub.
create table if not exists public.commutes (
  parent_id uuid not null references public.profiles on delete cascade,
  hub_id uuid not null references public.hubs on delete cascade,
  home text not null default '',
  lat double precision,
  lng double precision,
  mode text not null default 'car' check (mode in ('walk', 'bike', 'car', 'bus')),
  seats smallint not null default 3 check (seats between 1 and 4),
  drop_time text not null default '08:30-09:30',
  pick_time text not null default '13:15-14:15',
  accepted_terms boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (parent_id, hub_id)
);
-- Days a family can't do: Monday = 0. Drop-offs and pick-ups are kept apart, so "no Tuesday pick-ups" works.
alter table public.commutes add column if not exists cant_drop smallint[] not null default '{}';
alter table public.commutes add column if not exists cant_pick smallint[] not null default '{}';

-- Emails a hub admin has invited. People still join with the hub code or link.
create table if not exists public.hub_invites (
  id uuid primary key default gen_random_uuid(),
  hub_id uuid not null references public.hubs on delete cascade,
  email text not null,
  name text not null default '',
  created_at timestamptz not null default now(),
  unique (hub_id, email)
);
-- When the invite email last went out (set by the send-invites Edge Function).
alter table public.hub_invites add column if not exists sent_at timestamptz;

-- A commute group belongs to the parent who started it; others join by invitation. One per parent per hub.
create table if not exists public.commute_groups (
  id uuid primary key default gen_random_uuid(),
  hub_id uuid not null references public.hubs on delete cascade,
  owner_id uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  unique (hub_id, owner_id)
);
-- A family can be in one commute for drop-offs and one for pick-ups at each group, or one commute that covers both.
-- So a parent may start two commutes at the same group (one for each), and the old one-per-parent rule goes.
alter table public.commute_groups drop constraint if exists commute_groups_hub_id_owner_id_key;
alter table public.commute_groups add column if not exists covers text not null default 'both';
alter table public.commute_groups drop constraint if exists commute_groups_covers_check;
alter table public.commute_groups add constraint commute_groups_covers_check check (covers in ('both', 'drop', 'pick'));
-- How the commute travels, taken from the parent who started it. Car groups are limited by seats and 4 families;
-- walking, cycling and bus groups by an adult-to-child ratio. Existing commutes take the mode of the parent who started them.
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'commute_groups' and column_name = 'mode') then
    alter table public.commute_groups add column mode text not null default 'car';
    update public.commute_groups g set mode = c.mode from public.commutes c where c.parent_id = g.owner_id and c.hub_id = g.hub_id;
  end if;
end $$;
alter table public.commute_groups drop constraint if exists commute_groups_mode_check;
alter table public.commute_groups add constraint commute_groups_mode_check check (mode in ('walk', 'bike', 'car', 'bus'));
create index if not exists commute_groups_hub on public.commute_groups (hub_id, owner_id);

create table if not exists public.group_members (
  group_id uuid not null references public.commute_groups on delete cascade,
  parent_id uuid not null references public.profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  primary key (group_id, parent_id)
);
-- Both sides say yes before a family joins a commute. An invite from the parent who started it is the group's yes;
-- a family asking to join (from a suggestion or a friend link) is the family's yes. A suggestion from the group's
-- admin (the school or club) needs both. 'pending' rows wait until both are true, then become 'accepted'.
alter table public.group_members add column if not exists group_ok boolean not null default true;
alter table public.group_members add column if not exists family_ok boolean not null default false;
-- How the family came to the commute: 'invite' (picked from the nearby list or by name), 'friend' (a friend link),
-- 'suggested' (Scata suggested them), 'admin' (the school or club suggested them).
alter table public.group_members add column if not exists source text not null default 'invite';
alter table public.group_members drop constraint if exists group_members_source_check;
alter table public.group_members add constraint group_members_source_check check (source in ('invite', 'friend', 'suggested', 'admin'));
-- When the family was accepted. For 24 hours after a suggested family joins, the others can object.
alter table public.group_members add column if not exists joined_at timestamptz;

create table if not exists public.rota_slots (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.commute_groups on delete cascade,
  week_start date not null,
  day smallint not null check (day between 0 and 6),
  kind text not null check (kind in ('drop', 'pick')),
  parent_id uuid not null references public.profiles on delete cascade,
  confirmed boolean not null default false,
  unique (group_id, week_start, day, kind)
);
-- Walking, cycling and bus groups with more than 6 children need a second adult on each trip: lead 1 and lead 2.
alter table public.rota_slots add column if not exists lead smallint not null default 1;
alter table public.rota_slots drop constraint if exists rota_slots_lead_check;
alter table public.rota_slots add constraint rota_slots_lead_check check (lead in (1, 2));
alter table public.rota_slots drop constraint if exists rota_slots_group_id_week_start_day_kind_key;
create unique index if not exists rota_slots_one_per_lead on public.rota_slots (group_id, week_start, day, kind, lead);
create index if not exists rota_slots_parent on public.rota_slots (parent_id, week_start);

-- The fair-share tally. Each week a rota is built, every family in the commute is owed an equal share of its trips.
-- A family's balance is everything it was owed minus the trips it did. It carries over from week to week.
create table if not exists public.rota_shares (
  group_id uuid not null references public.commute_groups on delete cascade,
  week_start date not null,
  parent_id uuid not null references public.profiles on delete cascade,
  share numeric not null,
  primary key (group_id, week_start, parent_id)
);

create table if not exists public.swap_requests (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.commute_groups on delete cascade,
  give_slot uuid not null references public.rota_slots on delete cascade,
  take_slot uuid not null references public.rota_slots on delete cascade,
  requester uuid not null references public.profiles on delete cascade,
  responder uuid not null references public.profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.commute_groups on delete cascade,
  sender_id uuid not null references public.profiles on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table if not exists public.locations (
  group_id uuid not null references public.commute_groups on delete cascade,
  parent_id uuid not null references public.profiles on delete cascade,
  lat double precision not null,
  lng double precision not null,
  updated_at timestamptz not null default now(),
  primary key (group_id, parent_id)
);

create table if not exists public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles on delete cascade,
  kind text not null default 'info',
  body text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

-- A notification about one rota slot links to it, so it can be confirmed from the notification.
alter table public.notifications add column if not exists slot_id uuid references public.rota_slots on delete set null;
-- A notification about a group (a request to join, an approval) links to it.
alter table public.notifications add column if not exists hub_id uuid references public.hubs on delete cascade;
-- Set once the families have been warned that a slot coming up isn't confirmed.
alter table public.rota_slots add column if not exists reminded boolean not null default false;

create index if not exists notifications_user on public.notifications (user_id, created_at desc);
create index if not exists messages_group on public.messages (group_id, created_at);
create index if not exists hub_members_user on public.hub_members (user_id);
create index if not exists commutes_hub on public.commutes (hub_id);

-- ---------- helpers (run with owner rights so policies can use them without recursion) ----------

create or replace function public.in_hub(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from hub_members where hub_id = h and user_id = auth.uid() and status = 'active')
$$;

create or replace function public.is_hub_admin(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from hub_members where hub_id = h and user_id = auth.uid() and role = 'admin')
$$;

-- True when I administer a hub that this person belongs to.
create or replace function public.admin_of(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from hub_members a join hub_members b on b.hub_id = a.hub_id
                  where a.user_id = auth.uid() and a.role = 'admin' and b.user_id = other)
$$;

create or replace function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false)
$$;

-- The group's own admins, and Scata admins, can manage a group.
create or replace function public.can_manage_hub(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_hub_admin(h) or is_platform_admin()
$$;

create or replace function public.in_group(g uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from commute_groups where id = g and owner_id = auth.uid())
      or exists (select 1 from group_members where group_id = g and parent_id = auth.uid() and status = 'accepted')
$$;

create or replace function public.shares_group(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  with mine as (
    select id from commute_groups where owner_id = auth.uid()
    union select group_id from group_members where parent_id = auth.uid() and status in ('accepted', 'pending')
  )
  select exists (select 1 from commute_groups g join mine on mine.id = g.id where g.owner_id = other)
      or exists (select 1 from group_members m join mine on mine.id = m.group_id where m.parent_id = other)
$$;

create or replace function public.notify(target uuid, k text, msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, kind, body) values (target, k, msg)
$$;
revoke execute on function public.notify(uuid, text, text) from public, anon, authenticated;

create or replace function public.notify_slot(target uuid, k text, msg text, slot uuid) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, kind, body, slot_id) values (target, k, msg, slot)
$$;
revoke execute on function public.notify_slot(uuid, text, text, uuid) from public, anon, authenticated;

create or replace function public.notify_hub(target uuid, k text, msg text, hub uuid) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, kind, body, hub_id) values (target, k, msg, hub)
$$;
revoke execute on function public.notify_hub(uuid, text, text, uuid) from public, anon, authenticated;

-- True when the person signed in has a confirmed email that a group's admin invited.
create or replace function public.invited_to(h uuid) returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from hub_invites i join auth.users u on lower(u.email) = lower(i.email)
                  where i.hub_id = h and u.id = auth.uid() and u.email_confirmed_at is not null)
$$;

-- Tell everyone else in a commute (the parent who started it and the families who accepted).
create or replace function public.notify_group(g uuid, k text, msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, kind, body)
  select pid, k, msg from (select owner_id pid from commute_groups where id = g
                           union select parent_id from group_members where group_id = g and status = 'accepted') x
   where pid is distinct from auth.uid()
$$;
revoke execute on function public.notify_group(uuid, text, text) from public, anon, authenticated;

-- How a hub's trip is described in messages.
create or replace function public.trip_word(h uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when kind = 'school' then 'the school run to ' || name
              when kind = 'sport' and trip_date is not null then 'lifts to ' || name || ' on ' || to_char(trip_date, 'Dy DD Mon')
              else 'trips to ' || name end from hubs where id = h
$$;

-- How one rota slot is described: a drop-off or pick-up, or for a single trip the lift there or the lift home.
create or replace function public.slot_word(s public.rota_slots) returns text
language sql stable security definer set search_path = public as $$
  select case when h.kind = 'sport' and h.trip_date is not null
              then to_char(s.week_start + s.day, 'Dy DD Mon') || ' ' || case s.kind when 'drop' then 'lift there' else 'lift home' end
              else to_char(s.week_start + s.day, 'Dy DD Mon') || ' ' || case s.kind when 'drop' then 'drop-off' else 'pick-up' end end
    from commute_groups g join hubs h on h.id = g.hub_id where g.id = s.group_id
$$;

-- A single trip runs on its own day only. Moving it to a new date (the next match) clears the old rota so a fresh one is built.
create or replace function public.on_hub_trip() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'sport' and new.trip_date is not null then
    new.days := array[(extract(isodow from new.trip_date)::int - 1)]::smallint[];
  end if;
  if tg_op = 'UPDATE' and new.trip_date is distinct from old.trip_date then
    delete from rota_slots s using commute_groups g where s.group_id = g.id and g.hub_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists hub_trip on public.hubs;
create trigger hub_trip before insert or update on public.hubs for each row execute function public.on_hub_trip();

-- ---------- row level security ----------

alter table public.hubs enable row level security;
alter table public.profiles enable row level security;
alter table public.hub_members enable row level security;
alter table public.children enable row level security;
alter table public.commutes enable row level security;
alter table public.hub_invites enable row level security;
alter table public.commute_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.rota_slots enable row level security;
alter table public.swap_requests enable row level security;
alter table public.messages enable row level security;
alter table public.locations enable row level security;
alter table public.notifications enable row level security;
alter table public.rota_shares enable row level security;

drop policy if exists "read my hubs" on public.hubs;
create policy "read my hubs" on public.hubs for select to authenticated using (public.in_hub(id) or public.is_platform_admin());
drop policy if exists "admin edits hub" on public.hubs;
create policy "admin edits hub" on public.hubs for update to authenticated using (public.can_manage_hub(id)) with check (public.can_manage_hub(id));

drop policy if exists "read memberships" on public.hub_members;
create policy "read memberships" on public.hub_members for select to authenticated using (user_id = auth.uid() or public.can_manage_hub(hub_id));

drop policy if exists "read profiles" on public.profiles;
create policy "read profiles" on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_group(id) or public.admin_of(id) or public.is_platform_admin());
drop policy if exists "edit own profile" on public.profiles;
create policy "edit own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "own children" on public.children;
create policy "own children" on public.children for all to authenticated using (parent_id = auth.uid()) with check (parent_id = auth.uid());

drop policy if exists "own commute" on public.commutes;
create policy "own commute" on public.commutes for all to authenticated
  using (parent_id = auth.uid()) with check (parent_id = auth.uid() and public.in_hub(hub_id));

drop policy if exists "admin invites" on public.hub_invites;
create policy "admin invites" on public.hub_invites for all to authenticated
  using (public.can_manage_hub(hub_id)) with check (public.can_manage_hub(hub_id));

drop policy if exists "read my groups" on public.commute_groups;
create policy "read my groups" on public.commute_groups for select to authenticated
  using (owner_id = auth.uid() or exists (select 1 from public.group_members m where m.group_id = id and m.parent_id = auth.uid()));

drop policy if exists "read members" on public.group_members;
create policy "read members" on public.group_members for select to authenticated
  using (parent_id = auth.uid() or public.in_group(group_id));

drop policy if exists "read rota" on public.rota_slots;
create policy "read rota" on public.rota_slots for select to authenticated using (public.in_group(group_id));
drop policy if exists "read shares" on public.rota_shares;
create policy "read shares" on public.rota_shares for select to authenticated using (public.in_group(group_id));

drop policy if exists "read swaps" on public.swap_requests;
create policy "read swaps" on public.swap_requests for select to authenticated using (requester = auth.uid() or responder = auth.uid());

drop policy if exists "read messages" on public.messages;
create policy "read messages" on public.messages for select to authenticated using (public.in_group(group_id));
drop policy if exists "send messages" on public.messages;
create policy "send messages" on public.messages for insert to authenticated with check (sender_id = auth.uid() and public.in_group(group_id));

drop policy if exists "read locations" on public.locations;
create policy "read locations" on public.locations for select to authenticated using (public.in_group(group_id));
drop policy if exists "share own location" on public.locations;
create policy "share own location" on public.locations for all to authenticated
  using (parent_id = auth.uid()) with check (parent_id = auth.uid() and public.in_group(group_id));

drop policy if exists "own notifications" on public.notifications;
create policy "own notifications" on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists "mark notifications read" on public.notifications;
create policy "mark notifications read" on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Columns a person may change on their own rows.
revoke insert, update on public.profiles from authenticated;
grant update (first_name, last_name, plus) on public.profiles to authenticated;
revoke update on public.notifications from authenticated;
grant update (read) on public.notifications to authenticated;
revoke update on public.hubs from authenticated;
grant update (name, address, size, open_time, close_time, days, lat, lng, trip_date, join_policy) on public.hubs to authenticated;
revoke insert, update, delete on public.hub_members, public.commute_groups, public.group_members, public.rota_slots, public.swap_requests, public.rota_shares from authenticated;
revoke insert on public.hubs from authenticated;

-- ---------- actions (called from the app) ----------

drop function if exists public.nearby_parents();
drop function if exists public.invite_parent(uuid);

create or replace function public.set_profile(p_first text, p_last text)
returns public.profiles language plpgsql security definer set search_path = public as $$
declare p profiles;
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  if trim(coalesce(p_first, '')) = '' or trim(coalesce(p_last, '')) = '' then raise exception 'Enter your first name and surname'; end if;
  insert into profiles (id, first_name, last_name) values (auth.uid(), trim(p_first), trim(p_last))
    on conflict (id) do update set first_name = excluded.first_name, last_name = excluded.last_name
    returning * into p;
  return p;
end $$;

-- Anyone signed in can set up a hub and becomes its admin. p_commute adds the creator as a family sharing trips there too.
-- A sports club group is a single trip, so it needs p_trip_date.
drop function if exists public.create_hub(text, text, text, text, text, text, smallint[], double precision, double precision, boolean);
create or replace function public.create_hub(p_kind text, p_name text, p_address text, p_size text, p_open text, p_close text, p_days smallint[], p_lat double precision default null, p_lng double precision default null, p_commute boolean default false, p_trip_date date default null)
returns public.hubs language plpgsql security definer set search_path = public as $$
declare h hubs; c text;
begin
  if not exists (select 1 from profiles where id = auth.uid()) then raise exception 'Please add your name first'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'Give the group a name'; end if;
  if p_kind = 'sport' and p_trip_date is null then raise exception 'Pick the day of the trip'; end if;
  if (select count(*) from hub_members where user_id = auth.uid() and role = 'admin') >= 20 then raise exception 'You already manage 20 groups'; end if;
  loop
    c := 'sca' || lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from hubs where code = c);
  end loop;
  insert into hubs (code, kind, name, address, size, open_time, close_time, days, lat, lng, created_by, trip_date)
    values (c, p_kind, trim(p_name), trim(p_address), nullif(p_size, ''), p_open, p_close, coalesce(p_days, '{0,1,2,3,4}'), p_lat, p_lng, auth.uid(),
            case when p_kind = 'sport' then p_trip_date end) returning * into h;
  insert into hub_members (hub_id, user_id, role) values (h.id, auth.uid(), 'admin');
  if p_commute then insert into commutes (parent_id, hub_id, drop_time, pick_time) values (auth.uid(), h.id, h.open_time, h.close_time); end if;
  return h;
end $$;

-- Join a hub with its code. Also used by an admin of a hub to start sharing trips there themselves.
-- Someone the admin invited by email goes straight in, and so does anyone when the group is open. Otherwise they ask to join
-- and wait for an admin to approve them, unless the group is invite only, when they're turned away.
create or replace function public.join_hub(p_code text)
returns public.hubs language plpgsql security definer set search_path = public as $$
declare h hubs; me profiles; m hub_members; who text;
begin
  select * into me from profiles where id = auth.uid();
  if me.id is null then raise exception 'Please add your name first'; end if;
  select * into h from hubs where code = lower(trim(p_code));
  if h.id is null then raise exception 'That code doesn''t match a group. Check the code in your invite.'; end if;
  select * into m from hub_members where hub_id = h.id and user_id = auth.uid();
  if m.status = 'active' then
    insert into commutes (parent_id, hub_id, drop_time, pick_time) values (auth.uid(), h.id, h.open_time, h.close_time) on conflict do nothing;
    return h;
  end if;
  if m.status = 'pending' then return h; end if;
  who := me.first_name || ' ' || me.last_name;
  if invited_to(h.id) or h.join_policy = 'open' then
    insert into hub_members (hub_id, user_id, status) values (h.id, auth.uid(), 'active') on conflict do nothing;
    insert into commutes (parent_id, hub_id, drop_time, pick_time) values (auth.uid(), h.id, h.open_time, h.close_time) on conflict do nothing;
    perform notify_hub(a.user_id, 'school', who || ' joined ' || h.name || ' on Scata.', h.id)
       from hub_members a where a.hub_id = h.id and a.role = 'admin' and a.user_id <> auth.uid();
  elsif h.join_policy = 'invite' then
    raise exception '% is invite only. Ask its admin to invite the email address you signed in with.', h.name;
  else
    insert into hub_members (hub_id, user_id, status) values (h.id, auth.uid(), 'pending') on conflict do nothing;
    perform notify_hub(a.user_id, 'join', who || ' asked to join ' || h.name || '. Approve or decline them.', h.id)
       from hub_members a where a.hub_id = h.id and a.role = 'admin' and a.user_id <> auth.uid();
  end if;
  return h;
end $$;

-- Groups I've asked to join and am waiting to be approved for.
create or replace function public.my_join_requests()
returns table (id uuid, name text, kind text, asked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select h.id, h.name, h.kind, m.created_at from hub_members m join hubs h on h.id = m.hub_id
   where m.user_id = auth.uid() and m.status = 'pending' order by m.created_at
$$;

-- An admin lets someone in. They start sharing trips there like anyone who joined.
create or replace function public.approve_join(p_hub uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare h hubs;
begin
  if not can_manage_hub(p_hub) then raise exception 'Only the group''s admins can do that'; end if;
  update hub_members set status = 'active', created_at = now() where hub_id = p_hub and user_id = p_user and status = 'pending';
  if not found then raise exception 'That request is no longer open'; end if;
  select * into h from hubs where id = p_hub;
  insert into commutes (parent_id, hub_id, drop_time, pick_time) values (p_user, h.id, h.open_time, h.close_time) on conflict do nothing;
  perform notify_hub(p_user, 'joined', 'You’re in! ' || h.name || ' approved your request to join. Set up your family’s trips there.', h.id);
end $$;

-- An admin turns a request down. The person is told and can ask again later.
create or replace function public.decline_join(p_hub uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare h hubs;
begin
  if not can_manage_hub(p_hub) then raise exception 'Only the group''s admins can do that'; end if;
  delete from hub_members where hub_id = p_hub and user_id = p_user and status = 'pending';
  if not found then raise exception 'That request is no longer open'; end if;
  select * into h from hubs where id = p_hub;
  perform notify(p_user, 'school', 'Your request to join ' || h.name || ' wasn’t approved.');
end $$;

-- My hubs, with my role and whether I share trips there.
drop function if exists public.my_hubs();
create function public.my_hubs()
returns table (id uuid, code text, kind text, name text, address text, size text, open_time text, close_time text, days smallint[], lat double precision, lng double precision, role text, commuting boolean, trip_date date, join_policy text, requests bigint)
language sql stable security definer set search_path = public as $$
  select h.id, h.code, h.kind, h.name, h.address, h.size, h.open_time, h.close_time, h.days, h.lat, h.lng, m.role,
         exists (select 1 from commutes c where c.hub_id = h.id and c.parent_id = auth.uid()), h.trip_date, h.join_policy,
         case when m.role = 'admin' then (select count(*) from hub_members r where r.hub_id = h.id and r.status = 'pending') else 0 end
    from hub_members m join hubs h on h.id = m.hub_id
   where m.user_id = auth.uid() and m.status = 'active'
   order by m.created_at
$$;

-- Leave a hub: my commute, my places in its commute groups, and my future rota slots go.
create or replace function public.leave_hub(p_hub uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if is_hub_admin(p_hub) and not exists (select 1 from hub_members where hub_id = p_hub and role = 'admin' and user_id <> auth.uid())
     and exists (select 1 from hub_members where hub_id = p_hub and user_id <> auth.uid() and status = 'active') then
    raise exception 'You''re the only admin. Other families still use this group, so it needs an admin.';
  end if;
  -- Tell the families in the commutes this person was part of.
  perform notify_group(g.id, 'rota', (select first_name || ' ' || last_name from profiles where id = auth.uid()) || ' has left ' || (select name from hubs where id = p_hub)
           || case when g.owner_id = auth.uid() then '. The commute they started has closed.' else '. Their slots from today on are now free.' end)
     from commute_groups g
    where g.hub_id = p_hub and (g.owner_id = auth.uid() or exists (select 1 from group_members m where m.group_id = g.id and m.parent_id = auth.uid() and m.status = 'accepted'));
  delete from rota_slots s using commute_groups g where s.group_id = g.id and g.hub_id = p_hub and s.parent_id = auth.uid() and s.week_start + s.day >= current_date;
  delete from group_members m using commute_groups g where m.group_id = g.id and g.hub_id = p_hub and m.parent_id = auth.uid();
  delete from commute_groups where hub_id = p_hub and owner_id = auth.uid();
  delete from commutes where hub_id = p_hub and parent_id = auth.uid();
  delete from hub_members where hub_id = p_hub and user_id = auth.uid();
  delete from hubs where id = p_hub and not exists (select 1 from hub_members where hub_id = p_hub and status = 'active');
end $$;

-- An admin's numbers. invited, joined and in a group show how far a named list has got;
-- grouped and waiting count families who share trips with another family, and those still waiting for a match.
drop function if exists public.hub_stats(uuid);
create function public.hub_stats(p_hub uuid)
returns table (members bigint, commutes bigint, walk bigint, bike bigint, car bigint, bus bigint, groups bigint, invited bigint, grouped bigint, waiting bigint)
language sql stable security definer set search_path = public as $$
  select (select count(*) from hub_members where hub_id = p_hub and status = 'active'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'walk'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'bike'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'car'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'bus'),
         (select count(*) from commute_groups where hub_id = p_hub),
         (select count(*) from hub_invites where hub_id = p_hub),
         (select count(*) from commutes c where c.hub_id = p_hub and c.accepted_terms and has_match(p_hub, c.parent_id)),
         (select count(*) from commutes c where c.hub_id = p_hub and c.accepted_terms and not has_match(p_hub, c.parent_id))
   where can_manage_hub(p_hub)
$$;

-- ---------- allocation: distance, group size and matching ----------
-- Scata suggests small groups of families on the same route, and families confirm them. Distances are straight-line
-- estimates from the home location each family enters (no paid routing service), and nobody ever sees an address.

-- Straight-line distance in km between two points (null when either is unknown).
create or replace function public.km(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select case when a_lat is null or a_lng is null or b_lat is null or b_lng is null then null
              else 6371 * acos(least(1, greatest(-1, cos(radians(a_lat)) * cos(radians(b_lat)) * cos(radians(b_lng) - radians(a_lng)) + sin(radians(a_lat)) * sin(radians(b_lat))))) end
$$;

-- Compass bearing in degrees from one point to another.
create or replace function public.bearing(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable as $$
  select degrees(atan2(sin(radians(b_lng - a_lng)) * cos(radians(b_lat)),
                       cos(radians(a_lat)) * sin(radians(b_lat)) - sin(radians(a_lat)) * cos(radians(b_lat)) * cos(radians(b_lng - a_lng))))
$$;

-- Extra minutes for a driver at home a to collect a child at home b on the way to the hub h. Straight lines at 30 km/h.
create or replace function public.detour_min(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision, h_lat double precision, h_lng double precision)
returns int language sql immutable as $$
  select case when km(a_lat, a_lng, h_lat, h_lng) is null or km(a_lat, a_lng, b_lat, b_lng) is null then null
              else greatest(0, round((km(a_lat, a_lng, b_lat, b_lng) + km(b_lat, b_lng, h_lat, h_lng) - km(a_lat, a_lng, h_lat, h_lng)) / 30 * 60))::int end
$$;

-- "On the way": both homes head to the hub in the same direction (within 30 degrees, 45 when widened) and, for cars,
-- collecting the other child adds under 5 minutes (10 when widened). Homes within 1 km of the hub skip the direction check,
-- and without the hub's location on the map only distance counts.
create or replace function public.on_route(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision,
                                           h_lat double precision, h_lng double precision, p_mode text, p_wide boolean)
returns boolean language sql immutable as $$
  select h_lat is null or h_lng is null or (
         (km(a_lat, a_lng, h_lat, h_lng) < 1 or km(b_lat, b_lng, h_lat, h_lng) < 1
          or abs(mod((bearing(a_lat, a_lng, h_lat, h_lng) - bearing(b_lat, b_lng, h_lat, h_lng) + 540)::numeric, 360) - 180) <= case when p_wide then 45 else 30 end)
     and (p_mode <> 'car' or coalesce(detour_min(a_lat, a_lng, b_lat, b_lng, h_lat, h_lng), 0) <= case when p_wide then 10 else 5 end))
$$;

-- How far apart homes can be for a suggestion (km): cars 1.5 km, walking, cycling and bus 500 m.
-- Doubled for an invite-only list of under 40 families, and doubled again when a parent widens their search.
create or replace function public.match_km(p_hub uuid, p_mode text, p_wide boolean) returns double precision
language sql stable security definer set search_path = public as $$
  select (case when p_mode = 'car' then 1.5 else 0.5 end)
       * (case when h.join_policy = 'invite' and (select count(*) from hub_members m where m.hub_id = h.id and m.status = 'active') < 40 then 2 else 1 end)
       * (case when p_wide then 2 else 1 end)
    from hubs h where h.id = p_hub
$$;

-- The legs a commute covers.
create or replace function public.legs_of(p_covers text) returns text[] language sql immutable as $$
  select case p_covers when 'drop' then array['drop'] when 'pick' then array['pick'] else array['drop', 'pick'] end
$$;

-- The legs (drop, pick) a family at a hub isn't yet sharing in a commute they started or joined.
create or replace function public.free_legs(p_hub uuid, p_parent uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(l), '{}') from unnest(array['drop', 'pick']) l
   where not exists (select 1 from commute_groups g
                      where g.hub_id = p_hub and l = any(legs_of(g.covers))
                        and (g.owner_id = p_parent or exists (select 1 from group_members m where m.group_id = g.id and m.parent_id = p_parent and m.status = 'accepted')))
$$;

-- True when a family shares trips with at least one other family at a hub.
create or replace function public.has_match(p_hub uuid, p_parent uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from commute_groups g join group_members m on m.group_id = g.id and m.status = 'accepted'
                  where g.hub_id = p_hub and (g.owner_id = p_parent or m.parent_id = p_parent))
$$;

-- A family's children, counted for seats: at least one.
create or replace function public.kids_of(p_parent uuid) returns int
language sql stable security definer set search_path = public as $$
  select greatest(1, (select count(*)::int from children where parent_id = p_parent))
$$;

-- How full a commute is. Car: every family drives in turn, so all the children must fit in the smallest car
-- (a family's own children plus the seats it offers), and 4 families is the most. Walking, cycling and bus: up to
-- 12 children, with one adult for every 6 on each trip. p_add counts one more family, to check before they join.
create or replace function public.group_space(p_group uuid, p_add uuid default null)
returns table (mode text, families int, kids int, places int, spare int)
language sql stable security definer set search_path = public as $$
  with g as (select * from commute_groups where id = p_group),
       fam as (select owner_id pid from g union select parent_id from group_members where group_id = p_group and status = 'accepted'
               union select p_add where p_add is not null),
       t as (select count(*)::int n, sum(kids_of(fam.pid))::int k, min(kids_of(fam.pid) + coalesce(c.seats, 0))::int cap
               from fam left join commutes c on c.parent_id = fam.pid and c.hub_id = (select hub_id from g))
  select g.mode, t.n, t.k, case when g.mode = 'car' then t.cap else 12 end,
         case when g.mode = 'car' then case when t.n >= 4 then 0 else greatest(0, t.cap - t.k) end else greatest(0, 12 - t.k) end
    from t, g
$$;

-- Null when the commute (with p_add, if given) is within its limits, or the reason it isn't.
create or replace function public.group_fit(p_group uuid, p_add uuid default null) returns text
language plpgsql stable security definer set search_path = public as $$
declare s record;
begin
  select * into s from group_space(p_group, p_add);
  if s.mode = 'car' then
    if s.families > 4 then return 'This commute already has 4 families, the most a car group can have.'; end if;
    if s.kids > s.places then return 'There aren’t enough seats. Every car in the group has to fit all ' || s.kids || ' children.'; end if;
  elsif s.kids > 12 then return 'This group would have more than 12 children, the most a walking, cycling or bus group can have.';
  end if;
  return null;
end $$;

-- How a commute's trips are described: both, or only drop-offs or pick-ups (lifts there or home for a single trip).
create or replace function public.covers_word(g public.commute_groups) returns text
language sql stable security definer set search_path = public as $$
  select case g.covers when 'both' then ''
              when 'drop' then case when h.kind = 'sport' and h.trip_date is not null then ' (lift there only)' else ' (drop-offs only)' end
              else case when h.kind = 'sport' and h.trip_date is not null then ' (lift home only)' else ' (pick-ups only)' end end
    from hubs h where h.id = g.hub_id
$$;

-- Other families in the hub who have set up a commute. Shows a first name and rough distance only, never an address.
create or replace function public.nearby_parents(p_hub uuid)
returns table (parent_id uuid, first_name text, kids bigint, km numeric, mode text, status text)
language sql stable security definer set search_path = public as $$
  with me as (select c.* from commutes c where c.parent_id = auth.uid() and c.hub_id = p_hub)
  select p.id, p.first_name,
         (select count(*) from children ch where ch.parent_id = p.id),
         round(km(me.lat, me.lng, c.lat, c.lng)::numeric, 1),
         c.mode,
         coalesce((select m.status from group_members m join commute_groups g on g.id = m.group_id
                    where g.owner_id = auth.uid() and g.hub_id = p_hub and m.parent_id = p.id
                    order by m.status = 'accepted' desc, m.status = 'pending' desc limit 1), 'none')
    from me
    join commutes c on c.hub_id = me.hub_id and c.parent_id <> me.parent_id and c.accepted_terms
    join profiles p on p.id = c.parent_id
   order by 4 nulls last, 2
   limit 30
$$;

-- The commutes I started, joined, or have an open invitation or request for, in one hub.
drop function if exists public.my_groups(uuid);
create function public.my_groups(p_hub uuid)
returns table (id uuid, mine boolean, status text, covers text, mode text, family_ok boolean, group_ok boolean, source text)
language sql stable security definer set search_path = public as $$
  select id, mine, status, covers, mode, family_ok, group_ok, source from (
    select g.id, true mine, 'accepted' status, g.covers, g.mode, true family_ok, true group_ok, 'invite' source, g.created_at
      from commute_groups g where g.hub_id = p_hub and g.owner_id = auth.uid()
    union all
    select g.id, false, m.status, g.covers, g.mode, m.family_ok, m.group_ok, m.source, m.created_at
      from group_members m join commute_groups g on g.id = m.group_id where g.hub_id = p_hub and m.parent_id = auth.uid()
  ) x order by status = 'accepted' desc, mine desc, created_at
$$;

-- Start a commute. p_covers is 'both', 'drop' or 'pick', and those trips must not already be shared in another commute here.
create or replace function public.start_group(p_hub uuid, p_covers text default 'both')
returns public.commute_groups language plpgsql security definer set search_path = public as $$
declare g commute_groups; c commutes;
begin
  select * into c from commutes where parent_id = auth.uid() and hub_id = p_hub and accepted_terms;
  if c.parent_id is null then raise exception 'Set up your own commute first'; end if;
  if p_covers is null or p_covers not in ('both', 'drop', 'pick') then raise exception 'Choose drop-offs, pick-ups or both'; end if;
  if not legs_of(p_covers) <@ free_legs(p_hub, auth.uid()) then
    raise exception 'You already share some of these trips in another commute here. Start one for the other trips, or leave that commute first.';
  end if;
  insert into commute_groups (hub_id, owner_id, covers, mode) values (p_hub, auth.uid(), p_covers, c.mode) returning * into g;
  return g;
end $$;

-- Both sides have said yes. Checks the commute still has room and the family isn't sharing these trips elsewhere, then adds them.
create or replace function public.complete_join(p_group uuid, p_parent uuid) returns void
language plpgsql security definer set search_path = public as $$
declare g commute_groups; m group_members; why text; who text; owner text;
begin
  select * into g from commute_groups where id = p_group;
  select * into m from group_members where group_id = p_group and parent_id = p_parent;
  select first_name || ' ' || last_name into who from profiles where id = p_parent;
  select first_name into owner from profiles where id = g.owner_id;
  if not legs_of(g.covers) <@ free_legs(g.hub_id, p_parent) then
    raise exception '%', case when p_parent = auth.uid() then 'You already share these trips in another commute here. Leave it first.'
                              else who || ' already shares these trips in another commute here.' end;
  end if;
  why := group_fit(p_group, p_parent);
  if why is not null then raise exception '%', why; end if;
  update group_members set status = 'accepted', family_ok = true, group_ok = true, joined_at = now() where group_id = p_group and parent_id = p_parent;
  -- Their other open invitations and requests for the same trips here lapse.
  delete from group_members x using commute_groups o
   where x.group_id = o.id and o.hub_id = g.hub_id and x.parent_id = p_parent and x.status = 'pending' and x.group_id <> p_group
     and legs_of(o.covers) && legs_of(g.covers);
  if p_parent <> auth.uid() then
    perform notify(p_parent, 'invite', 'You’re in! You now share ' || trip_word(g.hub_id) || covers_word(g) || ' with ' || owner || '’s commute.');
  end if;
  insert into notifications (user_id, kind, body)
  select pid, 'invite', who || ' joined ' || case when pid = g.owner_id then 'your' else owner || '’s' end || ' commute for ' || trip_word(g.hub_id) || '.'
         || case when m.source in ('suggested', 'admin') and pid <> g.owner_id
                 then case when m.source = 'admin' then ' ' || (select name from hubs where id = g.hub_id) else ' Scata' end
                      || ' suggested them. If you have a concern, you can object from My commute in the next 24 hours.' else '' end
    from (select g.owner_id pid union select parent_id from group_members where group_id = p_group and status = 'accepted') x
   where pid <> p_parent and pid is distinct from auth.uid();
end $$;
revoke execute on function public.complete_join(uuid, uuid) from public, anon, authenticated;

-- The parent who started a commute invites a family (from the nearby list, a name search, or Scata's suggestions).
-- The family joins once they accept. A family that already asked to join goes straight in.
create or replace function public.invite_to_group(p_group uuid, p_target uuid, p_source text default 'invite')
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; m group_members; me profiles; why text;
begin
  select * into g from commute_groups where id = p_group;
  if g.id is null or g.owner_id <> auth.uid() then raise exception 'Only the parent who started the commute can invite families'; end if;
  if p_target = auth.uid() then raise exception 'That’s you'; end if;
  if p_source not in ('invite', 'suggested') then p_source := 'invite'; end if;
  if not exists (select 1 from commutes where parent_id = p_target and hub_id = g.hub_id and accepted_terms) then raise exception 'That family isn''t available to invite'; end if;
  select * into m from group_members where group_id = p_group and parent_id = p_target;
  if m.status = 'accepted' then return; end if;
  if not legs_of(g.covers) <@ free_legs(g.hub_id, p_target) then raise exception 'That family already shares these trips in another commute.'; end if;
  why := group_fit(p_group, p_target);
  if why is not null then raise exception '%', why; end if;
  if m.status = 'pending' and m.family_ok then
    update group_members set group_ok = true where group_id = p_group and parent_id = p_target;
    perform complete_join(p_group, p_target);
    return;
  end if;
  select * into me from profiles where id = auth.uid();
  insert into group_members (group_id, parent_id, status, group_ok, family_ok, source) values (p_group, p_target, 'pending', true, false, p_source)
    on conflict (group_id, parent_id) do update set status = 'pending', group_ok = true, family_ok = false, source = excluded.source, created_at = now();
  perform notify(p_target, 'invite', me.first_name || ' ' || me.last_name || ' invited you to share ' || trip_word(g.hub_id) || covers_word(g) || '.');
end $$;

-- Kept so the older app keeps working: invites into the commute I started here, starting one if I haven't.
create or replace function public.invite_parent(p_hub uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare gid uuid; fl text[];
begin
  select id into gid from commute_groups where hub_id = p_hub and owner_id = auth.uid() order by created_at limit 1;
  if gid is null then
    fl := free_legs(p_hub, auth.uid());
    gid := (start_group(p_hub, case when fl @> array['drop', 'pick'] then 'both' when fl = array['drop'] then 'drop' when fl = array['pick'] then 'pick' else 'both' end)).id;
  end if;
  perform invite_to_group(gid, p_target, 'invite');
end $$;

-- A family answers an invitation or a suggestion. If the commute has already said yes, they're in.
create or replace function public.respond_invite(p_group uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; m group_members; me profiles;
begin
  select * into me from profiles where id = auth.uid();
  select * into m from group_members where group_id = p_group and parent_id = auth.uid() and status = 'pending';
  if m.group_id is null then raise exception 'There is no open invitation to answer'; end if;
  select * into g from commute_groups where id = p_group;
  if not p_accept then
    update group_members set status = 'declined' where group_id = p_group and parent_id = auth.uid();
    if m.group_ok then perform notify(g.owner_id, 'invite', me.first_name || ' declined your invitation to share ' || trip_word(g.hub_id) || '.'); end if;
    return;
  end if;
  update group_members set family_ok = true where group_id = p_group and parent_id = auth.uid();
  if m.group_ok then
    perform complete_join(p_group, auth.uid());
  else
    perform notify(g.owner_id, 'invite', me.first_name || ' ' || me.last_name || ' would like to join your commute for ' || trip_word(g.hub_id) || '. Approve or decline them in My commute.');
  end if;
end $$;

-- A family asks to join a commute Scata suggested, or one a friend sent them a link to. The parent who started it approves.
create or replace function public.ask_to_join(p_group uuid, p_source text default 'suggested')
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; m group_members; me profiles; why text;
begin
  select * into g from commute_groups where id = p_group;
  if g.id is null then raise exception 'That commute no longer exists'; end if;
  if g.owner_id = auth.uid() then return; end if;
  if p_source not in ('suggested', 'friend') then p_source := 'suggested'; end if;
  if not exists (select 1 from commutes where parent_id = auth.uid() and hub_id = g.hub_id and accepted_terms) then raise exception 'Set up your own commute first'; end if;
  select * into m from group_members where group_id = p_group and parent_id = auth.uid();
  if m.status = 'accepted' then return; end if;
  if m.status = 'declined' then raise exception 'That commute can’t take you. Try another suggestion.'; end if;
  if not legs_of(g.covers) <@ free_legs(g.hub_id, auth.uid()) then raise exception 'You already share these trips in another commute here. Leave it first.'; end if;
  why := group_fit(p_group, auth.uid());
  if why is not null then raise exception '%', why; end if;
  if m.status = 'pending' and m.group_ok then
    update group_members set family_ok = true where group_id = p_group and parent_id = auth.uid();
    perform complete_join(p_group, auth.uid());
    return;
  end if;
  select * into me from profiles where id = auth.uid();
  insert into group_members (group_id, parent_id, status, group_ok, family_ok, source) values (p_group, auth.uid(), 'pending', false, true, p_source)
    on conflict (group_id, parent_id) do update set family_ok = true;
  perform notify(g.owner_id, 'invite', me.first_name || ' ' || me.last_name || ' asked to join your commute for ' || trip_word(g.hub_id)
    || case when p_source = 'friend' then ' with your friend link' else '' end || '. Approve or decline them in My commute.');
end $$;

-- The parent who started a commute answers a family's request, or the school's or club's suggestion.
create or replace function public.respond_request(p_group uuid, p_parent uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; m group_members; me profiles;
begin
  select * into g from commute_groups where id = p_group;
  if g.id is null or g.owner_id <> auth.uid() then raise exception 'Only the parent who started the commute can answer'; end if;
  select * into m from group_members where group_id = p_group and parent_id = p_parent and status = 'pending';
  if m.group_id is null then raise exception 'That request is no longer open'; end if;
  select * into me from profiles where id = auth.uid();
  if not p_accept then
    update group_members set status = 'declined' where group_id = p_group and parent_id = p_parent;
    if m.family_ok then perform notify(p_parent, 'invite', me.first_name || '’s commute can’t take you this time. Scata will keep looking for a match.'); end if;
    return;
  end if;
  update group_members set group_ok = true where group_id = p_group and parent_id = p_parent;
  if m.family_ok then
    perform complete_join(p_group, p_parent);
  else
    perform notify(p_parent, 'invite', me.first_name || ' ' || me.last_name || ' would like you to share ' || trip_word(g.hub_id) || covers_word(g) || '. Accept or decline in My commute.');
  end if;
end $$;

-- For 24 hours after a family Scata or the school suggested joins, anyone else in the commute can object, which takes them out.
create or replace function public.object_member(p_group uuid, p_parent uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; m group_members; me profiles; who text;
begin
  select * into g from commute_groups where id = p_group;
  if not in_group(p_group) or p_parent = auth.uid() then raise exception 'You can’t do that'; end if;
  select * into m from group_members where group_id = p_group and parent_id = p_parent and status = 'accepted';
  if m.group_id is null or m.source not in ('suggested', 'admin') or m.joined_at < now() - interval '24 hours' then
    raise exception 'You can only object in the first 24 hours after a suggested family joins. Talk to the parent who started the commute.';
  end if;
  select * into me from profiles where id = auth.uid();
  select first_name || ' ' || last_name into who from profiles where id = p_parent;
  update group_members set status = 'declined' where group_id = p_group and parent_id = p_parent;
  delete from rota_slots where group_id = p_group and parent_id = p_parent and week_start + day >= current_date;
  perform notify(p_parent, 'invite', 'A family in the commute you joined for ' || trip_word(g.hub_id) || ' raised a concern, so you’ve been taken out of it. Scata will keep looking for a match.');
  insert into notifications (user_id, kind, body)
  select pid, 'rota', me.first_name || ' objected to ' || who || ' joining, so they’ve been taken out of the commute. Reset the rota if any of their trips are coming up.'
    from (select g.owner_id pid union select parent_id from group_members where group_id = p_group and status = 'accepted') x
   where pid <> auth.uid();
end $$;

-- A school or club admin suggests a family for a commute. Both the family and the parent who started it still say yes.
create or replace function public.admin_suggest(p_group uuid, p_parent uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; h hubs; m group_members; why text; who text; owner text; own boolean;
begin
  select * into g from commute_groups where id = p_group;
  if g.id is null or not can_manage_hub(g.hub_id) then raise exception 'Only the group''s admins can do that'; end if;
  select * into h from hubs where id = g.hub_id;
  if p_parent = g.owner_id then raise exception 'They started this commute'; end if;
  if not exists (select 1 from commutes where parent_id = p_parent and hub_id = g.hub_id and accepted_terms) then raise exception 'That family hasn’t set up their trips yet'; end if;
  select * into m from group_members where group_id = p_group and parent_id = p_parent;
  if m.status = 'accepted' then raise exception 'They’re already in this commute'; end if;
  if m.status = 'pending' then raise exception 'They already have an open invitation or request for this commute'; end if;
  if not legs_of(g.covers) <@ free_legs(g.hub_id, p_parent) then raise exception 'That family already shares these trips in another commute.'; end if;
  why := group_fit(p_group, p_parent);
  if why is not null then raise exception '%', why; end if;
  own := g.owner_id = auth.uid();
  select first_name || ' ' || last_name into who from profiles where id = p_parent;
  select first_name into owner from profiles where id = g.owner_id;
  insert into group_members (group_id, parent_id, status, group_ok, family_ok, source) values (p_group, p_parent, 'pending', own, false, 'admin')
    on conflict (group_id, parent_id) do update set status = 'pending', group_ok = own, family_ok = false, source = 'admin', created_at = now();
  if not own then
    perform notify_hub(g.owner_id, 'invite', h.name || ' suggested ' || who || ' for your commute. Approve or decline them in My commute.', h.id);
  end if;
  perform notify_hub(p_parent, 'invite', h.name || ' suggested you share ' || trip_word(h.id) || covers_word(g) || ' with ' || owner || '’s commute. Accept or decline in My commute.', h.id);
end $$;

-- Families Scata suggests to fill a commute's spare places: same travel mode, close to someone already in it,
-- on the same route, free for these trips, and within the size limits. First name, children and rough distance only.
create or replace function public.suggest_families(p_group uuid, p_wide boolean default false)
returns table (parent_id uuid, first_name text, kids int, km numeric, detour_min int)
language sql stable security definer set search_path = public as $$
  with g as (select * from commute_groups where id = p_group and in_group(p_group)),
       h as (select hubs.* from hubs join g on g.hub_id = hubs.id),
       o as (select c.* from commutes c join g on c.parent_id = g.owner_id and c.hub_id = g.hub_id),
       homes as (select c.lat, c.lng from commutes c join g on c.hub_id = g.hub_id
                  where c.lat is not null and (c.parent_id = g.owner_id or c.parent_id in (select m.parent_id from group_members m where m.group_id = p_group and m.status = 'accepted'))),
       cand as (select c.*, (select min(km(x.lat, x.lng, c.lat, c.lng)) from homes x) d
                  from commutes c join g on c.hub_id = g.hub_id
                 where c.accepted_terms and c.mode = g.mode and c.lat is not null and c.parent_id <> g.owner_id
                   and not exists (select 1 from group_members m where m.group_id = p_group and m.parent_id = c.parent_id))
  select cand.parent_id, p.first_name, kids_of(cand.parent_id), round(cand.d::numeric, 1), detour_min(o.lat, o.lng, cand.lat, cand.lng, h.lat, h.lng)
    from cand join profiles p on p.id = cand.parent_id, g, h, o
   where cand.d <= match_km(g.hub_id, g.mode, p_wide)
     and on_route(o.lat, o.lng, cand.lat, cand.lng, h.lat, h.lng, g.mode, p_wide)
     and legs_of(g.covers) <@ free_legs(g.hub_id, cand.parent_id)
     and group_fit(p_group, cand.parent_id) is null
   order by cand.d
   limit 10
$$;

-- Commutes with room that Scata suggests to a family looking for one (for trips they don't share yet).
create or replace function public.suggest_groups(p_hub uuid, p_wide boolean default false)
returns table (id uuid, owner_first text, covers text, families int, kids int, spare int, km numeric, detour_min int, status text)
language sql stable security definer set search_path = public as $$
  with me as (select c.* from commutes c where c.parent_id = auth.uid() and c.hub_id = p_hub and c.accepted_terms and c.lat is not null),
       h as (select * from hubs where id = p_hub),
       gs as (select g.*, (select min(km(x.lat, x.lng, me.lat, me.lng)) from commutes x
                            where x.hub_id = g.hub_id and x.lat is not null
                              and (x.parent_id = g.owner_id or x.parent_id in (select m.parent_id from group_members m where m.group_id = g.id and m.status = 'accepted'))) d,
                     (select m.status from group_members m where m.group_id = g.id and m.parent_id = auth.uid()) mine
                from commute_groups g, me where g.hub_id = p_hub and g.owner_id <> auth.uid() and g.mode = me.mode)
  select gs.id, p.first_name, gs.covers, s.families, s.kids, s.spare, round(gs.d::numeric, 1), detour_min(o.lat, o.lng, me.lat, me.lng, h.lat, h.lng), coalesce(gs.mine, 'none')
    from gs join profiles p on p.id = gs.owner_id join commutes o on o.parent_id = gs.owner_id and o.hub_id = gs.hub_id
         cross join me cross join h cross join lateral group_space(gs.id) s
   where coalesce(gs.mine, 'none') in ('none', 'pending')
     and gs.d <= match_km(p_hub, gs.mode, p_wide)
     and on_route(o.lat, o.lng, me.lat, me.lng, h.lat, h.lng, gs.mode, p_wide)
     and legs_of(gs.covers) <@ free_legs(p_hub, auth.uid())
     and group_fit(gs.id, auth.uid()) is null
   order by gs.d
   limit 5
$$;

-- Find families you already know at the hub by name, to invite them whatever the distance.
-- detour_min is how much longer your own drive would be to collect them, so the app can warn about a long one.
create or replace function public.search_families(p_hub uuid, p_q text, p_group uuid default null)
returns table (parent_id uuid, first_name text, last_name text, kids int, km numeric, detour_min int, mode text, status text, busy boolean)
language sql stable security definer set search_path = public as $$
  with me as (select c.* from commutes c where c.parent_id = auth.uid() and c.hub_id = p_hub),
       h as (select * from hubs where id = p_hub),
       g as (select * from commute_groups where id = p_group and hub_id = p_hub)
  select c.parent_id, p.first_name, p.last_name, kids_of(c.parent_id), round(km(me.lat, me.lng, c.lat, c.lng)::numeric, 1),
         detour_min(me.lat, me.lng, c.lat, c.lng, h.lat, h.lng), c.mode,
         coalesce((select m.status from group_members m join g on g.id = m.group_id where m.parent_id = c.parent_id), case when c.parent_id = (select owner_id from g) then 'accepted' else 'none' end),
         exists (select 1 from g where not legs_of(g.covers) <@ free_legs(p_hub, c.parent_id)
                   and not exists (select 1 from group_members m where m.group_id = g.id and m.parent_id = c.parent_id and m.status = 'accepted'))
    from me cross join h
    join commutes c on c.hub_id = p_hub and c.parent_id <> auth.uid() and c.accepted_terms
    join profiles p on p.id = c.parent_id
   where in_hub(p_hub) and length(trim(coalesce(p_q, ''))) >= 2
     and position(lower(trim(p_q)) in lower(p.first_name || ' ' || p.last_name)) > 0
   order by p.first_name, p.last_name
   limit 20
$$;

-- Families at a hub who have set up their trips but don't share them with anyone yet: the waiting list, for admins.
create or replace function public.hub_waiting(p_hub uuid)
returns table (parent_id uuid, name text, mode text, kids int, free text[], since timestamptz)
language sql stable security definer set search_path = public as $$
  select c.parent_id, p.first_name || ' ' || p.last_name, c.mode, kids_of(c.parent_id), free_legs(p_hub, c.parent_id), c.updated_at
    from commutes c join profiles p on p.id = c.parent_id
   where c.hub_id = p_hub and c.accepted_terms and can_manage_hub(p_hub) and not has_match(p_hub, c.parent_id)
   order by c.updated_at
$$;

-- When a family finishes setting up its trips (or moves home or changes mode), tell the families nearby who are still
-- waiting for a match, and the parents whose commutes have room on that route.
create or replace function public.on_commute_ready() returns trigger
language plpgsql security definer set search_path = public as $$
declare h hubs; lim double precision;
begin
  if not new.accepted_terms or new.lat is null then return new; end if;
  if tg_op = 'UPDATE' and old.accepted_terms and old.lat is not distinct from new.lat and old.lng is not distinct from new.lng and old.mode = new.mode then return new; end if;
  select * into h from hubs where id = new.hub_id;
  lim := match_km(new.hub_id, new.mode, false);
  insert into notifications (user_id, kind, body, hub_id)
  select c.parent_id, 'match', 'A family on your route just joined ' || h.name || '. Open My commute to see if you can share trips.', h.id
    from commutes c
   where c.hub_id = new.hub_id and c.parent_id <> new.parent_id and c.accepted_terms and c.mode = new.mode
     and km(c.lat, c.lng, new.lat, new.lng) <= lim and on_route(c.lat, c.lng, new.lat, new.lng, h.lat, h.lng, new.mode, false)
     and not has_match(new.hub_id, c.parent_id)
   limit 20;
  insert into notifications (user_id, kind, body, hub_id)
  select distinct on (g.owner_id) g.owner_id, 'match', 'A family ' || round(km(o.lat, o.lng, new.lat, new.lng)::numeric, 1) || ' km from you just joined ' || h.name
         || '. Your commute has room: see Fill your spare seats in My commute.', h.id
    from commute_groups g join commutes o on o.parent_id = g.owner_id and o.hub_id = g.hub_id
   where g.hub_id = new.hub_id and g.owner_id <> new.parent_id and g.mode = new.mode and has_match(g.hub_id, g.owner_id)
     and km(o.lat, o.lng, new.lat, new.lng) <= lim and on_route(o.lat, o.lng, new.lat, new.lng, h.lat, h.lng, g.mode, false)
     and legs_of(g.covers) <@ free_legs(g.hub_id, new.parent_id) and group_fit(g.id, new.parent_id) is null
   limit 20;
  return new;
end $$;
drop trigger if exists commute_ready on public.commutes;
create trigger commute_ready after insert or update on public.commutes for each row execute function public.on_commute_ready();

-- Leaving a commute frees your slots from today on, and tells the others so the rota can be sorted out.
create or replace function public.leave_group(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me profiles; g commute_groups;
begin
  select * into me from profiles where id = auth.uid();
  select * into g from commute_groups where id = p_group;
  if not exists (select 1 from group_members where group_id = p_group and parent_id = auth.uid() and status = 'accepted') then
    delete from group_members where group_id = p_group and parent_id = auth.uid();
    return;
  end if;
  delete from group_members where group_id = p_group and parent_id = auth.uid();
  delete from rota_slots where group_id = p_group and parent_id = auth.uid() and week_start + day >= current_date;
  perform notify_group(p_group, 'rota', me.first_name || ' ' || me.last_name || ' has left your commute for ' || trip_word(g.hub_id)
    || '. Their slots from today on are now free, so ' || (select first_name from profiles where id = g.owner_id) || ' can reset the rota. There’s room for another family: see Fill your spare seats.');
end $$;

-- Builds one week's rota on the hub's days for the trips the commute covers. Keeps an existing week as it is.
-- Fair over time: every family in the commute is owed an equal share of the week's trips, and each trip goes to whoever
-- owes most (owed minus done, carried over from earlier weeks). Nobody gets a day they said they can't do, or two trips
-- at the same time in different commutes, unless there's no one else. Walking, cycling and bus groups with more than
-- 6 children get two adults on each trip. A single trip (a sports club group with a date) only has a rota in its own week.
create or replace function public.build_rota(p_group uuid, p_week date)
returns setof public.rota_slots language plpgsql security definer set search_path = public as $$
declare g commute_groups; members uuid[]; bal numeric[]; cnt int[]; lastday int[]; n int; d int; i int; l int; best int; pass int;
        k text; wk date := date_trunc('week', p_week)::date; ds smallint[]; td date; legs text[]; leads int; total int; owed numeric; done int;
        score numeric; best_score numeric; cd smallint[]; cp smallint[]; taken uuid[];
begin
  if not in_group(p_group) then raise exception 'You''re not in this commute'; end if;
  select * into g from commute_groups where id = p_group;
  select h.trip_date into td from hubs h where h.id = g.hub_id and h.kind = 'sport';
  if td is not null and wk <> date_trunc('week', td)::date then return; end if;
  if not exists (select 1 from rota_slots where group_id = p_group and week_start = wk) then
    select array_agg(pid order by pid) into members from (
      select g.owner_id pid union select parent_id from group_members where group_id = p_group and status = 'accepted') x;
    n := array_length(members, 1);
    if n < 2 then raise exception 'Invite at least one family who accepts before building a rota'; end if;
    select array_agg(x order by x) into ds from (select distinct unnest(h.days) x from hubs h where h.id = g.hub_id) y;
    legs := legs_of(g.covers);
    leads := case when g.mode <> 'car' and (select sum(kids_of(m)) from unnest(members) m) > 6 then 2 else 1 end;
    total := coalesce(array_length(ds, 1), 0) * array_length(legs, 1) * leads;
    -- Each family's balance so far: what it was owed minus what it did. Weeks built before the tally existed count an equal share.
    bal := array[]::numeric[]; cnt := array[]::int[]; lastday := array[]::int[];
    for i in 1..n loop
      select coalesce(sum(share), 0) into owed from rota_shares where group_id = p_group and parent_id = members[i] and week_start < wk;
      owed := owed + coalesce((select sum(c)::numeric / n from (select count(*) c from rota_slots s where s.group_id = p_group and s.week_start < wk
                                 and not exists (select 1 from rota_shares r where r.group_id = p_group and r.week_start = s.week_start) group by s.week_start) y), 0);
      select count(*) into done from rota_slots where group_id = p_group and parent_id = members[i] and week_start < wk;
      bal := bal || (owed - done + total::numeric / n); cnt := cnt || 0; lastday := lastday || -1;
    end loop;
    foreach d in array ds loop
      foreach k in array legs loop
        taken := array[]::uuid[];
        for l in 1..leads loop
          best := null;
          -- Pass 1 respects days people can't do and trips in other commutes. Pass 2 drops the "can't do" days, pass 3 the clashes.
          for pass in 1..3 loop
            for i in 1..n loop
              continue when members[i] = any(taken);
              if pass < 3 and exists (select 1 from rota_slots s where s.parent_id = members[i] and s.group_id <> p_group and s.week_start + s.day = wk + d and s.kind = k) then continue; end if;
              if pass < 2 then
                select c.cant_drop, c.cant_pick into cd, cp from commutes c where c.parent_id = members[i] and c.hub_id = g.hub_id;
                if d = any(coalesce(case when k = 'drop' then cd else cp end, '{}')) then continue; end if;
              end if;
              -- Owes most first. Then avoid both trips on one day, then a different order each week.
              score := (bal[i] - cnt[i]) * 1000 - case when lastday[i] = d then 500 else 0 end
                       + ('x' || substr(md5(members[i]::text || wk::text || d::text || k), 1, 6))::bit(24)::int / 16777216.0;
              if best is null or score > best_score then best := i; best_score := score; end if;
            end loop;
            exit when best is not null;
          end loop;
          insert into rota_slots (group_id, week_start, day, kind, lead, parent_id) values (p_group, wk, d, k, l, members[best]);
          taken := taken || members[best]; cnt[best] := cnt[best] + 1; lastday[best] := d;
        end loop;
      end loop;
    end loop;
    insert into rota_shares (group_id, week_start, parent_id, share)
    select p_group, wk, m, total::numeric / n from unnest(members) m on conflict do nothing;
  end if;
  return query select * from rota_slots where group_id = p_group and week_start = wk order by day, kind, lead;
end $$;

-- Rebuild a week after someone joins or leaves. Only the parent who started the commute can do it.
create or replace function public.rebuild_rota(p_group uuid, p_week date)
returns setof public.rota_slots language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from commute_groups where id = p_group and owner_id = auth.uid()) then raise exception 'Only the parent who started the commute can reset the rota'; end if;
  if date_trunc('week', p_week)::date + 6 < current_date then raise exception 'That week has already happened'; end if;
  delete from rota_slots where group_id = p_group and week_start = date_trunc('week', p_week)::date;
  delete from rota_shares where group_id = p_group and week_start = date_trunc('week', p_week)::date;
  perform notify_group(p_group, 'rota', (select first_name from profiles where id = auth.uid()) || ' reset the rota for the week of '
    || to_char(date_trunc('week', p_week)::date, 'DD Mon') || '. Check your slots and confirm them again.');
  return query select * from build_rota(p_group, p_week);
end $$;

-- Each family's fair-share balance in a commute up to the end of a week: trips owed minus trips done.
-- Positive means they're due to do more; negative means they've done more than their share.
create or replace function public.rota_tally(p_group uuid, p_week date)
returns table (parent_id uuid, owed numeric, done bigint)
language sql stable security definer set search_path = public as $$
  with fam as (select owner_id pid from commute_groups where id = p_group union select parent_id from group_members where group_id = p_group and status = 'accepted'),
       wk as (select date_trunc('week', p_week)::date w),
       legacy as (select coalesce(sum(c), 0)::numeric / greatest(1, (select count(*) from fam)) e
                    from (select count(*) c from rota_slots s, wk where s.group_id = p_group and s.week_start <= wk.w
                            and not exists (select 1 from rota_shares r where r.group_id = p_group and r.week_start = s.week_start) group by s.week_start) y)
  select fam.pid,
         round(coalesce((select sum(share) from rota_shares r, wk where r.group_id = p_group and r.parent_id = fam.pid and r.week_start <= wk.w), 0) + (select e from legacy), 1),
         (select count(*) from rota_slots s, wk where s.group_id = p_group and s.parent_id = fam.pid and s.week_start <= wk.w)
    from fam where in_group(p_group)
$$;

create or replace function public.confirm_slot(p_slot uuid)
returns void language sql security definer set search_path = public as $$
  update rota_slots set confirmed = true where id = p_slot and parent_id = auth.uid() and week_start + day >= current_date;
$$;

create or replace function public.request_swap(p_give uuid, p_take uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a rota_slots; b rota_slots; me profiles;
begin
  select * into a from rota_slots where id = p_give;
  select * into b from rota_slots where id = p_take;
  if a.parent_id is distinct from auth.uid() then raise exception 'You can only swap your own slot'; end if;
  if b.id is null or b.group_id <> a.group_id or b.parent_id = auth.uid() then raise exception 'Pick a slot another parent is doing'; end if;
  if a.week_start + a.day < current_date or b.week_start + b.day < current_date then raise exception 'That slot has already happened'; end if;
  -- Nobody ends up with two trips at the same time (two adults on one walk, or trips in two commutes).
  if exists (select 1 from rota_slots s where s.parent_id = auth.uid() and s.id <> a.id and s.week_start + s.day = b.week_start + b.day and s.kind = b.kind) then
    raise exception 'You already have a trip at that time'; end if;
  if exists (select 1 from rota_slots s where s.parent_id = b.parent_id and s.id <> b.id and s.week_start + s.day = a.week_start + a.day and s.kind = a.kind) then
    raise exception 'They already have a trip at that time'; end if;
  select * into me from profiles where id = auth.uid();
  insert into swap_requests (group_id, give_slot, take_slot, requester, responder) values (a.group_id, a.id, b.id, auth.uid(), b.parent_id);
  perform notify(b.parent_id, 'swap', me.first_name || ' asked to swap: you’d take their ' || slot_word(a) || ' and they’d take your ' || slot_word(b) || '.');
end $$;

create or replace function public.respond_swap(p_swap uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r swap_requests; me profiles;
begin
  select * into r from swap_requests where id = p_swap and responder = auth.uid() and status = 'pending';
  if r.id is null then raise exception 'That swap request is no longer open'; end if;
  if p_accept and exists (select 1 from rota_slots where id in (r.give_slot, r.take_slot) and week_start + day < current_date) then
    update swap_requests set status = 'declined' where id = r.id;
    raise exception 'That slot has already happened';
  end if;
  select * into me from profiles where id = auth.uid();
  if p_accept then
    if (select parent_id from rota_slots where id = r.give_slot) <> r.requester or (select parent_id from rota_slots where id = r.take_slot) <> r.responder then
      update swap_requests set status = 'declined' where id = r.id;
      raise exception 'The rota changed since this swap was asked for';
    end if;
    update rota_slots set parent_id = r.responder, confirmed = true where id = r.give_slot;
    update rota_slots set parent_id = r.requester, confirmed = true where id = r.take_slot;
  end if;
  update swap_requests set status = case when p_accept then 'accepted' else 'declined' end where id = r.id;
  perform notify(r.requester, 'swap', me.first_name || case when p_accept then ' agreed to your swap.' else ' couldn’t do the swap.' end);
end $$;

create or replace function public.nudge_slot(p_slot uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s rota_slots; me profiles;
begin
  select * into s from rota_slots where id = p_slot;
  if s.id is null or not in_group(s.group_id) or s.confirmed or s.week_start + s.day < current_date then return; end if;
  select * into me from profiles where id = auth.uid();
  perform notify_slot(s.parent_id, 'confirm', me.first_name || ' asked you to confirm your ' || slot_word(s) || '.', s.id);
end $$;

-- Warns a commute, once, about each slot today or tomorrow that nobody has confirmed.
-- Runs every morning if pg_cron is turned on (see the end of this file), and each time someone opens the rota.
-- Called by a parent, it only looks at their own commutes.
create or replace function public.remind_unconfirmed()
returns int language plpgsql security definer set search_path = public as $$
declare s rota_slots; n int := 0; who text;
begin
  for s in select r.* from rota_slots r where not r.confirmed and not r.reminded
             and r.week_start + r.day between current_date and current_date + 1
             and (auth.uid() is null or in_group(r.group_id)) loop
    update rota_slots set reminded = true where id = s.id;
    select first_name into who from profiles where id = s.parent_id;
    perform notify_slot(s.parent_id, 'confirm', 'Please confirm your ' || slot_word(s) || '. It’s coming up soon and the other families are waiting to hear.', s.id);
    insert into notifications (user_id, kind, body, slot_id)
    select pid, 'rota', who || ' hasn’t confirmed the ' || slot_word(s) || ' yet.', s.id
      from (select owner_id pid from commute_groups where id = s.group_id
            union select parent_id from group_members where group_id = s.group_id and status = 'accepted') x
     where pid <> s.parent_id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Names of the people in my commute groups, for the rota and chat, with where each family stands in joining.
drop function if exists public.group_people(uuid);
create function public.group_people(p_group uuid)
returns table (parent_id uuid, first_name text, last_name text, status text, is_owner boolean, kids bigint,
               family_ok boolean, group_ok boolean, source text, joined_at timestamptz, places int)
language sql stable security definer set search_path = public as $$
  select p.id, p.first_name, p.last_name, 'accepted', true, (select count(*) from children c where c.parent_id = p.id),
         true, true, 'invite', g.created_at, kids_of(p.id) + coalesce(c.seats, 0)
    from commute_groups g join profiles p on p.id = g.owner_id left join commutes c on c.parent_id = g.owner_id and c.hub_id = g.hub_id
   where g.id = p_group and (in_group(p_group) or exists (select 1 from group_members where group_id = p_group and parent_id = auth.uid()))
  union all
  select p.id, p.first_name, p.last_name, m.status, false, (select count(*) from children c where c.parent_id = p.id),
         m.family_ok, m.group_ok, m.source, m.joined_at, kids_of(p.id) + coalesce(c.seats, 0)
    from group_members m join commute_groups g on g.id = m.group_id join profiles p on p.id = m.parent_id
         left join commutes c on c.parent_id = m.parent_id and c.hub_id = g.hub_id
   where m.group_id = p_group and (in_group(p_group) or m.parent_id = auth.uid())
$$;

-- Tell the rest of the group when someone sends a chat message.
create or replace function public.on_message() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into notifications (user_id, kind, body)
  select pid, 'chat', (select first_name from profiles where id = new.sender_id) || ': ' || left(new.body, 120)
    from (select owner_id pid from commute_groups where id = new.group_id
          union select parent_id from group_members where group_id = new.group_id and status = 'accepted') x
   where pid <> new.sender_id
     and not exists (select 1 from notifications n where n.user_id = pid and n.kind = 'chat' and not n.read and n.created_at > now() - interval '10 minutes');
  return new;
end $$;
drop trigger if exists message_notify on public.messages;
create trigger message_notify after insert on public.messages for each row execute function public.on_message();

-- ---------- group admin tools (schools, clubs, and the parent who set a group up) ----------

-- An admin's view of the group's people: who joined plus invited emails that have not joined yet.
drop function if exists public.hub_people(uuid);
create function public.hub_people(p_hub uuid)
returns table (user_id uuid, name text, email text, status text, role text, commuting boolean, joined_at timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
  select m.user_id, p.first_name || ' ' || p.last_name, u.email::text,
         case when m.status = 'pending' then 'pending' when m.role = 'admin' then 'admin' else 'active' end, m.role,
         exists (select 1 from commutes c where c.hub_id = m.hub_id and c.parent_id = m.user_id), m.created_at
    from hub_members m join profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
   where m.hub_id = p_hub and can_manage_hub(p_hub)
  union all
  select null, i.name, i.email, 'invited', null, false, i.created_at
    from hub_invites i
   where i.hub_id = p_hub and can_manage_hub(p_hub)
     and not exists (select 1 from auth.users u join hub_members m on m.user_id = u.id where lower(u.email) = lower(i.email) and m.hub_id = i.hub_id)
  ) x(user_id, name, email, status, role, commuting, joined_at)
  order by status = 'pending' desc, joined_at desc
$$;

-- The commute groups families have formed inside a group, for its admins: who's in each, and how much room is left.
drop function if exists public.hub_groups(uuid);
create function public.hub_groups(p_hub uuid)
returns table (id uuid, owner text, members text, pending bigint, created_at timestamptz, covers text, mode text, families int, kids int, spare int)
language sql stable security definer set search_path = public as $$
  select g.id, p.first_name || ' ' || p.last_name,
         coalesce((select string_agg(q.first_name || ' ' || q.last_name, ', ' order by q.first_name)
                     from group_members m join profiles q on q.id = m.parent_id where m.group_id = g.id and m.status = 'accepted'), ''),
         (select count(*) from group_members m where m.group_id = g.id and m.status = 'pending'),
         g.created_at, g.covers, g.mode, s.families, s.kids, s.spare
    from commute_groups g join profiles p on p.id = g.owner_id cross join lateral group_space(g.id) s
   where g.hub_id = p_hub and can_manage_hub(p_hub)
   order by g.created_at
$$;

create or replace function public.set_hub_role(p_hub uuid, p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare h hubs;
begin
  if not can_manage_hub(p_hub) then raise exception 'Only the group''s admins can do that'; end if;
  if p_role not in ('admin', 'member') then raise exception 'Choose admin or member'; end if;
  if p_role = 'member' and not exists (select 1 from hub_members where hub_id = p_hub and role = 'admin' and user_id <> p_user) then
    raise exception 'Every group needs at least one admin. Make someone else an admin first.';
  end if;
  if exists (select 1 from hub_members where hub_id = p_hub and user_id = p_user and status = 'pending') then raise exception 'Approve them first'; end if;
  update hub_members set role = p_role where hub_id = p_hub and user_id = p_user and role <> p_role;
  if not found then return; end if;
  select * into h from hubs where id = p_hub;
  if p_user <> auth.uid() then
    perform notify(p_user, 'school', case when p_role = 'admin' then 'You’re now an admin of ' || h.name || '.' else 'You’re no longer an admin of ' || h.name || '.' end);
  end if;
end $$;

-- Takes someone out of a group: their commute, their places in its commute groups, and their future rota slots go.
create or replace function public.remove_from_hub(p_hub uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare h hubs;
begin
  if not can_manage_hub(p_hub) then raise exception 'Only the group''s admins can do that'; end if;
  if p_user = auth.uid() then raise exception 'You can’t remove yourself here'; end if;
  if not exists (select 1 from hub_members where hub_id = p_hub and user_id = p_user) then raise exception 'That person isn''t in this group'; end if;
  if not exists (select 1 from hub_members where hub_id = p_hub and role = 'admin' and user_id <> p_user)
     and exists (select 1 from hub_members where hub_id = p_hub and user_id <> p_user and status = 'active') then
    raise exception 'They’re the only admin. Make someone else an admin first.';
  end if;
  select * into h from hubs where id = p_hub;
  delete from rota_slots s using commute_groups g where s.group_id = g.id and g.hub_id = p_hub and s.parent_id = p_user and s.week_start >= date_trunc('week', now())::date;
  delete from group_members m using commute_groups g where m.group_id = g.id and g.hub_id = p_hub and m.parent_id = p_user;
  delete from commute_groups where hub_id = p_hub and owner_id = p_user;
  delete from commutes where hub_id = p_hub and parent_id = p_user;
  delete from hub_members where hub_id = p_hub and user_id = p_user;
  delete from hub_invites i using auth.users u where u.id = p_user and i.hub_id = p_hub and lower(i.email) = lower(u.email);
  perform notify(p_user, 'school', 'You were removed from ' || h.name || ' on Scata.');
  delete from hubs where id = p_hub and not exists (select 1 from hub_members where hub_id = p_hub and status = 'active');
end $$;

-- Closes a group for everyone. Its commute groups, rotas and chats go with it.
create or replace function public.delete_hub(p_hub uuid)
returns void language plpgsql security definer set search_path = public as $$
declare h hubs;
begin
  if not can_manage_hub(p_hub) then raise exception 'Only the group''s admins can do that'; end if;
  select * into h from hubs where id = p_hub;
  if h.id is null then return; end if;
  perform notify(m.user_id, 'school', h.name || ' was closed on Scata.') from hub_members m where m.hub_id = p_hub and m.user_id <> auth.uid();
  delete from hubs where id = p_hub;
end $$;

-- Ends one commute group (its rota, swaps and chat go too).
create or replace function public.delete_commute_group(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups;
begin
  select * into g from commute_groups where id = p_group;
  if g.id is null then return; end if;
  if not can_manage_hub(g.hub_id) then raise exception 'Only the group''s admins can do that'; end if;
  perform notify(x.pid, 'school', 'An admin of ' || (select name from hubs where id = g.hub_id) || ' ended a commute you shared there.')
     from (select g.owner_id pid union select parent_id from group_members where group_id = p_group) x where x.pid <> auth.uid();
  delete from commute_groups where id = p_group;
end $$;

-- ---------- Scata admin panel (people who run Scata; profiles.is_admin) ----------

create or replace function public.admin_stats()
returns table (accounts bigint, unconfirmed bigint, no_name bigint, plus bigint, hubs bigint, schools bigint, clubs bigint, others bigint,
               memberships bigint, commutes bigint, groups bigint, messages bigint, new_week bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Only Scata admins can do that'; end if;
  return query select
    (select count(*) from auth.users),
    (select count(*) from auth.users where email_confirmed_at is null),
    (select count(*) from auth.users u where not exists (select 1 from profiles p where p.id = u.id)),
    (select count(*) from profiles where profiles.plus),
    (select count(*) from public.hubs),
    (select count(*) from public.hubs where kind = 'school'),
    (select count(*) from public.hubs where kind = 'sport'),
    (select count(*) from public.hubs where kind = 'other'),
    (select count(*) from hub_members),
    (select count(*) from public.commutes where accepted_terms),
    (select count(*) from commute_groups),
    (select count(*) from public.messages),
    (select count(*) from auth.users where created_at > now() - interval '7 days');
end $$;

create or replace function public.admin_users()
returns table (id uuid, email text, name text, plus boolean, is_admin boolean, confirmed boolean, created_at timestamptz, last_sign_in timestamptz, hubs text, children bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Only Scata admins can do that'; end if;
  return query
  select u.id, u.email::text, case when p.id is null then null else p.first_name || ' ' || p.last_name end,
         coalesce(p.plus, false), coalesce(p.is_admin, false), u.email_confirmed_at is not null, u.created_at, u.last_sign_in_at,
         coalesce((select string_agg(h.name || case when m.status = 'pending' then ' (asked to join)' when m.role = 'admin' then ' (admin)' else '' end, ', ' order by m.created_at)
                     from hub_members m join public.hubs h on h.id = m.hub_id where m.user_id = u.id), ''),
         (select count(*) from public.children c where c.parent_id = u.id)
    from auth.users u left join profiles p on p.id = u.id
   order by u.created_at desc;
end $$;

drop function if exists public.admin_hubs();
create function public.admin_hubs()
returns table (id uuid, code text, kind text, name text, address text, created_at timestamptz, creator text, members bigint, admins bigint, commutes bigint, groups bigint, trip_date date, join_policy text, requests bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Only Scata admins can do that'; end if;
  return query
  select h.id, h.code, h.kind, h.name, h.address, h.created_at,
         (select p.first_name || ' ' || p.last_name from profiles p where p.id = h.created_by),
         (select count(*) from hub_members m where m.hub_id = h.id and m.status = 'active'),
         (select count(*) from hub_members m where m.hub_id = h.id and m.role = 'admin'),
         (select count(*) from public.commutes c where c.hub_id = h.id and c.accepted_terms),
         (select count(*) from commute_groups g where g.hub_id = h.id), h.trip_date, h.join_policy,
         (select count(*) from hub_members m where m.hub_id = h.id and m.status = 'pending')
    from public.hubs h
   order by h.created_at desc;
end $$;

create or replace function public.admin_set_plus(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Only Scata admins can do that'; end if;
  update profiles set plus = p_on where id = p_user;
  if not found then raise exception 'That person hasn’t finished signing up yet'; end if;
end $$;

create or replace function public.admin_set_admin(p_user uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_platform_admin() then raise exception 'Only Scata admins can do that'; end if;
  if p_user = auth.uid() and not p_on then raise exception 'You can’t remove your own admin access here'; end if;
  update profiles set is_admin = p_on where id = p_user;
  if not found then raise exception 'That person hasn’t finished signing up yet'; end if;
end $$;

-- Deletes an account and everything it owns. A group it was the only admin of passes to its longest-standing member.
create or replace function public.admin_delete_user(p_user uuid)
returns void language plpgsql security definer set search_path = public, auth as $$
declare orphaned uuid[];
begin
  if not is_platform_admin() then raise exception 'Only Scata admins can do that'; end if;
  if p_user = auth.uid() then raise exception 'You can’t delete your own account here'; end if;
  select array_agg(m.hub_id) into orphaned from hub_members m
   where m.user_id = p_user and m.role = 'admin'
     and not exists (select 1 from hub_members o where o.hub_id = m.hub_id and o.role = 'admin' and o.user_id <> p_user);
  delete from auth.users where id = p_user;
  if orphaned is not null then
    update hub_members m set role = 'admin'
      from (select distinct on (hub_id) hub_id, user_id from hub_members where hub_id = any(orphaned) and status = 'active' order by hub_id, created_at) f
     where m.hub_id = f.hub_id and m.user_id = f.user_id;
    perform notify(m.user_id, 'school', 'You’re now the admin of ' || h.name || ' on Scata.')
       from hub_members m join public.hubs h on h.id = m.hub_id where m.hub_id = any(orphaned) and m.role = 'admin';
    delete from public.hubs h where h.id = any(orphaned) and not exists (select 1 from hub_members m where m.hub_id = h.id and m.status = 'active');
  end if;
end $$;

grant execute on all functions in schema public to authenticated;
revoke execute on function public.notify(uuid, text, text) from authenticated;
revoke execute on function public.notify_slot(uuid, text, text, uuid) from authenticated;
revoke execute on function public.notify_group(uuid, text, text) from authenticated;
revoke execute on function public.notify_hub(uuid, text, text, uuid) from authenticated;
revoke execute on function public.complete_join(uuid, uuid) from authenticated;

-- Morning reminders about unconfirmed slots. Needs pg_cron: Supabase > Database > Extensions > pg_cron. Then run this file again.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('scata-remind-unconfirmed', '0 7 * * *', 'select public.remind_unconfirmed()');
  end if;
end $$;

-- ---------- live updates ----------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.locations; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.rota_slots; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.group_members; exception when duplicate_object then null; end;
  end if;
end $$;

commit;
