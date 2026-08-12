// =========================================================================
// hiring-interview-scheduler edge function
// =========================================================================
// Three jobs, one function:
//
//   mode="process_assessed"  (internal, shared_secret gated)
//     Scans hiring_candidates in status='assessed' that haven't been
//     processed yet. Runs verdict_assessment() per candidate:
//       - verdict='decline'            -> auto-decline + email
//       - verdict='consider' or 'pass' -> compute open interview slots on
//                                          Peter's calendar, generate a
//                                          booking link, email it
//
//   mode="get_offer"  (public, token gated)
//     Booking page calls this to find out who the token belongs to and
//     what slots are still open. Never exposes anything beyond first name,
//     position, and the slot list.
//
//   mode="claim_slot"  (public, token gated)
//     Candidate picked a time. Re-checks the calendar live (closes the
//     race between two candidates picking the same slot), creates the
//     calendar event with a fresh Google Meet link, emails confirmation.
//
// Candidates never see or touch Peter's calendar directly — only the
// slots this function computed and offered.
// =========================================================================

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, jsonResponse, corsJson, CORS_HEADERS, AGENCY_ID_DEFAULT, getSettings } from "../_shared/supabase.ts";
import { requireSharedSecret } from "../_shared/auth.ts";
import { callComposio } from "../_shared/composio.ts";
import { getComposioGmailCreds, sendGmail } from "../_shared/gmail.ts";
import { escHtml } from "../_shared/html.ts";

const TZ = "America/Chicago";
const CALENDAR_ID = "primary";
const INTERVIEW_MINUTES = 35;
const SLOT_GRID_MINUTES = 45; // interview + buffer
const DAY_START_HOUR = 9;     // 9:00 AM local
const DAY_END_HOUR = 16;      // last slot STARTS at 16:00 (ends 16:35)
const LOOKAHEAD_BUSINESS_DAYS = 10;
const SLOTS_TO_OFFER = 6;
const BOOKING_WINDOW_DAYS = 7; // link expiry
const BOOKING_BASE_URL = "https://newtworks.vercel.app/schedule";

function newToken(): string {
  const bytes = new Uint8Array(24);
  crypto.getRandomValues(bytes);
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// -------------------------------------------------------------------------
// Local-time <-> UTC helpers for America/Chicago, DST-aware via Intl.
// -------------------------------------------------------------------------
function chicagoOffsetMinutes(utcDate: Date): number {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const parts = dtf.formatToParts(utcDate).reduce((acc: any, p) => { acc[p.type] = p.value; return acc; }, {});
  const asUTC = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour === 24 ? 0 : +parts.hour, +parts.minute, +parts.second);
  return Math.round((asUTC - utcDate.getTime()) / 60000);
}

// Build a UTC Date for a given Chicago local Y/M/D H:M.
function chicagoLocalToUtc(y: number, m: number, d: number, h: number, min: number): Date {
  const approxUtc = new Date(Date.UTC(y, m - 1, d, h, min));
  const offset = chicagoOffsetMinutes(approxUtc);
  return new Date(approxUtc.getTime() - offset * 60000);
}

function isWeekend(y: number, m: number, d: number): boolean {
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  return dow === 0 || dow === 6;
}

// -------------------------------------------------------------------------
// Slot computation
// -------------------------------------------------------------------------
interface Slot { start: string; end: string; } // ISO UTC

