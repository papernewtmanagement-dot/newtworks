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
//   mode="send_reminders"  (internal, shared_secret gated)
//     Run once a day (7:59 Central, automation recipe "Interview Reminders").
//     Two touches per booked interview, per Steiner et al. 2018 (Am J Manag
//     Care 24:377) where reminders three days and one day out beat either
//     alone: a confirm-or-reschedule email three days before, and a reminder
//     the day before. Both carry Yes / Reschedule / No-longer-interested
//     links. Morning of, still unconfirmed -> Telegram DM to the owner.
//     The same run offers earlier open times to anyone booked further out.
//
//   mode="rebook"  (public, token gated)
//     A booked candidate takes an earlier open time.
//
//   mode="release_booking"  (internal, shared_secret gated)
//     Fired by the hiring_candidates trigger when a booked candidate is
//     declined: cancels the calendar event and frees the slot. The candidate
//     gets the Google cancellation notice.
//
//   mode="offer_earlier"  (internal, shared_secret gated)
//     Emails booked candidates whose interview is still days away when an
//     open time exists at least a day earlier than what they hold.
//
//   mode="respond"  (public, token gated)
//     The candidate answered a reminder link. confirm stamps the
//     confirmation; reschedule cancels the calendar event, frees the slot
//     and re-offers times; withdraw frees the slot and declines the
//     candidate as candidate_withdrew.
//
//   mode="calendar_busy"  (admin, session-token gated)
//     Busy Google Calendar events in a date range, so the Interview Slots
//     calendar can show which slots are being knocked out and by what.
//
//   mode="move_bookings"  (admin session or shared_secret)
//     Unbooks everyone in a date range (a week just closed), emails them
//     why, and hands them fresh times.
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
import { ensureWatcherTask } from "../_shared/watchers.ts";

const TZ = "America/Chicago";
const CALENDAR_ID = "primary";
const INTERVIEW_MINUTES = 30;
const LOOKAHEAD_DAYS = 45; // calendar days scanned forward for eligible slots
const BOOKING_WINDOW_DAYS = 7; // link expiry
const BOOKING_BASE_URL = "https://newtworks.vercel.app/schedule";

// Meet & greet defaults. The modal can override the length; the address is
// fixed and matches the one on the offer letter.
const MEET_GREET_DEFAULT_MINUTES = 30;
const OFFICE_ADDRESS = "28120 US Hwy 281 N, Suite 125, San Antonio, TX 78260";

// The interview slot schedule (weekly times, backup times, Friday rules, vacation weeks, manual slots, blackouts)
// lives in one place: SQL public.interview_slot_grid. This function, the Interview Slots page and the onboarding
// coaching blocks all read it there (Peter 2026-10-04: one function per job). Backup (secondary) times are only
// offered once the main times inside the 7-day offer window are booked (see pickOffers).
type SlotTier = "primary" | "secondary";
const OFFER_COUNT = 4;        // how many open times a candidate is shown
const OFFER_WINDOW_DAYS = 7;  // ... drawn from the next 7 days



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
interface Slot { start: string; end: string; dateKey: string; tier?: SlotTier; blackedOut?: boolean; } // dateKey = Chicago YYYY-MM-DD

// Every slot between two Chicago dates from SQL public.interview_slot_grid, blacked-out ones flagged. Null when the
// database can't be read.
async function slotGrid(agencyId: string, fromDateKey: string, throughDateKey: string): Promise<Slot[] | null> {
  const { data, error } = await sb.rpc("interview_slot_grid", { p_agency_id: agencyId, p_from: fromDateKey, p_to: throughDateKey });
  if (error) { console.error("interview_slot_grid failed:", error.message); return null; }
  return (data ?? []).map((r: any) => ({
    start: new Date(r.start_at).toISOString(),
    end: new Date(r.end_at).toISOString(),
    dateKey: String(r.slot_date),
    tier: r.tier as SlotTier,
    blackedOut: !!r.blacked_out,
  }));
}

