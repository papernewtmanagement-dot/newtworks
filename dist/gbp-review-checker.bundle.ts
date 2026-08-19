// =========================================================================
// gbp-review-checker bundle (auto-generated)
// Source of truth: supabase/functions/gbp-review-checker/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py gbp-review-checker`.
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

// ==================== gbp-review-checker/index.ts ====================
// =========================================================================
// gbp-review-checker
// =========================================================================
// v2 (2026-08-18): Runs HOURLY (not weekly — the 5-review-per-call cap on
// Google Maps' API means a weekly cadence could silently drop reviews on
// weeks with 6+ new ones; hourly makes that a non-issue in practice).
// Pulls the 5 most recent Google Business Profile reviews via Composio's
// Google Maps GET_PLACE_DETAILS tool, diffs against gbp_review_tracker
// (keyed on place_id + google review resource name), and for anything new:
// drafts a response with Groq (compliance-guardrailed, varied against the
// last 10 drafted openings so nothing echoes), posts it to the Paper Newt
// Management Telegram group tagging Alvi (team record: Marie Story,
// alvipelo@gmail.com — flagged once in commit history, not silently
// assumed), AND inserts a `tasks` row as the durable paper trail. Google's
// Business Profile reply API is invite-only, so posting is still manual —
// this gets the draft in front of a human (fast, via Telegram) as soon as
// possible after the review lands.
//
// Invoked by pg_cron via dispatch_gbp_review_checker (automation-runner's
// INTERNAL/dispatch_ branch does a direct fetch to /functions/v1/gbp-
// review-checker). See op-rule "Newtworks dispatch_* recipe convention".
// =========================================================================

// deno-lint-ignore-file no-explicit-any

