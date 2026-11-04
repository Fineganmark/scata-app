-- Scata demo data: a pretend school, a sports club trip, and the families who share runs there.
-- Paste this whole file into Supabase > SQL Editor and click Run, after schema.sql.
-- Safe to run again: it wipes the old demo data first and rebuilds it around today's date,
-- so run it on the morning of a demo to get a fresh rota, unread notifications and a live car.
-- Every demo account signs in with the password ScataDemo2026 (logins are listed in the README).
-- To take the demo out, run supabase/demo-remove.sql.

-- ---------- 1. clear any earlier demo data ----------
delete from public.hubs where id::text like 'de300000-0000-4000-8000-%';
delete from auth.users where id::text like 'de300000-0000-4000-8000-%' or email like 'demo.%@example.com';

-- ---------- 2. people ----------
create or replace function pg_temp.demo_user(n int, p_email text, p_first text, p_last text, p_plus boolean, p_joined interval)
returns uuid language plpgsql as $$
declare uid uuid := ('de300000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid;
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, last_sign_in_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, email_change, email_change_token_new, recovery_token)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', p_email,
          extensions.crypt('ScataDemo2026', extensions.gen_salt('bf')), now() - p_joined, null,
          '{"provider":"email","providers":["email"]}', '{}', now() - p_joined, now() - p_joined, '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (uid::text, uid, jsonb_build_object('sub', uid::text, 'email', p_email, 'email_verified', true), 'email', null, now() - p_joined, now() - p_joined);
  insert into public.profiles (id, first_name, last_name, plus, created_at) values (uid, p_first, p_last, p_plus, now() - p_joined);
  return uid;
end $$;

-- Newer Supabase versions have more token columns that must be empty text rather than null for sign-in to work.
do $$
declare c text;
begin
  foreach c in array array['email_change_token_current', 'phone_change', 'phone_change_token', 'reauthentication_token'] loop
    if exists (select 1 from information_schema.columns where table_schema = 'auth' and table_name = 'users' and column_name = c) then
      execute format('update auth.users set %I = coalesce(%I, '''') where id::text like ''de300000-0000-4000-8000-%%''', c, c);
    end if;
  end loop;
end $$;

-- Logins (the ones you use in the demo) and background families (they make the group look lived in).
select pg_temp.demo_user( 1, 'demo.principal@example.com', 'Áine',    'Murphy',    false, '21 days');
select pg_temp.demo_user( 2, 'demo.sean@example.com',      'Seán',    'Kelly',     true,  '20 days');
select pg_temp.demo_user( 3, 'demo.paul@example.com',      'Paul',    'Doyle',     true,  '19 days');
select pg_temp.demo_user( 4, 'demo.niamh@example.com',     'Niamh',   'O''Brien',  false, '19 days');
select pg_temp.demo_user( 5, 'demo.ciara@example.com',     'Ciara',   'Walsh',     false, '18 days');
select pg_temp.demo_user( 6, 'demo.david@example.com',     'David',   'Byrne',     false, '2 hours');
select pg_temp.demo_user( 7, 'demo.coach@example.com',     'Declan',  'Farrell',   false, '30 days');
select pg_temp.demo_user( 8, 'demo.emma@example.com',      'Emma',    'Ryan',      false, '17 days');
select pg_temp.demo_user( 9, 'demo.grainne@example.com',   'Gráinne', 'Lynch',     false, '12 days');
select pg_temp.demo_user(10, 'demo.conor@example.com',     'Conor',   'Nolan',     false, '10 days');
select pg_temp.demo_user(11, 'demo.orla@example.com',      'Orla',    'Quinn',     false, '6 days');
select pg_temp.demo_user(12, 'demo.rory@example.com',      'Rory',    'Brennan',   false, '4 days');