// Every slot across the lookahead window, starting tomorrow (Chicago), before filtering for calendar busy.
async function fixedScheduleGrid(startFrom: Date, agencyId: string): Promise<Slot[]> {
  const [y0, m0, d0] = chicagoDateKey(startFrom).split("-").map(Number);
  const first = new Date(Date.UTC(y0, m0 - 1, d0 + 1));
  const last = new Date(first.getTime() + (LOOKAHEAD_DAYS - 1) * 86400000);
  return (await slotGrid(agencyId, first.toISOString().slice(0, 10), last.toISOString().slice(0, 10))) ?? [];
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


// Peter directive 2026-09-11: offer the next four open times inside seven
// days. Primary times first; backup (secondary) times only once the primary
// times in the window are used up; and if the whole window is full, the
// earliest primary times beyond it so the candidate is never shown nothing.
function pickOffers(free: Slot[], now: Date): Slot[] {
  const windowEnd = new Date(now.getTime() + OFFER_WINDOW_DAYS * 24 * 3600 * 1000).toISOString();
  const byStart = [...free].sort((a, b) => a.start.localeCompare(b.start));
  const inWindow = (s: Slot) => s.start <= windowEnd;
  const offers: Slot[] = [];
  const take = (pool: Slot[]) => {
    for (const s of pool) {
      if (offers.length >= OFFER_COUNT) break;
      if (!offers.some((o) => o.start === s.start)) offers.push(s);
    }
  };
  take(byStart.filter((s) => s.tier !== "secondary" && inWindow(s)));
  take(byStart.filter((s) => s.tier === "secondary" && inWindow(s)));
  take(byStart.filter((s) => s.tier !== "secondary" && !inWindow(s)));
  return offers.sort((a, b) => a.start.localeCompare(b.start));
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

// Every open slot in the lookahead window: template minus calendar-busy
// minus blackouts. computeOfferedSlots narrows this to what a candidate is
// shown; earlier-time offers and rebooking read it directly.
async function computeFreeSlots(agencyId: string): Promise<Slot[] | null> {
  const creds = await getCalendarCreds(agencyId);
  if (!creds) return null;
  const now = new Date();
  const grid = await fixedScheduleGrid(now, agencyId);
  if (grid.length === 0) return [];

  const busy = await fetchBusy(creds, grid[0].start, grid[grid.length - 1].end);
  return grid.filter((s) => !s.blackedOut && !overlapsBusy(s, busy));
}

async function computeOfferedSlots(agencyId: string): Promise<Slot[] | null> {
  const free = await computeFreeSlots(agencyId);
  if (!free) return null;
  return pickOffers(free, new Date());
}

// Open times a booked candidate could move up to: inside the offer window,
// at least a day earlier than what they hold, primary times before backups,
// four at most. Empty when nothing earlier is open.
function earlierOptions(free: Slot[], currentStart: string, now: Date): Slot[] {
  const cutoff = new Date(new Date(currentStart).getTime() - 24 * 3600 * 1000).toISOString();
  const earlier = free.filter((s) => s.start <= cutoff && s.start > now.toISOString());
  return pickOffers(earlier, now).filter((s) => s.start <= cutoff);
}

const toDisplay = (s: Slot) => ({ start: s.start, end: s.end, display: formatChicago(s.start) });

// -------------------------------------------------------------------------
// Email bodies
// -------------------------------------------------------------------------
// Every candidate letter is a row in public.hiring_email_templates. Peter reads
// and edits them in the app under Team > Growth > Email Templates, and the
// {{tokens}} get filled in here. Nothing is hardcoded on purpose: a copy kept
// in this file would quietly win over whatever he last saved.

type Tpl = { subject: string; body: string };
let tplCache: { at: number; map: Map<string, Tpl> } | null = null;
const TPL_TTL_MS = 30_000;

async function loadTemplates(agencyId: string): Promise<Map<string, Tpl>> {
  if (tplCache && Date.now() - tplCache.at < TPL_TTL_MS) return tplCache.map;
  const { data, error } = await sb
    .from("hiring_email_templates")
    .select("template_key, subject, body_html")
    .eq("agency_id", agencyId);
  if (error) throw new Error(`hiring_email_templates unreadable: ${error.message}`);
  const map = new Map<string, Tpl>();
  for (const r of data ?? []) map.set(r.template_key, { subject: r.subject ?? "", body: r.body_html ?? "" });
  tplCache = { at: Date.now(), map };
  return map;
}

function fillTokens(text: string, vars: Record<string, string>): string {
  let out = text;
  for (const [k, v] of Object.entries(vars)) out = out.split(`{{${k}}}`).join(v ?? "");
  return out;
}

async function renderEmail(
  agencyId: string,
  key: string,
  vars: Record<string, string>,
): Promise<{ subject: string; html: string }> {
  const t = (await loadTemplates(agencyId)).get(key);
  if (!t) throw new Error(`hiring email template "${key}" not found`);
  return { subject: fillTokens(t.subject, vars), html: fillTokens(t.body, vars) };
}

// The one sentence telling a candidate how to prepare. Shared by the
// confirmation, every reminder, and the booking page, so it lives in its own
// row and is edited once.
async function prepLine(agencyId: string): Promise<string> {
  const t = (await loadTemplates(agencyId)).get("snippet_prep_line");
  return t?.body ?? "";
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

  // No Gmail credentials fetched here any more: processAssessed does not send
  // an email itself. The decline letter is the decline-notice trigger's job
  // and the CTS letter is SQL's.
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
      // THE CTS GATE. Peter 2026-09-15: no CTS result on file, no interview
      // invite. Clearing the assessment verdict no longer books anything — it
      // sends the sales profile link and stops here. The interview invite is
      // fired later by trg_dispatch_cts_result, when record_cts_result()
      // stamps cts_completed_at. See sendInterviewInvite below.
      //
      // The letter itself lives in SQL (send_cts_invite_to_candidate) because
      // the hourly sweep sends the same letter to anyone this path missed.
      // One wording, two callers, no second copy.
      if (!c.email) {
        results.push({ id: c.id, name: c.candidate_name, action: "skipped_cts", reason: "no email" });
        continue;
      }
      const { data: ctsRes, error: ctsErr } = await sb.rpc("send_cts_invite_to_candidate", {
        p_agency_id: agencyId,
        p_candidate_id: c.id,
      });
      results.push({
        id: c.id,
        name: c.candidate_name,
        action: "cts_sent_awaiting_result",
        composite: v.composite,
        cts: ctsErr ? { ok: false, error: ctsErr.message } : ctsRes,
      });
      continue;
    }

    results.push({ id: c.id, name: c.candidate_name, action: "skipped", reason: `unexpected verdict ${verdict}` });
  }

  return jsonResponse({ ok: true, processed: results.length, results });
}

