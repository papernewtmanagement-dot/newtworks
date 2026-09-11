// =========================================================================
// hiring-interview-scheduler bundle (auto-generated)
// Source of truth: supabase/functions/hiring-interview-scheduler/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py hiring-interview-scheduler`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// ==================== _shared/supabase.ts ====================
// =========================================================================
// _shared/supabase.ts
// =========================================================================
// Canonical Supabase client + settings + response helpers for ALL Newtworks
// edge functions. Source of truth for code that used to be copy-pasted into
// every function (client creation, getSetting, jsonResponse, stripFences).
//
// Edge functions deploy as single-file bundles: `scripts/bundle_edge_fn.py`
// inlines this file into each function's bundle. Never edit a bundle by hand;
// edit here and rebundle every consumer.
// =========================================================================


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
// Two variants on purpose — they preserve the two behaviors that existed in
// the wild before consolidation:
//   getSetting        — THROWS if the settings table read itself errors
//                       (infra failure ≠ missing row). Use on critical paths.
//   getSettingOrNull  — swallows read errors, returns null. Use where the
//                       caller treats "can't read" the same as "not set".
// Both return null when the row simply doesn't exist.
// -------------------------------------------------------------------------

async function getSetting(
  agencyId: string,
  key: string,
): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(
      `settings read failed for agency ${agencyId} key ${key}: ${error.message}`,
    );
  }
  return data?.setting_value ?? null;
}

async function getSettingOrNull(
  agencyId: string,
  key: string,
): Promise<string | null> {
  try {
    const { data } = await sb
      .from("settings")
      .select("setting_value")
      .eq("agency_id", agencyId)
      .eq("setting_key", key)
      .maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) {
    return null;
  }
}

// Batch read — one query for N keys. Missing keys come back as null.
async function getSettings(
  agencyId: string,
  keys: string[],
): Promise<Record<string, string | null>> {
  const out: Record<string, string | null> = {};
  for (const k of keys) out[k] = null;
  const { data, error } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", keys);
  if (error) {
    throw new Error(`settings batch read failed for agency ${agencyId}: ${error.message}`);
  }
  for (const row of data ?? []) {
    out[(row as any).setting_key] = (row as any).setting_value ?? null;
  }
  return out;
}

// -------------------------------------------------------------------------
// HTTP responses
// -------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== _shared/auth.ts ====================
// =========================================================================
// _shared/auth.ts
// =========================================================================
// Canonical shared-secret gate for cron/internally-dispatched edge functions.
// The dispatch side (_dispatch_edge_fn, run_automation_recipe, automation-
// runner INTERNAL handlers) POSTs { agency_id, shared_secret } in the body;
// the secret must match settings.automation_runner_cron_secret.
//
// Usage in a handler:
//   const denied = await requireSharedSecret(agencyId, body.shared_secret);
//   if (denied) return denied;
// =========================================================================


async function requireSharedSecret(
  agencyId: string,
  provided: string | undefined | null,
): Promise<Response | null> {
  if (!provided) {
    return jsonResponse({ ok: false, error: "missing shared_secret" }, 401);
  }
  const expected = await getSettingOrNull(agencyId, "automation_runner_cron_secret");
  if (!expected || provided !== expected) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }
  return null;
}

// -------------------------------------------------------------------------
// Caller-identity gate for admin actions fired from the browser
// -------------------------------------------------------------------------
// Some functions serve BOTH public token-gated traffic — which forces
// verify_jwt to stay false at the platform level — AND admin-only actions
// triggered from inside the Newtworks app. Those admin actions get no help
// from the platform gate, so they check the caller here instead: the bearer
// token has to identify a real signed-in user, and that user's public.users
// row has to be an owner or manager of the agency being acted on.
//
// Same two-step check invite-team-member does inline. This is the shared copy
// so the next function that needs it does not write a third one.
//
// A shared secret would NOT do the job here. The call comes from a browser,
// and anything the browser can send, anyone reading the page can read.

const ADMIN_ROLES = ["owner", "manager"];

