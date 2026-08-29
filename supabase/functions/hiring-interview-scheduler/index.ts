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
//   mode="schedule_meet_greet"  (admin, session-token gated)
//     The stage AFTER the interview, and it works the opposite way round:
//     Peter picks the time, because the meeting has to suit two or three
//     teammates as well as him. Creates one calendar event carrying the
//     candidate and the chosen teammates, moves the candidate to the
//     meet_and_greet stage, and emails the candidate.
//
// Candidates never see or touch Peter's calendar directly — only the
// slots this function computed and offered.
//
// The name says "interview" because that is what it did first. It is the
// hiring scheduler now — interviews and meet & greets both live here so the
// calendar, time-zone and email plumbing is written once.
// =========================================================================

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, jsonResponse, corsJson, CORS_HEADERS, AGENCY_ID_DEFAULT, getSettings, getSettingOrNull } from "../_shared/supabase.ts";
import { requireSharedSecret, requireOwnerOrManager } from "../_shared/auth.ts";
import { callComposio } from "../_shared/composio.ts";
import { getComposioGmailCreds, sendGmail } from "../_shared/gmail.ts";
import { escHtml } from "../_shared/html.ts";

const TZ = "America/Chicago";
const CALENDAR_ID = "primary";
const INTERVIEW_MINUTES = 35;
const LOOKAHEAD_DAYS = 45; // calendar days scanned forward for eligible slots
const BOOKING_WINDOW_DAYS = 7; // link expiry
const BOOKING_BASE_URL = "https://newtworks.vercel.app/schedule";

// Meet & greet defaults. The modal can override the length; the address is
// fixed and matches the one on the offer letter.
const MEET_GREET_DEFAULT_MINUTES = 30;
const OFFICE_ADDRESS = "28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260";

// Fixed weekly interview schedule (Chicago local time), per Peter directive
// 2026-08-12. getUTCDay()-style weekday numbering (0=Sun..6=Sat) applied to
// a date built from Chicago-local Y/M/D — same convention isWeekend() uses.
// Each day lists its offered start times in chronological order.
const FIXED_TIMES_BY_WEEKDAY: Record<number, { h: number; m: number }[]> = {
  1: [{ h: 10, m: 0 }, { h: 15, m: 30 }], // Monday
  2: [{ h: 10, m: 0 }, { h: 15, m: 30 }], // Tuesday
  3: [{ h: 10, m: 0 }],                   // Wednesday
  4: [{ h: 15, m: 30 }],                  // Thursday
  5: [{ h: 12, m: 30 }],                  // Friday (see isThirdFriday exclusion)
};

function isThirdFriday(y: number, m: number, d: number): boolean {
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  if (dow !== 5) return false;
  return Math.ceil(d / 7) === 3;
}

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
interface Slot { start: string; end: string; dateKey: string; } // dateKey = Chicago YYYY-MM-DD

interface ManualSlot { slot_date: string; start_time: string; end_time: string; }

async function fetchManualSlots(agencyId: string, fromDateKey: string, throughDateKey: string): Promise<ManualSlot[]> {
  const { data, error } = await sb
    .from("hiring_interview_manual_slots")
    .select("slot_date, start_time, end_time")
    .eq("agency_id", agencyId)
    .gte("slot_date", fromDateKey)
    .lte("slot_date", throughDateKey);
  if (error) return [];
  return (data ?? []) as ManualSlot[];
}