// -------------------------------------------------------------------------
// mode=send_interview_invite  (internal, shared_secret gated)
// -------------------------------------------------------------------------
// The only place an interview invite is created. Nothing calls it on a
// schedule; the database trigger trg_dispatch_cts_result fires it the moment
// a CTS result is recorded on a candidate still waiting at the gate.
//
// It re-checks the gate itself rather than trusting the caller. A trigger can
// be re-fired, a result can be recorded twice, and an invite sent twice means
// two booking tokens and two emails to the same person.
async function sendInterviewInvite(agencyId: string, candidateId: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, position, status, decision_at, interview_invite_token, cts_completed_at, is_test_candidate")
    .eq("id", candidateId)
    .eq("agency_id", agencyId)
    .maybeSingle();
  if (error) return jsonResponse({ ok: false, error: error.message }, 500);
  if (!c) return jsonResponse({ ok: false, error: "not_found" }, 404);
  if (c.is_test_candidate === true) return jsonResponse({ ok: true, action: "skipped", reason: "test candidate" });
  if (c.decision_at) return jsonResponse({ ok: true, action: "skipped", reason: "already decided" });
  if (c.interview_invite_token) return jsonResponse({ ok: true, action: "skipped", reason: "already invited" });
  if (!c.cts_completed_at) return jsonResponse({ ok: true, action: "skipped", reason: "no CTS result on file" });

  const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
  const name = c.candidate_name || firstName;

  if (!c.email) {
    await ensureWatcherTask({
      agencyId, source: "interview_invite_send_failed", relatedId: c.id,
      title: `Interview invite not sent — no email for ${name}`,
      description: `${name} has a CTS result on file and is ready for an interview, but there is no email address on the record. Add one and record the result again, or invite them by hand.`,
      priority: "high", category: "team_development",
    });
    return jsonResponse({ ok: false, action: "skipped", reason: "no email" });
  }

  const slots = await computeOfferedSlots(agencyId);
  if (!slots) return jsonResponse({ ok: false, action: "skipped", reason: "calendar creds missing" }, 500);

  const token = newToken();
  const expiresAt = new Date(Date.now() + BOOKING_WINDOW_DAYS * 24 * 3600 * 1000).toISOString();
  const { error: updErr } = await sb.from("hiring_candidates").update({
    status: "interview",
    interview_invite_token: token,
    interview_slots_offered: slots,
    interview_invite_sent_at: new Date().toISOString(),
    interview_booking_expires_at: expiresAt,
  }).eq("id", c.id);
  if (updErr) return jsonResponse({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);

  const bookingUrl = `${BOOKING_BASE_URL}/${token}`;
  const gmailCreds = await getComposioGmailCreds(agencyId);
  let emailSent = false;
  let emailError: string | null = null;
  if (gmailCreds.ok) {
    const letter = await renderEmail(agencyId, "interview_invite", {
      first_name: escHtml(firstName),
      booking_url: escHtml(bookingUrl),
    });
    const sendRes = await sendGmail({
      creds: gmailCreds.creds,
      to: c.email,
      subject: letter.subject,
      html: letter.html,
    });
    emailSent = sendRes.ok;
    if (!sendRes.ok) emailError = sendRes.error;
  } else {
    emailError = gmailCreds.error;
  }

  // The status write already happened, so a failed letter leaves a candidate
  // sitting in Interview holding a booking link nobody sent them. Say it out
  // loud instead of letting them wait.
  if (!emailSent) {
    await ensureWatcherTask({
      agencyId, source: "interview_invite_send_failed", relatedId: c.id,
      title: `Interview invite not sent — ${name}`,
      description: `${name} cleared the CTS gate and was moved to Interview, but the booking email did not send: ${emailError}. Their booking link still works: ${bookingUrl}`,
      priority: "high", category: "team_development",
    });
  }

  return jsonResponse({
    ok: true, action: "invited", name,
    email_sent: emailSent, email_error: emailError,
    slots_offered: slots.length, booking_url: bookingUrl,
  });
}

// -------------------------------------------------------------------------
// mode=get_offer  (public, token-gated)
// -------------------------------------------------------------------------
async function getOffer(agencyId: string, token: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, position, interview_slots_offered, interview_booking_expires_at, interview_booked_at, interview_scheduled_start, interview_meet_url, interview_confirmed_at")
    .eq("interview_invite_token", token)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "not_found" }, 404);

  if (c.interview_booked_at) {
    const free = await computeFreeSlots(agencyId);
    const earlier = free ? earlierOptions(free, c.interview_scheduled_start, new Date()) : [];
    return corsJson({
      ok: true,
      already_booked: true,
      confirmed: !!c.interview_confirmed_at,
      first_name: c.first_name || (c.candidate_name || "").split(" ")[0] || "there",
      scheduled_start: c.interview_scheduled_start,
      scheduled_start_display: formatChicago(c.interview_scheduled_start),
      meet_url: c.interview_meet_url,
      earlier_slots: earlier.map(toDisplay),
      prep_line: await prepLine(agencyId),
    });
  }

  const expired = c.interview_booking_expires_at ? new Date(c.interview_booking_expires_at).getTime() < Date.now() : false;
  let slots = (c.interview_slots_offered as Slot[] | null) ?? [];
  // Offered times go stale: a candidate who asked to reschedule, or opens
  // the link days later, would otherwise see times that already passed.
  // Any past time in the offer -> recompute and save a fresh set.
  if (!expired && slots.some((s) => new Date(s.start).getTime() <= Date.now())) {
    const fresh = await computeOfferedSlots(agencyId);
    if (fresh) {
      slots = fresh;
      await sb.from("hiring_candidates").update({ interview_slots_offered: fresh }).eq("id", c.id);
    } else {
      slots = slots.filter((s) => new Date(s.start).getTime() > Date.now());
    }
  }
  return corsJson({
    ok: true,
    already_booked: false,
    expired,
    first_name: c.first_name || (c.candidate_name || "").split(" ")[0] || "there",
    position: c.position || null,
    prep_line: await prepLine(agencyId),
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
  if (!(await slotStillOpen(agencyId, creds, chosen))) {
    const freshSlots = await computeOfferedSlots(agencyId);
    if (freshSlots) {
      await sb.from("hiring_candidates").update({ interview_slots_offered: freshSlots }).eq("id", c.id);
    }
    return corsJson({ ok: false, error: "slot_taken", slots: (freshSlots ?? []).map(toDisplay) }, 409);
  }

  return await bookCandidate(agencyId, creds, c, chosen);
}

async function slotStillOpen(agencyId: string, creds: { apiKey: string; userId: string; accountId: string }, slot: Slot): Promise<boolean> {
  const dateKey = slot.dateKey || chicagoDateKey(new Date(slot.start));
  const [busy, grid] = await Promise.all([fetchBusy(creds, slot.start, slot.end), slotGrid(agencyId, dateKey, dateKey)]);
  const at = new Date(slot.start).getTime();
  const live = (grid ?? []).find((g) => new Date(g.start).getTime() === at);
  return !!live && !live.blackedOut && !overlapsBusy(slot, busy);
}

// Creates the calendar event with a Meet link, writes the booking, emails
// the confirmation. Shared by a first booking and a move to an earlier time.
async function bookCandidate(agencyId: string, creds: { apiKey: string; userId: string; accountId: string }, c: any, chosen: Slot, moved = false): Promise<Response> {
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
    interview_confirmed_at: null,
    interview_reminder_3d_sent_at: null,
    interview_reminder_1d_sent_at: null,
    interview_unconfirmed_alerted_at: null,
    interview_reminder_response: null,
  }).eq("id", c.id);
  if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);

  if (c.email) {
    const gmailCreds = await getComposioGmailCreds(agencyId);
    if (gmailCreds.ok) {
      const letter = await renderEmail(agencyId, moved ? "interview_confirmation_moved" : "interview_confirmation", {
        first_name: escHtml(firstName),
        when: escHtml(startLocalStr),
        meet_url: escHtml(meetUrl || ""),
        prep_line: escHtml(await prepLine(agencyId)),
      });
      await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: letter.subject,
        html: letter.html,
      });
    }
  }

  return corsJson({ ok: true, moved, scheduled_start: chosen.start, scheduled_start_display: startLocalStr, meet_url: meetUrl, prep_line: await prepLine(agencyId) });
}

// -------------------------------------------------------------------------
// mode=rebook  (public, token-gated)
// -------------------------------------------------------------------------
// A booked candidate takes an earlier open time. The old event is canceled
// (they asked for it, so their calendar gets the update) and the new one is
// booked through the same path as a first booking.
async function rebook(agencyId: string, token: string, chosenStart: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, position, status, interview_booked_at, interview_scheduled_start, interview_calendar_event_id")
    .eq("interview_invite_token", token)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "not_found" }, 404);
  if (!c.interview_booked_at || !c.interview_scheduled_start) return corsJson({ ok: false, error: "not_booked" }, 409);
  if (c.status === "declined") return corsJson({ ok: false, error: "not_booked" }, 409);
  if (chosenStart >= c.interview_scheduled_start) return corsJson({ ok: false, error: "not_earlier" }, 400);

  const creds = await getCalendarCreds(agencyId);
  if (!creds) return corsJson({ ok: false, error: "calendar_unavailable" }, 500);

  const free = await computeFreeSlots(agencyId);
  const chosen = (free ?? []).find((s) => s.start === chosenStart);
  if (!chosen) {
    const earlier = free ? earlierOptions(free, c.interview_scheduled_start, new Date()) : [];
    return corsJson({ ok: false, error: "slot_taken", earlier_slots: earlier.map(toDisplay) }, 409);
  }

  await cancelCalendarEvent(agencyId, c.interview_calendar_event_id, "all");
  return await bookCandidate(agencyId, creds, c, chosen, true);
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
      const letter = await renderEmail(agencyId, "meet_greet", {
        first_name: escHtml(firstName),
        when: escHtml(whenLocal),
        where_block: isVideo
          ? `<p>It's a video call over Google Meet${meetUrl ? `: <a href="${escHtml(meetUrl)}">${escHtml(meetUrl)}</a>` : ""}.</p>`
          : `<p>We'll meet at our office:<br/>${escHtml(locationText)}</p>`,
        note_block: note ? `<p>${escHtml(note)}</p>` : "",
      });
      const sendRes = await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: letter.subject,
        html: letter.html,
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
// Reminders + candidate responses
// -------------------------------------------------------------------------
type ReminderKind = "three_days" | "day_before";
type RespondAction = "confirm" | "reschedule" | "withdraw";

