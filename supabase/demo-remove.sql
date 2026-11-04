-- Scata demo: removes every demo account, group, rota, chat and notification made by demo-seed.sql.
-- Real accounts and groups are not touched. Paste into Supabase > SQL Editor and click Run.
delete from public.hubs where id::text like 'de300000-0000-4000-8000-%';
delete from auth.users where id::text like 'de300000-0000-4000-8000-%' or email like 'demo.%@example.com';
select 'Scata demo data removed' as done;