-- Shortcut to a demo person's id.
create or replace function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('de300000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid
$$;

insert into public.children (parent_id, name, dob) values
  (pg_temp.u(2),  'Oisín',  '2017-03-14'), (pg_temp.u(2),  'Saoirse', '2019-08-02'),
  (pg_temp.u(3),  'Jack',   '2017-06-21'),
  (pg_temp.u(4),  'Fiadh',  '2017-01-09'), (pg_temp.u(4),  'Cillian', '2015-11-30'),
  (pg_temp.u(5),  'Ella',   '2018-04-17'),
  (pg_temp.u(6),  'Tadhg',  '2018-02-25'),
  (pg_temp.u(8),  'Lily',   '2018-09-05'),
  (pg_temp.u(9),  'Conall', '2016-12-12'),
  (pg_temp.u(10), 'Darragh','2015-07-19'),
  (pg_temp.u(11), 'Aoife',  '2019-05-28'),
  (pg_temp.u(12), 'Senan',  '2017-10-03');

-- ---------- 3. the school and the club trip ----------
-- Greenfield National School (made up), Drumcondra, Dublin 9. Join code sca000101.
insert into public.hubs (id, code, kind, name, address, size, open_time, close_time, days, lat, lng, created_by, created_at)
values ('de300000-0000-4000-8000-100000000001', 'sca000101', 'school', 'Greenfield National School (Demo)', 'D09 GF01', '200-400',
        '08:30-09:00', '14:30-15:00', '{0,1,2,3,4}', 53.3712, -6.2563, pg_temp.u(1), now() - interval '21 days');

-- Drumcondra Juniors U12s (made up): one away match this coming Saturday. Join code sca000102.
-- If the single-trip update is in (hubs.trip_date), this is one trip; otherwise it shows as a Saturday group.
insert into public.hubs (id, code, kind, name, address, open_time, close_time, days, lat, lng, created_by, created_at)
values ('de300000-0000-4000-8000-100000000002', 'sca000102', 'sport', 'Drumcondra Juniors U12s: away match in Raheny (Demo)',
        'St Anne''s Park, Raheny, Dublin 5', '09:15-09:45', '11:30-12:00', '{5}', 53.3707, -6.1826, pg_temp.u(7), now() - interval '9 days');

do $$
declare d date := current_date + (case when extract(isodow from current_date) = 6 then 7 else (6 - extract(isodow from current_date))::int end);
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'hubs' and column_name = 'trip_date') then
    execute 'update public.hubs set trip_date = $1 where id = ''de300000-0000-4000-8000-100000000002''' using d;
  end if;
end $$;

insert into public.hub_members (hub_id, user_id, role, created_at)
select 'de300000-0000-4000-8000-100000000001', pg_temp.u(n), case when n = 1 then 'admin' else 'member' end, now() - j
  from (values (1, interval '21 days'), (2, '20 days'), (3, '19 days'), (4, '19 days'), (5, '18 days'), (8, '17 days'),
               (9, '12 days'), (10, '10 days'), (11, '6 days'), (12, '4 days'), (6, '2 hours')) v(n, j);

insert into public.hub_members (hub_id, user_id, role, created_at)
select 'de300000-0000-4000-8000-100000000002', pg_temp.u(n), case when n = 7 then 'admin' else 'member' end, now() - j
  from (values (7, interval '9 days'), (2, '8 days'), (4, '7 days'), (10, '5 days'), (12, '3 days')) v(n, j);

-- Families the principal has invited by email who haven't joined yet.
insert into public.hub_invites (hub_id, email, name, created_at) values
  ('de300000-0000-4000-8000-100000000001', 'mary.hughes@example.com', 'Mary Hughes', now() - interval '3 days'),
  ('de300000-0000-4000-8000-100000000001', 'k.osullivan@example.com', 'Karen O''Sullivan', now() - interval '1 day');

-- How each family travels. Homes are rough points near the school; the app only shows other families a distance.
insert into public.commutes (parent_id, hub_id, home, lat, lng, mode, seats, drop_time, pick_time, accepted_terms, updated_at)
select pg_temp.u(n), 'de300000-0000-4000-8000-100000000001', home, lat, lng, mode, seats, '08:30-09:00', '14:30-15:00', accepted, now() - interval '3 days'
  from (values
    (2,  'Griffith Avenue, Dublin 9',     53.3741, -6.2482, 'car',  3, true),
    (3,  'Hampstead Avenue, Dublin 9',    53.3769, -6.2511, 'car',  2, true),
    (4,  'Grace Park Road, Dublin 9',     53.3735, -6.2440, 'car',  3, true),
    (5,  'St Alphonsus Road, Dublin 9',   53.3655, -6.2601, 'walk', 4, true),
    (8,  'Botanic Avenue, Dublin 9',      53.3683, -6.2617, 'walk', 4, true),
    (6,  'Iona Road, Dublin 9',           53.3671, -6.2668, 'walk', 4, true),
    (9,  'Ballymun Road, Dublin 9',       53.3797, -6.2627, 'bike', 1, true),
    (10, 'Collins Avenue, Dublin 9',      53.3828, -6.2459, 'car',  3, true),
    (11, 'Drumcondra Road Upper, Dublin 9',53.3698, -6.2549, 'bus',  1, true),
    (12, 'Clonturk Park, Dublin 9',       53.3702, -6.2488, 'car',  2, false)
  ) v(n, home, lat, lng, mode, seats, accepted);

insert into public.commutes (parent_id, hub_id, home, lat, lng, mode, seats, drop_time, pick_time, accepted_terms, updated_at)
select pg_temp.u(n), 'de300000-0000-4000-8000-100000000002', home, lat, lng, 'car', seats, '09:15-09:45', '11:30-12:00', true, now() - interval '2 days'
  from (values
    (2,  'Griffith Avenue, Dublin 9',  53.3741, -6.2482, 3),
    (4,  'Grace Park Road, Dublin 9',  53.3735, -6.2440, 3),
    (10, 'Collins Avenue, Dublin 9',   53.3828, -6.2459, 3),
    (12, 'Clonturk Park, Dublin 9',    53.3702, -6.2488, 2)
  ) v(n, home, lat, lng, seats);