function chicagoDateKey(d: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" })
    .formatToParts(d).reduce((acc: any, p) => { acc[p.type] = p.value; return acc; }, {});
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function daysBetweenKeys(fromKey: string, toKey: string): number {
  const [fy, fm, fd] = fromKey.split("-").map(Number);
  const [ty, tm, td] = toKey.split("-").map(Number);
  return Math.round((Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86400000);
}

function respondUrl(token: string, action: RespondAction): string {
  return `${BOOKING_BASE_URL}/${token}?respond=${action}`;
}

function responseButtonsHtml(token: string): string {
  const btn = (action: RespondAction, label: string, bg: string) =>
    `<a href="${escHtml(respondUrl(token, action))}" style="display:inline-block;margin:6px 8px 6px 0;padding:10px 16px;border-radius:8px;background:${bg};color:#fff;text-decoration:none;font-weight:600;">${label}</a>`;
  return `<p>${btn("confirm", "Yes, I'll be there", "#2563eb")}${btn("reschedule", "I need a different time", "#475569")}</p>
<p style="font-size:13px;color:#64748b;">No longer interested? <a href="${escHtml(respondUrl(token, "withdraw"))}">Let us know here</a> and we'll open the time up for someone else.</p>`;
}

async function cancelCalendarEvent(
  agencyId: string,
  eventId: string | null,
  sendUpdates: "all" | "none" = "all",
  who?: { candidateId: string; name: string; when: string | null },
): Promise<{ ok: boolean; error?: string }> {
  if (!eventId) return { ok: true };
  const creds = await getCalendarCreds(agencyId);
  if (!creds) return { ok: false, error: "calendar creds missing" };

  // Google refuses a delete now and again for no lasting reason. One retry
  // turns most of those into a clean cancellation. Peter 2026-09-14: two
  // candidates declined a minute apart, one interview came off the calendar
  // and the other was left sitting there.
  let lastError = "unknown";
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) await new Promise((r) => setTimeout(r, 1500));
    const res = await callComposio({
      apiKey: creds.apiKey,
      userId: creds.userId,
      connectedAccountId: creds.accountId,
      toolSlug: "GOOGLECALENDAR_DELETE_EVENT",
      toolArguments: { calendar_id: CALENDAR_ID, event_id: eventId, send_updates: sendUpdates },
    });
    if (res.ok) return { ok: true };
    lastError = res.error ?? "unknown";
  }

  // Still on the calendar. Say so out loud. This used to be a true/false in a
  // response nobody reads, so a meeting stayed booked with nothing pointing
  // at it and the time never came back.
  const nameLine = who?.name ?? "A candidate";
  const whenLine = who?.when ? ` at ${who.when}` : "";
  await ensureWatcherTask({
    agencyId,
    source: `interview_event_not_canceled:${eventId}`,
    relatedId: who?.candidateId ?? null,
    title: `Interview still on the calendar — ${nameLine}`,
    description: `${nameLine}'s interview${whenLine} could not be taken off the calendar: ${lastError}. Delete it by hand so the time opens back up. Calendar event id ${eventId}.`,
    priority: "high",
    category: "team_development",
  });
  return { ok: false, error: lastError };
}

// The booking fields that come off a candidate when their time goes back on
// the board. The calendar event id is the one exception: if the event could
// NOT be removed from the calendar, the id stays on the row, so the meeting
// still traces back to a person instead of becoming an orphan nobody can
// match up. Written once here because four places give a booking back.
function clearedBookingFields(calendarCanceled: boolean): Record<string, unknown> {
  const cleared: Record<string, unknown> = {
    interview_scheduled_start: null,
    interview_scheduled_end: null,
    interview_meet_url: null,
    interview_booked_at: null,
    interview_confirmed_at: null,
    interview_reminder_3d_sent_at: null,
    interview_reminder_1d_sent_at: null,
    interview_unconfirmed_alerted_at: null,
  };
  if (calendarCanceled) cleared.interview_calendar_event_id = null;
  return cleared;
}

