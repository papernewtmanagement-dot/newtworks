// =========================================================================
// pfa-reconciliation-send bundle (auto-generated)
// Source of truth: supabase/functions/pfa-reconciliation-send/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py pfa-reconciliation-send`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { PDFDocument, StandardFonts, rgb, PDFPage, PDFFont } from "npm:pdf-lib@1.17.1";
import SparkMD5 from "npm:spark-md5@3.0.2";

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

// ==================== pfa-reconciliation-send/index.ts ====================
// =========================================================================
// pfa-reconciliation-send edge function
// =========================================================================
// Generates the SF-required PFA Bank Reconciliation PDF and emails it to
// peter.story.yrru@statefarm.com from paper.newt.management@gmail.com via
// Composio Gmail.
//
// Called two ways:
//   1. RPC pfa_send_reconciliation(recon_id, force) → shared_secret + http_post
//   2. Automation recipe pfa_monthly_reconciliation → same RPC on clean recons
//
// AUTH: POST body must include shared_secret matching the agency's
// automation_runner_cron_secret setting.
//
// LAYOUT: Matches operational_rule "PFA reconciliation PDF layout spec".
// Single page. Colors: light blue #eef3fa for enter-here, pale yellow #fff9c4
// for locked, pale orange #fce4c4 for DIFFERENCE TO RECONCILE only.
// HARD RULE: NO Newtworks self-attribution footer.
// =========================================================================


const SF_RECIPIENT = "peter.story.yrru@statefarm.com";

// =========================================================================
// Composio file staging  (added 2026-08-04)
// =========================================================================
// GMAIL_SEND_EMAIL's `attachment` parameter is a FileUploadable and accepts
// EXACTLY { name, mimetype, s3key }. There is no field anywhere on that tool
// that takes raw base64 bytes. The previous version of this function passed
// base64 in invented fields (`attachments[].content`, `attached_file`) with an
// empty s3key, so every send failed Composio schema validation before it ever
// reached Gmail. That is why no PFA reconciliation has ever been emailed
// automatically -- the only one that landed (June 2026) was sent by hand as a
// Gmail draft, which is why that row carries an email_gmail_draft_id and the
// July row carries nothing.
//
// Correct flow, reachable with only the agency's composio_api_key:
//   1. POST /api/v3/files/upload/request -> { key, new_presigned_url, type }
//   2. PUT the raw bytes to new_presigned_url with a matching Content-Type
//   3. Pass { name, mimetype, s3key: key } as `attachment`
async function stageFileWithComposio(opts: {
  apiKey: string;
  fileName: string;
  mimeType: string;
  bytes: Uint8Array;
  toolSlug: string;
  toolkitSlug: string;
}): Promise<{ ok: boolean; s3key: string | null; error: string | null }> {
  let md5: string;
  try {
    const ab = opts.bytes.buffer.slice(
      opts.bytes.byteOffset,
      opts.bytes.byteOffset + opts.bytes.byteLength,
    );
    md5 = SparkMD5.ArrayBuffer.hash(ab);
  } catch (e) {
    return { ok: false, s3key: null, error: `md5 failed: ${e instanceof Error ? e.message : String(e)}` };
  }

  let presignRes: Response;
  try {
    presignRes = await fetch("https://backend.composio.dev/api/v3/files/upload/request", {
      method: "POST",
      headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
      body: JSON.stringify({
        filename: opts.fileName,
        mimetype: opts.mimeType,
        md5,
        tool_slug: opts.toolSlug,
        toolkit_slug: opts.toolkitSlug,
      }),
    });
  } catch (e) {
    return { ok: false, s3key: null, error: `presign threw: ${e instanceof Error ? e.message : String(e)}` };
  }
  const presignText = await presignRes.text();
  if (!presignRes.ok) {
    return { ok: false, s3key: null, error: `presign HTTP ${presignRes.status}: ${presignText.slice(0, 300)}` };
  }
  let presign: any;
  try { presign = JSON.parse(presignText); }
  catch { return { ok: false, s3key: null, error: `presign not JSON: ${presignText.slice(0, 200)}` }; }

  const uploadUrl: string | undefined = presign?.new_presigned_url ?? presign?.newPresignedUrl;
  const s3key: string | undefined = presign?.key;
  if (!uploadUrl || !s3key) {
    return { ok: false, s3key: null, error: `presign missing key/url: ${presignText.slice(0, 300)}` };
  }

  // type === "old" means Composio already holds this exact file (md5 match), so
  // the PUT is unnecessary. Re-uploading would be harmless, just wasteful.
  if (presign?.type !== "old") {
    let putRes: Response;
    try {
      putRes = await fetch(uploadUrl, {
        method: "PUT",
        headers: { "Content-Type": opts.mimeType },
        body: opts.bytes,
      });
    } catch (e) {
      return { ok: false, s3key: null, error: `upload PUT threw: ${e instanceof Error ? e.message : String(e)}` };
    }
    if (!putRes.ok) {
      const t = await putRes.text().catch(() => "");
      return { ok: false, s3key: null, error: `upload PUT HTTP ${putRes.status}: ${t.slice(0, 300)}` };
    }
  }

  return { ok: true, s3key, error: null };
}