async function requireOwnerOrManager(
  req: Request,
  agencyId: string,
): Promise<Response | null> {
  const token = (req.headers.get("Authorization") || "").replace("Bearer ", "").trim();
  if (!token) return corsJson({ ok: false, error: "missing session token" }, 401);

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!anonKey) return corsJson({ ok: false, error: "auth unavailable" }, 500);

  // The anon key is also what an unauthenticated caller sends as its bearer
  // token, so getUser() failing here is the normal "nobody is signed in" path,
  // not an infrastructure problem.
  const caller = createClient(SUPABASE_URL, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoErr } = await caller.auth.getUser();
  if (whoErr || !who?.user) return corsJson({ ok: false, error: "invalid or expired session" }, 401);

  const { data: row, error: rowErr } = await sb
    .from("users")
    .select("role, agency_id")
    .eq("auth_user_id", who.user.id)
    .maybeSingle();
  if (rowErr) return corsJson({ ok: false, error: "could not verify caller" }, 500);
  if (!row || row.agency_id !== agencyId || !ADMIN_ROLES.includes(row.role as string)) {
    return corsJson({ ok: false, error: "not permitted" }, 403);
  }
  return null;
}

// ==================== _shared/alerts.ts ====================
// =========================================================================
// _shared/alerts.ts
// =========================================================================
// Canonical alerts writer for ALL Newtworks edge functions.
//
// Why this exists: the alerts table takes (alert_type NOT NULL, severity,
// title, message, module_reference, related_id, is_resolved). Hand-written
// inserts have shipped with a `body:` column that does not exist and with
// alert_type missing — both fail silently when the insert result isn't
// checked. Going through this helper makes that class of bug impossible.
// =========================================================================


async function insertAlert(opts: {
  agencyId: string;
  alertType: string;
  severity: "info" | "warning" | "high" | "critical" | string;
  title: string;
  message: string;
  moduleReference?: string;
  relatedId?: string | null;
}): Promise<{ ok: boolean; error: string | null }> {
  const row: Record<string, unknown> = {
    agency_id: opts.agencyId,
    alert_type: opts.alertType,
    severity: opts.severity,
    title: opts.title,
    message: opts.message,
    is_read: false,
    is_resolved: false,
  };
  if (opts.moduleReference != null) row.module_reference = opts.moduleReference;
  if (opts.relatedId != null) row.related_id = opts.relatedId;

  const { error } = await sb.from("alerts").insert(row);
  if (error) {
    // Never throw — alerting must not mask the underlying failure being
    // reported. But do surface the miss to whoever reads the function logs.
    console.error(`insertAlert failed (${opts.alertType}): ${error.message}`);
    return { ok: false, error: error.message };
  }
  return { ok: true, error: null };
}

// Resolve all open alerts carrying a given module_reference (the standard
// "this condition cleared" pattern used by surepayroll + pfa flows).
async function resolveAlerts(opts: {
  agencyId: string;
  moduleReference: string;
}): Promise<{ ok: boolean; resolved: number; error: string | null }> {
  const { data, error } = await sb
    .from("alerts")
    .update({ is_resolved: true, resolved_at: new Date().toISOString() })
    .eq("agency_id", opts.agencyId)
    .eq("module_reference", opts.moduleReference)
    .eq("is_resolved", false)
    .select("id");
  if (error) {
    console.error(`resolveAlerts failed (${opts.moduleReference}): ${error.message}`);
    return { ok: false, resolved: 0, error: error.message };
  }
  return { ok: true, resolved: (data ?? []).length, error: null };
}