// -------------------------------------------------------------------------
// mode=send_reminders  (internal, shared_secret gated)
// -------------------------------------------------------------------------
// Three days before: confirm-or-reschedule ask. Day before: reminder with
// the Meet link (still carrying the response links if unconfirmed). A
// booking made with less than three days' notice gets the ask at the next
// morning run, so nobody is skipped. Morning of, still unconfirmed -> DM to
// the owner. Idempotent per touch via the *_sent_at stamps.
async function sendReminders(agencyId: string): Promise<Response> {
  const now = new Date();
  const todayKey = chicagoDateKey(now);
  const { data: rows, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, status, interview_invite_token, interview_scheduled_start, interview_meet_url, interview_confirmed_at, interview_reminder_3d_sent_at, interview_reminder_1d_sent_at, interview_unconfirmed_alerted_at")
    .eq("agency_id", agencyId)
    .not("interview_booked_at", "is", null)
    .not("interview_scheduled_start", "is", null)
    .gt("interview_scheduled_start", now.toISOString())
    .neq("status", "declined")
    .order("interview_scheduled_start", { ascending: true })
    .limit(100);
  if (error) return jsonResponse({ ok: false, error: error.message }, 500);

  const gmailCreds = await getComposioGmailCreds(agencyId);
  if (!gmailCreds.ok) return jsonResponse({ ok: false, error: `gmail creds: ${gmailCreds.error}` }, 500);

  const results: any[] = [];
  for (const c of rows ?? []) {
    if (!c.email || !c.interview_invite_token) { results.push({ id: c.id, action: "skipped", reason: "no email or token" }); continue; }
    const daysAhead = daysBetweenKeys(todayKey, chicagoDateKey(new Date(c.interview_scheduled_start)));
    const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
    const startLocal = formatChicago(c.interview_scheduled_start);
    const confirmed = !!c.interview_confirmed_at;

    if (daysAhead === 0) {
      if (!confirmed && !c.interview_unconfirmed_alerted_at) {
        const dm = await notifyOwnerUnconfirmed(agencyId, c, startLocal);
        await sb.from("hiring_candidates").update({ interview_unconfirmed_alerted_at: now.toISOString() }).eq("id", c.id);
        results.push({ id: c.id, name: c.candidate_name, action: "owner_notified", owner_notified: dm });
      }
      continue;
    }

    let kind: ReminderKind | null = null;
    if (daysAhead === 1 && !c.interview_reminder_1d_sent_at) kind = "day_before";
    else if (daysAhead >= 2 && daysAhead <= 3 && !c.interview_reminder_3d_sent_at) kind = "three_days";
    if (!kind) continue;
    const reminderKey = `interview_reminder_${kind === "day_before" ? "1day" : "3day"}_${confirmed ? "confirmed" : "unconfirmed"}`;
    const letter = await renderEmail(agencyId, reminderKey, {
      first_name: escHtml(firstName),
      when: escHtml(startLocal),
      meet_line: c.interview_meet_url
        ? `<p>Google Meet link: <a href="${escHtml(c.interview_meet_url)}">${escHtml(c.interview_meet_url)}</a></p>`
        : `<p>The Google Meet link is in your calendar invite.</p>`,
      response_buttons: responseButtonsHtml(c.interview_invite_token),
      prep_line: escHtml(await prepLine(agencyId)),
    });
    const sendRes = await sendGmail({
      creds: gmailCreds.creds,
      to: c.email,
      subject: letter.subject,
      html: letter.html,
    });
    if (!sendRes.ok) { results.push({ id: c.id, name: c.candidate_name, action: "send_failed", kind, error: sendRes.error }); continue; }
    const stamp = kind === "day_before" ? { interview_reminder_1d_sent_at: now.toISOString() } : { interview_reminder_3d_sent_at: now.toISOString() };
    await sb.from("hiring_candidates").update(stamp).eq("id", c.id);
    results.push({ id: c.id, name: c.candidate_name, action: "sent", kind, confirmed, days_ahead: daysAhead });
  }

  const earlier = await offerEarlierTimes(agencyId);
  const unbooked = await followUpUnbooked(agencyId, gmailCreds, now);
  const sent = results.filter((r) => r.action === "sent").length;
  const bumps = earlier.offered.length;
  const nudges = unbooked.filter((r) => r.action === "booking_reminder_sent").length;
  const closed = unbooked.filter((r) => r.action === "closed_not_booked").length;
  return jsonResponse({
    ok: true, today: todayKey, scanned: (rows ?? []).length, sent, results, earlier_offers: earlier, unbooked,
    records_processed: sent + bumps + nudges + closed,
    output_summary: `${sent} reminder(s), ${bumps} earlier-time offer(s), ${(rows ?? []).length} upcoming, ${nudges} booking nudge(s), ${closed} closed never booked`,
  });
}

// -------------------------------------------------------------------------
// Unbooked interview invites (Peter 2026-09-27)
// -------------------------------------------------------------------------
// Someone sent the booking link who never picks a time used to sit in
// Interview forever. Same shape as the assessment and sales-profile nudges:
// reminder 1 a day after the link, reminder 2 a day after that, then stop.
// When the 7-day link expires still unbooked, they are closed as
// interview_not_booked; the decline-notice trigger sends the standard letter.
// Runs inside the 7 AM send_reminders run.
async function followUpUnbooked(agencyId: string, gmailCreds: any, now: Date): Promise<any[]> {
  const out: any[] = [];
  const { data: rows, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, interview_invite_token, interview_invite_sent_at, interview_booking_expires_at, interview_booking_reminder_1_sent_at, interview_booking_reminder_2_sent_at")
    .eq("agency_id", agencyId)
    .eq("status", "interview")
    .eq("is_test_candidate", false)
    .is("decision_at", null)
    .is("interview_booked_at", null)
    .not("interview_invite_token", "is", null)
    .limit(100);
  if (error) return [{ action: "unbooked_query_failed", error: error.message }];

  const dayMs = 24 * 3600 * 1000;
  for (const c of rows ?? []) {
    const expires = c.interview_booking_expires_at ? new Date(c.interview_booking_expires_at) : null;
    if (expires && expires.getTime() < now.getTime()) {
      const { error: updErr } = await sb.from("hiring_candidates").update({
        status: "declined",
        decline_reason: "interview_not_booked",
        final_decision: "no_hire",
        decision_at: now.toISOString(),
        decision_notes: `Closed automatically: booking link sent ${String(c.interview_invite_sent_at ?? "").slice(0, 10)}, two reminders, never booked; link expired ${expires.toISOString().slice(0, 10)}.`,
      }).eq("id", c.id);
      out.push({ id: c.id, name: c.candidate_name, action: updErr ? "close_failed" : "closed_not_booked", error: updErr?.message });
      continue;
    }
    if (!c.email || !gmailCreds.ok) continue;
    const sentAt = c.interview_invite_sent_at ? new Date(c.interview_invite_sent_at).getTime() : null;
    const r1 = c.interview_booking_reminder_1_sent_at ? new Date(c.interview_booking_reminder_1_sent_at).getTime() : null;
    let n: 1 | 2 | null = null;
    if (!r1 && sentAt && now.getTime() - sentAt >= dayMs) n = 1;
    else if (r1 && !c.interview_booking_reminder_2_sent_at && now.getTime() - r1 >= dayMs) n = 2;
    if (!n) continue;

    const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
    const bookingUrl = `${BOOKING_BASE_URL}/${c.interview_invite_token}`;
    const letter = await renderEmail(agencyId, "interview_booking_reminder", {
      first_name: escHtml(firstName),
      booking_url: escHtml(bookingUrl),
      expires: escHtml(expires ? formatChicago(expires.toISOString()) : "in a few days"),
    });
    const sendRes = await sendGmail({ creds: gmailCreds.creds, to: c.email, subject: letter.subject, html: letter.html });
    if (!sendRes.ok) { out.push({ id: c.id, name: c.candidate_name, action: "booking_reminder_failed", n, error: sendRes.error }); continue; }
    const stamp = n === 1
      ? { interview_booking_reminder_1_sent_at: now.toISOString() }
      : { interview_booking_reminder_2_sent_at: now.toISOString() };
    await sb.from("hiring_candidates").update(stamp).eq("id", c.id);
    out.push({ id: c.id, name: c.candidate_name, action: "booking_reminder_sent", n });
  }
  return out;
}

// -------------------------------------------------------------------------
// Earlier-time offers
// -------------------------------------------------------------------------
// Shorter waits mean fewer no-shows (Gallucci, Swartz & Hackerman 2005,
// Psychiatric Services 56:344), so when a slot opens up, people booked
// further out get first crack at it. Limits so it never turns into noise:
// only interviews more than three days out, only unconfirmed candidates, only
// when an open time is at least a day earlier, and one email per candidate
// every three days at most. Taking the time happens on the booking page
// (mode=rebook); nothing changes for anyone who ignores the email.
const EARLIER_OFFER_MIN_DAYS_OUT = 3;
const EARLIER_OFFER_COOLDOWN_HOURS = 72;

async function offerEarlierTimes(agencyId: string): Promise<{ offered: any[]; skipped: number; error?: string }> {
  const now = new Date();
  const free = await computeFreeSlots(agencyId);
  if (!free) return { offered: [], skipped: 0, error: "calendar creds missing" };
  const minStart = new Date(now.getTime() + EARLIER_OFFER_MIN_DAYS_OUT * 24 * 3600 * 1000).toISOString();
  const { data: rows, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, interview_invite_token, interview_scheduled_start, interview_earlier_offer_sent_at")
    .eq("agency_id", agencyId)
    .not("interview_booked_at", "is", null)
    .gt("interview_scheduled_start", minStart)
    .is("interview_confirmed_at", null)
    .neq("status", "declined")
    .order("interview_scheduled_start", { ascending: false })
    .limit(100);
  if (error) return { offered: [], skipped: 0, error: error.message };

  const gmailCreds = await getComposioGmailCreds(agencyId);
  if (!gmailCreds.ok) return { offered: [], skipped: 0, error: gmailCreds.error };

  const offered: any[] = [];
  let skipped = 0;
  for (const c of rows ?? []) {
    if (!c.email || !c.interview_invite_token) { skipped++; continue; }
    if (c.interview_earlier_offer_sent_at && (now.getTime() - new Date(c.interview_earlier_offer_sent_at).getTime()) < EARLIER_OFFER_COOLDOWN_HOURS * 3600 * 1000) { skipped++; continue; }
    const options = earlierOptions(free, c.interview_scheduled_start, now);
    if (options.length === 0) { skipped++; continue; }
    const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
    const letter = await renderEmail(agencyId, "interview_earlier_time", {
      first_name: escHtml(firstName),
      when: escHtml(formatChicago(c.interview_scheduled_start)),
      options_list: options.map((o) => `<li>${escHtml(formatChicago(o.start))}</li>`).join(""),
      booking_url: escHtml(`${BOOKING_BASE_URL}/${c.interview_invite_token}`),
    });
    const sendRes = await sendGmail({
      creds: gmailCreds.creds,
      to: c.email,
      subject: letter.subject,
      html: letter.html,
    });
    if (!sendRes.ok) { offered.push({ id: c.id, name: c.candidate_name, action: "send_failed", error: sendRes.error }); continue; }
    await sb.from("hiring_candidates").update({ interview_earlier_offer_sent_at: now.toISOString() }).eq("id", c.id);
    offered.push({ id: c.id, name: c.candidate_name, current: formatChicago(c.interview_scheduled_start), options: options.map((o) => formatChicago(o.start)) });
  }
  return { offered, skipped };
}

// -------------------------------------------------------------------------
// mode=calendar_busy  (admin, session-token gated)
// -------------------------------------------------------------------------
// The Interview Slots calendar asks for anything on Peter's Google Calendar
// that would knock out a slot, so a removed slot is never invisible. Returns
// timed, busy (non-transparent) events in the range, minus the interviews
// themselves. All-day events count as busy for the whole day — which is
// exactly why the compliance reminders had to be switched to "free".
async function calendarBusy(agencyId: string, fromDateKey: string, throughDateKey: string): Promise<Response> {
  const creds = await getCalendarCreds(agencyId);
  if (!creds) return corsJson({ ok: false, error: "calendar_unavailable" }, 500);
  const res = await callComposio({
    apiKey: creds.apiKey,
    userId: creds.userId,
    connectedAccountId: creds.accountId,
    toolSlug: "GOOGLECALENDAR_EVENTS_LIST",
    toolArguments: {
      calendarId: CALENDAR_ID,
      timeMin: `${fromDateKey}T00:00:00-05:00`,
      timeMax: `${throughDateKey}T23:59:59-05:00`,
      singleEvents: true,
      orderBy: "startTime",
      maxResults: 500,
    },
  });
  if (!res.ok) return corsJson({ ok: false, error: res.error ?? "events_list_failed" }, 500);
  const items = (res.data?.response_data?.items ?? res.data?.items ?? res.data?.data?.items ?? []) as any[];
  const events = items
    .filter((e) => e && e.status !== "cancelled" && e.transparency !== "transparent")
    .filter((e) => !/^Interview AMA/.test(e.summary || "") && !/^Meet & Greet/.test(e.summary || ""))
    .map((e) => {
      const allDay = !!e.start?.date && !e.start?.dateTime;
      return {
        summary: e.summary || "(busy)",
        all_day: allDay,
        start: allDay ? `${e.start.date}T00:00:00-05:00` : e.start?.dateTime,
        end: allDay ? `${e.end.date}T00:00:00-05:00` : e.end?.dateTime,
      };
    })
    .filter((e) => e.start && e.end);
  return corsJson({ ok: true, events });
}

// -------------------------------------------------------------------------
// mode=move_bookings  (admin session OR internal shared_secret)
// -------------------------------------------------------------------------
// The week just closed (vacation moved, week blacked out): everyone booked in
// the range is unbooked, told why, and handed fresh times. The event leaves
// their calendar without a Google notice; the email is the notice.
async function moveBookings(agencyId: string, fromDateKey: string, throughDateKey: string, reason: string): Promise<Response> {
  const { data: rows, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, interview_invite_token, interview_scheduled_start, interview_calendar_event_id")
    .eq("agency_id", agencyId)
    .not("interview_booked_at", "is", null)
    .neq("status", "declined")
    .gte("interview_scheduled_start", `${fromDateKey}T00:00:00-05:00`)
    .lt("interview_scheduled_start", `${throughDateKey}T23:59:59-05:00`);
  if (error) return corsJson({ ok: false, error: error.message }, 500);

  const gmailCreds = await getComposioGmailCreds(agencyId);
  const moved: any[] = [];
  for (const c of rows ?? []) {
    const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
    const oldLocal = formatChicago(c.interview_scheduled_start);
    const cancel = await cancelCalendarEvent(agencyId, c.interview_calendar_event_id, "none", {
      candidateId: c.id,
      name: c.candidate_name || firstName,
      when: oldLocal,
    });
    const slots = (await computeOfferedSlots(agencyId)) ?? [];
    const token = c.interview_invite_token || newToken();
    const { error: updErr } = await sb.from("hiring_candidates").update({
      ...clearedBookingFields(cancel.ok),
      interview_reminder_response: null,
      interview_invite_token: token,
      interview_slots_offered: slots,
      interview_invite_sent_at: new Date().toISOString(),
      interview_booking_expires_at: new Date(Date.now() + BOOKING_WINDOW_DAYS * 24 * 3600 * 1000).toISOString(),
    }).eq("id", c.id);
    if (updErr) { moved.push({ id: c.id, name: c.candidate_name, action: "db_update_failed", error: updErr.message }); continue; }

    let emailed = false;
    if (c.email && gmailCreds.ok) {
      const bookingUrl = `${BOOKING_BASE_URL}/${token}`;
      const letter = await renderEmail(agencyId, "interview_moved_by_us", {
        first_name: escHtml(firstName),
        reason: escHtml(reason),
        old_when: escHtml(oldLocal),
        booking_url: escHtml(bookingUrl),
      });
      const sendRes = await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: letter.subject,
        html: letter.html,
      });
      emailed = sendRes.ok;
    }
    moved.push({ id: c.id, name: c.candidate_name, was: oldLocal, emailed, slots_offered: slots.length });
  }
  return corsJson({ ok: true, moved, records_processed: moved.length, output_summary: `${moved.length} booking(s) moved out of ${fromDateKey}..${throughDateKey}` });
}

// -------------------------------------------------------------------------
// mode=release_booking  (internal, shared_secret gated)
// -------------------------------------------------------------------------
// A booked candidate was declined in the pipeline. The event comes off the
// calendar WITH the notification, the booking fields clear, and the freed
// time is offered to whoever is waiting.
//
// Peter 2026-09-14: the cancellation used to go out silently, on the idea
// that the decline letter should break the news first. It does not work.
// The decline letter waits for a batch, so a candidate declined an hour
// before their interview sat there with a live meeting on their calendar and
// no word from us. He is not showing up, so they have to be told at once,
// and the calendar notice is the only message that is instant.
async function releaseBooking(agencyId: string, candidateId: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, candidate_name, interview_booked_at, interview_scheduled_start, interview_calendar_event_id")
    .eq("id", candidateId)
    .eq("agency_id", agencyId)
    .maybeSingle();
  if (error || !c) return jsonResponse({ ok: false, error: "not_found" }, 404);
  if (!c.interview_booked_at && !c.interview_calendar_event_id) return jsonResponse({ ok: true, released: false, reason: "nothing booked" });

  const cancel = await cancelCalendarEvent(agencyId, c.interview_calendar_event_id, "all", {
    candidateId: c.id,
    name: c.candidate_name || "Candidate",
    when: c.interview_scheduled_start ? formatChicago(c.interview_scheduled_start) : null,
  });
  const { error: updErr } = await sb.from("hiring_candidates")
    .update(clearedBookingFields(cancel.ok))
    .eq("id", c.id);
  if (updErr) return jsonResponse({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);

  const earlier = await offerEarlierTimes(agencyId);
  return jsonResponse({ ok: true, released: true, name: c.candidate_name, freed: c.interview_scheduled_start ? formatChicago(c.interview_scheduled_start) : null, calendar_canceled: cancel.ok, earlier_offers: earlier });
}

async function notifyOwnerUnconfirmed(agencyId: string, c: any, startLocal: string): Promise<boolean> {
  try {
    const { data: owner } = await sb
      .from("team")
      .select("telegram_user_id")
      .eq("agency_id", agencyId)
      .eq("role_level", "Owner")
      .eq("is_excluded_paper_newt_bot", false)
      .not("telegram_user_id", "is", null)
      .limit(1)
      .maybeSingle();
    if (!owner?.telegram_user_id) return false;
    const { data: full } = await sb.from("hiring_candidates").select("phone").eq("id", c.id).maybeSingle();
    const name = c.candidate_name || c.first_name || "Candidate";
    const phone = full?.phone ? `\nPhone: ${full.phone}` : "";
    const text = `⚠️ Interview today, not confirmed\n\n${name} — ${startLocal} CT${phone}\n\nThey got the confirm ask two days ago and the morning-of reminder just now, no answer yet. Might be worth a text.`;
    const { error } = await sb.rpc("telegram_send_message_v2", { p_chat_id: owner.telegram_user_id, p_text: text, p_bot: "paper_newt" });
    return !error;
  } catch {
    return false;
  }
}

// -------------------------------------------------------------------------
// mode=respond  (public, token-gated)
// -------------------------------------------------------------------------
async function respond(agencyId: string, token: string, action: RespondAction): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, status, interview_booked_at, interview_scheduled_start, interview_calendar_event_id, interview_meet_url, interview_confirmed_at")
    .eq("interview_invite_token", token)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "not_found" }, 404);
  if (!c.interview_booked_at) return corsJson({ ok: false, error: "not_booked" }, 409);
  const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";

  if (action === "confirm") {
    const { error: updErr } = await sb.from("hiring_candidates").update({
      interview_confirmed_at: c.interview_confirmed_at || new Date().toISOString(),
      interview_reminder_response: "confirmed",
    }).eq("id", c.id);
    if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);
    return corsJson({
      ok: true, action, first_name: firstName,
      scheduled_start_display: formatChicago(c.interview_scheduled_start),
      meet_url: c.interview_meet_url, prep_line: await prepLine(agencyId),
    });
  }

  // reschedule or withdraw: the booked time goes back on the board.
  const cancel = await cancelCalendarEvent(agencyId, c.interview_calendar_event_id, "all", {
    candidateId: c.id,
    name: c.candidate_name || firstName,
    when: c.interview_scheduled_start ? formatChicago(c.interview_scheduled_start) : null,
  });
  const cleared = clearedBookingFields(cancel.ok);

  if (action === "withdraw") {
    const { error: updErr } = await sb.from("hiring_candidates").update({
      ...cleared,
      interview_reminder_response: "withdrew",
      status: "declined",
      decline_reason: "candidate_withdrew",
      status_updated_at: new Date().toISOString(),
    }).eq("id", c.id);
    if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);
    const earlier = await offerEarlierTimes(agencyId);
    return corsJson({ ok: true, action, first_name: firstName, calendar_canceled: cancel.ok, earlier_offers: earlier.offered.length });
  }

  // reschedule
  const slots = await computeOfferedSlots(agencyId);
  if (!slots) return corsJson({ ok: false, error: "calendar_unavailable" }, 500);
  const { error: updErr } = await sb.from("hiring_candidates").update({
    ...cleared,
    interview_reminder_response: "reschedule",
    interview_slots_offered: slots,
    interview_invite_sent_at: new Date().toISOString(),
    interview_booking_expires_at: new Date(Date.now() + BOOKING_WINDOW_DAYS * 24 * 3600 * 1000).toISOString(),
  }).eq("id", c.id);
  if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);

  if (c.email) {
    const gmailCreds = await getComposioGmailCreds(agencyId);
    if (gmailCreds.ok) {
      const letter = await renderEmail(agencyId, "interview_rebook", {
        first_name: escHtml(firstName),
        booking_url: escHtml(`${BOOKING_BASE_URL}/${token}`),
      });
      await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: letter.subject,
        html: letter.html,
      });
    }
  }
  const earlier = await offerEarlierTimes(agencyId);
  return corsJson({
    ok: true, action, first_name: firstName, calendar_canceled: cancel.ok, prep_line: await prepLine(agencyId), earlier_offers: earlier.offered.length,
    slots: slots.map(toDisplay),
  });
}

