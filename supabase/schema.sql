-- Scata database. Paste this whole file into Supabase > SQL Editor and click Run.
-- Safe to run again: it only creates what is missing and replaces functions and policies.

create extension if not exists pgcrypto;

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

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  first_name text not null,
  last_name text not null,
  plus boolean not null default false,
  created_at timestamptz not null default now()
);

-- Who belongs to each hub. Admins (the school, the coach, or the parent who set it up) manage it.
create table if not exists public.hub_members (
  hub_id uuid not null references public.hubs on delete cascade,
  user_id uuid not null references public.profiles on delete cascade,
  role text not null default 'member' check (role in ('admin', 'member')),
  created_at timestamptz not null default now(),
  primary key (hub_id, user_id)
);

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

-- Emails a hub admin has invited. People still join with the hub code or link.
create table if not exists public.hub_invites (
  id uuid primary key default gen_random_uuid(),
  hub_id uuid not null references public.hubs on delete cascade,
  email text not null,
  name text not null default '',
  created_at timestamptz not null default now(),
  unique (hub_id, email)
);

-- A commute group belongs to the parent who started it; others join by invitation. One per parent per hub.
create table if not exists public.commute_groups (
  id uuid primary key default gen_random_uuid(),
  hub_id uuid not null references public.hubs on delete cascade,
  owner_id uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  unique (hub_id, owner_id)
);

create table if not exists public.group_members (
  group_id uuid not null references public.commute_groups on delete cascade,
  parent_id uuid not null references public.profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  primary key (group_id, parent_id)
);

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

create index if not exists notifications_user on public.notifications (user_id, created_at desc);
create index if not exists messages_group on public.messages (group_id, created_at);
create index if not exists hub_members_user on public.hub_members (user_id);
create index if not exists commutes_hub on public.commutes (hub_id);

-- ---------- helpers (run with owner rights so policies can use them without recursion) ----------

create or replace function public.in_hub(h uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from hub_members where hub_id = h and user_id = auth.uid())
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

-- How a hub's trip is described in messages.
create or replace function public.trip_word(h uuid) returns text
language sql stable security definer set search_path = public as $$
  select case kind when 'school' then 'the school run to ' else 'trips to ' end || name from hubs where id = h
$$;

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

drop policy if exists "read my hubs" on public.hubs;
create policy "read my hubs" on public.hubs for select to authenticated using (public.in_hub(id));
drop policy if exists "admin edits hub" on public.hubs;
create policy "admin edits hub" on public.hubs for update to authenticated using (public.is_hub_admin(id)) with check (public.is_hub_admin(id));

drop policy if exists "read memberships" on public.hub_members;
create policy "read memberships" on public.hub_members for select to authenticated using (user_id = auth.uid() or public.is_hub_admin(hub_id));

drop policy if exists "read profiles" on public.profiles;
create policy "read profiles" on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_group(id) or public.admin_of(id));
drop policy if exists "edit own profile" on public.profiles;
create policy "edit own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "own children" on public.children;
create policy "own children" on public.children for all to authenticated using (parent_id = auth.uid()) with check (parent_id = auth.uid());

drop policy if exists "own commute" on public.commutes;
create policy "own commute" on public.commutes for all to authenticated
  using (parent_id = auth.uid()) with check (parent_id = auth.uid() and public.in_hub(hub_id));

drop policy if exists "admin invites" on public.hub_invites;
create policy "admin invites" on public.hub_invites for all to authenticated
  using (public.is_hub_admin(hub_id)) with check (public.is_hub_admin(hub_id));

drop policy if exists "read my groups" on public.commute_groups;
create policy "read my groups" on public.commute_groups for select to authenticated
  using (owner_id = auth.uid() or exists (select 1 from public.group_members m where m.group_id = id and m.parent_id = auth.uid()));

drop policy if exists "read members" on public.group_members;
create policy "read members" on public.group_members for select to authenticated
  using (parent_id = auth.uid() or public.in_group(group_id));

