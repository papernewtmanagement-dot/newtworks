// =========================================================================
// automation-runner bundle (auto-generated)
// Source of truth: supabase/functions/automation-runner/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py automation-runner`.
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

// ==================== automation-runner/index.ts ====================
// =========================================================================
// automation-runner  (Newtworks)
// =========================================================================
// v45 (2026-08-03): writeOutput() now resolves business_entity_id for
// cash_register_preliminary rows before insert (table renamed from
// bank_register_preliminary 2026-08-09 to match the Cash Register module
// it feeds). The 2026-07-29 migration
// (drop_entity_default_trigger_and_set_not_null_on_13_tables) removed the
// auto-populate trigger and made the column NOT NULL, but this generic
// writer only ever picked columns present on the parsed record — Groq's
// bank-alert parser has no concept of business_entity_id, so every insert
// started failing with a not-null violation once a real transaction showed
// up (silent while records_processed stayed 0, so it went unnoticed for a
// day and a half). Resolution: look up account_last4 against
// chart_of_accounts (checking/primary accounts) then accounts
// (any kind, including alternate_last4s for reissued numbers) — same
// sources document-processor's writeStatementBalance() already trusts.
//
// v43 (2026-07-10): After a successful sf_crm_analytics_email parse, stamp
// crm_analytics_ingested=true + crm_analytics_ingested_at=now on the
// affected agency_snapshot rows, then DM Peter via paper_newt_bot with the
// book snapshot summary. The stamp is needed because the row is pre-created
// by the Telegram check-in flow (source=cpr_weekly_manual), so fill_nulls_only
// alone can't flip a boolean that's already defaulted to false.
//
// v42 (2026-07-10): pg_net polling architecture retired again per the
// 2026-06-19 rule. INTERNAL branch splits on internal_handler prefix:
//   dispatch_<name>  -> direct fetch to /functions/v1/<name>
//   otherwise        -> run_internal_recipe RPC (pure-SQL, synchronous)
// Neither branch touches pg_net. See op-rule "Newtworks dispatch_* recipe
// convention" and op-rule "PostgREST cannot reliably read net._http_response".
// =========================================================================

// deno-lint-ignore-file no-explicit-any


const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";
const PETER_TELEGRAM_ID_FALLBACK = 7778113542;

async function getDefaultModel(agencyId: string): Promise<string> {
  try { const v = await getSetting(agencyId, "groq_model_default"); return (v && v.trim()) || LLM_MODEL_FALLBACK; }
  catch (_e) { return LLM_MODEL_FALLBACK; }
}

async function sleep(ms: number): Promise<void> { return new Promise((r) => setTimeout(r, ms)); }


async function telegram(agencyId: string | null, text: string): Promise<void> {
  if (!agencyId) return;
  const botToken = await getSetting(agencyId, "telegram_bot_token");
  const chatId = await getSetting(agencyId, "telegram_chat_id");
  if (!botToken || !chatId) return;
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: true }),
    });
  } catch (_e) { /* non-fatal */ }
}

// Personal DM to Peter via paper_newt_bot. Non-fatal on error — the parse
// still succeeded, DM is icing not core work.
async function telegramPeterDm(agencyId: string, text: string): Promise<void> {
  try {
    const botToken = await getSetting(agencyId, "chatbot_bot_token");
    if (!botToken) return;
    // Prefer live team_telegram_map entry, fall back to hardcoded ID that has
    // historically worked for paper_newt_bot DMs (payroll_weekly_nag pattern).
    let chatId: number | null = null;
    try {
      const { data } = await sb
        .from("team_telegram_map")
        .select("telegram_user_id, team!inner(first_name,last_name)")
        .eq("team.first_name", "Peter")
        .eq("team.last_name", "Story")
        .maybeSingle();
      if (data?.telegram_user_id) chatId = Number(data.telegram_user_id);
    } catch (_e) { /* fall through to fallback */ }
    if (!chatId) chatId = PETER_TELEGRAM_ID_FALLBACK;
    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: true }),
    });
  } catch (_e) { /* non-fatal */ }
}