// -------------------------------------------------------------------------
// Offer letter
// -------------------------------------------------------------------------
// The letter body is markdown, written by Peter in Team > Growth > Email
// Templates and filled in by the offer form. Gmail needs HTML, so it is
// converted here at send time. Sending raw markdown puts literal asterisks and
// bracket syntax in front of the candidate.
//
// Supported, because that is what the letter actually uses:
//   **bold**, [text](url), "- " bullets nested by two spaces per level,
//   blank-line-separated paragraphs. A line that is nothing but bold text is
//   treated as a section heading and gets the heading spacing.

function offerInline(text: string): string {
  let out = escHtml(text);
  // Links first: the label can itself contain bold.
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, label, url) => `<a href="${url}">${label}</a>`);
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  return out;
}

export function offerMarkdownToHtml(md: string): string {
  const lines = String(md || "").replace(/\r\n/g, "\n").split("\n");
  const out: string[] = [];
  let openLists = 0;

  const closeLists = (toDepth: number) => {
    while (openLists > toDepth) { out.push("</ul>"); openLists--; }
  };

  for (const raw of lines) {
    const line = raw.replace(/\s+$/, "");
    if (line.trim() === "") { closeLists(0); continue; }

    const bullet = line.match(/^(\s*)-\s+(.*)$/);
    if (bullet) {
      // Two spaces per level. Anything shallower than a full level rounds down,
      // so a stray single space cannot silently create a new nesting level.
      const depth = Math.floor(bullet[1].length / 2) + 1;
      while (openLists < depth) { out.push("<ul>"); openLists++; }
      closeLists(depth);
      out.push(`<li>${offerInline(bullet[2])}</li>`);
      continue;
    }

    closeLists(0);
    const heading = line.trim().match(/^\*\*(.+)\*\*$/);
    if (heading) {
      out.push(`<p style="margin:22px 0 8px 0;"><strong>${escHtml(heading[1])}</strong></p>`);
      continue;
    }
    out.push(`<p>${offerInline(line.trim())}</p>`);
  }
  closeLists(0);

  return `<div style="font-family:Arial,Helvetica,sans-serif;font-size:14px;line-height:1.55;color:#1a1a1a;max-width:640px;">\n${out.join("\n")}\n</div>`;
}