-- ---------- 4. commute groups ----------
-- A: Seán's car pool (Seán, Paul, Niamh).  B: Ciara's walking bus (Ciara, Emma; David invited today).
-- C: Seán's lift share for the away match (Seán, Niamh, Conor).
insert into public.commute_groups (id, hub_id, owner_id, created_at) values
  ('de300000-0000-4000-8000-200000000001', 'de300000-0000-4000-8000-100000000001', pg_temp.u(2), now() - interval '16 days'),
  ('de300000-0000-4000-8000-200000000002', 'de300000-0000-4000-8000-100000000001', pg_temp.u(5), now() - interval '15 days'),
  ('de300000-0000-4000-8000-200000000003', 'de300000-0000-4000-8000-100000000002', pg_temp.u(2), now() - interval '4 days');

insert into public.group_members (group_id, parent_id, status, created_at) values
  ('de300000-0000-4000-8000-200000000001', pg_temp.u(3), 'accepted', now() - interval '16 days'),
  ('de300000-0000-4000-8000-200000000001', pg_temp.u(4), 'accepted', now() - interval '15 days'),
  ('de300000-0000-4000-8000-200000000002', pg_temp.u(8), 'accepted', now() - interval '14 days'),
  ('de300000-0000-4000-8000-200000000002', pg_temp.u(6), 'pending',  now() - interval '1 hour'),
  ('de300000-0000-4000-8000-200000000003', pg_temp.u(4), 'accepted', now() - interval '4 days'),
  ('de300000-0000-4000-8000-200000000003', pg_temp.u(10),'accepted', now() - interval '3 days'),
  ('de300000-0000-4000-8000-200000000003', pg_temp.u(12),'pending',  now() - interval '1 day');

-- ---------- 5. rotas ----------
-- School car pool, this week and next. Days already past are confirmed; Niamh hasn't confirmed one of hers next week.
do $$
declare
  wk date := date_trunc('week', current_date)::date;
  today int := extract(isodow from current_date)::int - 1;
  who int[] := array[2, 3, 4];
  w int; d int; k text; p int;
  car uuid := 'de300000-0000-4000-8000-200000000001';
  walk uuid := 'de300000-0000-4000-8000-200000000002';
begin
  for w in 0..1 loop
    for d in 0..4 loop
      foreach k in array array['drop', 'pick'] loop
        p := who[((d + (k = 'pick')::int + w) % 3) + 1];
        insert into rota_slots (group_id, week_start, day, kind, parent_id, confirmed)
        values (car, wk + 7 * w, d, k, pg_temp.u(p), w = 0 or p = 2 or (p = 3 and d < 3));
        -- Walking bus: Ciara and Emma take turns leading it.
        insert into rota_slots (group_id, week_start, day, kind, parent_id, confirmed)
        values (walk, wk + 7 * w, d, k, pg_temp.u(case when (d + (k = 'pick')::int) % 2 = 0 then 5 else 8 end), w = 0 or d < 2);
      end loop;
    end loop;
  end loop;
end $$;

-- Away match: Seán drives the team there, Niamh brings them home (not confirmed yet).
do $$
declare
  d date := current_date + (case when extract(isodow from current_date) = 6 then 7 else (6 - extract(isodow from current_date))::int end);
  g uuid := 'de300000-0000-4000-8000-200000000003';
begin
  insert into rota_slots (group_id, week_start, day, kind, parent_id, confirmed) values
    (g, date_trunc('week', d)::date, 5, 'drop', pg_temp.u(2), true),
    (g, date_trunc('week', d)::date, 5, 'pick', pg_temp.u(4), false);
end $$;

-- Niamh asks Seán to swap one of her trips next week for one of his.
insert into swap_requests (group_id, give_slot, take_slot, requester, responder, created_at)
select 'de300000-0000-4000-8000-200000000001', a.id, b.id, pg_temp.u(4), pg_temp.u(2), now() - interval '40 minutes'
  from rota_slots a, rota_slots b
 where a.group_id = 'de300000-0000-4000-8000-200000000001' and b.group_id = a.group_id
   and a.week_start = date_trunc('week', current_date)::date + 7 and b.week_start = a.week_start
   and a.parent_id = pg_temp.u(4) and b.parent_id = pg_temp.u(2)
 order by a.day, a.kind, b.day desc, b.kind
 limit 1;