// ==================== _shared/composio.ts ====================
// =========================================================================
// _shared/composio.ts
// =========================================================================
// Canonical Composio HTTP wrapper for Newtworks edge functions.
//
// This file used to CLAIM to be "the one true copy" while three others
// existed: document-processor/lib/composio.ts (a fork that had timeout
// handling this one lacked), plus inline copies in automation-runner and
// generate-custom-probes. The 2026-08-06 fix for hung calls therefore landed
// in exactly one of the four, and automation-runner — which drives every
// scheduled Gmail parser — went five days still able to die as an uncaught
// exception. Consolidated 2026-08-11: the timeout handling lives HERE now, so
// a fix applied once is a fix applied everywhere.
//
// TIMEOUTS, and why they are not optional. An external call that hangs is not
// an error the calling code can catch. It runs until the Supabase platform's
// own wall-clock limit kills the whole invocation, surfacing as status 546
// with no stack and no log line. On a cron path that is close to invisible:
// the run simply never reports. Every call through this file is bounded, and a
// timeout comes back as an ordinary {ok:false} result the caller can handle.
//
// NO RETRIES here, on purpose. Retrying a hang doubles the wait and can push
// an otherwise-healthy invocation over the platform limit too. Retry is a
// separate decision belonging to the caller.
// =========================================================================


const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

/** Default ceiling for any single Composio call. Well under the platform
 *  wall-clock limit so a stuck call fails fast AND catchably. */
const COMPOSIO_TIMEOUT_MS = 25000;

/** Same number, separate name: storage/S3 downloads are a distinct concern
 *  that happens to want the same ceiling. Kept apart so changing one does not
 *  silently change the other. */
const S3_FETCH_TIMEOUT_MS = 25000;

/** Where a timeout should be reported, if anywhere. Omit entirely and a
 *  timeout returns a clean failed result without writing an alert — correct
 *  for callers that already record their own failures (automation-runner logs
 *  every recipe failure to automation_run_log and Telegram). */
interface TimeoutAlertTarget {
  agencyId?: string;
  moduleReference: string;
  context: string;
}

async function writeTimeoutAlert(
  service: string,
  elapsedMs: number,
  target: TimeoutAlertTarget,
): Promise<void> {
  try {
    await insertAlert({
      agencyId: target.agencyId ?? AGENCY_ID_DEFAULT,
      alertType: "external_call_timeout",
      severity: "warning",
      title: `${service} call timed out`,
      message: `${service} call did not respond within ${elapsedMs}ms and was aborted. Context: ${target.context}`,
      moduleReference: target.moduleReference,
    });
  } catch (_e) {
    // Best-effort. Must never mask the original timeout or throw a second
    // uncaught exception on the way out.
  }
}

/**
 * fetch() with a hard time limit. Returns res:null on timeout or throw, never
 * rejects. Use this for ANY outbound call in an edge function, not just
 * Composio ones — a bare fetch() to Google, Groq or storage carries exactly
 * the same hang risk.
 */
async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  service: string,
  context: string,
  alertTarget?: TimeoutAlertTarget,
): Promise<{ res: Response | null; timedOut: boolean; elapsedMs: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();
  try {
    const res = await fetch(url, { ...init, signal: controller.signal });
    return { res, timedOut: false, elapsedMs: Date.now() - startedAt };
  } catch (e) {
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut && alertTarget) {
      await writeTimeoutAlert(service, elapsedMs, alertTarget);
    } else if (!timedOut) {
      console.error(`[${service}] fetch threw after ${elapsedMs}ms (${context}): ${e instanceof Error ? e.message : String(e)}`);
    }
    return { res: null, timedOut, elapsedMs };
  } finally {
    clearTimeout(timer);
  }
}

function unwrapComposio(text: string, httpOk: boolean, status: number): ComposioCallResult {
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = httpOk && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: status };
}

function composioTimeoutResult(slug: string, timedOut: boolean, elapsedMs: number): ComposioCallResult {
  return {
    ok: false,
    data: null,
    httpStatus: 0,
    error: timedOut
      ? `Composio ${slug} did not respond within ${elapsedMs}ms and was aborted`
      : `Composio ${slug} fetch failed after ${elapsedMs}ms`,
  };
}

interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  /**
   * Which published set of tools to use. LEAVE THIS UNSET unless you have a
   * reason not to.
   *
   * Composio publishes its tools in dated sets. A request that does not name a
   * set gets the oldest one, which holds far fewer tools than the account
   * actually has — 51 Google Drive tools instead of 90. Anything missing from
   * that oldest set answers "Tool ... not found", which reads exactly like a
   * permission problem and is not one. Two months of Drive filing and every
   * scanned resume were lost to this, and four rounds of fixing went at the
   * wrong layer, because a tool tested by hand goes through a connection that
   * DOES name a set and therefore always worked.
   *
   * It is set per request on purpose. Naming a newer set changes the shape of
   * what comes back, and the payroll, bank statement and comp parsers all read
   * those shapes. So each caller opts in where it has been checked, rather than
   * one flip changing everything at once.
   */
  toolkitVersion?: string;
  timeoutMs?: number;
  alertTarget?: TimeoutAlertTarget;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        connected_account_id: opts.connectedAccountId,
        arguments: opts.toolArguments,
        ...(opts.toolkitVersion ? { version: opts.toolkitVersion } : {}),
      }),
    },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS,
    `composio:${opts.toolSlug}`,
    `tool=${opts.toolSlug}`,
    opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

async function callComposioNoAuth(opts: {
  apiKey: string;
  userId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  timeoutMs?: number;
  alertTarget?: TimeoutAlertTarget;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await fetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        arguments: opts.toolArguments,
      }),
    },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS,
    `composio:${opts.toolSlug}`,
    `tool=${opts.toolSlug} (no connected account)`,
    opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

// ==================== _shared/gmail.ts ====================
// =========================================================================
// _shared/gmail.ts
// =========================================================================
// Canonical "send an email through Composio Gmail" path for ALL Newtworks
// edge functions. Replaces the settings-triplet fetch + GMAIL_SEND_EMAIL
// call that used to be copy-pasted into txn-coding-question-mailer,
// license-reminder-runner, pfa-reconciliation-send, terminate-team-member
// and the document-processor wrap-up parsers.
//
// The sender account is Composio-managed paper.newt.management@gmail.com.
// =========================================================================


interface GmailCreds {
  apiKey: string;
  userId: string;
  accountId: string;
}

// One batch settings query for the three Composio Gmail credentials.
async function getComposioGmailCreds(
  agencyId: string,
): Promise<{ ok: true; creds: GmailCreds } | { ok: false; error: string }> {
  let map: Record<string, string | null>;
  try {
    map = await getSettings(agencyId, [
      "composio_api_key",
      "composio_user_id",
      "composio_gmail_account_id",
    ]);
  } catch (e) {
    return { ok: false, error: `settings read failed: ${(e as Error).message}` };
  }
  const apiKey = map["composio_api_key"];
  const userId = map["composio_user_id"];
  const accountId = map["composio_gmail_account_id"];
  if (!apiKey || !userId || !accountId) {
    return { ok: false, error: "missing Composio Gmail credentials in settings" };
  }
  return { ok: true, creds: { apiKey, userId, accountId } };
}

// Send one email. Exactly one of html / text should be provided.
// attachment (if any) must already be staged with Composio — GMAIL_SEND_EMAIL
// only accepts { name, mimetype, s3key } pointers, never raw bytes.
async function sendGmail(opts: {
  creds: GmailCreds;
  to: string;
  subject: string;
  html?: string;
  text?: string;
  cc?: string[];
  attachment?: { name: string; mimetype: string; s3key: string };
}): Promise<ComposioCallResult> {
  const args: Record<string, any> = {
    recipient_email: opts.to,
    subject: opts.subject,
    body: opts.html ?? opts.text ?? "",
    is_html: opts.html != null,
    user_id: "me",
  };
  if (opts.cc && opts.cc.length > 0) args.cc = opts.cc;
  if (opts.attachment) args.attachment = opts.attachment;

  return await callComposio({
    apiKey: opts.creds.apiKey,
    userId: opts.creds.userId,
    connectedAccountId: opts.creds.accountId,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolArguments: args,
  });
}

// ==================== _shared/html.ts ====================
// =========================================================================
// _shared/html.ts
// =========================================================================
// Tiny HTML helpers shared across the email-composing edge functions.
// Formatting helpers (money, dates) stay LOCAL to each function on purpose —
// their formats genuinely differ per surface and unifying them would change
// live email output.
// =========================================================================