// Mails the offer letter already filed on the candidate row. The database
// trigger trg_send_offer_letter calls this the moment the offer form saves,
// which is the only path that puts a letter body on the row.
//
// One decider: the trigger dispatches, this function decides. offer_sent_at is
// the duplicate stop — it is stamped only on a successful send, and a row that
// already carries it is skipped, so bouncing a candidate out of Offer and back
// cannot mail them twice.
async function sendOfferLetter(agencyId: string, candidateId: string): Promise<Response> {
  const { data: c, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, status, offer_letter_body, offer_sent_at, is_test_candidate")
    .eq("agency_id", agencyId)
    .eq("id", candidateId)
    .maybeSingle();

  if (error) return jsonResponse({ ok: false, error: error.message }, 500);
  if (!c) return jsonResponse({ ok: false, error: "candidate not found" }, 404);

  if (c.is_test_candidate === true) return jsonResponse({ ok: true, action: "skipped", reason: "test candidate" });
  if (c.status !== "offer")         return jsonResponse({ ok: true, action: "skipped", reason: "not in offer stage" });
  if (c.offer_sent_at)              return jsonResponse({ ok: true, action: "skipped", reason: "already sent" });
  if (!c.offer_letter_body)         return jsonResponse({ ok: true, action: "skipped", reason: "no letter body" });

  const name = c.candidate_name || c.first_name || "the candidate";

  if (!c.email) {
    await ensureWatcherTask({
      agencyId, source: "offer_letter_send_failed", relatedId: c.id,
      title: `Offer letter not sent — no email address for ${name}`,
      description: `${name} was moved to the Offer stage and the letter is ready, but there is no email address on the record. Add one and move them out of Offer and back to send it.`,
      priority: "high", category: "team_development",
    });
    return jsonResponse({ ok: false, action: "failed", reason: "no email address" }, 200);
  }

  const { data: tpl } = await sb
    .from("offer_letter_templates")
    .select("subject")
    .eq("agency_id", agencyId)
    .eq("is_active", true)
    .maybeSingle();

  const subject = tpl?.subject || "Reference Check & Next Steps";
  // The acceptance link is minted here rather than when the letter is
  // written, so its one-day clock starts when the email actually goes out and
  // re-sending an offer always replaces a stale or already-used link.
  let letterBody = c.offer_letter_body;
  if (letterBody.includes("{{accept_link}}")) {
    const { data: acceptToken, error: tokenErr } = await sb.rpc("hiring_issue_offer_accept_token", {
      p_candidate_id: c.id,
    });
    if (tokenErr || !acceptToken) {
      console.error("could not mint the offer acceptance token", tokenErr);
      return jsonResponse({ ok: false, error: "could not create the acceptance link" }, 500);
    }
    const base = (await getSettingOrNull(agencyId, "app_base_url")) || "https://newtworks.vercel.app";
    letterBody = letterBody.replaceAll("{{accept_link}}", `${base}/accept-offer/${acceptToken}`);
  }

  const html = offerMarkdownToHtml(letterBody);

  const gmailCreds = await getComposioGmailCreds(agencyId);
  if (!gmailCreds.ok) {
    await ensureWatcherTask({
      agencyId, source: "offer_letter_send_failed", relatedId: c.id,
      title: `Offer letter not sent to ${name} — Gmail is not connected`,
      description: `${name}'s offer letter is ready but Gmail could not be reached: ${gmailCreds.error}. Reconnect Gmail, then move them out of Offer and back to send it.`,
      priority: "critical", category: "team_development",
    });
    return jsonResponse({ ok: false, action: "failed", reason: gmailCreds.error }, 200);
  }

  const sendRes = await sendGmail({ creds: gmailCreds.creds, to: c.email, subject, html });

  if (!sendRes.ok) {
    await ensureWatcherTask({
      agencyId, source: "offer_letter_send_failed", relatedId: c.id,
      title: `Offer letter not sent to ${name}`,
      description: `Gmail refused the send: ${sendRes.error}. The letter is still on the candidate record. Fix the problem, then move them out of Offer and back to try again.`,
      priority: "critical", category: "team_development",
    });
    return jsonResponse({ ok: false, action: "failed", reason: sendRes.error }, 200);
  }

  await sb.from("hiring_candidates").update({ offer_sent_at: new Date().toISOString() }).eq("id", c.id);

  return jsonResponse({ ok: true, action: "sent", to: c.email, subject });
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

  if (mode === "send_offer_letter") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    if (!body.candidate_id) return jsonResponse({ ok: false, error: "missing candidate_id" }, 400);
    return await sendOfferLetter(agencyId, body.candidate_id);
  }

  if (mode === "send_interview_invite") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    if (!body.candidate_id) return jsonResponse({ ok: false, error: "missing candidate_id" }, 400);
    return await sendInterviewInvite(agencyId, body.candidate_id);
  }

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
    return await getOffer(agencyId, body.token);
  }

  if (mode === "claim_slot") {
    if (!body.token || !body.start) return corsJson({ ok: false, error: "missing token or start" }, 400);
    return await claimSlot(agencyId, body.token, body.start);
  }

  if (mode === "respond") {
    if (!body.token) return corsJson({ ok: false, error: "missing token" }, 400);
    if (!["confirm", "reschedule", "withdraw"].includes(body.action)) return corsJson({ ok: false, error: "bad action" }, 400);
    return await respond(agencyId, body.token, body.action as RespondAction);
  }

  if (mode === "rebook") {
    if (!body.token || !body.start) return corsJson({ ok: false, error: "missing token or start" }, 400);
    return await rebook(agencyId, body.token, body.start);
  }

  if (mode === "send_reminders") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    return await sendReminders(agencyId);
  }

  if (mode === "release_booking") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    if (!body.candidate_id) return jsonResponse({ ok: false, error: "missing candidate_id" }, 400);
    return await releaseBooking(agencyId, body.candidate_id);
  }

  if (mode === "calendar_busy") {
    const denied = await requireOwnerOrManager(req, agencyId);
    if (denied) return denied;
    if (!body.from || !body.through) return corsJson({ ok: false, error: "missing from/through" }, 400);
    return await calendarBusy(agencyId, body.from, body.through);
  }

  if (mode === "move_bookings") {
    // Admin from the slots calendar, or internal with the shared secret.
    const deniedAdmin = body.shared_secret ? null : await requireOwnerOrManager(req, agencyId);
    if (deniedAdmin) return deniedAdmin;
    if (body.shared_secret) { const denied = await requireSharedSecret(agencyId, body.shared_secret); if (denied) return denied; }
    if (!body.from || !body.through) return corsJson({ ok: false, error: "missing from/through" }, 400);
    return await moveBookings(agencyId, body.from, body.through, body.reason || "Our schedule changed that week,");
  }

  if (mode === "offer_earlier") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    const out = await offerEarlierTimes(agencyId);
    return jsonResponse({ ok: !out.error, ...out, records_processed: out.offered.length, output_summary: `${out.offered.length} earlier-time offer(s)` });
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