function candidateSlotGrid(startFrom: Date): Slot[] {
  const grid: Slot[] = [];
  const nowChicago = new Intl.DateTimeFormat("en-US", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(startFrom).reduce((acc: any, p) => { acc[p.type] = p.value; return acc; }, {});
  let y = +nowChicago.year, m = +nowChicago.month, d = +nowChicago.day;
  // start tomorrow, local
  let cursor = new Date(Date.UTC(y, m - 1, d + 1));
  let daysAdded = 0;
  while (daysAdded < LOOKAHEAD_BUSINESS_DAYS) {
    const cy = cursor.getUTCFullYear(), cm = cursor.getUTCMonth() + 1, cd = cursor.getUTCDate();
    if (!isWeekend(cy, cm, cd)) {
      const dayStartMin = DAY_START_HOUR * 60;
      const dayEndMin = DAY_END_HOUR * 60; // last slot STARTS at this minute
      for (let minuteOfDay = dayStartMin; minuteOfDay <= dayEndMin; minuteOfDay += SLOT_GRID_MINUTES) {
        const actualHour = Math.floor(minuteOfDay / 60);
        const actualMinute = minuteOfDay % 60;
        const start = chicagoLocalToUtc(cy, cm, cd, actualHour, actualMinute);
        const end = new Date(start.getTime() + INTERVIEW_MINUTES * 60000);
        grid.push({ start: start.toISOString(), end: end.toISOString() });
      }
      daysAdded++;
    }
    cursor = new Date(cursor.getTime() + 24 * 3600 * 1000);
  }
  return grid;
}

function overlapsBusy(slot: Slot, busy: { start: string; end: string }[]): boolean {
  const s = new Date(slot.start).getTime();
  const e = new Date(slot.end).getTime();
  return busy.some((b) => {
    const bs = new Date(b.start).getTime();
    const be = new Date(b.end).getTime();
    return s < be && bs < e;
  });
}

async function fetchBusy(creds: { apiKey: string; userId: string; accountId: string }, timeMin: string, timeMax: string): Promise<{ start: string; end: string }[]> {
  const res = await callComposio({
    apiKey: creds.apiKey,
    userId: creds.userId,
    connectedAccountId: creds.accountId,
    toolSlug: "GOOGLECALENDAR_FREE_BUSY_QUERY",
    toolArguments: {
      timeMin, timeMax,
      items: [{ id: CALENDAR_ID }],
      timeZone: TZ,
    },
  });
  if (!res.ok) return [];
  const busy = res.data?.calendars?.[CALENDAR_ID]?.busy ?? res.data?.response_data?.calendars?.[CALENDAR_ID]?.busy ?? [];
  return Array.isArray(busy) ? busy : [];
}

async function getCalendarCreds(agencyId: string) {
  const map = await getSettings(agencyId, ["composio_api_key", "composio_user_id", "composio_googlecalendar_account_id"]);
  const apiKey = map["composio_api_key"];
  const userId = map["composio_user_id"];
  const accountId = map["composio_googlecalendar_account_id"];
  if (!apiKey || !userId || !accountId) return null;
  return { apiKey, userId, accountId };
}

async function computeOfferedSlots(agencyId: string): Promise<Slot[] | null> {
  const creds = await getCalendarCreds(agencyId);
  if (!creds) return null;
  const now = new Date();
  const grid = candidateSlotGrid(now);
  if (grid.length === 0) return [];
  const timeMin = grid[0].start;
  const timeMax = grid[grid.length - 1].end;
  const busy = await fetchBusy(creds, timeMin, timeMax);
  const free = grid.filter((s) => !overlapsBusy(s, busy));

  // Spread across distinct days: take up to 2 per day until we have enough.
  const byDay = new Map<string, Slot[]>();
  for (const s of free) {
    const dayKey = s.start.slice(0, 10);
    if (!byDay.has(dayKey)) byDay.set(dayKey, []);
    byDay.get(dayKey)!.push(s);
  }
  const offered: Slot[] = [];
  for (const [, daySlots] of byDay) {
    for (const s of daySlots.slice(0, 2)) {
      offered.push(s);
      if (offered.length >= SLOTS_TO_OFFER) break;
    }
    if (offered.length >= SLOTS_TO_OFFER) break;
  }
  return offered;
}

// -------------------------------------------------------------------------
// Email bodies
// -------------------------------------------------------------------------
function declineEmailHtml(firstName: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>Thank you for taking the time to complete our assessment and for your interest in joining our team. After reviewing your results, we've decided to move forward with other candidates for this role.</p>
<p>We know that takes real time and effort on your part, and we appreciate you putting it in. We wish you the very best in your search.</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

function inviteEmailHtml(firstName: string, bookingUrl: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>Thank you for completing our assessment — we'd like to move forward with an interview.</p>
<p>The interview is a video call (about 35 minutes) over Google Meet. Please pick a time that works for you:</p>
<p><a href="${escHtml(bookingUrl)}">${escHtml(bookingUrl)}</a></p>
<p>This link is valid for the next 7 days. Once you pick a time, you'll get a confirmation email with the Google Meet link.</p>
<p>Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

function confirmationEmailHtml(firstName: string, startLocal: string, meetUrl: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>You're confirmed for <strong>${escHtml(startLocal)}</strong> (Central time).</p>
<p>This will be a video call over Google Meet: <a href="${escHtml(meetUrl)}">${escHtml(meetUrl)}</a></p>
<p>A calendar invite is on its way to this email address as well. Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

// Naive "YYYY-MM-DDTHH:MM:SS" in Chicago local time — the format Composio's
// GOOGLECALENDAR_CREATE_EVENT actually wants paired with timezone param
// (verified live 2026-08-11; a Z-suffixed ISO string is NOT the tested path).
function toChicagoNaive(iso: string): string {
  const dtf = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, hour12: false,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  });
  const parts = dtf.formatToParts(new Date(iso)).reduce((acc: any, p) => { acc[p.type] = p.value; return acc; }, {});
  const hh = parts.hour === "24" ? "00" : parts.hour;
  return `${parts.year}-${parts.month}-${parts.day}T${hh}:${parts.minute}:${parts.second}`;
}

function formatChicago(iso: string): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, weekday: "long", month: "long", day: "numeric",
    hour: "numeric", minute: "2-digit",
  }).format(new Date(iso));
}