function escHtml(s: string | null | undefined): string {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ==================== hiring-interview-scheduler/index.ts ====================
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
//     Care 24:377) where two reminders beat one: a confirm-or-reschedule
//     email two days before, and a morning-of reminder. Both carry
//     Yes / Reschedule / No-longer-interested links.
//
//   mode="respond"  (public, token gated)
//     The candidate answered a reminder link. confirm stamps the
//     confirmation; reschedule cancels the calendar event, frees the slot
//     and re-offers times; withdraw frees the slot and declines the
//     candidate as candidate_withdrew.
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

// Weekly interview schedule (Chicago local time), Peter directive 2026-09-11.
// getUTCDay()-style weekday numbering (0=Sun..6=Sat) applied to a date built
// from Chicago-local Y/M/D — same convention isWeekend() uses.
//
// PRIMARY times are always offered. SECONDARY times are backups: they are
// only offered once the primary times inside the 7-day offer window are
// booked (see pickOffers). No Thursday-morning backup, no Wednesday-afternoon
// backup — both Peter's call. Third Friday of the month has no slots at all.
type SlotTier = "primary" | "secondary";
const PRIMARY_TIMES_BY_WEEKDAY: Record<number, { h: number; m: number }[]> = {
  1: [{ h: 10, m: 0 }, { h: 13, m: 0 }, { h: 15, m: 30 }], // Monday
  2: [{ h: 10, m: 0 }, { h: 13, m: 0 }, { h: 15, m: 30 }], // Tuesday
  3: [{ h: 10, m: 0 }, { h: 13, m: 0 }],                   // Wednesday
  4: [{ h: 13, m: 0 }, { h: 15, m: 30 }],                  // Thursday
  5: [{ h: 13, m: 0 }],                                    // Friday (see isThirdFriday exclusion)
};
const SECONDARY_TIMES_BY_WEEKDAY: Record<number, { h: number; m: number }[]> = {
  1: [{ h: 10, m: 45 }, { h: 16, m: 15 }], // Monday
  2: [{ h: 10, m: 45 }, { h: 16, m: 15 }], // Tuesday
  3: [{ h: 10, m: 45 }],                   // Wednesday (no afternoon backup)
  4: [{ h: 16, m: 15 }],                   // Thursday (no morning backup)
  5: [{ h: 10, m: 45 }, { h: 16, m: 15 }], // Friday (see isThirdFriday exclusion)
};
const OFFER_COUNT = 4;        // how many open times a candidate is shown
const OFFER_WINDOW_DAYS = 7;  // ... drawn from the next 7 days

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
interface Slot { start: string; end: string; dateKey: string; tier?: SlotTier; } // dateKey = Chicago YYYY-MM-DD

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
    if (!isThirdFriday(cy, cm, cd)) {
      const dateKey = `${cy}-${String(cm).padStart(2, "0")}-${String(cd).padStart(2, "0")}`;
      const tiers: [SlotTier, { h: number; m: number }[]][] = [
        ["primary", PRIMARY_TIMES_BY_WEEKDAY[dow] ?? []],
        ["secondary", SECONDARY_TIMES_BY_WEEKDAY[dow] ?? []],
      ];
      for (const [tier, times] of tiers) {
        for (const t of times) {
          const start = chicagoLocalToUtc(cy, cm, cd, t.h, t.m);
          const end = new Date(start.getTime() + INTERVIEW_MINUTES * 60000);
          grid.push({ start: start.toISOString(), end: end.toISOString(), dateKey, tier });
        }
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
      grid.push({ start: start.toISOString(), end: end.toISOString(), dateKey: m.slot_date, tier: "primary" });
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
  return pickOffers(free, now);
}

// -------------------------------------------------------------------------
// Email bodies
// -------------------------------------------------------------------------
const PREP_LINE = "This is an Interview AMA — please take some time beforehand to research Story Agency and State Farm, and come ready with your own questions for us.";

function inviteEmailHtml(firstName: string, bookingUrl: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>Thank you for completing our assessment — we'd like to move forward with an Interview AMA.</p>
<p>It's a video call (about 30 minutes) over Google Meet. Please pick a time that works for you:</p>
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
    .select("first_name, candidate_name, position, interview_slots_offered, interview_booking_expires_at, interview_booked_at, interview_scheduled_start, interview_meet_url, interview_confirmed_at")
    .eq("interview_invite_token", token)
    .maybeSingle();
  if (error || !c) return corsJson({ ok: false, error: "not_found" }, 404);

  if (c.interview_booked_at) {
    return corsJson({
      ok: true,
      already_booked: true,
      confirmed: !!c.interview_confirmed_at,
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
    interview_confirmed_at: null,
    interview_reminder_2d_sent_at: null,
    interview_reminder_day_sent_at: null,
    interview_reminder_response: null,
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
// Reminders + candidate responses
// -------------------------------------------------------------------------
type ReminderKind = "two_days" | "day_of";
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

function reminderEmailHtml(firstName: string, startLocal: string, meetUrl: string | null, token: string, kind: ReminderKind, confirmed: boolean): string {
  const meetLine = meetUrl
    ? `<p>Google Meet link: <a href="${escHtml(meetUrl)}">${escHtml(meetUrl)}</a></p>`
    : `<p>The Google Meet link is in your calendar invite.</p>`;
  const opener = kind === "day_of"
    ? `<p>Your Interview AMA with Story Agency is <strong>today, ${escHtml(startLocal)}</strong> (Central time). It's a 30-minute video call.</p>`
    : `<p>A quick reminder that your Interview AMA with Story Agency is <strong>${escHtml(startLocal)}</strong> (Central time). It's a 30-minute video call over Google Meet.</p>`;
  const ask = confirmed
    ? `<p>You've already confirmed, so we're all set. If anything changes, use the links below.</p>${responseButtonsHtml(token)}`
    : `<p>Can you confirm you'll be there? One tap:</p>${responseButtonsHtml(token)}`;
  return `<p>Hi ${escHtml(firstName)},</p>
${opener}
${meetLine}
${ask}
<p>${escHtml(PREP_LINE)}</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

function reminderSubject(startLocal: string, kind: ReminderKind, confirmed: boolean): string {
  if (kind === "day_of") return `Today: your Interview AMA with Story Agency (${startLocal})`;
  return confirmed ? `Reminder: your Interview AMA is ${startLocal}` : `Still good for ${startLocal}? Your Interview AMA`;
}

async function cancelCalendarEvent(agencyId: string, eventId: string | null): Promise<{ ok: boolean; error?: string }> {
  if (!eventId) return { ok: true };
  const creds = await getCalendarCreds(agencyId);
  if (!creds) return { ok: false, error: "calendar creds missing" };
  const res = await callComposio({
    apiKey: creds.apiKey,
    userId: creds.userId,
    connectedAccountId: creds.accountId,
    toolSlug: "GOOGLECALENDAR_DELETE_EVENT",
    toolArguments: { calendar_id: CALENDAR_ID, event_id: eventId, send_updates: "all" },
  });
  return res.ok ? { ok: true } : { ok: false, error: res.error ?? "unknown" };
}

// -------------------------------------------------------------------------
// mode=send_reminders  (internal, shared_secret gated)
// -------------------------------------------------------------------------
// Two days before: confirm-or-reschedule ask. Morning of: reminder with the
// Meet link (still carrying the response links if unconfirmed). A booking
// made with less than two days' notice gets the ask the morning before, so
// nobody is skipped. Idempotent per touch via the *_sent_at stamps.
async function sendReminders(agencyId: string): Promise<Response> {
  const now = new Date();
  const todayKey = chicagoDateKey(now);
  const { data: rows, error } = await sb
    .from("hiring_candidates")
    .select("id, first_name, candidate_name, email, status, interview_invite_token, interview_scheduled_start, interview_meet_url, interview_confirmed_at, interview_reminder_2d_sent_at, interview_reminder_day_sent_at")
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
    let kind: ReminderKind | null = null;
    if (daysAhead === 0 && !c.interview_reminder_day_sent_at) kind = "day_of";
    else if (daysAhead >= 1 && daysAhead <= 2 && !c.interview_reminder_2d_sent_at) kind = "two_days";
    if (!kind) continue;

    const firstName = c.first_name || (c.candidate_name || "").split(" ")[0] || "there";
    const startLocal = formatChicago(c.interview_scheduled_start);
    const confirmed = !!c.interview_confirmed_at;
    const sendRes = await sendGmail({
      creds: gmailCreds.creds,
      to: c.email,
      subject: reminderSubject(startLocal, kind, confirmed),
      html: reminderEmailHtml(firstName, startLocal, c.interview_meet_url, c.interview_invite_token, kind, confirmed),
    });
    if (!sendRes.ok) { results.push({ id: c.id, name: c.candidate_name, action: "send_failed", kind, error: sendRes.error }); continue; }
    const stamp = kind === "day_of" ? { interview_reminder_day_sent_at: now.toISOString() } : { interview_reminder_2d_sent_at: now.toISOString() };
    await sb.from("hiring_candidates").update(stamp).eq("id", c.id);
    results.push({ id: c.id, name: c.candidate_name, action: "sent", kind, confirmed, days_ahead: daysAhead });

    // Morning of, still no answer to the two-day ask -> Peter hears about it
    // before he sits down for a call nobody joins. Telegram DM via the
    // paper_newt bot, same channel the task reminders use.
    if (kind === "day_of" && !confirmed) {
      const dm = await notifyOwnerUnconfirmed(agencyId, c, startLocal);
      results[results.length - 1].owner_notified = dm;
    }
  }
  const sent = results.filter((r) => r.action === "sent").length;
  return jsonResponse({
    ok: true, today: todayKey, scanned: (rows ?? []).length, sent, results,
    records_processed: sent,
    output_summary: sent === 0 ? `no interview reminders due (${(rows ?? []).length} upcoming)` : `sent ${sent} interview reminder(s)`,
  });
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
      meet_url: c.interview_meet_url, prep_line: PREP_LINE,
    });
  }

  // reschedule or withdraw: the booked time goes back on the board.
  const cancel = await cancelCalendarEvent(agencyId, c.interview_calendar_event_id);
  const cleared = {
    interview_scheduled_start: null,
    interview_scheduled_end: null,
    interview_calendar_event_id: null,
    interview_meet_url: null,
    interview_booked_at: null,
    interview_confirmed_at: null,
    interview_reminder_2d_sent_at: null,
    interview_reminder_day_sent_at: null,
  };

  if (action === "withdraw") {
    const { error: updErr } = await sb.from("hiring_candidates").update({
      ...cleared,
      interview_reminder_response: "withdrew",
      status: "declined",
      decline_reason: "candidate_withdrew",
      status_updated_at: new Date().toISOString(),
    }).eq("id", c.id);
    if (updErr) return corsJson({ ok: false, error: "db_update_failed", detail: updErr.message }, 500);
    return corsJson({ ok: true, action, first_name: firstName, calendar_canceled: cancel.ok });
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
      await sendGmail({
        creds: gmailCreds.creds,
        to: c.email,
        subject: "Pick a new time for your Interview AMA — Story Agency",
        html: inviteEmailHtml(firstName, `${BOOKING_BASE_URL}/${token}`),
      });
    }
  }
  return corsJson({
    ok: true, action, first_name: firstName, calendar_canceled: cancel.ok, prep_line: PREP_LINE,
    slots: slots.map((s) => ({ start: s.start, end: s.end, display: formatChicago(s.start) })),
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

  if (mode === "respond") {
    if (!body.token) return corsJson({ ok: false, error: "missing token" }, 400);
    if (!["confirm", "reschedule", "withdraw"].includes(body.action)) return corsJson({ ok: false, error: "bad action" }, 400);
    return await respond(agencyId, body.token, body.action as RespondAction);
  }

  if (mode === "send_reminders") {
    const denied = await requireSharedSecret(agencyId, body.shared_secret);
    if (denied) return denied;
    return await sendReminders(agencyId);
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