drop policy if exists "read rota" on public.rota_slots;
create policy "read rota" on public.rota_slots for select to authenticated using (public.in_group(group_id));

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
grant update (name, address, size, open_time, close_time, days, lat, lng) on public.hubs to authenticated;
revoke insert, update, delete on public.hub_members, public.commute_groups, public.group_members, public.rota_slots, public.swap_requests from authenticated;
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
create or replace function public.create_hub(p_kind text, p_name text, p_address text, p_size text, p_open text, p_close text, p_days smallint[], p_lat double precision default null, p_lng double precision default null, p_commute boolean default false)
returns public.hubs language plpgsql security definer set search_path = public as $$
declare h hubs; c text;
begin
  if not exists (select 1 from profiles where id = auth.uid()) then raise exception 'Please add your name first'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'Give the group a name'; end if;
  if (select count(*) from hub_members where user_id = auth.uid() and role = 'admin') >= 20 then raise exception 'You already manage 20 groups'; end if;
  loop
    c := 'sca' || lpad((floor(random() * 1000000))::int::text, 6, '0');
    exit when not exists (select 1 from hubs where code = c);
  end loop;
  insert into hubs (code, kind, name, address, size, open_time, close_time, days, lat, lng, created_by)
    values (c, p_kind, trim(p_name), trim(p_address), nullif(p_size, ''), p_open, p_close, coalesce(p_days, '{0,1,2,3,4}'), p_lat, p_lng, auth.uid()) returning * into h;
  insert into hub_members (hub_id, user_id, role) values (h.id, auth.uid(), 'admin');
  if p_commute then insert into commutes (parent_id, hub_id, drop_time, pick_time) values (auth.uid(), h.id, h.open_time, h.close_time); end if;
  return h;
end $$;

-- Join a hub with its code. Also used by an admin of a hub to start sharing trips there themselves.
create or replace function public.join_hub(p_code text)
returns public.hubs language plpgsql security definer set search_path = public as $$
declare h hubs; me profiles; fresh boolean;
begin
  select * into me from profiles where id = auth.uid();
  if me.id is null then raise exception 'Please add your name first'; end if;
  select * into h from hubs where code = lower(trim(p_code));
  if h.id is null then raise exception 'That code doesn''t match a group. Check the code in your invite.'; end if;
  insert into hub_members (hub_id, user_id) values (h.id, auth.uid()) on conflict do nothing;
  fresh := found;
  insert into commutes (parent_id, hub_id, drop_time, pick_time) values (auth.uid(), h.id, h.open_time, h.close_time) on conflict do nothing;
  if fresh then
    perform notify(m.user_id, 'school', me.first_name || ' ' || me.last_name || ' joined ' || h.name || ' on Scata.')
       from hub_members m where m.hub_id = h.id and m.role = 'admin' and m.user_id <> auth.uid();
  end if;
  return h;
end $$;

-- My hubs, with my role and whether I share trips there.
create or replace function public.my_hubs()
returns table (id uuid, code text, kind text, name text, address text, size text, open_time text, close_time text, days smallint[], lat double precision, lng double precision, role text, commuting boolean)
language sql stable security definer set search_path = public as $$
  select h.id, h.code, h.kind, h.name, h.address, h.size, h.open_time, h.close_time, h.days, h.lat, h.lng, m.role,
         exists (select 1 from commutes c where c.hub_id = h.id and c.parent_id = auth.uid())
    from hub_members m join hubs h on h.id = m.hub_id
   where m.user_id = auth.uid()
   order by m.created_at
$$;