-- ---------- 6. chat (Scata Plus) ----------
alter table public.messages disable trigger message_notify;
insert into public.messages (group_id, sender_id, body, created_at) values
  ('de300000-0000-4000-8000-200000000001', pg_temp.u(3), 'Morning all! Jack has his swimming bag today, it''s a big one 😅', now() - interval '3 hours 10 minutes'),
  ('de300000-0000-4000-8000-200000000001', pg_temp.u(2), 'No problem, plenty of room in the boot.', now() - interval '3 hours 6 minutes'),
  ('de300000-0000-4000-8000-200000000001', pg_temp.u(4), 'Could someone swap a day with me next week? I have an early meeting. Sent Seán a request in the app.', now() - interval '41 minutes'),
  ('de300000-0000-4000-8000-200000000001', pg_temp.u(2), 'Leaving now, at yours in 5 Paul.', now() - interval '2 minutes'),
  ('de300000-0000-4000-8000-200000000002', pg_temp.u(5), 'Walking bus leaves the corner of St Alphonsus Road at 8:35. Hi-vis vests on!', now() - interval '1 day'),
  ('de300000-0000-4000-8000-200000000002', pg_temp.u(8), 'Lily is so excited. See you there.', now() - interval '23 hours'),
  ('de300000-0000-4000-8000-200000000003', pg_temp.u(2), 'I''ll take four of them out to Raheny on Saturday. Boots and gumshields please!', now() - interval '1 day'),
  ('de300000-0000-4000-8000-200000000003', pg_temp.u(10),'Great, Darragh will be ready at 9:10.', now() - interval '20 hours');
alter table public.messages enable trigger message_notify;

-- ---------- 7. live tracking: Seán is on the road to school ----------
-- Fresh for 15 minutes. Run supabase/demo-drive.sql to move the car along before you show it.
insert into public.locations (group_id, parent_id, lat, lng, updated_at)
values ('de300000-0000-4000-8000-200000000001', pg_temp.u(2), 53.3756, -6.2499, now());

-- ---------- 8. notifications (unread, so each login shows a badge) ----------
insert into public.notifications (user_id, kind, body, read, created_at) values
  (pg_temp.u(1), 'school', 'David Byrne joined Greenfield National School (Demo) on Scata.', false, now() - interval '2 hours'),
  (pg_temp.u(1), 'school', 'Rory Brennan joined Greenfield National School (Demo) on Scata.', true, now() - interval '4 days'),
  (pg_temp.u(1), 'school', 'Orla Quinn joined Greenfield National School (Demo) on Scata.', true, now() - interval '6 days'),
  (pg_temp.u(2), 'swap',   'Niamh asked to swap: you’d take their Tue drop-off next week and they’d take your Fri pick-up.', false, now() - interval '40 minutes'),
  (pg_temp.u(2), 'invite', 'Conor accepted your invitation to share trips to Drumcondra Juniors U12s: away match in Raheny (Demo).', true, now() - interval '3 days'),
  (pg_temp.u(3), 'chat',   'Seán: Leaving now, at yours in 5 Paul.', false, now() - interval '2 minutes'),
  (pg_temp.u(4), 'rota',   'Seán asked you to confirm your pick-up for Saturday’s away match.', false, now() - interval '25 minutes'),
  (pg_temp.u(4), 'chat',   'Seán: Leaving now, at yours in 5 Paul.', false, now() - interval '2 minutes'),
  (pg_temp.u(5), 'invite', 'Emma accepted your invitation to share the school run to Greenfield National School (Demo).', true, now() - interval '14 days'),
  (pg_temp.u(6), 'invite', 'Ciara Walsh invited you to share the school run to Greenfield National School (Demo).', false, now() - interval '1 hour'),
  (pg_temp.u(7), 'school', 'Rory Brennan joined Drumcondra Juniors U12s: away match in Raheny (Demo) on Scata.', false, now() - interval '3 days'),
  (pg_temp.u(12),'invite', 'Seán Kelly invited you to share trips to Drumcondra Juniors U12s: away match in Raheny (Demo).', false, now() - interval '1 day');

-- Make the notification wording match the actual swap slots picked above.
update public.notifications n
   set body = 'Niamh asked to swap: you’d take their ' || to_char(a.week_start + a.day, 'Dy DD Mon') || ' ' || case a.kind when 'drop' then 'drop-off' else 'pick-up' end
           || ' and they’d take your ' || to_char(b.week_start + b.day, 'Dy DD Mon') || ' ' || case b.kind when 'drop' then 'drop-off' else 'pick-up' end || '.'
  from swap_requests s join rota_slots a on a.id = s.give_slot join rota_slots b on b.id = s.take_slot
 where n.user_id = pg_temp.u(2) and n.kind = 'swap' and s.requester = pg_temp.u(4);

select 'Scata demo ready: 12 families, 1 school, 1 club trip. Password for every demo login: ScataDemo2026' as done;