// Every fixed-schedule slot across the lookahead window, before filtering
// for blackouts or calendar busy — one row per (eligible day x fixed time),
// plus any manually-added one-off slots in the same window.
async function fixedScheduleGrid(startFrom: Date, agencyId: string): Promise<Slot[]> {
  const grid: Slot[] = [];
  const nowChicago = new Intl.DateTimeFormat("en-US", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(startFrom).reduce((acc: any, p) => { acc[p.type] = p.value; return acc; }, {});
  const y0 = +nowChicago.year, m0 = +nowChicago.month, d0 = +nowChicago.day;
  let cursor = new Date(Date.UTC(y0, m0 - 1, d0 + 1)); // start tomorrow, local
  for (let i = 0; i < LOOKAHEAD_DAYS; i++) {
    const cy = cursor.getUTCFullYear(), cm = cursor.getUTCMonth() + 1, cd = cursor.getUTCDate();
    const dow = cursor.getUTCDay();
    const times = FIXED_TIMES_BY_WEEKDAY[dow];
    if (times && !isThirdFriday(cy, cm, cd)) {
      const dateKey = `${cy}-${String(cm).padStart(2, "0")}-${String(cd).padStart(2, "0")}`;
      for (const t of times) {
        const start = chicagoLocalToUtc(cy, cm, cd, t.h, t.m);
        const end = new Date(start.getTime() + INTERVIEW_MINUTES * 60000);
        grid.push({ start: start.toISOString(), end: end.toISOString(), dateKey });
      }
    }
    cursor = new Date(cursor.getTime() + 24 * 3600 * 1000);
  }

  if (grid.length > 0) {
    const fromKey = grid[0].dateKey;
    const throughKey = grid[grid.length - 1].dateKey;
    const manual = await fetchManualSlots(agencyId, fromKey, throughKey);
    for (const m of manual) {
      const [h, min] = m.start_time.split(":").map(Number);
      const [eh, emin] = m.end_time.split(":").map(Number);
      const [y, mo, d] = m.slot_date.split("-").map(Number);
      const start = chicagoLocalToUtc(y, mo, d, h, min);
      const end = chicagoLocalToUtc(y, mo, d, eh, emin);
      grid.push({ start: start.toISOString(), end: end.toISOString(), dateKey: m.slot_date });
    }
    grid.sort((a, b) => a.start.localeCompare(b.start));
  }

  return grid;
}

function overlapsBusy(slot: { start: string; end: string }, busy: { start: string; end: string }[]): boolean {
  const s = new Date(slot.start).getTime();
  const e = new Date(slot.end).getTime();
  return busy.some((b) => {
    const bs = new Date(b.start).getTime();
    const be = new Date(b.end).getTime();
    return s < be && bs < e;
  });
}

interface Blackout { blackout_date: string; start_time: string | null; end_time: string | null; }
interface RecurringBlackout { weekday: number; start_time: string | null; end_time: string | null; starts_on: string; ends_on: string | null; }

async function fetchBlackouts(agencyId: string, fromDateKey: string, throughDateKey: string): Promise<Blackout[]> {
  const { data, error } = await sb
    .from("hiring_interview_blackouts")
    .select("blackout_date, start_time, end_time")
    .eq("agency_id", agencyId)
    .gte("blackout_date", fromDateKey)
    .lte("blackout_date", throughDateKey);
  if (error) return [];
  return (data ?? []) as Blackout[];
}

async function fetchRecurringBlackouts(agencyId: string, throughDateKey: string): Promise<RecurringBlackout[]> {
  const { data, error } = await sb
    .from("hiring_interview_recurring_blackouts")
    .select("weekday, start_time, end_time, starts_on, ends_on")
    .eq("agency_id", agencyId)
    .lte("starts_on", throughDateKey);
  if (error) return [];
  return (data ?? []) as RecurringBlackout[];
}

function matchesTimeWindow(slotLocalTimeStr: string, startTime: string | null, endTime: string | null): boolean {
  if (!startTime || !endTime) return true; // whole-day rule
  const [sh, sm] = slotLocalTimeStr.split(":").map(Number);
  const slotMin = sh * 60 + sm;
  const [bsh, bsm] = startTime.split(":").map(Number);
  const [beh, bem] = endTime.split(":").map(Number);
  return slotMin >= bsh * 60 + bsm && slotMin < beh * 60 + bem;
}

function isBlackedOut(slot: Slot, blackouts: Blackout[], recurring: RecurringBlackout[]): boolean {
  const slotLocalTime = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour12: false, hour: "2-digit", minute: "2-digit" }).format(new Date(slot.start));
  for (const b of blackouts) {
    if (b.blackout_date !== slot.dateKey) continue;
    if (matchesTimeWindow(slotLocalTime, b.start_time, b.end_time)) return true;
  }
  const weekday = ((): number => {
    const [y, m, d] = slot.dateKey.split("-").map(Number);
    return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  })();
  for (const r of recurring) {
    if (r.weekday !== weekday) continue;
    if (slot.dateKey < r.starts_on) continue;
    if (r.ends_on && slot.dateKey > r.ends_on) continue;
    if (matchesTimeWindow(slotLocalTime, r.start_time, r.end_time)) return true;
  }
  return false;
}

