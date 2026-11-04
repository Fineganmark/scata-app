-- Scata demo: moves Seán's car one step along the school run (home → Paul's → Greenfield NS).
-- Run it in Supabase > SQL Editor just before you show live tracking, and again to move the car on.
-- Anyone in Seán's car pool with Scata Plus (log in as Paul) sees the car move without refreshing.
do $$
declare
  route double precision[][] := array[
    [53.3741, -6.2482], [53.3748, -6.2490], [53.3756, -6.2499], [53.3763, -6.2506], [53.3769, -6.2511],
    [53.3760, -6.2525], [53.3748, -6.2538], [53.3735, -6.2549], [53.3722, -6.2558], [53.3712, -6.2563]];
  g uuid := 'de300000-0000-4000-8000-200000000001';
  sean uuid := 'de300000-0000-4000-8000-000000000002';
  cur record; best int := 0; bestd double precision := 1e9; i int; d double precision; nxt int;
begin
  select * into cur from public.locations where group_id = g and parent_id = sean;
  if cur is not null then
    for i in 1..array_length(route, 1) loop
      d := (route[i][1] - cur.lat) ^ 2 + (route[i][2] - cur.lng) ^ 2;
      if d < bestd then bestd := d; best := i; end if;
    end loop;
  end if;
  nxt := case when best = 0 or best = array_length(route, 1) then 1 else best + 1 end;
  insert into public.locations (group_id, parent_id, lat, lng, updated_at)
  values (g, sean, route[nxt][1], route[nxt][2], now())
  on conflict (group_id, parent_id) do update set lat = excluded.lat, lng = excluded.lng, updated_at = excluded.updated_at;
  raise notice 'Seán is at stop % of %', nxt, array_length(route, 1);
end $$;
