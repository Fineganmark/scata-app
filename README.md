# Scata

Safe, sustainable school commutes. Schools, sports clubs or parents set up a group, invite families, and families share the trips there (school runs, lifts to training, and so on). A family can belong to several groups.

The whole app is `index.html` (Preact + htm, no build step). `config.js` holds the Google Maps browser key and the Supabase project address and public (anon) key. Without a Maps key, the app shows drawn maps instead of Google Maps.

The site publishes to GitHub Pages on every push to `main` (`.github/workflows/pages.yml`).

Accounts and data live in Supabase (Postgres with row-level security, Auth and Realtime). `src/demo.html` is the earlier clickable mock-up with simulated parents.

## Database setup (once per Supabase project)

1. Supabase dashboard → SQL Editor → New query → paste all of `supabase/schema.sql` → Run. It is safe to run again after changes.
2. Authentication → URL Configuration: Site URL `https://fineganmark.github.io/scata-app/`, and add the same address under Redirect URLs.
3. Make yourself a Scata admin (opens the **Scata admin** panel in the menu: every account and group, Plus on/off, delete test accounts and groups). In the SQL Editor run, with the email you sign in with:
   `update public.profiles set is_admin = true where id = (select id from auth.users where email = 'you@example.com');`
   Sign in to the app and add your name first, so your profile exists.
4. Never put the `service_role` key or the database password in this repo; only the anon key belongs in `config.js`.

Before launch: set up custom SMTP (Authentication → Emails) because Supabase's built-in mailer only sends a few emails an hour, and add real payments for Scata Plus (it is free during the pilot).

## Demo data

For demos, `supabase/demo-seed.sql` adds a made-up school (Greenfield National School), a sports club away match, and twelve families with rotas, chat, a swap request and a car on the live map. Run it in the SQL Editor after `schema.sql`; it rebuilds everything around today's date, so run it again on the morning of a demo. Every demo login (`demo.principal@example.com`, `demo.sean@example.com`, `demo.paul@example.com`, `demo.niamh@example.com`, `demo.ciara@example.com`, `demo.david@example.com`, `demo.coach@example.com`) uses the password `ScataDemo2026`. `supabase/demo-drive.sql` moves Seán's car one step along the school run; `supabase/demo-remove.sql` takes all demo data out.

## Editing

Edit `src/app.html` (or `src/demo.html` for the mock-up), then run `sh build.sh` to regenerate `index.html`.