// Silent failure is what let this break for a month: the SQL function returned
// success, the runner logged success, and nothing anywhere said the compliance
// email had not gone out. Any send failure now leaves a durable unresolved
// alert row so it surfaces in the app instead of only in a log nobody reads.
async function raiseSendFailureAlert(
  agencyId: string,
  reconciliationId: string,
  periodEnd: string,
  detail: string,
): Promise<void> {
  await insertAlert({
    agencyId,
    alertType: "pfa_reconciliation_send_failed",
    severity: "warning",
    title: `PFA reconciliation email did NOT send — statement ending ${periodEnd}`,
    message: `The reconciliation for the PFA statement ending ${periodEnd} computed clean, but the email to State Farm failed. Nothing has been filed for this period. Detail: ${detail.slice(0, 500)}`,
    moduleReference: `pfa_reconciliation_send_failed:${reconciliationId}`,
    relatedId: reconciliationId,
  });
}

// =========================================================================
// Number & date formatting
// =========================================================================
function fmtMoney(n: number): string {
  const neg = n < 0;
  const abs = Math.abs(n);
  const s = abs.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return neg ? `-$${s}` : `$${s}`;
}

const MONTH_NAMES = ["January","February","March","April","May","June","July","August","September","October","November","December"];

function fmtMonthYear(iso: string): string {
  const [y, m] = iso.split("-").map(Number);
  return `${MONTH_NAMES[m - 1]} ${y}`;
}
function fmtLongDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  return `${MONTH_NAMES[m - 1]} ${d}, ${y}`;
}
// Today in America/Chicago as YYYY-MM-DD. The agency runs on Central for every
// date-bearing surface (calendar conventions principle), and a UTC "today" would
// print tomorrow's date on the form for anything sent after 6 or 7 PM local.
function todayCentralIso(): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Chicago", year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "01";
  return `${get("year")}-${get("month")}-${get("day")}`;
}
function fmtShortMMDD(iso: string): string {
  const [_, m, d] = iso.split("-").map(Number);
  return `${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

// =========================================================================
// Colors
// =========================================================================
const COLOR_LT_BLUE   = rgb(0xEE / 255, 0xF3 / 255, 0xFA / 255);   // #eef3fa
const COLOR_PL_YELLOW = rgb(0xFF / 255, 0xF9 / 255, 0xC4 / 255);   // #fff9c4
const COLOR_PL_ORANGE = rgb(0xFC / 255, 0xE4 / 255, 0xC4 / 255);   // #fce4c4
const COLOR_BLACK     = rgb(0, 0, 0);
const COLOR_GRAY      = rgb(0.55, 0.55, 0.55);
const COLOR_BORDER    = rgb(0.35, 0.35, 0.35);

// =========================================================================
// Draw helpers
// =========================================================================
interface DrawCtx { page: PDFPage; regular: PDFFont; bold: PDFFont; italic: PDFFont; }

function drawText(ctx: DrawCtx, text: string, x: number, y: number, opts: { size?: number; font?: PDFFont; color?: any } = {}) {
  ctx.page.drawText(text, {
    x, y, size: opts.size ?? 10,
    font: opts.font ?? ctx.regular,
    color: opts.color ?? COLOR_BLACK,
  });
}

function drawRect(ctx: DrawCtx, x: number, y: number, w: number, h: number, fillColor: any, borderColor: any = COLOR_BORDER, borderWidth = 0.5) {
  ctx.page.drawRectangle({ x, y, width: w, height: h, color: fillColor, borderColor, borderWidth });
}

function drawLine(ctx: DrawCtx, x1: number, y1: number, x2: number, y2: number, color: any = COLOR_BLACK, thickness = 0.5) {
  ctx.page.drawLine({ start: { x: x1, y: y1 }, end: { x: x2, y: y2 }, color, thickness });
}

// Draw right-aligned text within a box
function drawTextRightAligned(ctx: DrawCtx, text: string, boxX: number, boxY: number, boxWidth: number, opts: { size?: number; font?: PDFFont; padding?: number } = {}) {
  const size = opts.size ?? 10;
  const font = opts.font ?? ctx.regular;
  const padding = opts.padding ?? 4;
  const textWidth = font.widthOfTextAtSize(text, size);
  drawText(ctx, text, boxX + boxWidth - textWidth - padding, boxY, { size, font });
}

// =========================================================================
// PDF layout
// =========================================================================
interface ReconData {
  agent_name: string;
  prepared_date: string;
  agent_code: string;
  bank_name: string;
  bank_mailing_address: string;
  account_number: string;
  statement_period_start: string;
  statement_period_end: string;
  statement_ending_balance: number;
  outstanding_checks_total: number;
  outstanding_sf_eft_total: number;
  outstanding_deposits_total: number;
  returned_checks_unreimbursed: number;
  adjusted_statement_balance: number;
  prior_personal_funds: number;
  current_bank_service_fees: number;
  difference_to_reconcile: number;
  explanation: string;
}

function buildPdfBytes(data: ReconData): Promise<Uint8Array> {
  return (async () => {
    const pdf = await PDFDocument.create();
    const page = pdf.addPage([612, 792]); // US Letter
    const regular = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const italic = await pdf.embedFont(StandardFonts.HelveticaOblique);
    const ctx: DrawCtx = { page, regular, bold, italic };

    // Layout constants
    const PW = 612, PH = 792;
    const MARGIN = 40;
    const CONTENT_W = PW - MARGIN * 2;   // 532
    const LABEL_COL_W = 320;
    const VALUE_COL_W = 130;
    const VALUE_COL_X = MARGIN + LABEL_COL_W;

    let y = PH - 45; // top of content, decreasing as we go down

    // ---- Title ----
    const title = "Premium Fund Account Bank Reconciliation";
    const titleWidth = bold.widthOfTextAtSize(title, 14);
    drawText(ctx, title, (PW - titleWidth) / 2, y, { size: 14, font: bold });
    y -= 28;

    // ---- Agent and Bank Information ----
    drawText(ctx, "Agent and Bank Information:", MARGIN, y, { size: 11, font: bold });
    y -= 16;

    const infoRow = (label: string, value: string) => {
      drawText(ctx, label, MARGIN + 4, y, { size: 10, font: bold });
      drawText(ctx, value, MARGIN + 160, y, { size: 10 });
      y -= 13;
    };
    infoRow("Agent Name:",          data.agent_name);
    infoRow("Agent Code:",          data.agent_code);
    infoRow("Bank Name:",           data.bank_name);
    infoRow("Bank Mailing Address:", data.bank_mailing_address);
    infoRow("Account Number:",       data.account_number);
    y -= 4;

    // ---- Statement inputs (light blue bg) ----
    const inputsHeight = 40;
    drawRect(ctx, MARGIN, y - inputsHeight, CONTENT_W, inputsHeight, COLOR_LT_BLUE);
    let iy = y - 14;
    drawText(ctx, "Enter Statement Ending Date here:", MARGIN + 6, iy, { size: 10, font: bold });
    drawText(ctx, fmtLongDate(data.statement_period_end), MARGIN + 260, iy, { size: 10 });
    iy -= 18;
    drawText(ctx, "Enter Ending Balance on Bank Statement:", MARGIN + 6, iy, { size: 10, font: bold });
    drawText(ctx, fmtMoney(data.statement_ending_balance), MARGIN + 260, iy, { size: 10 });
    y -= inputsHeight + 12;

    // ---- Uncleared items section ----
    drawText(ctx, "Uncleared PFA checks & pending EFT transactions:", MARGIN, y, { size: 11, font: bold });
    y -= 14;

    const unclearedRow = (label: string, sign: string, value: number, yellowBg = true) => {
      const rowH = 16;
      // Value box on right (yellow bg)
      if (yellowBg) {
        drawRect(ctx, VALUE_COL_X, y - rowH + 3, VALUE_COL_W, rowH, COLOR_PL_YELLOW);
      }
      drawText(ctx, label, MARGIN + 4, y - 10, { size: 9.5 });
      drawText(ctx, sign, VALUE_COL_X - 22, y - 10, { size: 10, font: bold });
      drawTextRightAligned(ctx, fmtMoney(value), VALUE_COL_X, y - 10, VALUE_COL_W, { size: 10 });
      y -= rowH + 2;
    };
    unclearedRow('(-) Outstanding PFA checks marked "No"', "(-)", data.outstanding_checks_total);
    unclearedRow('(+) Missing deposit marked "No"',        "(+)", data.outstanding_deposits_total);
    unclearedRow('(-) Outstanding SF withdrawals (EFT) marked "No"', "(-)", data.outstanding_sf_eft_total);
    unclearedRow("(-) Returned checks total (unreimbursed)", "(-)", data.returned_checks_unreimbursed);
    y -= 6;

    // ---- Adjusted statement balance (bordered highlight) ----
    {
      const rowH = 20;
      drawRect(ctx, MARGIN, y - rowH + 3, CONTENT_W, rowH, COLOR_PL_YELLOW, COLOR_BLACK, 1);
      drawText(ctx, "Adjusted statement balance (current balance of agent's personal funds):",
        MARGIN + 6, y - 12, { size: 10, font: bold });
      drawText(ctx, "(=)", VALUE_COL_X - 22, y - 12, { size: 10, font: bold });
      drawTextRightAligned(ctx, fmtMoney(data.adjusted_statement_balance),
        VALUE_COL_X, y - 12, VALUE_COL_W, { size: 10.5, font: bold });
      y -= rowH + 8;
    }

    // ---- 4-row block ending in DIFFERENCE ----
    const blockRow = (label: string, sign: string, value: number, bg: any, bold_?: boolean) => {
      const rowH = 18;
      drawRect(ctx, VALUE_COL_X, y - rowH + 3, VALUE_COL_W, rowH, bg);
      drawText(ctx, label, MARGIN + 4, y - 11, { size: 10, font: bold_ ? bold : regular });
      drawText(ctx, sign, VALUE_COL_X - 22, y - 11, { size: 10, font: bold });
      drawTextRightAligned(ctx, fmtMoney(value), VALUE_COL_X, y - 11, VALUE_COL_W, {
        size: 10, font: bold_ ? bold : regular,
      });
      y -= rowH + 2;
    };
    blockRow("Agent's Personal Funds from previous month:", "", data.prior_personal_funds, COLOR_LT_BLUE);
    blockRow("Current bank service fees:",                  "(-)", data.current_bank_service_fees, COLOR_LT_BLUE);
    blockRow("Adjusted:",                                    "(=)", data.prior_personal_funds - data.current_bank_service_fees, COLOR_PL_YELLOW);
    blockRow("DIFFERENCE TO RECONCILE (list action taken to resolve below):",
             "(=)", data.difference_to_reconcile, COLOR_PL_ORANGE, true);
    y -= 8;

    // ---- Explanation section ----
    drawText(ctx, "Explanation of unresolved 'difference to reconcile':", MARGIN, y, { size: 11, font: bold });
    y -= 14;
    // Wrap explanation text into lines that fit CONTENT_W
    const wrapText = (text: string, maxWidth: number, size: number, font: PDFFont): string[] => {
      if (!text) return [];
      const words = text.split(/\s+/);
      const lines: string[] = [];
      let current = "";
      for (const w of words) {
        const trial = current ? `${current} ${w}` : w;
        if (font.widthOfTextAtSize(trial, size) <= maxWidth) {
          current = trial;
        } else {
          if (current) lines.push(current);
          current = w;
        }
      }
      if (current) lines.push(current);
      return lines;
    };
    const explLines = wrapText(data.explanation || "N/A — reconciliation balanced.", CONTENT_W - 8, 10, regular);
    // Draw a light-yellow box behind
    const explBoxH = Math.max(28, explLines.length * 13 + 6);
    drawRect(ctx, MARGIN, y - explBoxH, CONTENT_W, explBoxH, COLOR_LT_BLUE, COLOR_BORDER, 0.5);
    let ey = y - 12;
    for (const line of explLines) {
      drawText(ctx, line, MARGIN + 6, ey, { size: 10 });
      ey -= 13;
    }
    y -= explBoxH + 14;

    // ---- Signature block ----
    // ~0.55" = ~40 points of blank writing space before the underscore lines
    const sigBlankHeight = 40;
    drawText(ctx, "Agent Signature and Date:", MARGIN, y, { size: 11, font: bold });
    y -= sigBlankHeight;
    // Signature line + date line
    const sigLineY = y;
    drawLine(ctx, MARGIN + 4, sigLineY, MARGIN + 300, sigLineY, COLOR_BLACK, 0.6);
    drawLine(ctx, MARGIN + 320, sigLineY, MARGIN + CONTENT_W - 4, sigLineY, COLOR_BLACK, 0.6);
    // Date is pre-filled; the signature line is deliberately left blank because
    // the signature is the agent's own certification and is signed by hand.
    drawText(ctx, fmtLongDate(data.prepared_date), MARGIN + 330, sigLineY + 4, { size: 10 });
    drawText(ctx, "Signature", MARGIN + 130, sigLineY - 12, { size: 9, color: COLOR_GRAY });
    drawText(ctx, "Date",      MARGIN + 400, sigLineY - 12, { size: 9, color: COLOR_GRAY });
    y = sigLineY - 24;
    // Printed name below signature line
    drawText(ctx, data.agent_name, MARGIN + 4, y, { size: 10, font: bold });
    drawText(ctx, "Printed Name", MARGIN + 130, y, { size: 9, color: COLOR_GRAY });
    y -= 20;

    // ---- Footer (SF template printing instruction) ----
    // No Newtworks self-attribution. Just the SF template line.
    const footer = "After the form is completed, please print this document and save with the bank statement for compliance purposes.";
    drawText(ctx, footer, MARGIN, 32, { size: 8, color: COLOR_GRAY, font: italic });

    const bytes = await pdf.save();
    return bytes;
  })();
}

// =========================================================================
// Email body builder
// =========================================================================
interface DepositLine { date: string; amount: number; }

function buildEmailBody(opts: {
  statement_period_start: string;
  statement_period_end: string;
  outstanding_items: string;
  adjusted_balance: number;
  prior_personal_funds: number;
  difference: number;
  deposits: DepositLine[];
  cleared_notes: string[];
}): string {
  const monthLabel = fmtMonthYear(opts.statement_period_end);
  const lines: string[] = [];
  lines.push(`Attached is the PFA Reconciliation printout for the ${monthLabel} statement period.`);
  lines.push("");

  // Deposits section
  lines.push("Deposits this cycle:");
  if (opts.deposits.length === 0) {
    lines.push("  (none)");
  } else {
    for (const d of opts.deposits) {
      lines.push(`  ${fmtShortMMDD(d.date)}: ${fmtMoney(d.amount)}`);
    }
    const total = opts.deposits.reduce((s, d) => s + d.amount, 0);
    lines.push(`  Total deposits: ${fmtMoney(total)}`);
  }
  lines.push("");

  // Reconciliation summary
  lines.push("Reconciliation summary:");
  lines.push(`  Statement period: ${fmtLongDate(opts.statement_period_start)} through ${fmtLongDate(opts.statement_period_end)}`);
  lines.push(`  Outstanding items at ${fmtLongDate(opts.statement_period_end)}: ${opts.outstanding_items}`);
  lines.push(`  Adjusted statement balance: ${fmtMoney(opts.adjusted_balance)}`);
  lines.push(`  Prior month personal funds: ${fmtMoney(opts.prior_personal_funds)}`);
  lines.push(`  Difference to reconcile: ${fmtMoney(opts.difference)}`);
  lines.push("");

  // Any cleared items notes
  if (opts.cleared_notes.length > 0) {
    for (const note of opts.cleared_notes) lines.push(note);
    lines.push("");
  }

  // Sign-off
  lines.push("— Peter J Story / Agent Code 53-1BDD");

  return lines.join("\n");
}

// =========================================================================
// Main handler
// =========================================================================
async function run(req: Request): Promise<Response> {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  const reconciliationId = body?.reconciliation_id as string;
  const force = body?.force === true;
  const dryRun = body?.dry_run === true;
  // Verification hatch: send the real PDF somewhere harmless to prove the
  // attachment path works without filing anything with State Farm. When set,
  // the reconciliation row is deliberately NOT stamped as sent, so the real
  // send is still pending afterwards.
  const overrideRecipient =
    typeof body?.override_recipient === "string" && body.override_recipient.includes("@")
      ? (body.override_recipient as string)
      : null;
  const recipient = overrideRecipient ?? SF_RECIPIENT;

  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);
  if (!reconciliationId) return jsonResponse({ ok: false, error: "reconciliation_id required" }, 400);

  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  const credsRes = await getComposioGmailCreds(agencyId);
  if (!credsRes.ok) {
    return jsonResponse({ ok: false, error: "missing composio credentials" }, 400);
  }
  const gmailCreds = credsRes.creds;
  const composioApiKey = gmailCreds.apiKey;

  // 1) Load the reconciliation
  const { data: recon, error: reconErr } = await sb
    .from("pfa_reconciliations")
    .select("*, pfa_accounts(id, agency_id, agent_name, agent_code, bank_name, bank_mailing_address, bank_account_number)")
    .eq("id", reconciliationId)
    .maybeSingle();
  if (reconErr || !recon) {
    return jsonResponse({ ok: false, error: `reconciliation lookup failed: ${reconErr?.message}` }, 404);
  }
  if (recon.pfa_accounts?.agency_id !== agencyId) {
    return jsonResponse({ ok: false, error: "reconciliation not in this agency" }, 403);
  }

  // 2) Skip logic
  if (recon.emailed_to_agent_at && !force && !overrideRecipient) {
    return jsonResponse({ ok: true, status: "already_sent",
      emailed_at: recon.emailed_to_agent_at,
      message_id: recon.emailed_to_agent_message_id });
  }
  const diff = Number(recon.difference_to_reconcile ?? 0);
  const isClean = Math.abs(diff) < 0.005;
  if (!isClean && !force) {
    return jsonResponse({ ok: true, status: "skipped_discrepancy",
      difference: diff,
      note: "Reconciliation has a discrepancy — auto-send blocked. Pass force=true to send anyway." });
  }

  // 3) Load statement + deposits for the email body
  const { data: stmt } = await sb
    .from("pfa_bank_statements")
    .select("statement_period_start, statement_period_end")
    .eq("id", recon.statement_id)
    .maybeSingle();
  const statementPeriodStart = stmt?.statement_period_start ?? recon.statement_ending_date;
  const statementPeriodEnd   = stmt?.statement_period_end   ?? recon.statement_ending_date;

  const { data: cleared_deposits } = await sb
    .from("pfa_transactions")
    .select("transaction_date, credit_amount")
    .eq("pfa_account_id", recon.pfa_account_id)
    .eq("transaction_type", "Deposit")
    .is("voided_at", null)
    .eq("cleared", true)
    .gte("cleared_date", statementPeriodStart)
    .lte("cleared_date", statementPeriodEnd)
    .order("transaction_date", { ascending: true });

  const depositLines: DepositLine[] = (cleared_deposits ?? []).map(d => ({
    date: d.transaction_date, amount: Number(d.credit_amount),
  }));

  // Outstanding items description
  const outCk  = Number(recon.outstanding_checks_total   ?? 0);
  const outEft = Number(recon.outstanding_sf_eft_total   ?? 0);
  const outDep = Number(recon.outstanding_deposits_total ?? 0);
  const outstandingParts: string[] = [];
  if (outEft > 0.005) outstandingParts.push(`SF EFT ${fmtMoney(outEft)}`);
  if (outDep > 0.005) outstandingParts.push(`Deposits ${fmtMoney(outDep)}`);
  if (outCk > 0.005)  outstandingParts.push(`Checks ${fmtMoney(outCk)}`);
  const outstandingItems = outstandingParts.length === 0 ? "none" : outstandingParts.join(", ");

  // 4) Build PDF
  const acct = recon.pfa_accounts;
  const pdfData: ReconData = {
    agent_name: acct?.agent_name || "Peter J Story",
    prepared_date: todayCentralIso(),
    agent_code: acct?.agent_code || "53-1BDD",
    bank_name: acct?.bank_name || "Frost Bank",
    bank_mailing_address: acct?.bank_mailing_address || "P.O. Box 1600, San Antonio TX 78296",
    account_number: acct?.bank_account_number || "",
    statement_period_start: statementPeriodStart,
    statement_period_end: statementPeriodEnd,
    statement_ending_balance: Number(recon.statement_ending_balance ?? 0),
    outstanding_checks_total: outCk,
    outstanding_sf_eft_total: outEft,
    outstanding_deposits_total: outDep,
    returned_checks_unreimbursed: Number(recon.returned_checks_unreimbursed ?? 0),
    adjusted_statement_balance: Number(recon.adjusted_statement_balance ?? 0),
    prior_personal_funds: Number(recon.prior_personal_funds ?? 0),
    current_bank_service_fees: Number(recon.current_bank_service_fees ?? 0),
    difference_to_reconcile: diff,
    explanation: recon.explanation || (isClean ? "N/A — reconciliation balanced." : ""),
  };
  let pdfBytes: Uint8Array;
  try {
    pdfBytes = await buildPdfBytes(pdfData);
  } catch (e) {
    return jsonResponse({ ok: false, error: `PDF build failed: ${e instanceof Error ? e.message : String(e)}` }, 500);
  }

  // Base64-encode the PDF for Gmail attachment
  let bin = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < pdfBytes.length; i += CHUNK) {
    bin += String.fromCharCode(...pdfBytes.subarray(i, i + CHUNK));
  }
  const pdfB64 = btoa(bin);

  if (dryRun) {
    return jsonResponse({
      ok: true, status: "dry_run",
      pdf_size: pdfBytes.length,
      pdf_base64: pdfB64,
      subject: `PFA Reconciliation — ${fmtMonthYear(statementPeriodEnd)}`,
      // Skip actually building the email; caller can compare the PDF to a golden.
    });
  }

  // 5) Build email body + send via Composio
  const monthLabel = fmtMonthYear(statementPeriodEnd);
  const subject = `PFA Reconciliation — ${monthLabel}`;
  const emailBody = buildEmailBody({
    statement_period_start: statementPeriodStart,
    statement_period_end: statementPeriodEnd,
    outstanding_items: outstandingItems,
    adjusted_balance: pdfData.adjusted_statement_balance,
    prior_personal_funds: pdfData.prior_personal_funds,
    difference: diff,
    deposits: depositLines,
    cleared_notes: [],
  });

  // Named to match the statement Peter forwards in ("YY_MM Statement.pdf"),
  // so the pair files together for the month: "26_08 Reconciliation.pdf".
  const yy = String(statementPeriodEnd).slice(2, 4);
  const mm = String(statementPeriodEnd).slice(5, 7);
  const fileName = `${yy}_${mm} Reconciliation.pdf`;

  // Stage the PDF with Composio first -- `attachment` needs an s3key, not bytes.
  const staged = await stageFileWithComposio({
    apiKey: composioApiKey,
    fileName,
    mimeType: "application/pdf",
    bytes: pdfBytes,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolkitSlug: "gmail",
  });
  if (!staged.ok || !staged.s3key) {
    const stageErr = `attachment staging failed: ${staged.error}`;
    if (!overrideRecipient) {
      await raiseSendFailureAlert(agencyId, reconciliationId, statementPeriodEnd, stageErr);
    }
    return jsonResponse({ ok: false, status: "send_failed", error: stageErr }, 502);
  }

  const sendRes = await sendGmail({
    creds: gmailCreds,
    to: recipient,
    subject,
    text: emailBody,
    attachment: { name: fileName, mimetype: "application/pdf", s3key: staged.s3key },
  });

  if (!sendRes.ok) {
    if (!overrideRecipient) {
      await raiseSendFailureAlert(agencyId, reconciliationId, statementPeriodEnd, String(sendRes.error));
    }
    return jsonResponse({ ok: false, status: "send_failed", error: sendRes.error }, 502);
  }

  const messageId = (sendRes.data as any)?.id
                  ?? (sendRes.data as any)?.message_id
                  ?? (sendRes.data as any)?.response_data?.id
                  ?? null;

  // 6) Update the reconciliation row -- skipped for verification sends so the
  //    real filing stays pending.
  if (!overrideRecipient) {
    await sb.from("pfa_reconciliations").update({
      emailed_to_agent_at: new Date().toISOString(),
      emailed_to_agent_message_id: messageId ?? "sent",
      updated_at: new Date().toISOString(),
    }).eq("id", reconciliationId);

    // 7) Resolve any related alerts (the discrepancy alert and any prior
    //    send-failure alert both clear once the filing actually goes out).
    await resolveAlerts({ agencyId, moduleReference: `pfa_reconciliation:${reconciliationId}` });
    await resolveAlerts({ agencyId, moduleReference: `pfa_reconciliation_send_failed:${reconciliationId}` });
  }

  return jsonResponse({
    ok: true, status: overrideRecipient ? "sent_test" : "sent",
    recipient,
    subject,
    message_id: messageId,
    pdf_size: pdfBytes.length,
    deposits_count: depositLines.length,
  });
}

Deno.serve(run);