async function callGroqLLM(opts: { agencyId: string; groqApiKey: string; systemPrompt: string; userContent: string; model?: string; maxTokens?: number; }): Promise<{ ok: boolean; data: any; error: string | null }> {
  const model = opts.model ?? await getDefaultModel(opts.agencyId);
  const body = { model, messages: [{ role: "system", content: opts.systemPrompt }, { role: "user", content: opts.userContent }], temperature: 0, max_tokens: opts.maxTokens ?? 4096, response_format: { type: "json_object" } };
  let lastErr = "unknown";
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(GROQ_API_URL, { method: "POST", headers: { "Authorization": `Bearer ${opts.groqApiKey}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    if ((res.status === 429 || res.status >= 500) && attempt < 2) { await sleep(500 * Math.pow(2, attempt)); continue; }
    const text = await res.text();
    let parsed: any = {};
    try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
    if (!res.ok) { lastErr = parsed?.error?.message || parsed?.error?.code || text.slice(0, 400); return { ok: false, data: null, error: `Groq HTTP ${res.status}: ${lastErr}` }; }
    const content = parsed?.choices?.[0]?.message?.content;
    if (!content) return { ok: false, data: null, error: "Groq returned empty content" };
    let extracted: any;
    try { extracted = JSON.parse(content); } catch (e) { return { ok: false, data: null, error: `Groq response not valid JSON: ${(e as Error).message}` }; }
    return { ok: true, data: extracted, error: null };
  }
  return { ok: false, data: null, error: `Groq exhausted retries: ${lastErr}` };
}

function decodeBase64Url(s: string): string {
  if (!s) return "";
  let n = s.replace(/-/g, "+").replace(/_/g, "/");
  while (n.length % 4 !== 0) n += "=";
  try { const bytes = Uint8Array.from(atob(n), (c) => c.charCodeAt(0)); return new TextDecoder("utf-8").decode(bytes); }
  catch { return ""; }
}

function findGmailPlainTextBody(payload: any): string {
  if (!payload) return "";
  if (payload.body?.data && (!payload.parts || payload.parts.length === 0)) {
    const d = decodeBase64Url(payload.body.data);
    if (/<[a-z][^>]*>/i.test(d)) return d.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
    return d;
  }
  const parts = payload.parts ?? [];
  const plain = parts.find((p: any) => p.mimeType === "text/plain");
  if (plain?.body?.data) return decodeBase64Url(plain.body.data);
  for (const p of parts) { if (p.parts) { const n = findGmailPlainTextBody(p); if (n) return n; } }
  const html = parts.find((p: any) => p.mimeType === "text/html");
  if (html?.body?.data) { const raw = decodeBase64Url(html.body.data); return raw.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim(); }
  return "";
}

function stripParenthesizedUrls(text: string): string { if (!text) return ""; return text.replace(/\s*\(\s*https?:\/\/[^)]+\)\s*/g, " ").replace(/\s+/g, " ").trim(); }

function extractGmailEssentials(composioData: any, perMessageBodyCap = 1000): any {
  const messages = Array.isArray(composioData) ? composioData : (composioData?.messages ?? composioData?.data?.messages ?? []);
  if (!Array.isArray(messages)) return composioData;
  return { total: messages.length, messages: messages.map((m: any) => {
    const headers = m.payload?.headers ?? [];
    const gh = (name: string) => (headers.find((x: any) => (x.name ?? "").toLowerCase() === name.toLowerCase())?.value ?? "");
    const pre = typeof m.messageText === "string" && m.messageText.length > 0 ? m.messageText : null;
    const raw = pre ?? findGmailPlainTextBody(m.payload);
    const body = stripParenthesizedUrls(raw).slice(0, perMessageBodyCap);
    return { messageId: m.messageId ?? m.id ?? "", threadId: m.threadId ?? "", subject: m.subject ?? gh("Subject"), from: m.sender ?? m.from ?? gh("From"), to: m.to ?? gh("To"), date: gh("Date") || m.internalDate || "", snippet: m.snippet ?? "", body };
  }) };
}

async function archiveProcessedGmailMessages(opts: { apiKey: string; userId: string; connectedAccountId: string; messageIds: string[]; additionalLabelsToAdd?: string[]; }): Promise<{ ok: boolean; archived: number; error: string | null }> {
  const ids = (opts.messageIds || []).filter((x): x is string => typeof x === "string" && x.length > 0);
  if (ids.length === 0) return { ok: true, archived: 0, error: null };
  let archived = 0; const errors: string[] = [];
  for (const msgId of ids) {
    const r = await callComposio({ apiKey: opts.apiKey, userId: opts.userId, connectedAccountId: opts.connectedAccountId, toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL", toolArguments: { message_id: msgId, remove_label_ids: ["INBOX"], ...(opts.additionalLabelsToAdd?.length ? { add_label_ids: opts.additionalLabelsToAdd } : {}) } });
    if (r.ok) archived += 1; else errors.push(`${msgId}: ${r.error}`);
  }
  if (errors.length > 0) return { ok: archived > 0, archived, error: `${errors.length}/${ids.length} failed: ${errors.slice(0, 3).join("; ")}` };
  return { ok: true, archived, error: null };
}

async function getComposioAccountId(agencyId: string, connection: string): Promise<string> {
  const key = `composio_${connection.toLowerCase()}_account_id`;
  const v = await getSetting(agencyId, key);
  if (!v) throw new Error(`Missing settings credential: ${key} (agency ${agencyId}).`);
  return v;
}

interface ParsedSfCrmAnalytics { source_message_id: string; week_ending_date: string | null; household_count: number | null; auto_pif: number | null; auto_premium: number | null; fire_pif: number | null; fire_premium: number | null; life_pif: number | null; life_premium: number | null; quarter_year: number | null; quarter_number: number | null; lead_sources: Array<{ source: string; won_households: number | null; won_premium: number | null }>; }
const SF_MONTH_NAMES = ["January","February","March","April","May","June","July","August","September","October","November","December"];
function _saturdayAfter(y: number, m: number, d: number): string { const dt = new Date(Date.UTC(y, m - 1, d)); dt.setUTCDate(dt.getUTCDate() + 1); return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth()+1).padStart(2,"0")}-${String(dt.getUTCDate()).padStart(2,"0")}`; }
function _stripHtmlAndUrls(s: string): string { let o = s.replace(/<https?:\/\/[^>]+>/g, ""); o = o.replace(/<[^>]+>/g, " "); o = o.replace(/\r\n/g, "\n"); return o.replace(/\n{3,}/g, "\n\n"); }
function _parseMoney(s: string): number | null { if (s == null) return null; const c = s.replace(/[\$,]/g, "").trim(); if (!c) return null; const n = parseFloat(c); return isFinite(n) ? n : null; }
function _parseInt2(s: string): number | null { if (s == null) return null; const c = s.replace(/[,]/g, "").trim(); if (!c) return null; const n = parseInt(c, 10); return isFinite(n) ? n : null; }
function _extractWidget(body: string, label: string): string | null { const esc = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); const re = new RegExp(`${esc}\\s+([\\s\\S]*?)\\s+Last updated:`, "i"); const m = body.match(re); return m ? m[1].trim() : null; }
function parseSfCrmAnalyticsEmailOne(message: any): ParsedSfCrmAnalytics | null {
  const msgId: string = message.messageId || message.id || "";
  const text: string = message.body || message.messageText || message.snippet || "";
  if (!text) return null;
  const body = _stripHtmlAndUrls(text);
  let wed: string | null = null;
  const fri = body.match(/For Friday,\s+([A-Z][a-z]+)\s+(\d{1,2}),\s+(\d{4})/);
  if (fri) { const mi = SF_MONTH_NAMES.findIndex((mn) => mn.toLowerCase() === fri[1].toLowerCase()); if (mi >= 0) wed = _saturdayAfter(parseInt(fri[3],10), mi+1, parseInt(fri[2],10)); }
  const hh = _parseInt2(_extractWidget(body, "HH #") ?? ""); const aP = _parseInt2(_extractWidget(body, "Auto #") ?? ""); const aD = _parseMoney(_extractWidget(body, "Auto $") ?? ""); const fP = _parseInt2(_extractWidget(body, "Fire #") ?? ""); const fD = _parseMoney(_extractWidget(body, "Fire $") ?? ""); const lP = _parseInt2(_extractWidget(body, "Life #") ?? ""); const lD = _parseMoney(_extractWidget(body, "Life $") ?? "");
  let qy: number | null = null; let qn: number | null = null;
  if (fri) { const mo = SF_MONTH_NAMES.findIndex((mn) => mn.toLowerCase() === fri[1].toLowerCase()) + 1; qy = parseInt(fri[3],10); qn = Math.ceil(mo/3); }
  const names: string[] = [];
  const hhRe = /(?:^|\s)([A-Za-z][A-Za-z0-9.\-]+(?:\s[A-Za-z][A-Za-z0-9.\-]+)?) Won HH - Qtr/g;
  let mm; while ((mm = hhRe.exec(body)) !== null) { const n = mm[1].trim(); if (!names.includes(n)) names.push(n); }
  const lead_sources: ParsedSfCrmAnalytics["lead_sources"] = names.map((name) => ({ source: name, won_households: _parseInt2(_extractWidget(body, `${name} Won HH - Qtr`) ?? ""), won_premium: _parseMoney(_extractWidget(body, `${name} Won $ - Qtr`) ?? "") }));
  return { source_message_id: msgId, week_ending_date: wed, household_count: hh, auto_pif: aP, auto_premium: aD, fire_pif: fP, fire_premium: fD, life_pif: lP, life_premium: lD, quarter_year: qy, quarter_number: qn, lead_sources };
}
function parseSfCrmAnalyticsEmail(messages: any[]): any[] { if (!Array.isArray(messages)) return []; const out: any[] = []; for (const m of messages) { const p = parseSfCrmAnalyticsEmailOne(m); if (p && p.week_ending_date && p.household_count !== null) out.push(p); } return out; }
const INTERNAL_PARSERS: Record<string, (input: any) => any[]> = { sf_crm_analytics_email: (i: any) => parseSfCrmAnalyticsEmail(i?.messages ?? []) };

function _fmtMoneyShort(n: number | null): string {
  if (n == null || !isFinite(n)) return "—";
  if (Math.abs(n) >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (Math.abs(n) >= 1_000) return `$${(n / 1_000).toFixed(0)}K`;
  return `$${n.toFixed(0)}`;
}
function _fmtMoneyExact(n: number | null): string {
  if (n == null || !isFinite(n)) return "—";
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function _fmtInt(n: number | null): string {
  if (n == null || !isFinite(n)) return "—";
  return n.toLocaleString("en-US");
}
function _fmtDateLong(iso: string | null): string {
  if (!iso) return "—";
  const [y, m, d] = iso.split("-").map((x) => parseInt(x, 10));
  if (!y || !m || !d) return iso;
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return `${months[m-1]} ${d}, ${y}`;
}

// Post-parse hook for sf_crm_analytics_email: (1) stamp the ingestion flag
// on the row (fill_nulls_only can't flip a boolean that already defaulted to
// false), (2) DM Peter a compact snapshot summary via paper_newt_bot.
async function afterCrmAnalyticsIngest(opts: { agencyId: string; records: any[] }): Promise<void> {
  const { agencyId, records } = opts;
  if (!Array.isArray(records) || records.length === 0) return;
  const stampAt = new Date().toISOString();
  for (const rec of records) {
    if (!rec?.week_ending_date) continue;
    try {
      await sb
        .from("agency_snapshot")
        .update({ crm_analytics_ingested: true, crm_analytics_ingested_at: stampAt })
        .eq("agency_id", agencyId)
        .eq("snapshot_date", rec.week_ending_date)
        .eq("cadence", "weekly");
    } catch (_e) { /* non-fatal — flag missing is not worse than the old world */ }
  }
  // Compose DM from the first record (the parser typically returns one row per email).
  const r = records[0];
  const lines: string[] = [];
  lines.push(`📊 <b>Book snapshot ingested</b>`);
  lines.push(`Week ending ${_fmtDateLong(r.week_ending_date)}`);
  lines.push("");
  lines.push(`HH ${_fmtInt(r.household_count)}`);
  lines.push(`Auto ${_fmtInt(r.auto_pif)} / ${_fmtMoneyShort(r.auto_premium)}`);
  lines.push(`Fire ${_fmtInt(r.fire_pif)} / ${_fmtMoneyShort(r.fire_premium)}`);
  lines.push(`Life ${_fmtInt(r.life_pif)} / ${_fmtMoneyShort(r.life_premium)}`);
  const ls: Array<{ source: string; won_households: number | null; won_premium: number | null }> = Array.isArray(r.lead_sources) ? r.lead_sources : [];
  if (ls.length > 0) {
    lines.push("");
    lines.push(`<b>Lead sources QTD</b>`);
    for (const s of ls) {
      const hh = s.won_households; const dol = s.won_premium;
      const hasAny = (hh != null) || (dol != null);
      lines.push(`• ${s.source}: ${hasAny ? `${_fmtInt(hh)} / ${_fmtMoneyExact(dol)}` : "—"}`);
    }
  }
  lines.push("");
  lines.push(`CPR is ready.`);
  await telegramPeterDm(agencyId, lines.join("\n"));
}

// Post-commit hook for pfa_monthly_reconciliation (added 2026-08-04). Fires
// AFTER the run_internal_recipe RPC has returned — i.e. after the SQL
// function's transaction has committed — so the send function can actually
// see the reconciliation row it's asked to look up. Handles two kinds of
// results[] entries the SQL function emits, both { reconciliation_id,
// clean: true, auto_sent: false }: freshly-computed clean reconciliations
// from this run, and a retry pass over any older clean-but-never-sent rows
// (e.g. the July 2026 reconciliation, stuck by the pre-fix synchronous-send
// bug). Both get the same treatment here.
async function afterPfaReconciliation(opts: { agencyId: string; results: any[] | undefined }): Promise<string[]> {
  // Returns a list of send failures so the caller can log the run as failed.
  // Previously this returned void and the run was logged "success" regardless,
  // which is how a month of never-sent PFA filings went unnoticed. Notices go
  // to Peter's DM, never the team group -- PFA is compliance detail.
  const failures: string[] = [];
  const results = Array.isArray(opts.results) ? opts.results : [];
  const toSend = results.filter((r) => r?.clean === true && r?.auto_sent === false && r?.reconciliation_id);
  if (toSend.length === 0) return failures;
  const sharedSecret = await getSetting(opts.agencyId, "automation_runner_cron_secret");
  if (!sharedSecret) {
    failures.push(`automation_runner_cron_secret missing for agency ${opts.agencyId}`);
    await telegramPeterDm(opts.agencyId, `🟡 PFA reconciliation send skipped — automation_runner_cron_secret missing for agency ${opts.agencyId}`);
    return failures;
  }
  const url = `${SUPABASE_URL}/functions/v1/pfa-reconciliation-send`;
  for (const r of toSend) {
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ agency_id: opts.agencyId, shared_secret: sharedSecret, reconciliation_id: r.reconciliation_id, force: false }),
      });
      const text = await res.text();
      let body: any = null;
      try { body = text ? JSON.parse(text) : null; } catch { body = null; }
      if (!res.ok || !body?.ok || body?.status !== "sent") {
        const err = body?.error ?? body?.status ?? `HTTP ${res.status}`;
        failures.push(`${r.reconciliation_id}: ${String(err).slice(0, 300)}`);
        await telegramPeterDm(opts.agencyId, `🟡 PFA reconciliation ${r.reconciliation_id} send failed (post-commit retry): ${String(err).slice(0, 300)}`);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      failures.push(`${r.reconciliation_id}: threw ${msg.slice(0, 300)}`);
      await telegramPeterDm(opts.agencyId, `🟡 PFA reconciliation ${r.reconciliation_id} send threw: ${msg.slice(0, 300)}`);
    }
  }
  return failures;
}