// -------------------------------------------------------------------------
// mode=process_assessed
// -------------------------------------------------------------------------
async function processAssessed(agencyId: string): Promise<Response> {
  const { data: candidates, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, position")
    .eq("agency_id", agencyId)
    .eq("status", "assessed")
    .eq("is_test_candidate", false)
    .is("decision_at", null)
    .is("interview_invite_token", null);
  if (error) return jsonResponse({ ok: false, error: error.message }, 500);

  const gmailCreds = await getComposioGmailCreds(agencyId);
  const results: any[] = [];

  for (const c of candidates ?? []) {
    const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
    const { data: verdictRows, error: vErr } = await sb.rpc("verdict_assessment", { p_candidate_id: c.id, p_role: null });
    if (vErr || !verdictRows || verdictRows.length === 0) {
      results.push({ id: c.id, name: c.candidate_name, action: "skipped", reason: vErr?.message || "no verdict" });
      continue;
    }
    const v = verdictRows[0];
    const verdict = v.verdict as string;

    if (verdict === "decline") {
      const { error: updErr } = await sb.from("hiring_candidates").update({
        status: "declined",
        decline_reason: "assessment_score",
        final_decision: "no_hire",
        decision_at: new Date().toISOString(),
        decision_notes: `Auto-declined — assessment composite ${v.composite} (${verdict}).`,
      }).eq("id", c.id);
      if (updErr) { results.push({ id: c.id, name: c.candidate_name, action: "decline_update_failed", error: updErr.message }); continue; }

      if (c.email && gmailCreds.ok) {
        const sendRes = await sendGmail({
          creds: gmailCreds.creds,
          to: c.email,
          subject: "Update on your application — Story Agency",
          html: declineEmailHtml(firstName),
        });
        results.push({ id: c.id, name: c.candidate_name, action: "declined", email_sent: sendRes.ok, composite: v.composite });
      } else {
        results.push({ id: c.id, name: c.candidate_name, action: "declined", email_sent: false, reason: "no email or gmail creds" });
      }
      continue;
    }

    if (verdict === "consider" || verdict === "pass") {
      if (!c.email) {
        results.push({ id: c.id, name: c.candidate_name, action: "skipped_invite", reason: "no email" });
        continue;
      }
      const slots = await computeOfferedSlots(agencyId);
      if (!slots) {
        results.push({ id: c.id, name: c.candidate_name, action: "skipped_invite", reason: "calendar creds missing" });
        continue;
      }
      const token = newToken();
      const expiresAt = new Date(Date.now() + BOOKING_WINDOW_DAYS * 24 * 3600 * 1000).toISOString();
      const { error: updErr } = await sb.from("hiring_candidates").update({
        status: "interview",
        interview_invite_token: token,
        interview_slots_offered: slots,
        interview_invite_sent_at: new Date().toISOString(),
        interview_booking_expires_at: expiresAt,
      }).eq("id", c.id);
      if (updErr) { results.push({ id: c.id, name: c.candidate_name, action: "invite_update_failed", error: updErr.message }); continue; }

      const bookingUrl = `${BOOKING_BASE_URL}/${token}`;
      let emailSent = false;
      if (gmailCreds.ok) {
        const sendRes = await sendGmail({
          creds: gmailCreds.creds,
          to: c.email,
          subject: "Next step: schedule your interview — Story Agency",
          html: inviteEmailHtml(firstName, bookingUrl),
        });
        emailSent = sendRes.ok;
      }
      results.push({ id: c.id, name: c.candidate_name, action: "invited", email_sent: emailSent, composite: v.composite, slots_offered: slots.length, booking_url: bookingUrl });
      continue;
    }

    results.push({ id: c.id, name: c.candidate_name, action: "skipped", reason: `unexpected verdict ${verdict}` });
  }

  return jsonResponse({ ok: true, processed: results.length, results });
}

// -------------------------------------------------------------------------
// mode=get_offer  (public, token-gated)
// -------------------------------------------------------------------------
async function getOffer(token: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("first_name, candidate_name, position, interview_slots_offered, interview_booking_expires_at, interview_booked_at, interview_scheduled_start, interview_meet_url")
    .eq("interview_invite_token", token)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "not_found" }, 404);

  if (c.interview_booked_at) {
    return corsJson({
      ok: true,
      already_booked: true,
      first_name: c.first_name || (c.candidate_name || "").split(" ")[0] || "there",
      scheduled_start: c.interview_scheduled_start,
      scheduled_start_display: formatChicago(c.interview_scheduled_start),
      meet_url: c.interview_meet_url,
    });
  }

  const expired = c.interview_booking_expires_at ? new Date(c.interview_booking_expires_at).getTime() < Date.now() : false;
  const slots = (c.interview_slots_offered as Slot[] | null) ?? [];
  return corsJson({
    ok: true,
    already_booked: false,
    expired,
    first_name: c.first_name || (c.candidate_name || "").split(" ")[0] || "there",
    position: c.position || null,
    slots: expired ? [] : slots.map((s) => ({ start: s.start, end: s.end, display: formatChicago(s.start) })),
  });
}

