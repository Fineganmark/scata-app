# Scata

Safe, sustainable school commutes. A web app where schools invite parents, and parents share the school run.

The whole app is `index.html` (Preact + htm, no build step). `config.js` holds the Google Maps browser key and the Supabase project address and public (anon) key. Without a Maps key, the app shows drawn maps instead of Google Maps.

The site publishes to GitHub Pages on every push to `main` (`.github/workflows/pages.yml`).

Accounts and data live in Supabase (Postgres with row-level security, Auth and Realtime). `src/demo.html` is the earlier clickable mock-up with simulated parents.

## Database setup (once per Supabase project)

1. Supabase dashboard → SQL Editor → New query → paste all of `supabase/schema.sql` → Run. It is safe to run again after changes.
2. Authentication → URL Configuration: Site URL `https://fineganmark.github.io/scata-app/`, and add the same address under Redirect URLs.
3. Never put the `service_role` key or the database password in this repo; only the anon key belongs in `config.js`.

Before launch: set up custom SMTP (Authentication → Emails) because Supabase's built-in mailer only sends a few emails an hour, and add real payments for Scata Plus (it is free during the pilot).

## Editing

Edit `src/app.html` (or `src/demo.html` for the mock-up), then run `sh build.sh` to regenerate `index.html`.