const _tableColumnsCache = new Map<string, Set<string>>();
async function getTableColumns(table: string): Promise<Set<string>> {
  const hit = _tableColumnsCache.get(table); if (hit) return hit;
  const { data, error } = await sb.rpc("get_table_columns_v1", { p_table_name: table });
  if (error) throw new Error(`get_table_columns_v1(${table}) failed: ${error.message}`);
  const cols = new Set<string>(((data as any[]) || []).map((r) => r.column_name));
  _tableColumnsCache.set(table, cols); return cols;
}
function pickKnownCols(rec: Record<string, any>, cols: Set<string>): Record<string, any> { const o: Record<string, any> = {}; for (const [k, v] of Object.entries(rec)) if (cols.has(k)) o[k] = v; return o; }

// -------------------------------------------------------------------------
// business_entity_id resolver for cash_register_preliminary (added v45,
// 2026-08-03; repointed to unified accounts table 2026-08-08 finance rebuild).
// Resolution order: chart_of_accounts first (checking/primary accounts,
// matched by "(last4)" in the account name), then accounts (any kind,
// including alternate_last4s for reissued cards). Cached per-agency for
// the life of the invocation since a recipe run never touches more than a
// handful of distinct last-4s.
// -------------------------------------------------------------------------
const _entityByLast4Cache = new Map<string, string | null>();
async function resolveBusinessEntityIdByLast4(agencyId: string, last4: string | null | undefined): Promise<string | null> {
  if (!last4) return null;
  const cacheKey = `${agencyId}:${last4}`;
  if (_entityByLast4Cache.has(cacheKey)) return _entityByLast4Cache.get(cacheKey)!;

  let resolved: string | null = null;

  const { data: coaRow } = await sb
    .from("chart_of_accounts")
    .select("business_entity_id")
    .eq("agency_id", agencyId)
    .ilike("account_name", `%(${last4})%`)
    .not("business_entity_id", "is", null)
    .maybeSingle();
  if (coaRow?.business_entity_id) resolved = coaRow.business_entity_id as string;

  if (!resolved) {
    // accounts replaces the old bank_accounts/credit_accounts pair
    // (finance rebuild, 2026-08-07). Same last4/alternate_last4s match.
    const { data: acctRow } = await sb
      .from("accounts")
      .select("business_entity_id")
      .eq("agency_id", agencyId)
      .or(`account_number_last4.eq.${last4},alternate_last4s.cs.{${last4}}`)
      .not("business_entity_id", "is", null)
      .maybeSingle();
    if (acctRow?.business_entity_id) resolved = acctRow.business_entity_id as string;
  }

  _entityByLast4Cache.set(cacheKey, resolved);
  return resolved;
}

