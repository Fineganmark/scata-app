# Scata

Safe, sustainable school commutes. Schools, sports clubs or parents set up a group, invite families, and families share the trips there (school runs, lifts to training, and so on). A family can belong to several groups.

The whole app is `index.html` (Preact + htm, no build step). `config.js` holds the Google Maps browser key and the Supabase project address and public (anon) key. Without a Maps key, the app shows drawn maps instead of Google Maps.

The site publishes to GitHub Pages on every push to `main` (`.github/workflows/pages.yml`).

Accounts and data live in Supabase (Postgres with row-level security, Auth and Realtime). `src/demo.html` is the earlier clickable mock-up with simulated parents.

## Database setup (once per Supabase project)

1. Supabase dashboard → SQL Editor → New query → paste all of `supabase/schema.sql` → Run. It is safe to run again after changes.
2. Authentication → URL Configuration: Site URL `https://fineganmark.github.io/scata-app/`, and add the same address followed by `**` under Redirect URLs (for example `https://fineganmark.github.io/scata-app/**`), so the sign-up email can bring people back with their group code.
3. Make yourself a Scata admin (opens the **Scata admin** panel in the menu: every account and group, Plus on/off, delete test accounts and groups). In the SQL Editor run, with the email you sign in with:
   `update public.profiles set is_admin = true where id = (select id from auth.users where email = 'you@example.com');`
   Sign in to the app and add your name first, so your profile exists.
4. Optional, for the morning reminders about rota slots nobody has confirmed: Database → Extensions → turn on `pg_cron`, then run `supabase/schema.sql` again. Without it, the reminders still go out whenever someone in the commute opens the rota.
5. Never put the `service_role` key or the database password in this repo; only the anon key belongs in `config.js`.

## Email (invites, sign-up confirmations, password resets)

Supabase's built-in mailer only delivers to people on your Supabase team and only a few an hour, so real parents get nothing until this is set up. Scata uses [Resend](https://resend.com) for all email.

1. **Resend:** create an account, then Domains → Add domain → `scata.mobilitymanagement.ie` (or `mobilitymanagement.ie`). Add the DNS records it shows at your domain registrar and wait for "Verified". Then API Keys → Create API key (Sending access).
2. **Account emails (Supabase Auth):** Authentication → Emails → SMTP Settings → enable custom SMTP. Host `smtp.resend.com`, port `465`, username `resend`, password = the Resend API key, sender e.g. `invites@scata.mobilitymanagement.ie`, sender name `Scata`.
3. **Group invite emails (Edge Function):** Edge Functions → Deploy a new function → Via Editor. Name it `send-invites`, paste all of `supabase/functions/send-invites/index.ts`, and deploy. Then Edge Functions → Secrets, add:
   - `RESEND_API_KEY` = the Resend API key
   - `INVITE_FROM` = `Scata <invites@scata.mobilitymanagement.ie>`
4. Re-run `supabase/schema.sql` (adds `hub_invites.sent_at`).

When a group admin presses **Send invites**, the app calls `send-invites`, which checks they manage the group, saves the invites and emails each person their join link and group code. If the function isn't deployed or Resend refuses, the invites are still saved and the app offers to open the admin's own email app instead.

Before launch: add real payments for Scata Plus (it is free during the pilot).

## Editing

Edit `src/app.html` (or `src/demo.html` for the mock-up), then run `sh build.sh` to regenerate `index.html`.

`terms.html` is the draft terms of use, safety and privacy page that the app links to. Have it reviewed before a wider launch.