-- Leave a hub: my commute, my places in its commute groups, and my future rota slots go.
create or replace function public.leave_hub(p_hub uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if is_hub_admin(p_hub) and not exists (select 1 from hub_members where hub_id = p_hub and role = 'admin' and user_id <> auth.uid())
     and exists (select 1 from hub_members where hub_id = p_hub and user_id <> auth.uid()) then
    raise exception 'You''re the only admin. Other families still use this group, so it needs an admin.';
  end if;
  delete from rota_slots s using commute_groups g where s.group_id = g.id and g.hub_id = p_hub and s.parent_id = auth.uid() and s.week_start >= date_trunc('week', now())::date;
  delete from group_members m using commute_groups g where m.group_id = g.id and g.hub_id = p_hub and m.parent_id = auth.uid();
  delete from commute_groups where hub_id = p_hub and owner_id = auth.uid();
  delete from commutes where hub_id = p_hub and parent_id = auth.uid();
  delete from hub_members where hub_id = p_hub and user_id = auth.uid();
  delete from hubs where id = p_hub and not exists (select 1 from hub_members where hub_id = p_hub);
end $$;

-- An admin's view of the hub's families: who joined plus invited emails that have not joined yet.
create or replace function public.hub_people(p_hub uuid)
returns table (name text, email text, status text, joined_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.first_name || ' ' || p.last_name, u.email::text, case when m.role = 'admin' then 'admin' else 'active' end, m.created_at
    from hub_members m join profiles p on p.id = m.user_id join auth.users u on u.id = m.user_id
   where m.hub_id = p_hub and is_hub_admin(p_hub)
  union all
  select i.name, i.email, 'invited', i.created_at
    from hub_invites i
   where i.hub_id = p_hub and is_hub_admin(p_hub)
     and not exists (select 1 from auth.users u join hub_members m on m.user_id = u.id where lower(u.email) = lower(i.email) and m.hub_id = i.hub_id)
  order by 4 desc
$$;

create or replace function public.hub_stats(p_hub uuid)
returns table (members bigint, commutes bigint, walk bigint, bike bigint, car bigint, bus bigint, groups bigint)
language sql stable security definer set search_path = public as $$
  select (select count(*) from hub_members where hub_id = p_hub),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'walk'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'bike'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'car'),
         (select count(*) from commutes where hub_id = p_hub and accepted_terms and mode = 'bus'),
         (select count(*) from commute_groups where hub_id = p_hub)
   where is_hub_admin(p_hub)
$$;

-- Other families in the hub who have set up a commute. Shows a first name and rough distance only, never an address.
create or replace function public.nearby_parents(p_hub uuid)
returns table (parent_id uuid, first_name text, kids bigint, km numeric, mode text, status text)
language sql stable security definer set search_path = public as $$
  with me as (select c.* from commutes c where c.parent_id = auth.uid() and c.hub_id = p_hub),
       g as (select id from commute_groups where owner_id = auth.uid() and hub_id = p_hub)
  select p.id, p.first_name,
         (select count(*) from children ch where ch.parent_id = p.id),
         case when me.lat is null or c.lat is null then null
              else round((6371 * acos(least(1, cos(radians(me.lat)) * cos(radians(c.lat)) * cos(radians(c.lng) - radians(me.lng)) + sin(radians(me.lat)) * sin(radians(c.lat)))))::numeric, 1) end,
         c.mode,
         coalesce((select m.status from group_members m join g on g.id = m.group_id where m.parent_id = p.id), 'none')
    from me
    join commutes c on c.hub_id = me.hub_id and c.parent_id <> me.parent_id and c.accepted_terms
    join profiles p on p.id = c.parent_id
   order by 4 nulls last, 2
   limit 30
$$;

-- The commute groups I own or was invited to in one hub.
create or replace function public.my_groups(p_hub uuid)
returns table (id uuid, mine boolean, status text)
language sql stable security definer set search_path = public as $$
  select g.id, true, 'accepted' from commute_groups g where g.hub_id = p_hub and g.owner_id = auth.uid()
  union all
  select g.id, false, m.status from group_members m join commute_groups g on g.id = m.group_id where g.hub_id = p_hub and m.parent_id = auth.uid()
$$;

create or replace function public.invite_parent(p_hub uuid, p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare gid uuid; me profiles;
begin
  select * into me from profiles where id = auth.uid();
  if not exists (select 1 from commutes where parent_id = auth.uid() and hub_id = p_hub and accepted_terms) then raise exception 'Set up your own commute first'; end if;
  if not exists (select 1 from commutes where parent_id = p_target and hub_id = p_hub and accepted_terms) then raise exception 'That family isn''t available to invite'; end if;
  insert into commute_groups (hub_id, owner_id) values (p_hub, auth.uid()) on conflict (hub_id, owner_id) do nothing;
  select id into gid from commute_groups where hub_id = p_hub and owner_id = auth.uid();
  insert into group_members (group_id, parent_id) values (gid, p_target)
    on conflict (group_id, parent_id) do update set status = 'pending' where group_members.status = 'declined';
  perform notify(p_target, 'invite', me.first_name || ' ' || me.last_name || ' invited you to share ' || trip_word(p_hub) || '.');
end $$;

create or replace function public.respond_invite(p_group uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare g commute_groups; me profiles;
begin
  select * into me from profiles where id = auth.uid();
  update group_members set status = case when p_accept then 'accepted' else 'declined' end
   where group_id = p_group and parent_id = auth.uid() and status = 'pending';
  if not found then raise exception 'There is no open invitation to answer'; end if;
  select * into g from commute_groups where id = p_group;
  perform notify(g.owner_id, 'invite', me.first_name || ' ' || case when p_accept then 'accepted' else 'declined' end || ' your invitation to share ' || trip_word(g.hub_id) || '.');
end $$;

create or replace function public.leave_group(p_group uuid)
returns void language sql security definer set search_path = public as $$
  delete from group_members where group_id = p_group and parent_id = auth.uid();
  delete from rota_slots where group_id = p_group and parent_id = auth.uid() and week_start >= date_trunc('week', now())::date;
$$;

-- Builds one week's rota on the hub's days, sharing trips round-robin. Keeps an existing week as it is.
create or replace function public.build_rota(p_group uuid, p_week date)
returns setof public.rota_slots language plpgsql security definer set search_path = public as $$
declare members uuid[]; n int; d int; i int := 0; k text; wk date := date_trunc('week', p_week)::date; shift int; ds smallint[];
begin
  if not in_group(p_group) then raise exception 'You''re not in this commute'; end if;
  if not exists (select 1 from rota_slots where group_id = p_group and week_start = wk) then
    select array_agg(pid order by pid) into members from (
      select owner_id pid from commute_groups where id = p_group
      union select parent_id from group_members where group_id = p_group and status = 'accepted') x;
    n := array_length(members, 1);
    if n < 2 then raise exception 'Invite at least one family who accepts before building a rota'; end if;
    select array_agg(x order by x) into ds from (select distinct unnest(h.days) x from commute_groups g join hubs h on h.id = g.hub_id where g.id = p_group) y;
    shift := ((wk - date '2024-01-01') / 7) % n; -- rotate who gets the extra trips each week
    foreach d in array ds loop
      foreach k in array array['drop', 'pick'] loop
        -- Each day starts with the next family, so drop-offs and pick-ups both rotate.
        insert into rota_slots (group_id, week_start, day, kind, parent_id) values (p_group, wk, d, k, members[((i + (k = 'pick')::int + shift) % n) + 1]);
      end loop;
      i := i + 1;
    end loop;
  end if;
  return query select * from rota_slots where group_id = p_group and week_start = wk order by day, kind;
end $$;

-- Rebuild a week after someone joins or leaves. Only the group's owner can do it.
create or replace function public.rebuild_rota(p_group uuid, p_week date)
returns setof public.rota_slots language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from commute_groups where id = p_group and owner_id = auth.uid()) then raise exception 'Only the parent who started the commute can rebuild the rota'; end if;
  delete from rota_slots where group_id = p_group and week_start = date_trunc('week', p_week)::date;
  return query select * from build_rota(p_group, p_week);
end $$;

create or replace function public.confirm_slot(p_slot uuid)
returns void language sql security definer set search_path = public as $$
  update rota_slots set confirmed = true where id = p_slot and parent_id = auth.uid();
$$;

create or replace function public.request_swap(p_give uuid, p_take uuid)
returns void language plpgsql security definer set search_path = public as $$
declare a rota_slots; b rota_slots; me profiles;
begin
  select * into a from rota_slots where id = p_give;
  select * into b from rota_slots where id = p_take;
  if a.parent_id is distinct from auth.uid() then raise exception 'You can only swap your own slot'; end if;
  if b.id is null or b.group_id <> a.group_id or b.parent_id = auth.uid() then raise exception 'Pick a slot another parent is doing'; end if;
  select * into me from profiles where id = auth.uid();
  insert into swap_requests (group_id, give_slot, take_slot, requester, responder) values (a.group_id, a.id, b.id, auth.uid(), b.parent_id);
  perform notify(b.parent_id, 'swap', me.first_name || ' asked to swap: you’d take their ' || to_char(a.week_start + a.day, 'Dy DD Mon') || ' ' || case a.kind when 'drop' then 'drop-off' else 'pick-up' end || ' and they’d take your ' || to_char(b.week_start + b.day, 'Dy DD Mon') || ' ' || case b.kind when 'drop' then 'drop-off' else 'pick-up' end || '.');
end $$;

create or replace function public.respond_swap(p_swap uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r swap_requests; me profiles;
begin
  select * into r from swap_requests where id = p_swap and responder = auth.uid() and status = 'pending';
  if r.id is null then raise exception 'That swap request is no longer open'; end if;
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
  if s.id is null or not in_group(s.group_id) or s.confirmed then return; end if;
  select * into me from profiles where id = auth.uid();
  perform notify(s.parent_id, 'rota', me.first_name || ' asked you to confirm your ' || to_char(s.week_start + s.day, 'Dy DD Mon') || ' ' || case s.kind when 'drop' then 'drop-off' else 'pick-up' end || '.');
end $$;

-- Names of the people in my commute groups, for the rota and chat.
create or replace function public.group_people(p_group uuid)
returns table (parent_id uuid, first_name text, last_name text, status text, is_owner boolean, kids bigint)
language sql stable security definer set search_path = public as $$
  select p.id, p.first_name, p.last_name, 'accepted', true, (select count(*) from children c where c.parent_id = p.id)
    from commute_groups g join profiles p on p.id = g.owner_id where g.id = p_group and (in_group(p_group) or exists (select 1 from group_members where group_id = p_group and parent_id = auth.uid()))
  union all
  select p.id, p.first_name, p.last_name, m.status, false, (select count(*) from children c where c.parent_id = p.id)
    from group_members m join profiles p on p.id = m.parent_id where m.group_id = p_group and (in_group(p_group) or m.parent_id = auth.uid())
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

grant execute on all functions in schema public to authenticated;
revoke execute on function public.notify(uuid, text, text) from authenticated;

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
