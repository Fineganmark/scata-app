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

## How families are grouped (from 19 Nov 2026)

- **Who can join a group:** open (anyone with the link), approval (an admin approves each family; people invited by email go straight in) or invite only (only invited emails). New groups default to approval; groups that existed before keep working as open.
- **Commutes:** a parent starts a commute and invites families they know (search by name, or a friend link that still needs their OK). Scata suggests families on the same route to fill spare places, and families with no commute are offered ones with room or go on the waiting list. Both sides say yes before anyone joins. For 24 hours after a suggested family joins, the others can object.
- **Size:** car commutes hold up to 4 families, and only as many children as the smallest car fits (each family's own children plus the seats it offers). Walking, cycling and bus groups hold up to 12 children, with a second adult on each trip above 6.
- **One commute per trip:** a family shares each trip in one commute at most: one commute for both, or one for drop-offs and another for pick-ups.
- **Matching (straight-line estimates, no routing service):** cars within 1.5 km, walking, cycling and bus within 500 m, heading the same way to the group (within 30°), and under 5 minutes' detour for cars. Limits double for an invite-only list of under 40 families, and again when a parent widens their search.
- **Rota:** each trip goes to the family most due one. A running tally of trips owed and done carries over from week to week, trips a family says it can't do go to others when possible, and nobody gets two trips at once.
- **Admins** see invited, joined, in a group and waiting, and can suggest a waiting family for a commute with room.

**Undo:** `supabase/rollback/2026-11-19-allocation-rollback.sql` puts the database back to how it was before this change (take a Supabase backup first, and revert the app too). Its header lists what is lost.

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