async function writeOutput(opts: { outputTable: string; outputConfig: any; records: any[]; agencyId: string | null; }): Promise<{ inserted: number; updated: number; secondary?: { table: string; inserted: number } }> {
  if (!Array.isArray(opts.records) || opts.records.length === 0) return { inserted: 0, updated: 0 };
  const cfg = opts.outputConfig || {};
  const primaryCols = await getTableColumns(opts.outputTable);
  const uniqueOn: string[] | undefined = cfg.unique_on || cfg.on_conflict_columns;
  const mergeStrategy: string = cfg.merge_strategy ? cfg.merge_strategy : (cfg.on_conflict === "update" ? "overwrite" : "ignore");
  const secondaryWrite: any = cfg.secondary_write;
  const secondaryRowsByIndex: any[][] = opts.records.map((r) => { if (secondaryWrite?.rows_from) { const v = (r as any)[secondaryWrite.rows_from]; return Array.isArray(v) ? v : []; } return []; });
  const needsBusinessEntityId = opts.agencyId && primaryCols.has("business_entity_id") && opts.outputTable === "cash_register_preliminary";
  const primaryRecords: any[] = [];
  for (const r of opts.records) {
    const o: any = pickKnownCols(r, primaryCols);
    if (opts.agencyId && primaryCols.has("agency_id")) o.agency_id = opts.agencyId;
    if (cfg.source && primaryCols.has("source")) o.source = cfg.source;
    if (cfg.cadence && primaryCols.has("cadence")) o.cadence = cfg.cadence;
    if (cfg.snapshot_date_field && primaryCols.has("snapshot_date")) { const sd = (r as any)[cfg.snapshot_date_field]; if (sd !== undefined && sd !== null) o.snapshot_date = sd; }
    if (needsBusinessEntityId && !o.business_entity_id) {
      const resolved = await resolveBusinessEntityIdByLast4(opts.agencyId as string, (r as any).account_last4);
      if (resolved) o.business_entity_id = resolved;
    }
    primaryRecords.push(o);
  }
  let primaryInserted = 0;
  if (uniqueOn && uniqueOn.length > 0) {
    if (mergeStrategy === "fill_nulls_only") {
      for (const rec of primaryRecords) {
        let q = sb.from(opts.outputTable).select("*");
        for (const col of uniqueOn) { if (rec[col] === undefined) throw new Error(`fill_nulls_only missing col ${col}`); q = q.eq(col, rec[col]); }
        const { data: existing, error: selErr } = await q.maybeSingle();
        if (selErr) throw new Error(`select failed: ${selErr.message}`);
        let merged: any; if (existing) { merged = { ...existing }; for (const [k, v] of Object.entries(rec)) if (merged[k] === null || merged[k] === undefined) merged[k] = v; } else merged = rec;
        if (primaryCols.has("updated_at")) merged.updated_at = new Date().toISOString();
        const { error: upErr } = await sb.from(opts.outputTable).upsert(merged, { onConflict: uniqueOn.join(","), ignoreDuplicates: false });
        if (upErr) throw new Error(`upsert failed: ${upErr.message}`);
        primaryInserted += 1;
      }
    } else if (mergeStrategy === "overwrite") {
      const { data, error } = await sb.from(opts.outputTable).upsert(primaryRecords, { onConflict: uniqueOn.join(","), ignoreDuplicates: false }).select("id");
      if (error) throw new Error(`upsert failed: ${error.message}`);
      primaryInserted = data?.length ?? 0;
    } else {
      const { data, error } = await sb.from(opts.outputTable).upsert(primaryRecords, { onConflict: uniqueOn.join(","), ignoreDuplicates: true }).select("id");
      if (error) throw new Error(`insert failed: ${error.message}`);
      primaryInserted = data?.length ?? 0;
    }
  } else {
    const { data, error } = await sb.from(opts.outputTable).insert(primaryRecords).select("id");
    if (error) throw new Error(`insert failed: ${error.message}`);
    primaryInserted = data?.length ?? 0;
  }
  let secondaryInserted = 0;
  if (secondaryWrite?.table && secondaryRowsByIndex.some((a) => a.length > 0)) {
    const secondaryCols = await getTableColumns(secondaryWrite.table);
    const secUniqueOn: string[] | undefined = secondaryWrite.on_conflict_columns || secondaryWrite.unique_on;
    const secMerge: string = secondaryWrite.merge_strategy || "ignore";
    const staticCols: Record<string, any> = secondaryWrite.static_columns || {};
    const secondaryRecords: any[] = [];
    for (let i = 0; i < opts.records.length; i++) {
      const orig = opts.records[i]; const rows = secondaryRowsByIndex[i];
      for (const row of rows) {
        const sec: any = pickKnownCols(row, secondaryCols);
        if (opts.agencyId && secondaryCols.has("agency_id")) sec.agency_id = opts.agencyId;
        for (const [k, v] of Object.entries(staticCols)) {
          if (k.endsWith("_field")) { const t = k.slice(0, -"_field".length); if (secondaryCols.has(t)) sec[t] = (orig as any)[v as string]; }
          else { if (secondaryCols.has(k)) sec[k] = v; }
        }
        secondaryRecords.push(sec);
      }
    }
    if (secondaryRecords.length > 0) {
      if (secUniqueOn && secUniqueOn.length > 0) {
        const { data, error } = await sb.from(secondaryWrite.table).upsert(secondaryRecords, { onConflict: secUniqueOn.join(","), ignoreDuplicates: secMerge === "ignore" }).select("id");
        if (error) throw new Error(`upsert secondary failed: ${error.message}`);
        secondaryInserted = data?.length ?? 0;
      } else {
        const { data, error } = await sb.from(secondaryWrite.table).insert(secondaryRecords).select("id");
        if (error) throw new Error(`insert secondary failed: ${error.message}`);
        secondaryInserted = data?.length ?? 0;
      }
    }
  }
  return { inserted: primaryInserted, updated: 0, ...(secondaryInserted > 0 && secondaryWrite?.table ? { secondary: { table: secondaryWrite.table, inserted: secondaryInserted } } : {}) };
}