// -------------------------------------------------------------------------
// mode=claim_slot  (public, token-gated)
// -------------------------------------------------------------------------
async function claimSlot(agencyId: string, token: string, chosenStart: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, position, interview_slots_offered, interview_booking_expires_at, interview_booked_at")
    .eq("interview_invite_token", token)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "not_found" }, 404);
  if (c.interview_booked_at) return corsJson({ ok: false, error: "already_booked" }, 409);

  const expired = c.interview_booking_expires_at ? new Date(c.interview_booking_expires_at).getTime() < Date.now() : false;
  if (expired) return corsJson({ ok: false, error: "expired" }, 410);

  const offeredSlots = (c.interview_slots_offered as Slot[] | null) ?? [];
  const chosen = offeredSlots.find((s) => s.start === chosenStart);
  if (!chosen) return corsJson({ ok: false, error: "slot_not_offered" }, 400);

  const creds = await getCalendarCreds(agencyId);
  if (!creds) return corsJson({ ok: false, error: "calendar_unavailable" }, 500);

  // Re-check live — closes the race if this slot filled between offer and claim.
  const busy = await fetchBusy(creds, chosen.start, chosen.end);
  if (overlapsBusy(chosen, busy)) {
    const freshSlots = await computeOfferedSlots(agencyId);
    if (freshSlots) {
      await sb.from("hiring_candidates").update({ interview_slots_offered: freshSlots }).eq("id", c.id);
    }
    return corsJson({ ok: false, error: "slot_taken", slots: (freshSlots ?? []).map((s) => ({ start: s.start, end: s.end, display: formatChicago(s.start) })) }, 409);
  }

  const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
  const startLocalStr = formatChicago(chosen.start);

  const createRes = await callComposio({
    apiKey: creds.apiKey,
    userId: creds.userId,
    connectedAccountId: creds.accountId,
    toolSlug: "GOOGLECALENDAR_CREATE_EVENT",
    toolArguments: {
      calendar_id: CALENDAR_ID,
      summary: `Interview — ${c.candidate_name || firstName}${c.position ? " (" + c.position + ")" : ""}`,
      description: `Candidate interview scheduled via Newtworks self-booking.\nCandidate: ${c.candidate_name || firstName}\nPosition: ${c.position || "n/a"}`,
      start_datetime: toChicagoNaive(chosen.start),
      timezone: TZ,
      event_duration_hour: 0,
      event_duration_minutes: INTERVIEW_MINUTES,
      attendees: c.email ? [c.email] : [],
      create_meeting_room: true,
      exclude_organizer: false,
      send_updates: true,
    },
  });

  if (!createRes.ok) {
    return corsJson({ ok: false, error: "calendar_create_failed", detail: createRes.error }, 500);
  }
  const ev = createRes.data?.response_data ?? createRes.data ?? {};
  const meetUrl = ev.hangoutLink || ev.conferenceData?.entryPoints?.find((e: any) => e.entryPointType === "video")?.uri || null;
  const eventId = ev.id || null;

  const { error: updErr } = await sb.from("hiring_candidates").update({
    interview_scheduled_start: chosen.start,
    interview_scheduled_end: chosen.end,
    interview_calendar_event_id: eventId,
    interview_meet_url: meetUrl,
    interview_booked_at: new Date().toISOString(),
  }).eq("id", c.id);
  if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);

  if (c.email) {
    const gmailCreds = await getComposioGmailCreds(agencyId);
    if (gmailCreds.ok) {
      await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: "You're confirmed — interview scheduled",
        html: confirmationEmailHtml(firstName, startLocalStr, meetUrl || ""),
      });
    }
  }

  return corsJson({ ok: true, scheduled_start: chosen.start, scheduled_start_display: startLocalStr, meet_url: meetUrl });
}

// -------------------------------------------------------------------------
// Router
// -------------------------------------------------------------------------
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const agencyId = body.agency_id || AGENCY_ID_DEFAULT;
  const mode = body.mode;

  if (mode === "process_assessed") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    return await processAssessed(agencyId);
  }

  if (mode === "get_offer") {
    if (!body.token) return corsJson({ ok: false, error: "missing token" }, 400);
    return await getOffer(body.token);
  }

  if (mode === "claim_slot") {
    if (!body.token || !body.start) return corsJson({ ok: false, error: "missing token or start" }, 400);
    return await claimSlot(agencyId, body.token, body.start);
  }

  return jsonResponse({ ok: false, error: "unknown mode" }, 400);
});