// Peter directive 2026-08-12: offer exactly three times, spaced out —
// first available day, skip a day, second offer, skip two days, final offer.
// "Skip N days" = N full calendar days pass untouched before resuming the
// search on day N+1 after the previous offer.
function pickThreeOffers(perDayEarliest: Slot[]): Slot[] {
  const byDateAsc = [...perDayEarliest].sort((a, b) => a.dateKey.localeCompare(b.dateKey));
  const findOnOrAfter = (dateKey: string): Slot | null =>
    byDateAsc.find((s) => s.dateKey >= dateKey) || null;
  const addDays = (dateKey: string, days: number): string => {
    const [y, m, d] = dateKey.split("-").map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d + days));
    return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth() + 1).padStart(2, "0")}-${String(dt.getUTCDate()).padStart(2, "0")}`;
  };

  const offers: Slot[] = [];
  const offer1 = byDateAsc[0];
  if (!offer1) return offers;
  offers.push(offer1);

  const offer2 = findOnOrAfter(addDays(offer1.dateKey, 2)); // skip 1 day
  if (offer2) {
    offers.push(offer2);
    const offer3 = findOnOrAfter(addDays(offer2.dateKey, 3)); // skip 2 days
    if (offer3) offers.push(offer3);
  }
  return offers;
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

async function getForwardEmail(agencyId: string): Promise<string | null> {
  return await getSettingOrNull(agencyId, "interview_calendar_forward_email");
}

async function computeOfferedSlots(agencyId: string): Promise<Slot[] | null> {
  const creds = await getCalendarCreds(agencyId);
  if (!creds) return null;
  const now = new Date();
  const grid = await fixedScheduleGrid(now, agencyId);
  if (grid.length === 0) return [];

  const timeMin = grid[0].start;
  const timeMax = grid[grid.length - 1].end;
  const [busy, blackouts, recurring] = await Promise.all([
    fetchBusy(creds, timeMin, timeMax),
    fetchBlackouts(agencyId, grid[0].dateKey, grid[grid.length - 1].dateKey),
    fetchRecurringBlackouts(agencyId, grid[grid.length - 1].dateKey),
  ]);

  const free = grid.filter((s) => !overlapsBusy(s, busy) && !isBlackedOut(s, blackouts, recurring));

  // Earliest available time per day (a day may offer two fixed times).
  const earliestPerDay = new Map<string, Slot>();
  for (const s of free) {
    const existing = earliestPerDay.get(s.dateKey);
    if (!existing || s.start < existing.start) earliestPerDay.set(s.dateKey, s);
  }

  return pickThreeOffers(Array.from(earliestPerDay.values()));
}

// -------------------------------------------------------------------------
// Email bodies
// -------------------------------------------------------------------------
const PREP_LINE = "This is an Interview AMA — please take some time beforehand to research Story Agency and State Farm, and come ready with your own questions for us.";

function inviteEmailHtml(firstName: string, bookingUrl: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>Thank you for completing our assessment — we'd like to move forward with an Interview AMA.</p>
<p>It's a video call (about 35 minutes) over Google Meet. Please pick a time that works for you:</p>
<p><a href="${escHtml(bookingUrl)}">${escHtml(bookingUrl)}</a></p>
<p>This link is valid for the next 7 days. Once you pick a time, you'll get a confirmation email with the Google Meet link.</p>
<p>Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

function confirmationEmailHtml(firstName: string, startLocal: string, meetUrl: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>You're confirmed for <strong>${escHtml(startLocal)}</strong> (Central time).</p>
<p>This will be a video call over Google Meet: <a href="${escHtml(meetUrl)}">${escHtml(meetUrl)}</a></p>
<p>${escHtml(PREP_LINE)}</p>
<p>A calendar invite is on its way to this email address as well. Looking forward to speaking with you.</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

function meetGreetEmailHtml(
  firstName: string,
  whenLocal: string,
  isVideo: boolean,
  locationText: string,
  meetUrl: string | null,
  note: string,
): string {
  const wherePara = isVideo
    ? `<p>It's a video call over Google Meet${meetUrl ? `: <a href="${escHtml(meetUrl)}">${escHtml(meetUrl)}</a>` : ""}.</p>`
    : `<p>We'll meet at our office:<br/>${escHtml(locationText)}</p>`;
  const notePara = note ? `<p>${escHtml(note)}</p>` : "";
  return `<p>Hi ${escHtml(firstName)},</p>
<p>Thank you for the conversation — we'd like you to meet the rest of the team.</p>
<p>You're set for <strong>${escHtml(whenLocal)}</strong> (Central time).</p>
${wherePara}
<p>This one is less formal than the interview. It's a chance for you to meet the people you'd be working alongside, and for them to meet you — so come with questions.</p>
${notePara}
<p>A calendar invite is on its way to this email address as well. If that time doesn't work, just reply to this email and we'll find another.</p>
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
async function processAssessed(agencyId: string, candidateId?: string): Promise<Response> {
  // candidateId narrows this to one person. The database trigger
  // trg_dispatch_assessed_candidate passes it whenever a candidate's status
  // lands on 'assessed', so the live path only ever touches the candidate who
  // just finished. Called without it, this still sweeps every eligible
  // candidate in 'assessed' -- deliberately left available, but nothing
  // schedules it, so a backlog is never processed by surprise.
  let query = sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, position")
    .eq("agency_id", agencyId)
    .eq("status", "assessed")
    .eq("is_test_candidate", false)
    .is("decision_at", null)
    .is("interview_invite_token", null);
  if (candidateId) query = query.eq("id", candidateId);
  const { data: candidates, error } = await query;
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

      // 2026-08-29: the decline letter is NOT sent from here any more. The
      // status write above fires trg_send_candidate_decline_notice, which owns
      // every decline letter for every path — one wording, one log, signed by
      // Peter rather than "Story Agency". Sending here as well produced two
      // different letters to the same person.
      results.push({ id: c.id, name: c.candidate_name, action: "declined", composite: v.composite, email: "queued by decline-notice trigger" });
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
          subject: "Next step: schedule your Interview AMA — Story Agency",
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
      prep_line: PREP_LINE,
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
    prep_line: PREP_LINE,
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

  // Re-check live — closes the race if this slot filled, or got blacked out,
  // between offer and claim.
  const dateKey = chosen.dateKey || chosen.start.slice(0, 10);
  const [busy, blackouts, recurring] = await Promise.all([
    fetchBusy(creds, chosen.start, chosen.end),
    fetchBlackouts(agencyId, dateKey, dateKey),
    fetchRecurringBlackouts(agencyId, dateKey),
  ]);
  if (overlapsBusy(chosen, busy) || isBlackedOut({ ...chosen, dateKey }, blackouts, recurring)) {
    const freshSlots = await computeOfferedSlots(agencyId);
    if (freshSlots) {
      await sb.from("hiring_candidates").update({ interview_slots_offered: freshSlots }).eq("id", c.id);
    }
    return corsJson({ ok: false, error: "slot_taken", slots: (freshSlots ?? []).map((s) => ({ start: s.start, end: s.end, display: formatChicago(s.start) })) }, 409);
  }

  const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
  const startLocalStr = formatChicago(chosen.start);

  const forwardEmail = await getForwardEmail(agencyId);
  const attendees = [...(c.email ? [c.email] : []), ...(forwardEmail ? [forwardEmail] : [])];

  const createRes = await callComposio({
    apiKey: creds.apiKey,
    userId: creds.userId,
    connectedAccountId: creds.accountId,
    toolSlug: "GOOGLECALENDAR_CREATE_EVENT",
    toolArguments: {
      calendar_id: CALENDAR_ID,
      summary: `Interview AMA — ${c.candidate_name || firstName}${c.position ? " (" + c.position + ")" : ""}`,
      description: `Candidate Interview AMA scheduled via Newtworks self-booking.\nCandidate: ${c.candidate_name || firstName}\nPosition: ${c.position || "n/a"}`,
      start_datetime: toChicagoNaive(chosen.start),
      timezone: TZ,
      event_duration_hour: 0,
      event_duration_minutes: INTERVIEW_MINUTES,
      attendees,
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
        subject: "You're confirmed — Interview AMA scheduled",
        html: confirmationEmailHtml(firstName, startLocalStr, meetUrl || ""),
      });
    }
  }

  return corsJson({ ok: true, scheduled_start: chosen.start, scheduled_start_display: startLocalStr, meet_url: meetUrl, prep_line: PREP_LINE });
}

// -------------------------------------------------------------------------
// mode=refresh_offer  (internal, shared_secret gated)
// -------------------------------------------------------------------------
// Recomputes and overwrites interview_slots_offered for candidates whose
// invite already went out under an older slot-selection algorithm — same
// booking link/token, no new email, just corrected options if they haven't
// booked yet. Extends the booking-link expiry from the refresh point.
async function refreshOffer(agencyId: string, candidateIds: string[]): Promise<Response> {
  const results: any[] = [];
  for (const id of candidateIds) {
    const { data: c, error } = await sb
      .from("hiring_candidates")
      .select("id, candidate_name, interview_invite_token, interview_booked_at")
      .eq("id", id)
      .eq("agency_id", agencyId)
      .maybeSingle();
    if (error || !c) { results.push({ id, action: "not_found" }); continue; }
    if (!c.interview_invite_token) { results.push({ id, name: c.candidate_name, action: "skipped_no_invite" }); continue; }
    if (c.interview_booked_at) { results.push({ id, name: c.candidate_name, action: "skipped_already_booked" }); continue; }

    const slots = await computeOfferedSlots(agencyId);
    if (!slots) { results.push({ id, name: c.candidate_name, action: "skipped_calendar_unavailable" }); continue; }

    const { error: updErr } = await sb.from("hiring_candidates").update({
      interview_slots_offered: slots,
      interview_booking_expires_at: new Date(Date.now() + BOOKING_WINDOW_DAYS * 24 * 3600 * 1000).toISOString(),
    }).eq("id", id);
    if (updErr) { results.push({ id, name: c.candidate_name, action: "update_failed", error: updErr.message }); continue; }

    results.push({ id, name: c.candidate_name, action: "refreshed", slots });
  }
  return jsonResponse({ ok: true, results });
}

// -------------------------------------------------------------------------
// mode=schedule_meet_greet  (admin, session-token gated)
// -------------------------------------------------------------------------
// The interview stage lets the candidate pick from slots this function
// computed. The meet & greet is the opposite: Peter picks the time (his
// ruling, 2026-08-21), because it has to suit two or three teammates as well
// as him. So there is no token, no offered-slot list and no booking window —
// just the one time he chose.
//
// One calendar event carries everyone. The candidate and each chosen teammate
// go on as attendees, so Google sends them all the invite and tracks their
// replies; the email to the candidate is separate and warmer than a bare
// calendar notification.
//
// The teammate rows are read back out of the database rather than trusted
// from the browser, so a page left open since last week cannot invite someone
// who has since left the team.
async function scheduleMeetGreet(agencyId: string, body: any): Promise<Response> {
  const candidateId = body.candidate_id;
  const startIso = body.start;
  const minutes = Number(body.duration_minutes) || MEET_GREET_DEFAULT_MINUTES;
  const isVideo = body.meeting_kind === "video";
  const preferPersonal = body.team_email_kind === "personal";
  const teamIds: string[] = Array.isArray(body.team_ids) ? body.team_ids : [];
  const note = typeof body.note === "string" ? body.note.trim() : "";

  if (!candidateId || !startIso) return corsJson({ ok: false, error: "missing candidate_id or start" }, 400);
  const startDate = new Date(startIso);
  if (Number.isNaN(startDate.getTime())) return corsJson({ ok: false, error: "bad start time" }, 400);
  if (!Number.isFinite(minutes) || minutes < 15 || minutes > 240) {
    return corsJson({ ok: false, error: "duration must be between 15 and 240 minutes" }, 400);
  }

  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, position")
    .eq("id", candidateId)
    .eq("agency_id", agencyId)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "candidate_not_found" }, 404);

  const creds = await getCalendarCreds(agencyId);
  if (!creds) return corsJson({ ok: false, error: "calendar_unavailable" }, 500);

  const endDate = new Date(startDate.getTime() + minutes * 60000);
  const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
  const whenLocal = formatChicago(startDate.toISOString());
  const locationText = isVideo ? "Google Meet" : OFFICE_ADDRESS;

  // Teammates, live from the team table.
  let teamRows: any[] = [];
  if (teamIds.length > 0) {
    const { data: t } = await sb
      .from("team")
      .select("id, first_name, last_name, nickname, email_sf, email_personal")
      .eq("agency_id", agencyId)
      .eq("is_active", true)
      .in("id", teamIds);
    teamRows = t ?? [];
  }
  const teamAttendees = teamRows
    .map((m: any) => ({
      team_id: m.id,
      name: `${m.nickname || m.first_name || ""} ${m.last_name || ""}`.trim(),
      email: preferPersonal
        ? (m.email_personal || m.email_sf)
        : (m.email_sf || m.email_personal),
    }))
    .filter((a: any) => !!a.email);

  const forwardEmail = await getForwardEmail(agencyId);
  const attendees = [
    ...(c.email ? [c.email] : []),
    ...teamAttendees.map((a: any) => a.email),
    ...(forwardEmail ? [forwardEmail] : []),
  ].filter((e, i, arr) => arr.indexOf(e) === i);

  // Soft conflict check. Peter chose this time on purpose, so a clash is not a
  // reason to refuse — but it IS worth saying out loud, because the calendar
  // he is booking is not the one he is usually looking at.
  const busy = await fetchBusy(creds, startDate.toISOString(), endDate.toISOString());
  const conflict = overlapsBusy({ start: startDate.toISOString(), end: endDate.toISOString() }, busy);

  const whoLine = teamAttendees.length > 0
    ? teamAttendees.map((a: any) => a.name).filter(Boolean).join(", ")
    : "no other teammates selected";

  const createRes = await callComposio({
    apiKey: creds.apiKey,
    userId: creds.userId,
    connectedAccountId: creds.accountId,
    toolSlug: "GOOGLECALENDAR_CREATE_EVENT",
    toolArguments: {
      calendar_id: CALENDAR_ID,
      summary: `Meet & Greet — ${c.candidate_name || firstName}${c.position ? " (" + c.position + ")" : ""}`,
      description: `Team meet & greet, scheduled from Newtworks.\nCandidate: ${c.candidate_name || firstName}\nPosition: ${c.position || "n/a"}\nTeam: ${whoLine}\nWhere: ${locationText}${note ? `\n\nNote to candidate: ${note}` : ""}`,
      // The address goes in the description as well as the location field —
      // if Composio ever stops passing location through, the candidate can
      // still read where to go.
      location: locationText,
      start_datetime: toChicagoNaive(startDate.toISOString()),
      timezone: TZ,
      event_duration_hour: Math.floor(minutes / 60),
      event_duration_minutes: minutes % 60,
      attendees,
      create_meeting_room: isVideo,
      exclude_organizer: false,
      send_updates: true,
    },
  });

  if (!createRes.ok) {
    return corsJson({ ok: false, error: "calendar_create_failed", detail: createRes.error }, 500);
  }
  const ev = createRes.data?.response_data ?? createRes.data ?? {};
  const meetUrl = isVideo
    ? (ev.hangoutLink || ev.conferenceData?.entryPoints?.find((e: any) => e.entryPointType === "video")?.uri || null)
    : null;
  const eventId = ev.id || null;

  const { error: updErr } = await sb.from("hiring_candidates").update({
    status: "meet_and_greet",
    status_updated_at: new Date().toISOString(),
    meet_greet_scheduled_start: startDate.toISOString(),
    meet_greet_scheduled_end: endDate.toISOString(),
    meet_greet_calendar_event_id: eventId,
    meet_greet_meet_url: meetUrl,
    meet_greet_location: locationText,
    meet_greet_attendees: teamAttendees,
    meet_greet_invited_at: new Date().toISOString(),
  }).eq("id", c.id);
  if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);

  // The calendar invite already went to the candidate. This is the human note
  // that goes with it, and it is best-effort: the meeting is booked either
  // way, so a mail failure is reported rather than rolled back.
  let emailed = false;
  let emailError: string | null = null;
  if (c.email) {
    const gmailCreds = await getComposioGmailCreds(agencyId);
    if (gmailCreds.ok) {
      const sendRes = await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: "You're set — meet the team",
        html: meetGreetEmailHtml(firstName, whenLocal, isVideo, locationText, meetUrl, note),
      });
      emailed = sendRes.ok;
      if (!sendRes.ok) emailError = sendRes.error;
    } else {
      emailError = gmailCreds.error;
    }
  } else {
    emailError = "candidate has no email address on file";
  }

  return corsJson({
    ok: true,
    scheduled_start: startDate.toISOString(),
    scheduled_end: endDate.toISOString(),
    scheduled_display: whenLocal,
    location: locationText,
    meet_url: meetUrl,
    calendar_event_id: eventId,
    attendees: teamAttendees,
    emailed,
    email_error: emailError,
    calendar_conflict: conflict,
  });
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
    return await processAssessed(agencyId, body.candidate_id || undefined);
  }

  if (mode === "refresh_offer") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    if (!Array.isArray(body.candidate_ids) || body.candidate_ids.length === 0) {
      return jsonResponse({ ok: false, error: "missing candidate_ids array" }, 400);
    }
    return await refreshOffer(agencyId, body.candidate_ids);
  }

  if (mode === "get_offer") {
    if (!body.token) return corsJson({ ok: false, error: "missing token" }, 400);
    return await getOffer(body.token);
  }

  if (mode === "claim_slot") {
    if (!body.token || !body.start) return corsJson({ ok: false, error: "missing token or start" }, 400);
    return await claimSlot(agencyId, body.token, body.start);
  }

  if (mode === "schedule_meet_greet") {
    // Fired from the candidate page in the app, so the gate is the caller's
    // own session rather than a shared secret — see requireOwnerOrManager.
    const denied = await requireOwnerOrManager(req, agencyId);
    if (denied) return denied;
    return await scheduleMeetGreet(agencyId, body);
  }

  return jsonResponse({ ok: false, error: "unknown mode" }, 400);
});