async function executeRecipe(recipe: any, triggeredBy: string): Promise<any> {
  const started = Date.now();
  const recipeId = recipe.id as string;
  const agencyId = recipe.agency_id as string;
  await sb.from("automation_recipes").update({ last_run_at: new Date().toISOString(), last_run_status: "running" }).eq("id", recipeId);
  let runStatus = "success"; let errorMessage: string | null = null; let recordsProcessed = 0; let outputSummary = "";
  try {
    if (recipe.composio_action === "INTERNAL") {
      // v42: no pg_net. Split by handler prefix.
      if (recipe.internal_handler && recipe.internal_handler.startsWith("dispatch_")) {
        const edgeName = recipe.internal_handler.replace(/^dispatch_/, "").replace(/_/g, "-");
        const url = `${SUPABASE_URL}/functions/v1/${edgeName}`;
        const sharedSecret = await getSetting(agencyId, "automation_runner_cron_secret");
        if (!sharedSecret) throw new Error(`Cannot dispatch ${edgeName}: automation_runner_cron_secret missing for agency ${agencyId}`);
        const bodyPayload = { agency_id: agencyId, recipe_id: recipeId, shared_secret: sharedSecret, ...(recipe.input_config ?? {}) };
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 180_000);
        let fetchRes: Response;
        try {
          fetchRes = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SERVICE_ROLE_KEY}` }, body: JSON.stringify(bodyPayload), signal: controller.signal });
        } catch (fe) {
          const msg = fe instanceof Error ? fe.message : String(fe);
          if (msg.toLowerCase().includes("abort")) throw new Error(`${edgeName} did not respond within 180s (direct fetch aborted)`);
          throw new Error(`${edgeName} fetch failed: ${msg}`);
        } finally { clearTimeout(timeoutId); }
        const text = await fetchRes.text();
        let parsedBody: any = null; try { parsedBody = text ? JSON.parse(text) : null; } catch { parsedBody = null; }
        if (!fetchRes.ok) { const em = parsedBody?.error || parsedBody?.output_summary || (text ? text.slice(0, 400) : "no body"); throw new Error(`${edgeName} returned HTTP ${fetchRes.status}: ${em}`); }
        if (parsedBody) {
          recordsProcessed = (parsedBody.records_processed as number) ?? (parsedBody.summary?.processed as number) ?? (parsedBody.rows_upserted as number) ?? (parsedBody.processed_messages as number) ?? 0;
          outputSummary = (parsedBody.output_summary as string) ?? (parsedBody.summary ? `${edgeName} completed: ${JSON.stringify(parsedBody.summary).slice(0,300)}` : `${edgeName} completed (records_processed=${recordsProcessed})`);
        } else {
          outputSummary = `${edgeName} returned HTTP ${fetchRes.status} (empty body)`;
        }
      } else {
        const { data: internalResult, error: internalErr } = await sb.rpc("run_internal_recipe", { p_recipe_id: recipeId });
        if (internalErr) throw new Error(`run_internal_recipe failed: ${internalErr.message}`);
        recordsProcessed = (internalResult?.records_processed as number) ?? 0;
        outputSummary = (internalResult?.output_summary as string) ?? `INTERNAL recipe completed (no summary returned)`;

        // Post-commit hook for pfa_monthly_reconciliation (added 2026-08-04).
        // The SQL function used to email the reconciliation PDF via a
        // synchronous http_post to pfa-reconciliation-send from INSIDE its
        // own still-open transaction. The row it had just inserted was not
        // yet visible to the second connection the edge function opens to
        // look it up, so the send always failed ("reconciliation lookup
        // failed: undefined" — a swallowed zero-rows case, not a real error).
        // Fix: the SQL function no longer attempts the send at all — it just
        // computes and returns results[]. This hook fires AFTER the RPC call
        // has returned, i.e. after the transaction has committed, so the row
        // is genuinely visible. Mirrors afterCrmAnalyticsIngest() above.
        if (recipe.internal_handler === "pfa_monthly_reconciliation") {
          try {
            const sendFailures = await afterPfaReconciliation({ agencyId, results: (internalResult as any)?.results });
            if (sendFailures.length > 0) {
              runStatus = "failed";
              errorMessage = `PFA reconciliation email did not send — ${sendFailures.join("; ")}`.slice(0, 1000);
              outputSummary += ` — ⚠️ ${sendFailures.length} PFA send failure(s)`;
            }
          }
          catch (hookErr) {
            const hm = hookErr instanceof Error ? hookErr.message : String(hookErr);
            runStatus = "failed";
            errorMessage = `PFA send hook threw: ${hm}`.slice(0, 1000);
            outputSummary += ` — ⚠️ PFA send hook error: ${hm.slice(0, 200)}`;
          }
        }
      }
      const durationSec = Math.round((Date.now() - started) / 1000);
      await sb.from("automation_run_log").insert({ agency_id: agencyId, recipe_id: recipeId, status: runStatus, records_processed: recordsProcessed, error_message: errorMessage, duration_seconds: durationSec, output_summary: outputSummary });
      await sb.from("automation_recipes").update({ last_run_status: runStatus }).eq("id", recipeId);
      return { recipe_id: recipeId, recipe_name: recipe.recipe_name, status: runStatus, records_processed: recordsProcessed, duration_seconds: durationSec, triggered_by: triggeredBy, error: errorMessage };
    }

    // --- Composio-driven branch ---
    const composioApiKey = await getSetting(agencyId, "composio_api_key");
    if (!composioApiKey) throw new Error(`Missing composio_api_key (agency ${agencyId})`);
    const composioUserId = await getSetting(agencyId, "composio_user_id");
    if (!composioUserId) throw new Error(`Missing composio_user_id (agency ${agencyId})`);
    const connection = recipe.composio_connection;
    if (!connection) throw new Error(`Recipe ${recipe.recipe_name} has no composio_connection set.`);
    const accountId = await getComposioAccountId(agencyId, connection);
    const action = recipe.composio_action;
    if (!action) throw new Error(`Recipe ${recipe.recipe_name} has no composio_action set.`);
    const inputConfig = recipe.input_config || {};
    const RUNNER_ONLY_KEYS = new Set(["gmail_query","gmail_labels","archive_after_parse","archive_label_ids_to_add","dedupe_by","local_time","gl_firewall","output_table","drive_folders","apply_coding_rules","coding_rules_table","file_unparsed_messages"]);
    const composioArgs: Record<string, any> = {};
    for (const [k, v] of Object.entries(inputConfig)) if (!RUNNER_ONLY_KEYS.has(k)) composioArgs[k] = v;
    if (action === "GMAIL_FETCH_EMAILS") { if (inputConfig.gmail_query && !composioArgs.query) composioArgs.query = inputConfig.gmail_query; if (!composioArgs.user_id) composioArgs.user_id = "me"; if (recipe.internal_parser && composioArgs.include_payload === undefined) composioArgs.include_payload = true; }
    const composioResult = await callComposio({ apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId, toolSlug: action, toolArguments: composioArgs });
    if (!composioResult.ok) throw new Error(`Composio ${action} failed: ${composioResult.error}`);

    let parsedRecords: any[] = []; let alreadyKnownMessageIds: string[] = []; let fetchedMessageIds: string[] = [];
    let usedInternalParser = false;
    if (recipe.internal_parser && INTERNAL_PARSERS[recipe.internal_parser]) {
      let inputData: any = composioResult.data;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS") {
        inputData = extractGmailEssentials(composioResult.data, 50000);
        const messages: any[] = Array.isArray(inputData?.messages) ? inputData.messages : [];
        const fetchedIds: string[] = messages.map((m: any) => m.messageId as string | undefined).filter((x: any): x is string => typeof x === "string" && x.length > 0);
        fetchedMessageIds = fetchedIds;
        if (recipe.output_table && fetchedIds.length > 0) {
          const { data: existing, error: dedupErr } = await sb.from(recipe.output_table).select("source_message_id").in("source_message_id", fetchedIds);
          if (!dedupErr) { const knownSet = new Set((existing ?? []).map((r: any) => r.source_message_id as string)); if (knownSet.size > 0) { alreadyKnownMessageIds = fetchedIds.filter((id) => knownSet.has(id)); const nm = messages.filter((m: any) => !knownSet.has(m.messageId)); inputData = { total: nm.length, messages: nm }; } }
        }
      }
      const parserFn = INTERNAL_PARSERS[recipe.internal_parser];
      const records = parserFn(inputData); parsedRecords = Array.isArray(records) ? records : []; usedInternalParser = true;
    }
    if (!usedInternalParser && recipe.groq_prompt && recipe.output_table) {
      const groqApiKey = await getSetting(agencyId, "groq_api_key");
      if (!groqApiKey) throw new Error(`Missing groq_api_key (agency ${agencyId})`);
      let inputData: any = composioResult.data;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS") {
        inputData = extractGmailEssentials(composioResult.data);
        const messages: any[] = Array.isArray(inputData?.messages) ? inputData.messages : [];
        const fetchedIds: string[] = messages.map((m: any) => m.messageId as string | undefined).filter((x: any): x is string => typeof x === "string" && x.length > 0);
        fetchedMessageIds = fetchedIds;
        if (fetchedIds.length > 0) {
          const { data: existing, error: dedupErr } = await sb.from(recipe.output_table).select("source_message_id").in("source_message_id", fetchedIds);
          if (!dedupErr) { const knownSet = new Set((existing ?? []).map((r: any) => r.source_message_id as string)); if (knownSet.size > 0) { alreadyKnownMessageIds = fetchedIds.filter((id) => knownSet.has(id)); const nm = messages.filter((m: any) => !knownSet.has(m.messageId)); inputData = { total: nm.length, messages: nm }; } }
        }
      }
      const msgsAfter = Array.isArray(inputData?.messages) ? inputData.messages.length : -1;
      if (msgsAfter === 0) { parsedRecords = []; }
      else {
        const inputForLLM = JSON.stringify(inputData).slice(0, 50000);
        const llmResult = await callGroqLLM({ agencyId: recipe.agency_id, groqApiKey, systemPrompt: recipe.groq_prompt + '\n\nReturn JSON: {"records": [...]}.', userContent: inputForLLM });
        if (!llmResult.ok) throw new Error(`LLM parsing failed: ${llmResult.error}`);
        parsedRecords = Array.isArray(llmResult.data?.records) ? llmResult.data.records : [];
      }
    } else if (recipe.output_table && Array.isArray(composioResult.data)) {
      parsedRecords = composioResult.data;
    }
    // -------------------------------------------------------------------
    // fileFetchedGmailMessages — label + archive EVERY fetched message,
    // including ones the parser deliberately returned no record for.
    //
    // Until 2026-08-22 only two groups were ever filed: messages that
    // produced a record on this run, and messages already present in the
    // output table from an earlier run. A message the parser SKIPPED on
    // purpose belonged to neither. It stayed in the inbox with no label,
    // and because "already handled" is judged by presence in the output
    // table, it was re-fetched and re-sent to the LLM on EVERY subsequent
    // run, indefinitely.
    //
    // That is not theoretical. The Cash Register Alert Ingestor's prompt
    // carries a business-account whitelist (3439/3977/4335/4676). Four US
    // Bank alerts for personal accounts 0353 and 2545 arrived 2026-08-21,
    // were correctly skipped, and were then re-parsed roughly 24 times in
    // a day — sitting unlabelled in the inbox the whole time and burning
    // a slice of the Groq daily token allowance on every pass, until the
    // allowance ran out and runs with real work started failing 429.
    //
    // OPT-IN, via input_config.file_unparsed_messages. Default OFF and
    // behaviour is byte-for-byte what it was. Recipes that read human
    // correspondence (candidate replies, time-off votes, bounce
    // detection) must NOT turn it on: filing an email the parser could
    // not read would bury a real message out of Peter's inbox. Turn it on
    // only where skipping is a designed outcome rather than a failure.
    //
    // Filing is never silent even when enabled: the count goes into the
    // run summary and an alert row records the message ids.
    // -------------------------------------------------------------------
    const fileFetchedGmailMessages = async (recordIds: string[]): Promise<string> => {
      const handled = new Set<string>([...recordIds, ...alreadyKnownMessageIds]);
      const skippedIds = inputConfig.file_unparsed_messages === true
        ? fetchedMessageIds.filter((id) => !handled.has(id))
        : [];
      const allIds = Array.from(new Set<string>([...handled, ...skippedIds]));
      if (allIds.length === 0) return "";
      const ar = await archiveProcessedGmailMessages({ apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId, messageIds: allIds, additionalLabelsToAdd: inputConfig.archive_label_ids_to_add as string[] | undefined });
      let note = "";
      if (ar.ok) {
        note += ` — archived ${ar.archived} from inbox`;
        if (alreadyKnownMessageIds.length > 0) note += ` (${alreadyKnownMessageIds.length} were dups)`;
        if (skippedIds.length > 0) note += ` (${skippedIds.length} filed with no record — parser skipped)`;
      } else {
        note += ` — ⚠️ archive failed: ${ar.error}`;
        await telegram(agencyId, `🟡 Post-parse archive failed for ${recipe.recipe_name}\n${(ar.error ?? "").slice(0,400)}`);
      }
      if (skippedIds.length > 0) {
        await insertAlert({
          agencyId,
          alertType: "gmail_parser_skipped_message",
          severity: "info",
          title: `${skippedIds.length} email(s) filed with no record — ${recipe.recipe_name}`,
          message: `The parser returned no record for ${skippedIds.length} fetched message(s). They have been labelled and archived so they are not re-parsed on every run. Gmail message ids: ${skippedIds.slice(0, 20).join(", ")}`,
          moduleReference: "automation-runner",
        });
      }
      return note;
    };

    if (recipe.output_table && parsedRecords.length > 0) {
      const wr = await writeOutput({ outputTable: recipe.output_table, outputConfig: recipe.output_config || {}, records: parsedRecords, agencyId });
      recordsProcessed = wr.inserted + wr.updated;
      outputSummary = `${recordsProcessed} records written to ${recipe.output_table}`;
      if (wr.secondary) outputSummary += ` (+ ${wr.secondary.inserted} rows to ${wr.secondary.table})`;

      // Post-write hook for sf_crm_analytics_email: stamp the ingestion flag
      // on the affected agency_snapshot rows + DM Peter a compact summary.
      if (recipe.internal_parser === "sf_crm_analytics_email") {
        try { await afterCrmAnalyticsIngest({ agencyId, records: parsedRecords }); }
        catch (hookErr) {
          const hm = hookErr instanceof Error ? hookErr.message : String(hookErr);
          outputSummary += ` — ⚠️ post-ingest hook error: ${hm.slice(0, 200)}`;
        }
      }

      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        const newIds = parsedRecords.map((r: any) => r.source_message_id as string | undefined).filter((x): x is string => typeof x === "string" && x.length > 0);
        outputSummary += await fileFetchedGmailMessages(newIds);
      }
    } else if (recipe.output_table && alreadyKnownMessageIds.length > 0) {
      outputSummary = `0 new records — ${alreadyKnownMessageIds.length} already processed historically`;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        outputSummary += await fileFetchedGmailMessages([]);
      }
    } else if (recipe.output_table) {
      outputSummary = `0 records — no records to write`;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        outputSummary += await fileFetchedGmailMessages([]);
      }
    } else {
      outputSummary = `Action ${action} executed successfully (no output_table)`;
      recordsProcessed = 1;
    }
  } catch (err) {
    runStatus = "failed";
    errorMessage = err instanceof Error ? err.message : String(err);
    outputSummary = `Failed: ${errorMessage.slice(0, 200)}`;
    await telegram(agencyId, `🛑 <b>Automation FAILED</b>\nRecipe: <b>${recipe.recipe_name}</b>\nError: ${errorMessage.slice(0, 400)}`);
  }
  const durationSec = Math.round((Date.now() - started) / 1000);
  await sb.from("automation_run_log").insert({ agency_id: agencyId, recipe_id: recipeId, status: runStatus, records_processed: recordsProcessed, error_message: errorMessage, duration_seconds: durationSec, output_summary: outputSummary });
  await sb.from("automation_recipes").update({ last_run_status: runStatus }).eq("id", recipeId);
  return { recipe_id: recipeId, recipe_name: recipe.recipe_name, status: runStatus, records_processed: recordsProcessed, duration_seconds: durationSec, triggered_by: triggeredBy, error: errorMessage };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed. Use POST." }, 405);
  let body: any = {};
  try { const text = await req.text(); body = text ? JSON.parse(text) : {}; } catch { return jsonResponse({ error: "Invalid JSON body" }, 400); }
  const recipeId: string | undefined = body.recipe_id;
  const triggeredBy: string = body.triggered_by || "manual";
  if (!recipeId) return jsonResponse({ error: "Missing recipe_id in body" }, 400);
  if (typeof body.shared_secret !== "string" || body.shared_secret.length === 0) return jsonResponse({ error: "Missing shared_secret in body" }, 401);
  const { data: recipe, error: recipeErr } = await sb.from("automation_recipes").select("*").eq("id", recipeId).maybeSingle();
  if (recipeErr || !recipe) return jsonResponse({ error: `Recipe ${recipeId} not found: ${recipeErr?.message || "no row"}` }, 404);
  if (!recipe.agency_id) return jsonResponse({ error: `Recipe ${recipeId} has no agency_id set.` }, 500);
  let expectedSecret: string | null;
  try { expectedSecret = await getSetting(recipe.agency_id, "automation_runner_cron_secret"); }
  catch (err) { const msg = err instanceof Error ? err.message : String(err); return jsonResponse({ error: `Auth lookup failed: ${msg}` }, 500); }
  if (!expectedSecret) return jsonResponse({ error: `Server missing settings.automation_runner_cron_secret for agency ${recipe.agency_id}` }, 500);
  if (body.shared_secret !== expectedSecret) return jsonResponse({ error: "Unauthorized: invalid shared_secret" }, 401);
  try {
    const result = await executeRecipe(recipe, triggeredBy);
    const status = result.status === "success" ? 200 : 500;
    return jsonResponse({ ok: result.status === "success", ...result }, status);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await telegram(recipe.agency_id, `🛑 automation-runner CRASHED\n${msg.slice(0, 300)}`);
    return jsonResponse({ ok: false, error: msg }, 500);
  }
});
