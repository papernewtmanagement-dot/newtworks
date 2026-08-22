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
// Candidates never see or touch Peter's calendar directly — only the
// slots this function computed and offered.
// =========================================================================


const TZ = "America/Chicago";
const CALENDAR_ID = "primary";
const INTERVIEW_MINUTES = 35;
const LOOKAHEAD_DAYS = 45; // calendar days scanned forward for eligible slots
const BOOKING_WINDOW_DAYS = 7; // link expiry
const BOOKING_BASE_URL = "https://newtworks.vercel.app/schedule";

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
function declineEmailHtml(firstName: string): string {
  return `<p>Hi ${escHtml(firstName)},</p>
<p>Thank you for taking the time to complete our assessment and for your interest in joining our team. After reviewing your results, we've decided to move forward with other candidates for this role.</p>
<p>We know that takes real time and effort on your part, and we appreciate you putting it in. We wish you the very best in your search.</p>
<p>Sincerely,<br/>Story Agency</p>`;
}

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

  return jsonResponse({ ok: false, error: "unknown mode" }, 400);
});
