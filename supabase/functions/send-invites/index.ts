// Scata: email group invites.
// Called by the app when a group admin invites people by email. It checks the caller
// manages the group, records the invites, and emails each person through Resend.
//
// Secrets (Supabase dashboard → Edge Functions → Secrets):
//   RESEND_API_KEY  your Resend API key (re_...)
//   INVITE_FROM     sender, e.g. "Scata <invites@scata.mobilitymanagement.ie>" (a domain verified in Resend)
//   SITE_URL        optional, defaults to https://fineganmark.github.io/scata-app/
// SUPABASE_URL and SUPABASE_ANON_KEY are provided automatically.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const RUN: Record<string, string> = { school: 'school run', sport: 'lifts to and from the club', other: 'trips' };
const MAX = 50; // emails per request
const RESEND_AGAIN_AFTER_MS = 10 * 60 * 1000; // don't email the same person twice within 10 minutes
const esc = (s: string) => s.replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
const emailOk = (e: string) => /^[^\s@,;<>"]+@[^\s@,;<>"]+\.[^\s@,;<>"]+$/.test(e);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply(405, { error: 'Use POST' });

  const key = Deno.env.get('RESEND_API_KEY');
  const from = Deno.env.get('INVITE_FROM');
  if (!key || !from) return reply(503, { error: 'Email sending isn’t set up yet (RESEND_API_KEY / INVITE_FROM missing).', code: 'not_configured' });
  const site = Deno.env.get('SITE_URL') || 'https://fineganmark.github.io/scata-app/';

  // Act as the signed-in user so the database's own rules decide what they may do.
  const auth = req.headers.get('Authorization') || '';
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
  const { data: u } = await db.auth.getUser(auth.replace(/^Bearer\s+/i, ''));
  if (!u?.user) return reply(401, { error: 'Please sign in again.' });

  let body: { hub_id?: string; emails?: string[] };
  try { body = await req.json(); } catch { return reply(400, { error: 'Bad request' }); }
  const hubId = String(body.hub_id || '');
  const emails = [...new Set((body.emails || []).map(e => String(e).trim().toLowerCase()).filter(Boolean))];
  if (!hubId || !emails.length) return reply(400, { error: 'Nothing to send' });
  if (emails.length > MAX) return reply(400, { error: `Send at most ${MAX} invites at a time.` });
  const bad = emails.filter(e => !emailOk(e));
  if (bad.length) return reply(400, { error: `Check ${bad.join(', ')}: that isn’t an email address` });

  const { data: allowed } = await db.rpc('can_manage_hub', { h: hubId });
  if (!allowed) return reply(403, { error: 'Only the group’s admins can send invites.' });
  const { data: hub } = await db.from('hubs').select('name, code, kind').eq('id', hubId).single();
  if (!hub) return reply(404, { error: 'Group not found' });
  const { data: me } = await db.from('profiles').select('first_name, last_name').eq('id', u.user.id).single();
  const inviter = [me?.first_name, me?.last_name].filter(Boolean).join(' ') || 'A parent';

  // Record the invites (the "admin invites" rule only lets group admins do this).
  const { error: upErr } = await db.from('hub_invites').upsert(emails.map(email => ({ hub_id: hubId, email })), { onConflict: 'hub_id,email', ignoreDuplicates: true });
  if (upErr) return reply(400, { error: upErr.message });

  // Skip anyone emailed in the last few minutes, so a double tap doesn't send twice.
  const { data: rows } = await db.from('hub_invites').select('email, sent_at').eq('hub_id', hubId).in('email', emails);
  const recent = new Set((rows || []).filter(r => r.sent_at && Date.now() - Date.parse(r.sent_at) < RESEND_AGAIN_AFTER_MS).map(r => r.email));
  const to = emails.filter(e => !recent.has(e));

  const link = `${site}${site.includes('?') ? '&' : '?'}join=${encodeURIComponent(hub.code)}`;
  const run = RUN[hub.kind] || RUN.other;
  const subject = `${inviter} invited you to join ${hub.name} on Scata`;
  const text = `Hello,\n\n${inviter} has invited you to join ${hub.name} on Scata, so families can share the ${run} safely.\n\nJoin here: ${link}\nOr sign up at ${site} and enter the group code ${hub.code}.\n\nYou got this email because ${inviter} added your address. If you weren't expecting it, you can ignore it.\n\nScata`;
  const htmlBody = `<div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;font-size:16px;line-height:1.5;color:#1d2330;max-width:520px">
<p>Hello,</p>
<p><b>${esc(inviter)}</b> has invited you to join <b>${esc(hub.name)}</b> on Scata, so families can share the ${esc(run)} safely.</p>
<p style="margin:28px 0"><a href="${esc(link)}" style="background:#1f7a4d;color:#fff;text-decoration:none;padding:12px 22px;border-radius:10px;font-weight:600;display:inline-block">Join ${esc(hub.name)}</a></p>
<p>Or sign up at <a href="${esc(site)}">${esc(site)}</a> and enter the group code <b>${esc(hub.code)}</b>.</p>
<p style="color:#6b7280;font-size:13px;margin-top:32px">You got this email because ${esc(inviter)} added your address in Scata. If you weren't expecting it, you can ignore it.</p>
</div>`;

  const sent: string[] = [];
  const failed: string[] = [];
  if (to.length) {
    // One email per person (no shared To/CC list), sent as a single batch.
    const res = await fetch('https://api.resend.com/emails/batch', {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(to.map(email => ({ from, to: [email], subject, text, html: htmlBody, reply_to: u.user!.email }))),
    });
    if (res.ok) sent.push(...to);
    else {
      failed.push(...to);
      const detail = await res.text();
      console.error('Resend error', res.status, detail);
      return reply(502, { error: 'The email service refused the invites. Check the Resend settings.', detail, sent, failed });
    }
    await db.from('hub_invites').update({ sent_at: new Date().toISOString() }).eq('hub_id', hubId).in('email', sent);
  }
  return reply(200, { sent, skipped: [...recent] });
});