async function sendTelegramReviewAlert(opts: {
  botToken: string;
  chatId: string;
  alviTelegramUserId: number | null;
  authorName: string;
  rating: number | null;
  reviewText: string;
  draftedResponse: string;
}): Promise<void> {
  const stars = opts.rating != null ? "★".repeat(Math.max(0, Math.min(5, Math.round(opts.rating)))) : "";
  const tagHtml = opts.alviTelegramUserId
    ? `<a href="tg://user?id=${opts.alviTelegramUserId}">Alvi</a>`
    : "Alvi";
  const escape = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const text =
    `🆕 <b>New Google review</b> — ${escape(opts.authorName)} (${stars})\n\n` +
    `"${escape(opts.reviewText).slice(0, 400)}"\n\n` +
    `<b>Drafted reply</b> (paste at business.google.com &gt; Reviews):\n${escape(opts.draftedResponse)}\n\n` +
    `${tagHtml} — can you post this one?`;
  try {
    await fetch(`https://api.telegram.org/bot${opts.botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: opts.chatId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
    });
  } catch (e) {
    console.error(`Telegram send failed: ${(e as Error).message}`);
  }
}

const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";
const PLACE_ID = "ChIJn5BEWaWHXIYR-u4V6qmytzM"; // Peter Story - State Farm Insurance Agent

const SYSTEM_PROMPT = `You write Google Business Profile owner-reply responses for an insurance agency (Peter Story State Farm, San Antonio TX).

FORMULA — every response, 2-4 sentences, hits these once each, naturally:
1. Reviewer's first name
2. One specific detail from THEIR review (product, teammate, situation)
3. Business/team mentioned once ("our team", not always the business name)
4. Vary sentence structure and opening phrase every time — you will be shown the last several openings used; NEVER repeat one of them or anything structurally similar.

HARD COMPLIANCE RULES (State Farm agent's agreement — violating any of these is a real compliance issue, not a style note):
- NEVER use: "expert", "specialist", "advisor", "consultant", "fully licensed"
- NEVER use superlatives or absolutes: "best", "always", "guaranteed", "#1", "top rated"
- NEVER mention product names, prices, premiums, or "save you money" / "save money"
- NEVER mention investments, banking, or securities (this profile is insurance-only)
- NEVER use internal State Farm program language
- Keep it warm but not effusive. Sound like a real person replied, not a template.

For 1-3 star reviews: acknowledge the experience without admitting to specific facts, do not reference any account/policy specifics, invite them to call the office directly, keep it SHORT (under 40 words), no defensiveness.

Return JSON only: {"response_text": "..."}`;

async function callGroq(agencyId: string, groqApiKey: string, userContent: string): Promise<{ ok: boolean; text: string | null; error: string | null }> {
  const model = (await getSetting(agencyId, "groq_model_default").catch(() => null)) || LLM_MODEL_FALLBACK;
  const body = {
    model,
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userContent },
    ],
    temperature: 0.7,
    max_tokens: 300,
    response_format: { type: "json_object" },
  };
  const res = await fetch(GROQ_API_URL, {
    method: "POST",
    headers: { "Authorization": `Bearer ${groqApiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const raw = await res.text();
  if (!res.ok) return { ok: false, text: null, error: `Groq HTTP ${res.status}: ${raw.slice(0, 300)}` };
  try {
    const parsed = JSON.parse(raw);
    const content = parsed?.choices?.[0]?.message?.content;
    if (!content) return { ok: false, text: null, error: "Groq returned empty content" };
    const extracted = JSON.parse(content);
    return { ok: true, text: extracted.response_text ?? null, error: null };
  } catch (e) {
    return { ok: false, text: null, error: `Groq parse failure: ${(e as Error).message}` };
  }
}

Deno.serve(async (req: Request) => {
  let body: any = {};
  try { body = await req.json(); } catch { /* cron dispatch may send empty body */ }
  const agencyId = body.agency_id || AGENCY_ID_DEFAULT;

  const denied = await requireSharedSecret(agencyId, body.shared_secret);
  if (denied) return denied;

  const apiKey = await getSetting(agencyId, "composio_api_key");
  const userId = await getSetting(agencyId, "composio_user_id");
  const mapsAccountId = await getSetting(agencyId, "composio_google_maps_account_id");
  const groqApiKey = await getSetting(agencyId, "groq_api_key");
  const telegramBotToken = await getSetting(agencyId, "telegram_bot_token");
  const telegramChatId = await getSetting(agencyId, "paper_newt_management_group_chat_id");
  const alviTelegramUserIdRaw = await getSetting(agencyId, "marie_telegram_user_id"); // team record for alvipelo@gmail.com
  const alviTelegramUserId = alviTelegramUserIdRaw ? parseInt(alviTelegramUserIdRaw, 10) : null;
  if (!apiKey || !userId || !mapsAccountId) {
    return jsonResponse({ ok: false, error: "missing Composio Google Maps credentials in settings" }, 500);
  }
  if (!groqApiKey) {
    return jsonResponse({ ok: false, error: "missing groq_api_key in settings" }, 500);
  }

  const composioResult = await callComposio({
    apiKey,
    userId,
    connectedAccountId: mapsAccountId,
    toolSlug: "GOOGLE_MAPS_GET_PLACE_DETAILS",
    toolArguments: { name: `places/${PLACE_ID}`, fieldMask: "id,displayName,rating,userRatingCount,reviews" },
    toolkitVersion: "latest",
  });

  if (!composioResult.ok) {
    return jsonResponse({ ok: false, error: `Google Maps call failed: ${composioResult.error}` }, 500);
  }

  const reviews: any[] = composioResult.data?.reviews ?? [];
  if (reviews.length === 0) {
    return jsonResponse({ ok: true, new_reviews: 0, note: "no reviews returned" });
  }

  // Recent-opening ledger, so new drafts don't echo the last several.
  const { data: recentDrafts } = await sb
    .from("gbp_review_tracker")
    .select("drafted_response")
    .eq("agency_id", agencyId)
    .not("drafted_response", "is", null)
    .order("created_at", { ascending: false })
    .limit(10);
  const recentOpenings = (recentDrafts ?? [])
    .map((r: any) => (r.drafted_response as string).split(" ").slice(0, 5).join(" "))
    .filter(Boolean);

  const results: any[] = [];

  for (const rev of reviews) {
    const googleReviewName: string = rev.name; // places/{id}/reviews/{reviewId} — stable resource name
    const authorName: string = rev.authorAttribution?.displayName ?? "there";
    const rating: number = rev.rating ?? null;
    const text: string = rev.text?.text ?? rev.originalText?.text ?? "";
    const publishTime: string | null = rev.publishTime ?? null;

    const { data: existing } = await sb
      .from("gbp_review_tracker")
      .select("id")
      .eq("place_id", PLACE_ID)
      .eq("google_review_name", googleReviewName)
      .maybeSingle();

    if (existing) continue; // already tracked, nothing to do

    const userContent = JSON.stringify({
      reviewer_first_name: authorName.split(" ")[0],
      rating,
      review_text: text,
      recent_openings_to_avoid: recentOpenings,
    });

    const groqResult = await callGroq(agencyId, groqApiKey, userContent);
    const draftedResponse = groqResult.ok ? groqResult.text : null;

    // Create a task for Peter to review + paste (Google's reply API is invite-only, no auto-post).
    let taskId: string | null = null;
    if (draftedResponse) {
      const { data: task, error: taskErr } = await sb
        .from("tasks")
        .insert({
          agency_id: agencyId,
          title: `New Google review from ${authorName} (${rating}★) — response drafted`,
          description: `Review: "${text}"\n\nDrafted response (ready to paste at business.google.com > Reviews):\n\n${draftedResponse}`,
          task_category: "marketing",
          task_type: "review_response",
          priority: rating <= 3 ? "high" : "medium",
          status: "open",
          created_by: "gbp_review_checker",
        })
        .select("id")
        .single();
      if (!taskErr) taskId = task?.id ?? null;

      if (telegramBotToken && telegramChatId) {
        await sendTelegramReviewAlert({
          botToken: telegramBotToken,
          chatId: telegramChatId,
          alviTelegramUserId,
          authorName,
          rating,
          reviewText: text,
          draftedResponse,
        });
      }
    }

    await sb.from("gbp_review_tracker").insert({
      agency_id: agencyId,
      place_id: PLACE_ID,
      google_review_name: googleReviewName,
      author_display_name: authorName,
      rating,
      review_text: text,
      publish_time: publishTime,
      drafted_response: draftedResponse,
      task_id: taskId,
      status: draftedResponse ? "drafted" : "draft_failed",
    });

    if (draftedResponse) recentOpenings.unshift(draftedResponse.split(" ").slice(0, 5).join(" "));
    results.push({ author: authorName, rating, drafted: !!draftedResponse, task_id: taskId });
  }

  return jsonResponse({ ok: true, new_reviews: results.length, results });
});
