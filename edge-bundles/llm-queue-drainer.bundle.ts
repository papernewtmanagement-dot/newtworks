// =========================================================================
// llm-queue-drainer bundle (auto-generated)
// Source of truth: supabase/functions/llm-queue-drainer/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py llm-queue-drainer`.
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

// ==================== _shared/llm.ts ====================
// =========================================================================
// _shared/llm.ts
// =========================================================================
// Canonical Groq chat caller for ALL Newtworks edge functions. Replaces the
// seven independent reimplementations that used to live in automation-runner,
// telegram, chatbot, team-trajectory-summarize, llm-queue-drainer,
// generate-custom-probes and document-processor/lib/llm.ts.
//
// Behavior knobs cover every existing call site:
//   temperature / maxTokens — per caller
//   jsonObject              — response_format {type:"json_object"} (runner style)
//   retries                 — retry 429/5xx with 500ms*2^n backoff (runner style)
//
// Returns the RAW assistant content string. JSON parsing of the content is
// the caller's job (some callers want text, some want JSON, some strip fences
// first). stripFences lives in _shared/supabase.ts.
// =========================================================================


const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";

// Reads settings.groq_model_default for the agency; falls back to
// LLM_MODEL_FALLBACK if the row is missing OR the settings read errors.
async function getDefaultModel(agencyId: string): Promise<string> {
  const v = await getSettingOrNull(agencyId, "groq_model_default");
  return (v && v.trim()) || LLM_MODEL_FALLBACK;
}

// settings.groq_api_key, then the GROQ_API_KEY env var, then null.
async function getGroqKey(agencyId: string): Promise<string | null> {
  const fromSettings = await getSettingOrNull(agencyId, "groq_api_key");
  if (fromSettings) return fromSettings;
  return Deno.env.get("GROQ_API_KEY") ?? null;
}

interface GroqChatResult {
  ok: boolean;
  raw: string;            // assistant content when ok, "" otherwise
  error: string | null;
  httpStatus: number;     // 0 on network failure
  // "length" means the model ran out of answer budget and the content is CUT
  // OFF mid-stream. A caller that JSON.parses the content must check this
  // first, otherwise a truncation is misreported as malformed JSON and the
  // real cause (budget, not the model's output shape) stays hidden.
  finishReason?: string | null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function callGroqChat(opts: {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userContent: string;
  maxTokens?: number;      // default 4000
  temperature?: number;    // default 0.1
  jsonObject?: boolean;    // request response_format json_object
  retries?: number;        // extra attempts on 429/5xx; default 0
  // gpt-oss models are REASONING models: Groq bills their hidden thinking
  // tokens against max_tokens, so thinking silently eats the answer budget.
  // Measured live 2026-08-18 on AMEX Discretionary 26-08: max_tokens 2623,
  // visible answer stopped at ~365 tokens (~1459 chars, mid-string) because
  // roughly 2250 tokens went to thinking. Set "low" for mechanical extraction
  // (statement parsing, field pulls) where thinking buys nothing. Omit to keep
  // the provider default.
  reasoningEffort?: "none" | "low" | "medium" | "high";
  // Abort a call that has not answered in this many ms (none by default).
  timeoutMs?: number;
  // Pacing (2026-10-09). With agencyId set, the call first books its tokens
  // against the agency's per-minute Groq budget (groq_pace() in the database,
  // shared by every function and every invocation) and waits its turn, so a
  // burst is spread out instead of tripping the 8,000-tokens-a-minute cap.
  // A turn further off than maxPaceWaitMs (default 30s) is not waited for:
  // the call returns "Groq busy" at once so the caller can use its backup.
  agencyId?: string;
  maxPaceWaitMs?: number;
}): Promise<GroqChatResult> {
  if (opts.agencyId) {
    const need = estimateTokens(opts.systemPrompt + opts.userContent) + (opts.maxTokens ?? 4000);
    const pace = await paceGroq(opts.agencyId, need, opts.maxPaceWaitMs ?? 30000);
    if (pace.busyMs > 0) {
      return {
        ok: false, raw: "", httpStatus: 429,
        error: `Groq busy: next turn under the per-minute token cap is ${Math.ceil(pace.busyMs / 1000)}s away`,
      };
    }
    if (pace.waitMs > 0) await sleep(pace.waitMs);
  }
  const body: Record<string, unknown> = {
    model: opts.model,
    messages: [
      { role: "system", content: opts.systemPrompt },
      { role: "user", content: opts.userContent },
    ],
    temperature: opts.temperature ?? 0.1,
    max_tokens: opts.maxTokens ?? 4000,
  };
  if (opts.jsonObject) body.response_format = { type: "json_object" };
  if (opts.reasoningEffort) body.reasoning_effort = opts.reasoningEffort;

  const attempts = 1 + Math.max(0, opts.retries ?? 0);
  let lastErr = "unknown";
  let lastStatus = 0;
  // A paced call that still gets a 429 (another account user, or a booking
  // estimate that came in low) waits once for Groq's own retry-after when it
  // is short, rather than giving up straight away.
  let honoredRetryAfter = !opts.agencyId;

  for (let attempt = 0; attempt < attempts; attempt++) {
    let res: Response;
    const controller = new AbortController();
    const timer = opts.timeoutMs ? setTimeout(() => controller.abort(), opts.timeoutMs) : null;
    const startedAt = Date.now();
    try {
      res = await fetch(GROQ_ENDPOINT, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${opts.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (e) {
      if (timer) clearTimeout(timer);
      const timedOut = e instanceof Error && e.name === "AbortError";
      return {
        ok: false, raw: "", httpStatus: 0,
        error: timedOut
          ? `Groq call timed out after ${Date.now() - startedAt}ms`
          : `Groq fetch failed: ${(e as Error).message}`,
      };
    }
    lastStatus = res.status;

    if (res.status === 429 && !honoredRetryAfter) {
      const after = Number(res.headers.get("retry-after"));
      if (Number.isFinite(after) && after > 0 && after <= 20) {
        honoredRetryAfter = true;
        await res.text().catch(() => "");
        if (timer) clearTimeout(timer);
        await sleep(after * 1000 + 250);
        attempt--; // this wait does not use up one of the caller's retries
        continue;
      }
    }

    if ((res.status === 429 || res.status >= 500) && attempt < attempts - 1) {
      lastErr = `Groq HTTP ${res.status}`;
      await res.text().catch(() => "");
      if (timer) clearTimeout(timer);
      await sleep(500 * Math.pow(2, attempt));
      continue;
    }

    let text: string;
    try { text = await res.text(); }
    catch (e) {
      return { ok: false, raw: "", error: `Groq answer could not be read: ${(e as Error).message}`, httpStatus: res.status };
    }
    finally { if (timer) clearTimeout(timer); }
    if (!res.ok) {
      return { ok: false, raw: "", error: `Groq HTTP ${res.status}: ${text.slice(0, 400)}`, httpStatus: res.status };
    }
    let parsed: any;
    try { parsed = JSON.parse(text); }
    catch (e) {
      return { ok: false, raw: text, error: `Groq returned non-JSON envelope: ${String(e)}`, httpStatus: res.status };
    }
    const finishReason = parsed?.choices?.[0]?.finish_reason ?? null;
    const content = parsed?.choices?.[0]?.message?.content ?? "";
    if (!content || typeof content !== "string") {
      return { ok: false, raw: "", error: "Groq returned empty content", httpStatus: res.status, finishReason };
    }
    return { ok: true, raw: content, error: null, httpStatus: res.status, finishReason };
  }

  return { ok: false, raw: "", error: `Groq exhausted retries: ${lastErr}`, httpStatus: lastStatus };
}

// =========================================================================
// Pacing (2026-10-09)
// =========================================================================
// Groq allows this account 8,000 tokens a minute (prompt + answer budget). A
// burst of reads used to fire together and all but the first came back 429.
// groq_pace() in the database keeps a one-minute booking list in the agency's
// settings row 'groq_tpm_ledger', locked per call, so every function and every
// invocation books from the same budget. It answers with how long to wait
// before sending (waitMs, already booked) or, when the next turn is further
// off than the caller will wait, how far off it is (busyMs, nothing booked).
// If the booking itself fails the call goes ahead unpaced: pacing must never
// be the reason a read does not happen.

// Statement and payroll text is dense with digits; 3.4 chars a token errs high.
const CHARS_PER_TOKEN_EST = 3.4;
function estimateTokens(s: string): number {
  return Math.ceil((s ?? "").length / CHARS_PER_TOKEN_EST);
}

// Groq caps EVERY request, prompt AND answer together, at 8,000 tokens on this
// tier. A caller's answer budget is a CEILING, not a reservation: fit it to
// what is left after the prompt. 413 (too big, fails forever) is not 429 (too
// fast, works after a wait). The one copy of this clamp; document-processor's
// parseWithLLM and llm-queue-drainer both call it (they each had their own
// until 2026-10-09).
const GROQ_REQUEST_TOKEN_CAP = 8000;
const GROQ_SAFETY_MARGIN = 300;
function fitMaxTokens(systemPrompt: string, userContent: string, ceiling: number, floor = 400): number {
  const available = GROQ_REQUEST_TOKEN_CAP - estimateTokens(systemPrompt + userContent) - GROQ_SAFETY_MARGIN;
  return Math.max(floor, Math.min(ceiling, available));
}

async function paceGroq(
  agencyId: string, tokens: number, maxWaitMs: number,
): Promise<{ waitMs: number; busyMs: number }> {
  try {
    const { data, error } = await sb.rpc("groq_pace", {
      p_agency_id: agencyId, p_tokens: Math.max(1, Math.round(tokens)), p_max_wait_ms: Math.round(maxWaitMs),
    });
    if (error || !data) return { waitMs: 0, busyMs: 0 };
    return { waitMs: Number(data.wait_ms) || 0, busyMs: Number(data.busy_ms) || 0 };
  } catch (_e) {
    return { waitMs: 0, busyMs: 0 };
  }
}

// =========================================================================
// Claude backup reader (2026-10-09)
// =========================================================================
// Groq reads first. Claude reads only when Groq errors or its answer fails
// the caller's checks. The call is lean: the same instructions and the same
// extracted text Groq got, nothing else. Pay-per-use key in
// settings.anthropic_api_key (the same key the database's claude_api_call()
// uses for the scheduled jobs).

const CLAUDE_BACKUP_MODEL = "claude-sonnet-5-5";
const CLAUDE_ENDPOINT = "https://api.anthropic.com/v1/messages";

async function getClaudeKey(agencyId: string): Promise<string | null> {
  return await getSettingOrNull(agencyId, "anthropic_api_key");
}

async function callClaudeChat(opts: {
  apiKey: string;
  systemPrompt: string;
  userContent: string;
  maxTokens?: number;   // default 8000
  model?: string;       // default CLAUDE_BACKUP_MODEL
  timeoutMs?: number;   // default 90s
}): Promise<GroqChatResult> {
  const controller = new AbortController();
  const timeoutMs = opts.timeoutMs ?? 90000;
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();
  try {
    const res = await fetch(CLAUDE_ENDPOINT, {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: opts.model ?? CLAUDE_BACKUP_MODEL,
        max_tokens: opts.maxTokens ?? 8000,
        system: opts.systemPrompt,
        messages: [{ role: "user", content: opts.userContent }],
      }),
      signal: controller.signal,
    });
    const text = await res.text();
    if (!res.ok) {
      return { ok: false, raw: "", error: `Claude HTTP ${res.status}: ${text.slice(0, 400)}`, httpStatus: res.status };
    }
    let parsed: any;
    try { parsed = JSON.parse(text); }
    catch (e) {
      return { ok: false, raw: text, error: `Claude returned non-JSON envelope: ${String(e)}`, httpStatus: res.status };
    }
    const content = Array.isArray(parsed?.content)
      ? parsed.content.filter((b: any) => b?.type === "text").map((b: any) => b.text ?? "").join("")
      : "";
    // Same word Groq uses for a cut-off answer, so callers check one thing.
    const finishReason = parsed?.stop_reason === "max_tokens" ? "length" : (parsed?.stop_reason ?? null);
    if (!content) {
      return { ok: false, raw: "", error: "Claude returned empty content", httpStatus: res.status, finishReason };
    }
    return { ok: true, raw: content, error: null, httpStatus: res.status, finishReason };
  } catch (e) {
    const timedOut = e instanceof Error && e.name === "AbortError";
    return {
      ok: false, raw: "", httpStatus: 0,
      error: timedOut
        ? `Claude call timed out after ${Date.now() - startedAt}ms`
        : `Claude fetch failed: ${(e as Error).message}`,
    };
  } finally {
    clearTimeout(timer);
  }
}

interface BackedReadResult extends GroqChatResult {
  reader: "groq" | "claude" | null;   // who gave the answer in raw (null: nobody)
  groqProblem: string | null;          // why Groq's answer was not used, if it was not
  // On a double failure, each reader's raw answer when it had one, so a
  // caller whose checks are only advisory can still use the better one.
  groqRaw: string | null;
  claudeRaw: string | null;
}

// The one place that decides "Groq first, Claude as backup". check() returns
// null when an answer is good, or a short reason it is not. A cut-off answer
// always counts as a failure.
async function readWithBackup(opts: {
  agencyId: string;
  groqKey: string | null;
  model: string;
  systemPrompt: string;
  userContent: string;
  maxTokens: number;            // Groq answer ceiling (callers clamp to the cap first)
  claudeMaxTokens?: number;     // default 8000; Claude has no 8,000 request cap
  temperature?: number;
  jsonObject?: boolean;         // ask Groq for a JSON object (Claude follows the prompt)
  reasoningEffort?: "none" | "low" | "medium" | "high";
  groqTimeoutMs?: number;
  claudeTimeoutMs?: number;
  maxPaceWaitMs?: number;
  check?: (raw: string) => string | null;
  label?: string;               // for the log line, e.g. "purpose=bank document=<id>"
}): Promise<BackedReadResult> {
  const judge = (r: GroqChatResult): string | null => {
    if (!r.ok) return r.error ?? "no answer";
    if (r.finishReason === "length") return `answer cut off at the answer budget (${r.raw.length} chars returned)`;
    try { return opts.check ? opts.check(r.raw) : null; }
    catch (e) { return `check threw: ${(e as Error).message}`; }
  };

  let groqProblem: string | null = opts.groqKey ? null : "no groq_api_key setting";
  let groqRaw: string | null = null;
  if (opts.groqKey) {
    const g = await callGroqChat({
      apiKey: opts.groqKey,
      model: opts.model,
      systemPrompt: opts.systemPrompt,
      userContent: opts.userContent,
      maxTokens: opts.maxTokens,
      temperature: opts.temperature ?? 0.1,
      jsonObject: opts.jsonObject,
      reasoningEffort: opts.reasoningEffort,
      timeoutMs: opts.groqTimeoutMs,
      agencyId: opts.agencyId,
      maxPaceWaitMs: opts.maxPaceWaitMs,
    });
    groqRaw = g.ok ? g.raw : null;
    groqProblem = judge(g);
    if (!groqProblem) return { ...g, reader: "groq", groqProblem: null, groqRaw, claudeRaw: null };
  }

  const claudeKey = await getClaudeKey(opts.agencyId);
  if (!claudeKey) {
    return {
      ok: false, raw: groqRaw ?? "", httpStatus: 0, reader: groqRaw ? "groq" : null,
      error: `Groq: ${groqProblem}; Claude backup: no anthropic_api_key setting`,
      groqProblem, groqRaw, claudeRaw: null,
    };
  }
  console.log(`[llm] Claude backup read (${opts.label ?? "no label"}); Groq: ${groqProblem}`);
  const c = await callClaudeChat({
    apiKey: claudeKey,
    systemPrompt: opts.systemPrompt,
    userContent: opts.userContent,
    maxTokens: opts.claudeMaxTokens ?? 8000,
    timeoutMs: opts.claudeTimeoutMs,
  });
  const claudeRaw = c.ok ? c.raw : null;
  const claudeProblem = judge(c);
  if (!claudeProblem) return { ...c, reader: "claude", groqProblem, groqRaw, claudeRaw };
  return {
    ok: false, raw: claudeRaw ?? groqRaw ?? "", httpStatus: c.httpStatus,
    reader: claudeRaw ? "claude" : (groqRaw ? "groq" : null),
    finishReason: c.finishReason,
    error: `Groq: ${groqProblem}; Claude backup: ${claudeProblem}`,
    groqProblem, groqRaw, claudeRaw,
  };
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

const ADMIN_ROLES = ["owner", "admin"];

async function requireOwnerOrManager(
  req: Request,
  agencyId: string,
): Promise<Response | null> {
  return requireCallerRole(req, agencyId, ADMIN_ROLES);
}

// Owner only. Terminations use this. Peter 2026-09-25: "A termination should
// only come from me through the website."
async function requireOwner(
  req: Request,
  agencyId: string,
): Promise<Response | null> {
  return requireCallerRole(req, agencyId, ["owner"]);
}

// The one caller check. The wrappers above only choose which roles pass.
async function requireCallerRole(
  req: Request,
  agencyId: string,
  roles: string[],
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
  if (!row || row.agency_id !== agencyId || !roles.includes(row.role as string)) {
    return corsJson({ ok: false, error: "not permitted" }, 403);
  }
  return null;
}

// ==================== _shared/statement_writer.ts ====================
// =========================================================================
// _shared/statement_writer.ts
// =========================================================================
// THE single statement ingestion writer. Both intake paths call this:
//   - document-processor handleBankStatement (synchronous parse)
//   - llm-queue-drainer drainBankStatementItem (queued parse)
// Collapsed 2026-08-11 from two hand-maintained copies (see open question
// "Collapse the twin statement ingestion writers into one shared function").
// What rides on the agreement between the two paths is money-sign
// correctness and cross-path duplicate detection — so there is now exactly
// one copy.
//
// Guarantees, in order of evaluation:
//   1. DUPLICATE-INGEST GUARD (document/period grain). The same statement
//      file historically arrived through two intake doors (email attachment
//      + Drive library sweep), producing two documents rows that were each
//      parsed. statement_balances has a unique index so balances collided;
//      statements has NO unique constraint so transactions doubled. Guard:
//      if another document already wrote transactions for this account +
//      statement period, stamp this document 'duplicate_ingest', emit a
//      low-severity alert, write NOTHING. Deliberately NOT a unique index
//      at the transaction grain — two genuinely distinct transactions can
//      share account, date, amount AND description (account 2110 has two
//      real 250.00 EVERQUOTE charges on 2026-05-10; the window ties with
//      both present).
//   2. RECONCILIATION GUARD. closing == opening + sum(signedAmount) within
//      STMT_RECON_EPSILON. Missing balances or a mismatch → stamp the
//      document 'held_reconciliation_mismatch', stash the parsed payload in
//      documents.notes, emit a high-severity alert, write NOTHING. This is
//      the deterministic backstop for silently dropped lines: the 2026-08-05
//      manual pass dropped repeated identical same-day charges (13 rows /
//      286.93 on AMEX 2141) and nothing checked the tie. Any dropped line —
//      whatever layer drops it — now breaks the tie loudly instead of
//      landing short.
//   3. BALANCE UPSERT keyed (agency_id, account_code, statement_period_end).
//      account_kind comes from the resolved accounts row — never inferred
//      from the account code string (the old '-CC-' inference can never
//      match numeric chart codes).
//   4. TRANSACTIONS with per-parse occurrence counting. Repeated identical
//      (account, date, amount, payee) lines within one parsed statement each
//      get their own occurrence number, carried on BOTH reference_number and
//      dedup_fingerprint (dp:<code>:<date>:<cents>:<payee20>[:N], N omitted
//      for the first occurrence). Any insert error → ok:false so callers do
//      NOT stamp the document processed (R2 silent-failure rule preserved
//      for both paths).
//
// Sign convention (D15): parser emits positive = money in, negative = money
// out, regardless of account kind. Bank rows keep the parser sign. Credit
// rows flip: a charge lands positive (balance owed goes up), a payment or
// refund lands negative. Derived only from account_kind, never from the
// amount's own sign.
// =========================================================================


const STMT_RECON_EPSILON = 0.01;

interface ParsedStatementTxn {
  date: string;          // ISO transaction date (date charged, not posted)
  payee: string;
  memo: string;
  signedAmount: number;  // parser convention: + money in, - money out
}

interface WriteParsedStatementOpts {
  agencyId: string;
  documentId: string;
  accountCode: string;               // chart code, e.g. "2141"
  account: {
    id: string;                      // accounts.id
    businessEntityId: string;
    accountKind: string;             // 'bank' | 'credit'
  };
  accountLast4: string | null;
  period: { start: string; end: string };
  openingBalance: number | null;
  closingBalance: number | null;
  transactions: ParsedStatementTxn[];
  source: "document_processor" | "llm_queue_drainer";
}

type WriteParsedStatementResult =
  | { ok: true; inserted: number }
  | { ok: false; held: "duplicate_ingest"; reason: string; priorDocumentId: string }
  | { ok: false; held: "reconciliation_mismatch"; reason: string; delta: number | null }
  | { ok: false; held?: undefined; error: string; inserted: number };

function moduleRef(source: WriteParsedStatementOpts["source"]): string {
  return source === "llm_queue_drainer" ? "llm-queue-drainer" : "document-processor";
}

async function writeParsedStatement(
  opts: WriteParsedStatementOpts,
): Promise<WriteParsedStatementResult> {
  const nowIso = () => new Date().toISOString();

  // ---- 1. Duplicate-ingest guard (document/period grain) ------------------
  const { data: priorBal } = await sb
    .from("statement_balances")
    .select("id, source_document_id")
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .eq("statement_period_end", opts.period.end)
    .maybeSingle();

  if (priorBal?.source_document_id && priorBal.source_document_id !== opts.documentId) {
    const { count } = await sb
      .from("statements")
      .select("id", { count: "exact", head: true })
      .eq("agency_id", opts.agencyId)
      .eq("source_document_id", priorBal.source_document_id);
    if ((count ?? 0) > 0) {
      const reason =
        `duplicate_ingest: document ${priorBal.source_document_id} already wrote ` +
        `${count} transactions for account ${opts.accountCode} period ending ${opts.period.end}. ` +
        `Nothing written from this document.`;
      await sb.from("documents").update({
        processing_status: "duplicate_ingest",
        notes: reason,
        processed_at: nowIso(),
      }).eq("id", opts.documentId);
      await ensureWatcherTask({
        agencyId: opts.agencyId,
        source: `duplicate_statement_ingest:${moduleRef(opts.source)}`,
        relatedId: opts.documentId,
        title: `Duplicate statement skipped — ${opts.accountCode} period ending ${opts.period.end}`,
        description: reason,
        priority: "low",
        category: "finances",
      });
      return { ok: false, held: "duplicate_ingest", reason, priorDocumentId: priorBal.source_document_id };
    }
  }

  // ---- 2. Reconciliation guard --------------------------------------------
  const openBal = opts.openingBalance;
  const closeBal = opts.closingBalance;
  let reconDelta: number | null = null;
  let reconHeldReason: string | null = null;

  if (openBal === null || closeBal === null) {
    reconHeldReason =
      `missing balance from parser: opening=${openBal === null ? "null" : openBal}, ` +
      `closing=${closeBal === null ? "null" : closeBal}`;
  } else {
    // The guard must compare like with like. Parser convention (D15) is
    // + money in / - money out regardless of account kind, but a CREDIT
    // statement's balances are amounts OWED: a purchase (parser negative)
    // makes the balance go UP, and a payment (parser positive) makes it go
    // DOWN. So the sum has to carry the same account_kind flip the row writer
    // applies below, or every card statement mis-ties by twice its own
    // activity. Bank balances move with the parser sign and need no flip.
    //
    // Found 2026-08-19 on AMEX Discretionary 26-08: opening 5460.25, closing
    // 3304.71, parser sum +2022.78. Unflipped the guard expected 7483.03 and
    // reported a $4178.32 break. Flipped it expects 3437.47, leaving exactly
    // -132.76 — which is 2 x 66.38, the single Amazon refund the parser had
    // read as a purchase. Flipping the guard is what made the residual
    // diagnostic instead of noise.
    const kindSign = opts.account.accountKind === "credit" ? -1 : 1;
    const txnSum = opts.transactions.reduce((acc, t) => acc + kindSign * t.signedAmount, 0);
    const expected = openBal + txnSum;
    reconDelta = Math.round((closeBal - expected) * 100) / 100;
    if (Math.abs(reconDelta) > STMT_RECON_EPSILON) {
      reconHeldReason =
        `delta=$${reconDelta.toFixed(2)} exceeds epsilon $${STMT_RECON_EPSILON.toFixed(2)} ` +
        `(opening=$${openBal.toFixed(2)}, sum_txns=$${txnSum.toFixed(2)}, ` +
        `expected_close=$${expected.toFixed(2)}, actual_close=$${closeBal.toFixed(2)}, ` +
        `${opts.transactions.length} txns)`;
    }
  }

  if (reconHeldReason !== null) {
    const heldNotes = JSON.stringify({
      held: "reconciliation_mismatch",
      reason: reconHeldReason,
      reconciliation_delta: reconDelta,
      source_account_code: opts.accountCode,
      account_last4: opts.accountLast4,
      statement_period: opts.period,
      opening_balance: openBal,
      closing_balance: closeBal,
      txn_count: opts.transactions.length,
      parsed_transactions: opts.transactions.map((t) => ({
        date: t.date, payee: t.payee, memo: t.memo, amount: t.signedAmount,
      })),
    });
    await sb.from("documents").update({
      processing_status: "held_reconciliation_mismatch",
      reconciliation_delta: reconDelta,
      notes: heldNotes,
      processed_at: nowIso(),
    }).eq("id", opts.documentId);
    await ensureWatcherTask({
      agencyId: opts.agencyId,
      source: `reconciliation_mismatch:${moduleRef(opts.source)}`,
      relatedId: opts.documentId,
      title: `Statement reconciliation mismatch — ${opts.accountCode} period ending ${opts.period.end}`,
      description:
        `Parsed statement for account ${opts.accountCode} does not tie to the printed ` +
        `statement summary. ${reconHeldReason}. Held for review — nothing written.`,
      priority: "high",
      category: "finances",
    });
    console.warn(`[statement_writer] reconciliation_mismatch doc=${opts.documentId} account=${opts.accountCode}: ${reconHeldReason}`);
    return { ok: false, held: "reconciliation_mismatch", reason: reconHeldReason, delta: reconDelta };
  }

  // Success path: record near-zero delta for the audit trail.
  await sb.from("documents").update({ reconciliation_delta: reconDelta }).eq("id", opts.documentId);

  // ---- 3. Balance upsert (agency_id, account_code, statement_period_end) --
  const balPayload = {
    business_entity_id: opts.account.businessEntityId,
    account_last4: opts.accountLast4,
    account_kind: opts.account.accountKind,
    statement_period_start: opts.period.start,
    opening_balance: openBal,
    closing_balance: closeBal,
    source_document_id: opts.documentId,
    source: opts.source,
    updated_at: nowIso(),
  };
  const upd = await sb
    .from("statement_balances")
    .update(balPayload)
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .eq("statement_period_end", opts.period.end)
    .select("id");
  if (upd.error) {
    return { ok: false, error: `statement_balances update failed: ${upd.error.message}`, inserted: 0 };
  }
  if (!upd.data || upd.data.length === 0) {
    const ins = await sb.from("statement_balances").insert({
      agency_id: opts.agencyId,
      account_code: opts.accountCode,
      statement_period_end: opts.period.end,
      ...balPayload,
    });
    if (ins.error) {
      return { ok: false, error: `statement_balances insert failed: ${ins.error.message}`, inserted: 0 };
    }
  }

  // ---- 4. Transactions with per-parse occurrence counting -----------------
  // legacy_source_table intentionally omitted — NULL is the correct value for
  // live intake (finrebuild_e1_statements_legacy_source_table_nullable).
  //
  // BATCHED, 2026-08-19. This used to insert one row per call, and each call
  // took long enough that a 51-transaction statement outlived the edge
  // function's wall clock: runs on AMEX 26-08 died at 21, then 31 rows, with
  // the queue row left claimed and the document half-written. One array insert
  // finishes in a single round trip. And because a killed run can now leave a
  // partial set behind for its reclaim to find, the batch is preceded by a
  // sweep of any rows this document already wrote — restart-safe: the reclaim
  // rewrites the full set instead of doubling the partial one.
  const refCounters = new Map<string, number>();

  const rows = opts.transactions.map((t) => {
    const amount = opts.account.accountKind === "credit" ? -t.signedAmount : t.signedAmount;
    const transactionType = opts.account.accountKind === "credit"
      ? (amount >= 0 ? "charge" : "payment_or_credit")
      : (amount >= 0 ? "deposit" : "withdrawal");
    const description = t.memo ? `${t.payee} — ${t.memo}` : t.payee;

    const payeeShort = t.payee.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 20);
    const amtCents = Math.round(Math.abs(amount) * 100);
    const fpBase = `dp:${opts.accountCode}:${t.date}:${amtCents}:${payeeShort}`;
    const occ = (refCounters.get(fpBase) ?? 0) + 1;
    refCounters.set(fpBase, occ);
    const withOcc = occ === 1 ? fpBase : `${fpBase}:${occ}`;

    return {
      id: crypto.randomUUID(),
      agency_id: opts.agencyId,
      business_entity_id: opts.account.businessEntityId,
      account_id: opts.account.id,
      account_kind: opts.account.accountKind,
      transaction_date: t.date,
      description,
      amount,
      transaction_type: transactionType,
      reference_number: withOcc,
      dedup_fingerprint: withOcc,
      source_document_id: opts.documentId,
    };
  });

  // The GL writer may already have posted the partial set to the ledger, and
  // ledger rows point at statements rows — so children go first, then parents.
  const { data: oldRows } = await sb.from("statements")
    .select("id")
    .eq("source_document_id", opts.documentId);
  if ((oldRows?.length ?? 0) > 0) {
    const oldIds = (oldRows ?? []).map((r: { id: string }) => r.id);
    const { error: lgErr } = await sb.from("ledger").delete().in("statement_id", oldIds);
    if (lgErr) {
      return { ok: false, error: `pre-insert ledger sweep failed: ${lgErr.message}`, inserted: 0 };
    }
  }
  const { error: delErr } = await sb.from("statements")
    .delete()
    .eq("source_document_id", opts.documentId);
  if (delErr) {
    return { ok: false, error: `pre-insert sweep failed: ${delErr.message}`, inserted: 0 };
  }

  const { error: batchErr } = await sb.from("statements").insert(rows);
  if (batchErr) {
    return {
      ok: false,
      error: `batched insert of ${rows.length} transactions failed: ${batchErr.message}`,
      inserted: 0,
    };
  }

  return { ok: true, inserted: rows.length };
}

// ==================== _shared/watchers.ts ====================
// =========================================================================
// _shared/watchers.ts
// =========================================================================
// Canonical "something needs a human" writer for ALL Newtworks edge
// functions. Replaces the retired _shared/alerts.ts.
//
// Why this exists: the alerts table was retired 2026-09-16 because nothing
// read it. A condition that genuinely needs Peter to act now becomes an
// ordinary row in tasks, so it gets scored, gets hours, and lands in a week
// like every other piece of work. Both helpers wrap the SQL functions
// ensure_watcher_task / close_watcher_task so the shaping lives in exactly
// one place, database side and edge side alike.
//
// Dedupe is on created_by ('watcher:' || source) plus related_id, open rows
// only. related_id must be a uuid or null. When the thing repeats per period
// and has no uuid of its own, PUT THE PERIOD IN THE SOURCE STRING
// (e.g. "wrapup_parser_stuck:2026-09-12") and leave relatedId null.
// =========================================================================


// tasks_priority_check allows exactly these four. "urgent" is NOT one of them.
type WatcherPriority = "low" | "medium" | "high" | "critical";

// tasks.task_category is a fixed check-constrained list. Anything outside it
// fails the insert.
type WatcherCategory =
  | "web_app"
  | "admin"
  | "marketing"
  | "team_development"
  | "handbook"
  | "processes"
  | "finances";

async function ensureWatcherTask(opts: {
  agencyId: string;
  source: string;
  relatedId?: string | null;
  title: string;
  description: string;
  priority?: WatcherPriority;
  category?: WatcherCategory;
}): Promise<{ ok: boolean; created: boolean; error: string | null }> {
  const { data, error } = await sb.rpc("ensure_watcher_task", {
    p_agency_id: opts.agencyId,
    p_source: opts.source,
    p_related_id: opts.relatedId ?? null,
    p_title: opts.title,
    p_description: opts.description,
    p_priority: opts.priority ?? "medium",
    p_category: opts.category ?? "admin",
  });
  if (error) {
    // Never throw — reporting a problem must not mask the problem being
    // reported. Surface the miss to whoever reads the function logs.
    console.error(`ensureWatcherTask failed (${opts.source}): ${error.message}`);
    return { ok: false, created: false, error: error.message };
  }
  return { ok: true, created: data === true, error: null };
}

async function closeWatcherTask(opts: {
  agencyId: string;
  source: string;
  relatedId?: string | null;
}): Promise<{ ok: boolean; closed: boolean; error: string | null }> {
  const { data, error } = await sb.rpc("close_watcher_task", {
    p_agency_id: opts.agencyId,
    p_source: opts.source,
    p_related_id: opts.relatedId ?? null,
  });
  if (error) {
    console.error(`closeWatcherTask failed (${opts.source}): ${error.message}`);
    return { ok: false, closed: false, error: error.message };
  }
  return { ok: true, closed: data === true, error: null };
}

// ==================== llm-queue-drainer/statement_reader.ts ====================
// =========================================================================
// llm-queue-drainer/statement_reader.ts
// =========================================================================
// THE statement reader's text handling, prompts and checks. Pure functions:
// no database, no network — so they can be run against real statement text
// before a deploy.
//
// Since 2026-09-26 every bank, card and investment statement is read here.
// document-processor no longer reads statements itself; it queues them, and
// llm-queue-drainer reads them with these helpers. Peter's ruling: the reader
// fixes what it can on its own — fine print trimmed, flipped signs corrected,
// health savings statements summarised — instead of a person hand-editing the
// queued text. Before this date each of those was fixed by hand in the queue.
//
// What lives here:
//   prepareStatementText      trim fine print so the statement fits one pass
//   BANK_STATEMENT_PROMPT_COMPACT / parseCompactStatement
//   reclassifyCreditsFromText card refunds misread as charges
//   resignFromTrailingMinus   deposit accounts whose withdrawals print "123.45-"
//   checkStatementPeriod      catches a "next closing date" read as the period
//   investment summary        health savings: money added, growth/loss, balance
// =========================================================================


type ReaderTxn = { date: string; payee: string; memo: string; amount: number };

// ---------------------------------------------------------------------------
// 1. TRIMMING
// ---------------------------------------------------------------------------

// Known issuer fine-print blocks, cut between two markers.
//
// AMEX 26-08 is 16,806 characters, of which roughly 8,700 are the same notices
// printed on every statement. None of it contains a transaction, and it was
// consuming about 2,175 tokens of a hard 8,000-token request budget on every
// call — budget the model then did not have left for its answer.
//
// SAFETY: a span is only cut when it holds almost no date-shaped text. Every
// transaction line carries a date, so a block with fewer than three of them
// cannot be hiding the detail.
const STATEMENT_BOILERPLATE_SPANS: { start: RegExp; end: RegExp }[] = [
  { start: /Late Payment Warning:/i, end: /Account Summary/i },
  { start: /Change of Address, phone number, email/i, end: /Payments and Credits Summary/i },
  // Capital One: ~8,900 chars of interest explanation and billing rights.
  { start: /How can I Avoid Paying Interest Charges/i, end: /Payments, Credits and Adjustments/i },
  // Chase: ~7,100 chars of payment/interest legalese before the activity table.
  { start: /You can pay down balances faster/i, end: /ACCOUNT ACTIVITY/i },
];

function trimKnownSpans(text: string): { text: string; removed: number } {
  const dateish = /\d{2}\/\d{2}\/\d{2}\b/g;
  let out = text;
  let removed = 0;
  for (const { start, end } of STATEMENT_BOILERPLATE_SPANS) {
    const s = start.exec(out);
    if (!s) continue;
    const rest = out.slice(s.index);
    const e = end.exec(rest);
    if (!e || e.index <= s[0].length) continue;
    const span = rest.slice(0, e.index);
    if (span.length < 300) continue;
    const dateHits = (span.match(dateish) ?? []).length;
    if (dateHits >= 3) continue;
    // Never cut the account summary. On Chase the "Late Payment Warning" to
    // "Account Summary" span holds "Previous Balance $6,739.41 ... Purchases",
    // so cutting it hid the opening balance from the model (Chase 26-09).
    if (/Previous Balance|Beginning Balance/i.test(span)) continue;
    out = out.slice(0, s.index) + " " + out.slice(s.index + span.length);
    removed += span.length;
  }
  return { text: out, removed };
}

// Generic fine-print trimmer, added 2026-09-26. Works on ANY issuer, including
// ones nobody has written a span for yet.
//
// Every figure the reader needs is a dollar amount or sits next to one or next
// to a date: transaction lines, the account summary, the period header. Legal
// notices are long runs of prose with neither. So: find every money amount and
// every date, and cut any stretch of 900+ characters that contains none,
// keeping 200 characters on each side so a heading next to an amount
// ("Other Withdrawals", "Payments and Credits") survives.
//
// By construction it never removes an amount or a date. Measured on the real
// September 2026 statements before shipping (all amounts preserved in every
// case): agency card 15,134 -> 8,035 chars (it had failed three times with an
// empty answer), personal checking 11,448 -> 3,676, AMEX 18,230 -> 10,805,
// Chase 11,948 -> 4,579, US Bank Income 11,541 -> 3,729.
const MONEY_TOKEN = /(?<![\d.,])\$?\s?\d{1,3}(?:,\d{3})*\.\d{2}-?(?![\d%])/g;
const DATE_TOKEN =
  /\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}\b/g;
const PROSE_MIN_GAP = 900;
const PROSE_KEEP = 200;

function trimLongProse(text: string): { text: string; removed: number } {
  const marks: [number, number][] = [];
  for (const re of [MONEY_TOKEN, DATE_TOKEN]) {
    for (const m of text.matchAll(re)) marks.push([m.index ?? 0, (m.index ?? 0) + m[0].length]);
  }
  marks.sort((a, b) => a[0] - b[0]);
  const cuts: [number, number][] = [];
  let prevEnd = 0;
  for (const [s, e] of [...marks, [text.length, text.length] as [number, number]]) {
    if (s - prevEnd >= PROSE_MIN_GAP) cuts.push([prevEnd + PROSE_KEEP, s - PROSE_KEEP]);
    prevEnd = Math.max(prevEnd, e);
  }
  let out = "";
  let cursor = 0;
  let removed = 0;
  for (const [a, b] of cuts) {
    out += text.slice(cursor, a) + " … ";
    removed += b - a;
    cursor = b;
  }
  out += text.slice(cursor);
  return { text: out, removed };
}

function prepareStatementText(raw: string): { text: string; removed: number } {
  const a = trimKnownSpans(raw);
  const b = trimLongProse(a.text);
  return { text: b.text, removed: a.removed + b.removed };
}

// ---------------------------------------------------------------------------
// 2. BANK AND CARD STATEMENTS — prompt and parser
// ---------------------------------------------------------------------------

const BANK_STATEMENT_PROMPT_COMPACT = `You are a parser for U.S. bank and credit card statements. You will be given the
text of one statement covering a single account. Long legal notices have been
cut out and replaced with "…".

Output PLAIN TEXT LINES ONLY. No JSON, no prose, no markdown, no code fences.
Emit exactly these line types, pipe-delimited, in this order:

PERIOD|<start YYYY-MM-DD>|<end YYYY-MM-DD>
  The period THIS statement covers. It is REQUIRED and is printed differently by
  each issuer: "Opening/Closing Date 07/23/26 - 08/22/26" (Chase), "Jul 29, 2026 -
  Aug 28, 2026" next to the card name (Capital One), a "Statement Period" line
  (US Bank), "Closing Date 09/14/26" with "Days in Billing Period: 31" (AMEX:
  the period starts the day after the previous closing, so 31 days back).
  NEVER use a "Next Closing Date" or a payment due date — those are in the
  future. The end of the period is on or just after the last transaction.
  A two-digit year is 20xx.
LAST4|<last 4 digits of the account, or NULL>
OPEN|<opening/beginning/previous balance as a number, or NULL>
  REQUIRED whenever the statement prints it. Chase and Capital One label it
  "Previous Balance", US Bank "Beginning Balance on <date>".
CLOSE|<closing/ending/new balance as a number, or NULL>
SUMCHARGES|<Account Summary total of new charges + fees + interest, or NULL>
SUMCREDITS|<Account Summary total of payments + credits, POSITIVE, or NULL>
TXN|<YYYY-MM-DD>|<KIND>|<payee>|<memo>|<amount>
...one TXN line per transaction...

KIND is exactly one letter classifying which part of the statement the line came
from. Decide this BEFORE you decide the sign:
  P = purchase / charge / fee / interest charged / withdrawal   -> amount NEGATIVE
  Y = payment made toward the account balance                  -> amount POSITIVE
  C = refund, credit, deposit, or interest paid to the account -> amount POSITIVE
  O = none of the above (use only if genuinely unclear)

SECTIONS ARE THE AUTHORITY ON KIND. Track which heading you are under
("Payments", "Credits", "New Charges", "Deposits", "Withdrawals", "Fees") and
take KIND from it, NEVER from the merchant name: an AMAZON.COM line under
"Credits" is C, while AMAZON.COM under "New Charges" is P.

Rules:
- Emit PERIOD, LAST4, OPEN, CLOSE, SUMCHARGES and SUMCREDITS exactly once each,
  before any TXN line.
- SUMCHARGES and SUMCREDITS come from the "Account Summary" block. Copy them as
  printed — never add them up from the transaction lines. Add every summary line
  that belongs on the same side:
    SUMCHARGES = "New Charges" + "Fees" + "Interest Charged" (AMEX, Chase), or
      "Transactions"/"Purchases" + "Cash Advances"/"Advances" + "Fees Charged" +
      "Interest Charged" (Capital One, US Bank cards), or "Other Withdrawals" +
      "Checks Paid" + "Card Withdrawals" (US Bank deposit accounts).
    SUMCREDITS = "Payments/Credits" (AMEX, Chase), or "Payments" + "Other
      Credits" (Capital One, US Bank cards), or "Deposits / Credits" (US Bank
      deposit accounts).
  Report both as POSITIVE numbers. Emit NULL only when there is no summary.
- Emit one TXN line for EVERY transaction line printed on the statement. Do not
  summarise, sample, or stop early. A dropped line breaks the books.
- Report a credit card's balance as a POSITIVE number (the amount owed).
- A per-cardmember subtotal ("Total for Account ...") is NOT a transaction.
- US Bank prints money OUT with a TRAILING minus ("$ 50.00-") and money IN with
  no sign. The printed minus is the authority, never the wording.
- A minus sign printed INSIDE a payments or credits section does not make the
  line a charge ("- $8.99" under Capital One credits is C, POSITIVE).
- date MUST be the TRANSACTION date, never the posting date.
- Skip beginning-balance, ending-balance and "Total" lines, and daily balance
  lists ("Balance Summary").
- Combine a multi-line description into one payee/memo pair. Append the bank's
  own notation ("CR", "AUTOPAY", "RETURNED PAYMENT") to memo.
- If memo would be empty, leave it empty: TXN|2026-07-04|P|COSTCO||-84.12
- Never put a "|" inside payee or memo.
- Repeated identical lines (same date, payee, amount) are separate transactions:
  emit one TXN line for EACH. Never merge them.
- ISO dates only. Amounts as bare numbers: no currency symbols, no thousands
  separators, no parentheses. Leading minus for money out.`;

type ParsedStatement = {
  statement_period: { start: string; end: string } | null;
  account_last4: string | null;
  opening_balance: number | null;
  closing_balance: number | null;
  declared_charges: number | null;
  declared_credits: number | null;
  transactions: ReaderTxn[];
};

function num(s: string): number | null {
  const t = (s ?? "").trim();
  if (!t || t.toUpperCase() === "NULL") return null;
  const v = Number(t.replace(/[$,]/g, ""));
  return Number.isFinite(v) ? v : null;
}

// Returns null when no transactions were recovered.
function parseCompactStatement(raw: string): ParsedStatement | null {
  let period: { start: string; end: string } | null = null;
  let last4: string | null = null;
  let open: number | null = null;
  let close: number | null = null;
  let declCharges: number | null = null;
  let declCredits: number | null = null;
  const txns: ReaderTxn[] = [];

  for (const line of stripFences(raw).split("\n")) {
    const t = line.trim();
    if (!t) continue;
    const parts = t.split("|");
    const tag = (parts[0] ?? "").trim().toUpperCase();

    if (tag === "PERIOD" && parts.length >= 3) {
      const s = parts[1].trim(), e = parts[2].trim();
      if (s && e && s.toUpperCase() !== "NULL" && e.toUpperCase() !== "NULL") period = { start: s, end: e };
    } else if (tag === "LAST4" && parts.length >= 2) {
      const v = parts[1].trim();
      last4 = (!v || v.toUpperCase() === "NULL") ? null : v;
    } else if (tag === "OPEN" && parts.length >= 2) {
      open = num(parts[1]);
    } else if (tag === "CLOSE" && parts.length >= 2) {
      close = num(parts[1]);
    } else if (tag === "SUMCHARGES" && parts.length >= 2) {
      const v = num(parts[1]);
      declCharges = v === null ? null : Math.abs(v);
    } else if (tag === "SUMCREDITS" && parts.length >= 2) {
      const v = num(parts[1]);
      declCredits = v === null ? null : Math.abs(v);
    } else if (tag === "TXN" && parts.length >= 6) {
      // amount is ALWAYS last and date ALWAYS first, so a stray "|" in the memo
      // folds back into the memo instead of shifting the amount.
      const date = parts[1].trim();
      const kind = (parts[2] ?? "").trim().toUpperCase().charAt(0);
      const rawAmt = num(parts[parts.length - 1]);
      const payee = parts[3].trim();
      const memo = parts.slice(4, parts.length - 1).join(" ").trim();
      if (!date || rawAmt === null || !payee) continue;
      // KIND is authoritative over the typed minus sign. "O" keeps the model's sign.
      const mag = Math.abs(rawAmt);
      let amount: number;
      if (kind === "P") amount = -mag;
      else if (kind === "Y" || kind === "C") amount = mag;
      else amount = rawAmt;
      txns.push({ date, payee, memo, amount });
    }
  }

  if (txns.length === 0) return null;
  return {
    statement_period: period,
    account_last4: last4,
    opening_balance: open,
    closing_balance: close,
    declared_charges: declCharges,
    declared_credits: declCredits,
    transactions: txns,
  };
}

// ---------------------------------------------------------------------------
// 3. SIGN REPAIRS — each is kept ONLY if the statement's own totals then tie
// ---------------------------------------------------------------------------

const MONTH_ABBR = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function amountPattern(amount: number): string {
  const [whole, cents] = Math.abs(amount).toFixed(2).split(".");
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",?")}\\.${cents}`;
}

// Card refunds misread as charges. A refund from a merchant you also buy from
// looks like a purchase by name; the statement's credits block knows better.
// Scans EVERY credits block (Capital One repeats the heading per cardmember).
function reclassifyCreditsFromText(statementText: string, txns: ReaderTxn[]): { flipped: number; txns: ReaderTxn[] } {
  const headingRe =
    /Payments,\s*Credits\s*and\s*Adjustments|Payments\s+and\s+Other\s+Credits|Credits\s+Amount|^[ \t]*Credits[ \t]*$/gim;
  const endRe =
    /Transactions\b|New Charges|Total New Charges|Fees\s+Amount|Fees Charged|Interest Charged|Cash Advances|Purchases\s+Amount/i;

  const spans: string[] = [];
  for (const m of statementText.matchAll(headingRe)) {
    const from = (m.index ?? 0) + m[0].length;
    const rest = statementText.slice(from, from + 4000);
    const e = endRe.exec(rest);
    spans.push(e ? rest.slice(0, e.index) : rest);
  }
  if (spans.length === 0) return { flipped: 0, txns };
  const span = spans.join("\n");

  let flipped = 0;
  const out = txns.map((t) => {
    if (t.amount >= 0) return t;
    const day = String(Number(t.date.slice(8, 10)));
    const mon = MONTH_ABBR[Number(t.date.slice(5, 7)) - 1];
    const dayPat = `(?:\\b0?${day}\\/|${mon}\\s+0?${day}\\b)`;
    const near = new RegExp(`${dayPat}[^|\\n]{0,140}?\\$?${amountPattern(t.amount)}`);
    if (near.test(span)) {
      flipped += 1;
      return { ...t, amount: Math.abs(t.amount) };
    }
    return t;
  });
  return { flipped, txns: out };
}

// Deposit accounts that print money OUT with a trailing minus ("1,000.00-").
// Added 2026-09-26 after US Bank Personal Checking 26-09 came out $2,231.66
// short: the PDF text put half the withdrawals after two pages of disclosures,
// away from their "Other Withdrawals" heading, and the model signed $5,596.42 of
// them as deposits. The printed trailing minus is the bank's own answer, so read
// it from the text: find each line by its date and amount, with no other date
// in between (so one line can never borrow the next line's sign), and take the
// sign printed right after the amount. A line whose matches disagree (the same
// date and amount printed both ways) is left alone.
// Tested before shipping on that statement with EVERY sign deliberately flipped:
// all 17 lines came back correct, including a $1,000.00 transfer in on Sep 16
// and a $1,000.00 Venmo payment out on Sep 17.
const ANY_DATE_PAT =
  "(?:\\b\\d{1,2}\\/\\d{1,2}\\b|\\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\.?\\s+\\d{1,2}\\b)";

function resignFromTrailingMinus(text: string, txns: ReaderTxn[]): { changed: number; unresolved: number; txns: ReaderTxn[] } {
  const trailing = (text.match(/\d\.\d{2}-(?!\d)/g) ?? []).length;
  if (trailing < 2) return { changed: 0, unresolved: txns.length, txns };
  let changed = 0;
  let unresolved = 0;
  const out = txns.map((t) => {
    const month = Number(t.date.slice(5, 7));
    const day = String(Number(t.date.slice(8, 10)));
    const mon = MONTH_ABBR[month - 1];
    if (!mon) { unresolved++; return t; }
    const dayPat = `(?:\\b0?${month}\\/0?${day}\\b|\\b${mon}[a-z]*\\.?\\s+0?${day}\\b)`;
    const re = new RegExp(
      `${dayPat}(?:(?!${ANY_DATE_PAT})[\\s\\S]){0,240}?(?<![\\d.,])\\$?\\s?${amountPattern(t.amount)}(-?)(?![\\d.])`,
      "g",
    );
    const signs = new Set<number>();
    for (const m of text.matchAll(re)) signs.add(m[1] === "-" ? -1 : 1);
    if (signs.size !== 1) { unresolved++; return t; }
    const amount = [...signs][0] * Math.abs(t.amount);
    if (amount !== t.amount) changed++;
    return { ...t, amount };
  });
  return { changed, unresolved, txns: out };
}

// Opening and closing balances read straight from the text, as a second
// opinion to the model's. Added 2026-09-26: on the original Chase 26-09 text the
// model returned no opening balance and took "Previous Balance $6,739.41" as the
// payments total, although the summary prints plainly "Previous Balance
// $6,739.41 ... New Balance $3,989.42". The caller only uses these figures when
// the transaction lines tie to them to the cent, so a wrong label match cannot
// get through.
const BAL_FIG = String.raw`(-?\$?\s?\d{1,3}(?:,\d{3})*\.\d{2}-?)`;

function balFigure(text: string, label: string): number | null {
  const m = new RegExp(`${label}\\s*[:=+]?\\s*${BAL_FIG}`, "i").exec(text);
  if (!m) return null;
  const t = m[1].trim();
  const neg = t.startsWith("-") || t.endsWith("-");
  const v = Number(t.replace(/[^\d.]/g, ""));
  return Number.isFinite(v) ? (neg ? -v : v) : null;
}

function balancesFromText(text: string): { open: number | null; close: number | null } {
  const onDate = String.raw`(?:\s+on\s+[A-Z][a-z]{2,8}\.?\s+\d{1,2}(?:,\s*\d{4})?)?`;
  return {
    open: balFigure(text, `(?:Previous Balance|Beginning Balance${onDate})`),
    close: balFigure(text, `(?:New Balance|Ending Balance${onDate})`),
  };
}

// ---------------------------------------------------------------------------
// 4. PERIOD CHECK
// ---------------------------------------------------------------------------

// AMEX Discretionary 26-09 was stored as Sep 14 - Oct 15 2026: the model took
// "Next Closing Date 10/15/26" as the end of the period. The balances tied, so
// nothing else noticed, and the account showed a statement from the future.
// A period that ends after today, starts after it ends, or ends well past the
// last transaction is refused so the item retries instead of writing bad dates.
//
// The "well past the last transaction" test is skipped when the end date that
// was read is printed on the statement as its closing/ending date: a quiet
// card month is real (US Bank SF Personal CC 26-10, 2026-10-09: "Closing Date:
// 10/07/2026", last charge 09/22, refused by Groq AND Claude reading the same
// thing). A "next closing date" misread is still caught by the future-date test.
function checkStatementPeriod(
  period: { start: string; end: string },
  txns: ReaderTxn[],
  todayIso: string,
  statementText?: string,
): string | null {
  const iso = /^\d{4}-\d{2}-\d{2}$/;
  if (!iso.test(period.start) || !iso.test(period.end)) return `period is not in YYYY-MM-DD form (${period.start} to ${period.end})`;
  if (period.start > period.end) return `period starts after it ends (${period.start} to ${period.end})`;
  if (period.end > todayIso) return `period ends in the future (${period.end}) — a "next closing date" was probably read as the period`;
  const dates = txns.map((t) => t.date).filter((d) => iso.test(d)).sort();
  if (dates.length) {
    const lastTxn = dates[dates.length - 1];
    const gapDays = (Date.parse(period.end) - Date.parse(lastTxn)) / 86400000;
    if (gapDays > 10 && !(statementText && endDatePrintedAsClosing(statementText, period.end))) return `period ends ${period.end}, ${Math.round(gapDays)} days after the last transaction (${lastTxn}) — period looks misread`;
  }
  return null;
}

// True when the statement prints this date right after a closing/ending label
// ("Closing Date: 10/07/2026", "Statement Period 09/09/2026 - 10/07/2026",
// "through 10/07/26"). Accepts MM/DD/YYYY and MM/DD/YY, with or without a
// leading zero.
function endDatePrintedAsClosing(text: string, endIso: string): boolean {
  const [y, m, d] = endIso.split("-");
  const mm = `0?${Number(m)}`, dd = `0?${Number(d)}`;
  const date = `${mm}/${dd}/(?:${y}|${y.slice(2)})\\b`;
  const label = String.raw`(?:closing\s+date|statement\s+(?:closing\s+)?date|ending\s+date|period\s+end(?:ing)?|statement\s+period|billing\s+period|through|thru)`;
  return new RegExp(`${label}[^\\n]{0,40}?${date}`, "i").test(text);
}

// ---------------------------------------------------------------------------
// 5. INVESTMENT ACCOUNTS (health savings) — summary only
// ---------------------------------------------------------------------------

// Peter's ruling 2026-09-26: a health savings statement is read for three
// things only — money added, growth or loss, and the current balance. The
// holdings, trades, dividend reinvestments and cash-flow tables are not read.
// The Fidelity report also bundles a second, unrelated brokerage account, so
// the reader looks only at the section for this account's number.
//
// Money taken out is read too, but only so the balance still ties: a
// withdrawal must never be booked as an investment loss.
const INVESTMENT_SUMMARY_PROMPT = `You read the account summary of ONE investment account (a health savings
account) from a brokerage statement. The statement may list several accounts;
use ONLY the account whose number ends in the digits given on the first line.

Use the figures for THIS PERIOD only, never Year-to-Date. Each summary line
prints two figures side by side: This Period first, then Year-to-Date.
A "-" printed in place of a number means 0: "Additions - 8,750.00" means
nothing was added this period (8,750.00 is the year so far).

Output exactly these six lines and nothing else, pipe-delimited:
PERIOD|<start YYYY-MM-DD>|<end YYYY-MM-DD>
OPEN|<Beginning Account Value for this period>
ADDED|<money added this period: Additions / Contributions / deposits, positive>
TAKEN|<money taken out this period: Subtractions / Distributions / withdrawals / fees, positive>
GROWTH|<Change in Investment Value this period, negative for a loss>
CLOSE|<Ending Account Value for this period>

Bare numbers only: no dollar signs, no commas.`;

// The account's own summary sits a few pages in. Hand the model a window that
// starts at this account's number and includes its summary, not the whole
// 29,000-character report.
function investmentWindow(text: string, last4: string | null): string {
  if (last4) {
    const re = new RegExp(`${last4}[^\\n]{0,160}?Account Summary`, "i");
    const m = re.exec(text);
    if (m) return text.slice(Math.max(0, (m.index ?? 0) - 400), (m.index ?? 0) + 2600);
  }
  return prepareStatementText(text).text.slice(0, 9000);
}

type InvestmentSummary = {
  period: { start: string; end: string } | null;
  open: number | null;
  added: number | null;
  taken: number | null;
  growth: number | null;
  close: number | null;
};

// Reads the summary straight from the text, no model call. Tried FIRST.
//
// Added 2026-09-26 after the first live test: the model took the Year-to-Date
// column for this month's additions (the report prints "Additions - 8,750.00",
// where "-" is THIS PERIOD and 8,750.00 is the year so far). The tie check
// refused it, correctly, but a statement laid out in two columns is better read
// by position: the first figure after each label is this period, and a lone "-"
// followed by a space means zero. Only the section for this account's number is
// searched, so the other account bundled in the report cannot be picked up.
// If anything is missing or the figures do not tie, the model is asked instead.
const INV_FIGURE = String.raw`(-(?=\s)|-?\$?\d[\d,]*\.\d{2}|\(\$?\d[\d,]*\.\d{2}\))`;

function invFigure(section: string, label: string): number | null {
  const m = new RegExp(`${label}\\s*\\*?\\s*${INV_FIGURE}`, "i").exec(section);
  if (!m) return null;
  const t = m[1];
  if (t === "-") return 0;
  const neg = t.startsWith("-") || t.startsWith("(");
  const v = Number(t.replace(/[()$,\-]/g, ""));
  return Number.isFinite(v) ? (neg ? -v : v) : null;
}

function investmentSummaryFromText(text: string, last4: string | null): InvestmentSummary {
  const out: InvestmentSummary = { period: null, open: null, added: null, taken: null, growth: null, close: null };
  const pm = /([A-Z][a-z]+ \d{1,2}, \d{4})\s*-\s*([A-Z][a-z]+ \d{1,2}, \d{4})/.exec(text);
  if (pm) {
    const toIso = (s: string) => {
      const d = new Date(`${s} 12:00:00 UTC`);
      return Number.isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10);
    };
    const s = toIso(pm[1]), e = toIso(pm[2]);
    if (s && e) out.period = { start: s, end: e };
  }
  if (!last4) return out;
  const anchor = new RegExp(`${last4}[^\\n]{0,160}?Account Summary`, "i").exec(text);
  if (!anchor) return out;
  const from = anchor.index ?? 0;
  const section = text.slice(from, from + 1500);
  out.open = invFigure(section, "Beginning Account Value");
  out.close = invFigure(section, "Ending Account Value");
  out.added = invFigure(section, "Additions") ?? 0;
  out.taken = invFigure(section, "Subtractions") ?? 0;
  out.growth = invFigure(section, "Change in Investment Value");
  return out;
}

function parseInvestmentSummary(raw: string): InvestmentSummary {
  const out: InvestmentSummary = { period: null, open: null, added: null, taken: null, growth: null, close: null };
  for (const line of stripFences(raw).split("\n")) {
    const parts = line.trim().split("|");
    const tag = (parts[0] ?? "").trim().toUpperCase();
    if (tag === "PERIOD" && parts.length >= 3) {
      const s = parts[1].trim(), e = parts[2].trim();
      if (s && e && s.toUpperCase() !== "NULL" && e.toUpperCase() !== "NULL") out.period = { start: s, end: e };
    } else if (tag === "OPEN") out.open = num(parts[1] ?? "");
    else if (tag === "ADDED") out.added = num(parts[1] ?? "");
    else if (tag === "TAKEN") out.taken = num(parts[1] ?? "");
    else if (tag === "GROWTH") out.growth = num(parts[1] ?? "");
    else if (tag === "CLOSE") out.close = num(parts[1] ?? "");
  }
  return out;
}

// Turns the summary into at most three statement lines dated at period end.
// Refuses (returns an error) unless opening + added - taken + growth = closing
// to the cent, so a misread figure can never reach the books.
function investmentSummaryToLines(
  s: InvestmentSummary,
  label: string,
): { ok: true; txns: ReaderTxn[]; note: string } | { ok: false; error: string } {
  if (!s.period) return { ok: false, error: "investment summary: no statement period" };
  if (s.open === null || s.close === null) return { ok: false, error: "investment summary: beginning or ending value missing" };
  const added = Math.abs(s.added ?? 0);
  const taken = Math.abs(s.taken ?? 0);
  const growth = s.growth ?? Math.round((s.close - s.open - added + taken) * 100) / 100;
  const gap = Math.round((s.open + added - taken + growth - s.close) * 100) / 100;
  if (Math.abs(gap) > 0.01) {
    return {
      ok: false,
      error: `investment summary does not tie: ${s.open} + ${added} added - ${taken} taken + ${growth} growth `
        + `= ${(s.open + added - taken + growth).toFixed(2)}, statement says ${s.close}`,
    };
  }
  const memo = `${label} ${s.period.start} to ${s.period.end}`;
  const txns: ReaderTxn[] = [];
  if (added > 0) txns.push({ date: s.period.end, payee: "Money added", memo, amount: added });
  if (taken > 0) txns.push({ date: s.period.end, payee: "Money taken out", memo, amount: -taken });
  if (Math.abs(growth) > 0.004) {
    txns.push({ date: s.period.end, payee: growth >= 0 ? "Investment growth" : "Investment loss", memo, amount: growth });
  }
  return {
    ok: true,
    txns,
    note: `investment summary ties: ${s.open} + ${added} added - ${taken} taken + ${growth} growth = ${s.close}`,
  };
}

// ==================== llm-queue-drainer/index.ts ====================
// llm-queue-drainer edge function
//
// Purpose: Drains pending items in public.llm_parse_queue that document-processor
// couldn't complete synchronously (transient Groq failures, JSON parse issues,
// max_tokens truncations, daily TPD exhaustion).
//
// Supported purposes:
//   - parse_bank_statement         → drainBankStatementItem  (statement_balances + statements)
//   - careerplug_applicant_extract → drainCareerplugItem     (hiring_candidates via upsert RPC)
//   - wrapup_organize              → drainWrapupOrganizeItem (weekly_cpr_team_detail.wrapup_text/_done via target_ref)
//
// Flow per item:
//   1. Call Groq direct with stored system_prompt + user_content
//   2. Parse JSON per purpose-specific shape
//   3. Purpose-specific write path
//   4. Mark queue item succeeded (or bump attempts on failure; 429 = don't burn)
//
// Bank, card and investment statements: since 2026-09-26 this is the ONLY
// statement reader. document-processor queues every statement rather than
// reading it, so the fine-print trimming, sign repairs, period check and the
// health-savings summary in ./statement_reader.ts apply to all of them.
//
// Invocation: POST { agency_id, shared_secret, [max_items=10, dry_run=false] }
//             POST { ..., dry_run: true, queue_ids: [...] } re-reads named rows
//             without writing anything (testing the reader on real statements).


// llama-3.3-70b-versatile (12,000 TPM) is decommissioned by Groq 2026-08-16.
// Moved to openai/gpt-oss-120b (8,000 TPM) 2026-08-08 — less throughput, but
// the only realistic account-tier model that survives the deadline; the
// account-wide plain-model TPM ceiling is 8,000 regardless of which model is
// picked (verified live against every candidate). Large statements that
// still exceed 8,000 tokens are a known, tracked gap (see finance-rebuild
// Groq-cap blocker) — never silently plugged or hand-entered.
const BANK_STATEMENT_MODEL = "openai/gpt-oss-120b";
// Careerplug items are small (~1-2K tokens) but gpt-oss-120b is often the daily-cap
// victim (200K TPD). Draining on a different model spreads TPD load so we can drain
// backlog even when gpt-oss-120b is exhausted. Was llama-3.3-70b-versatile
// (decommissioned 2026-08-16) — no other account-tier model beats gpt-oss-120b's
// TPD headroom for this purpose, so this constant is now the same model as the
// default; kept as a separate constant for the TPD-spreading intent, not because
// it currently differs.
const CAREERPLUG_MODEL = "openai/gpt-oss-120b";
// Wrap-up organize items are small (~1-3K tokens). They queue on Friday
// afternoons, which is precisely when the whole team sends wrap-ups within the
// same hour and gpt-oss-120b is most likely to be over quota -- so drain on a
// different model for the same TPD-spreading reason as careerplug. Was
// llama-3.3-70b-versatile (decommissioned 2026-08-16); same note as above.
const WRAPUP_MODEL = "openai/gpt-oss-120b";

// Purposes this drainer currently handles. Adding a new purpose = adding a
// handler function below AND appending its key here.
const SUPPORTED_PURPOSES = ["parse_bank_statement", "careerplug_applicant_extract", "wrapup_organize"];

// Every read goes through the shared readWithBackup(): Groq first (paced
// against the per-minute token cap, answer budget fitted by the one shared
// fitMaxTokens clamp), Claude only when Groq errors, cuts off or fails the
// check passed in. Both readers get the same instructions and the same text.
// Statement text handling, prompts, sign repairs and checks live in
// ./statement_reader.ts (pure functions, testable against real statements).
async function readItem(
  item: QueueItem,
  groqKey: string,
  model: string,
  systemPrompt: string,
  userContent: string,
  budget: { ceiling: number; floor: number; claude?: number },
  check: (raw: string) => string | null,
  reasoningEffort?: "none" | "low" | "medium" | "high",
): Promise<BackedReadResult> {
  const r = await readWithBackup({
    agencyId: item.agency_id,
    groqKey,
    model,
    systemPrompt,
    userContent,
    maxTokens: fitMaxTokens(systemPrompt, userContent, budget.ceiling, budget.floor),
    claudeMaxTokens: budget.claude ?? 8000,
    reasoningEffort,
    check,
    label: `purpose=${item.purpose} queue=${item.id}`,
  });
  if (r.reader === "claude" && r.ok) console.log(`[drainer] ${item.purpose} ${item.id} read by the Claude backup (Groq: ${r.groqProblem})`);
  return r;
}

// Answer must be JSON (fences stripped). Used by the small purposes.
function notJsonProblem(raw: string): string | null {
  try { JSON.parse(stripFences(raw)); return null; }
  catch (_e) { return `answer is not JSON: ${raw.slice(0, 160)}`; }
}

interface QueueItem {
  id: string;
  agency_id: string;
  document_id: string | null;
  purpose: string;
  system_prompt: string;
  user_content: string;
  model: string;
  attempts: number;
  target_ref: Record<string, any> | null;
}

interface DrainResult {
  ok: boolean;
  error?: string;
  // Optional purpose-specific fields:
  wrapupDone?: boolean;           // wrapup organize
  wrapupMissingItems?: string[];  // wrapup organize
  statementBalance?: any;         // bank statements
  transactionsInserted?: number;  // bank statements
  skippedInformational?: number;  // bank statements
  skippedDuplicates?: number;     // bank statements
  skippedUntyped?: number;        // bank statements (credit accounts only — R3)
  untypedLines?: string[];        // bank statements — raw_line text for skippedUntyped rows
  docId?: string | null;          // bank statements
  applicantsUpserted?: number;    // careerplug
  applicantActions?: any[];       // careerplug
  note?: string;
}

// Which reader runs depends on the account, so the account is resolved FIRST
// (moved ahead of the model call 2026-09-26; it used to be looked up after).
//   investment accounts (health savings) -> summary only: money added,
//                                           growth or loss, balance
//   bank and card accounts               -> every transaction line
// Every statement comes through here: since 2026-09-26 document-processor
// queues statements instead of reading them itself, so there is one reader.
async function drainBankStatementItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  if (!item.document_id) return { ok: false, error: "queue item has no document_id" };
  const { data: doc } = await sb
    .from("documents")
    .select("id, source_account_code, agency_id")
    .eq("id", item.document_id)
    .maybeSingle();
  if (!doc) return { ok: false, error: "document not found" };
  if (!doc.source_account_code) return { ok: false, error: "document.source_account_code missing" };

  const { data: coa } = await sb
    .from("chart_of_accounts")
    .select("id, account_type, business_entity_id, account_name")
    .eq("agency_id", doc.agency_id)
    .eq("account_code", doc.source_account_code)
    .maybeSingle();
  if (!coa) return { ok: false, error: `chart_of_accounts row not found for account_code=${doc.source_account_code}` };

  // accounts replaces the old bank_accounts/credit_accounts pair (finance
  // rebuild, 2026-08-07). account_kind is 'bank' | 'credit' | 'investment'.
  const { data: acct } = await sb
    .from("accounts")
    .select("id, business_entity_id, account_kind, account_number_last4, account_name, institution")
    .eq("agency_id", doc.agency_id)
    .eq("chart_account_id", coa.id)
    .maybeSingle();
  if (!acct) return { ok: false, error: `accounts row not found for chart_account_id=${coa.id} (account_code=${doc.source_account_code})` };

  const read = acct.account_kind === "investment"
    ? await readInvestmentStatement(item.user_content, acct.account_number_last4 ?? null,
        (acct.institution && !String(acct.account_name ?? "").includes(acct.institution)
          ? `${acct.institution} ${acct.account_name ?? ""}` : String(acct.account_name ?? "")).trim(), groqKey, item)
    : await readBankOrCardStatement(item.user_content, acct.account_kind, groqKey, item);
  if (!read.ok) return { ok: false, error: read.error };

  const { period, openingBalance, closingBalance, txns } = read;
  const controlNote = read.reader === "claude"
    ? `${read.controlNote}${read.controlNote ? " | " : ""}read by the Claude backup` : read.controlNote;
  // The account's own last four win over what the model read off the page
  // (a September test read 0353 as "5353").
  const accountLast4 = acct.account_number_last4 ?? read.accountLast4;
  const periodProblem = statementPeriodProblem(read, item.user_content);
  if (periodProblem) return { ok: false, error: periodProblem };

  if (dryRun) {
    return {
      ok: true,
      statementBalance: { period, openingBalance, closingBalance, accountLast4 },
      transactionsInserted: txns.length,
      docId: doc.id,
      note: controlNote || "control check: nothing to report",
    };
  }

  // Shared statement writer — duplicate-ingest guard, reconciliation guard,
  // statement_balances upsert and the occurrence-counted statements loop all
  // live in _shared/statement_writer.ts.
  //
  // Held outcomes are TERMINAL for the queue item: the writer has already
  // stamped the document (held_reconciliation_mismatch / duplicate_ingest)
  // and emitted the alert. Insert errors stay ok:false so the item retries.
  const cleanTxns = txns
    .filter((t) => t && typeof t.amount === "number" && t.date && String(t.payee ?? "").trim())
    .map((t) => ({ date: String(t.date), payee: String(t.payee).trim(), memo: String(t.memo ?? "").trim(), signedAmount: t.amount }));

  const w = await writeParsedStatement({
    agencyId: doc.agency_id,
    documentId: doc.id,
    accountCode: doc.source_account_code,
    account: {
      id: acct.id,
      businessEntityId: acct.business_entity_id,
      // Investment accounts are written as "bank": same sign rule (money in is
      // positive), it is how every earlier health savings month was stored, and
      // the statements table accepts only bank or credit (first live run of the
      // health savings summary was refused on exactly that, 2026-09-26).
      accountKind: acct.account_kind === "investment" ? "bank" : acct.account_kind,
    },
    accountLast4,
    period: { start: period.start, end: period.end },
    openingBalance,
    closingBalance,
    transactions: cleanTxns,
    source: "llm_queue_drainer",
  });

  if (!w.ok) {
    if (w.held === "reconciliation_mismatch") {
      return {
        ok: true,
        note: `held_reconciliation_mismatch: ${w.reason}${controlNote ? ` | ${controlNote}` : ""}`,
        transactionsInserted: 0,
        docId: doc.id,
      };
    }
    if (w.held === "duplicate_ingest") {
      return { ok: true, note: `duplicate_ingest: ${w.reason}`, transactionsInserted: 0, docId: doc.id };
    }
    return { ok: false, error: w.error, transactionsInserted: w.inserted, docId: doc.id };
  }

  await sb.from("documents").update({
    processing_status: "processed",
    processed_at: new Date().toISOString(),
    notes: `${w.inserted} statement rows via llm_queue_drainer; balance ${openingBalance}→${closingBalance}`,
    tables_updated: ["statement_balances", "statements"],
    records_created: w.inserted + 1,
  }).eq("id", doc.id);

  return {
    ok: true,
    statementBalance: { period, openingBalance, closingBalance, accountLast4 },
    transactionsInserted: w.inserted,
    docId: doc.id,
    note: controlNote || undefined,
  };
}

type StatementRead =
  | {
      ok: true;
      period: { start: string; end: string };
      openingBalance: number | null;
      closingBalance: number | null;
      accountLast4: string | null;
      txns: ReaderTxn[];
      controlNote: string;
      // Did the lines tie to the balances or summary totals? null: nothing to
      // tie against. A false read is still written (the writer holds it), but
      // it counts as a failed check, so the Claude backup gets a turn first.
      tied?: boolean | null;
      reader?: "groq" | "claude" | null;
    }
  | { ok: false; error: string };

// The one place the period check is called from, with the statement text so
// a closing date printed on the statement is believed.
function statementPeriodProblem(r: StatementRead, statementText: string): string | null {
  if (!r.ok) return r.error;
  return checkStatementPeriod(r.period, r.txns, new Date().toISOString().slice(0, 10), statementText);
}

// The safety check both readers' answers face: a read that failed, a period
// that looks misread, or lines that do not tie.
function statementReadProblem(r: StatementRead, statementText: string): string | null {
  if (!r.ok) return r.error;
  const periodProblem = statementPeriodProblem(r, statementText);
  if (periodProblem) return periodProblem;
  if (r.tied === false) return r.controlNote;
  return null;
}

// Pick the answer to use. Clean pass: that reader's read. Both failed: a read
// whose ONLY fault is lines not tying is still used, as before the backup
// existed (the writer holds it for review); Claude's first, then Groq's.
function settleStatementRead(
  backed: BackedReadResult, interpret: (raw: string) => StatementRead, statementText: string,
): StatementRead {
  if (backed.ok) return { ...interpret(backed.raw), reader: backed.reader } as StatementRead;
  for (const [raw, who] of [[backed.claudeRaw, "claude"], [backed.groqRaw, "groq"]] as const) {
    if (!raw) continue;
    const r = interpret(raw);
    if (r.ok && r.tied === false && !statementPeriodProblem(r, statementText)) {
      return { ...r, reader: who };
    }
  }
  return { ok: false, error: backed.error ?? "read failed" };
}

// Health savings and other investment accounts: summary only (Peter,
// 2026-09-26). Three figures and the balance, checked to the cent.
async function readInvestmentStatement(
  rawText: string, last4: string | null, label: string, groqKey: string, item: QueueItem,
): Promise<StatementRead> {
  // Read by position first; the model is only asked when that does not tie.
  const fromText = investmentSummaryFromText(rawText, last4);
  const textLines = investmentSummaryToLines(fromText, label || "Investment account");
  if (textLines.ok && fromText.period) {
    return {
      ok: true,
      period: fromText.period,
      openingBalance: fromText.open,
      closingBalance: fromText.close,
      accountLast4: last4,
      txns: textLines.txns,
      controlNote: `${textLines.note} (read from the statement text)`,
    };
  }
  const window = investmentWindow(rawText, last4);
  const userContent = `ACCOUNT NUMBER ENDS IN: ${last4 ?? "unknown"}\n\n${window}`;
  const interpret = (raw: string): StatementRead => {
    const s = parseInvestmentSummary(raw);
    const lines = investmentSummaryToLines(s, label || "Investment account");
    if (!lines.ok) return { ok: false, error: `${lines.error}. Answer head: ${raw.slice(0, 200)}` };
    return {
      ok: true,
      period: s.period!,
      openingBalance: s.open,
      closingBalance: s.close,
      accountLast4: last4,
      txns: lines.txns,
      controlNote: lines.note,
    };
  };
  const backed = await readItem(item, groqKey, BANK_STATEMENT_MODEL, INVESTMENT_SUMMARY_PROMPT, userContent,
    { ceiling: 1500, floor: 600, claude: 2000 }, (raw) => statementReadProblem(interpret(raw), rawText), "low");
  return settleStatementRead(backed, interpret, rawText);
}

// Bank and card statements: every transaction line, then the control checks.
//
// Why this path sends its OWN compact prompt instead of item.system_prompt,
// and why reasoning_effort is "low" (measured 2026-08-19 on AMEX 26-08):
// openai/gpt-oss-120b bills hidden thinking against max_tokens, so "medium"
// returned an EMPTY answer and a verbose prompt dropped lines. One compact line
// per transaction is ~17 tokens instead of ~90.
async function readBankOrCardStatement(
  rawText: string, accountKind: string, groqKey: string, item: QueueItem,
): Promise<StatementRead> {
  const prepared = prepareStatementText(rawText);
  const statementText = prepared.text;
  if (prepared.removed > 0) {
    console.log(`[drainer] trimmed ${prepared.removed} chars of fine print (${rawText.length} -> ${statementText.length})`);
  }
  // A cut-off answer counts as a failed read in readWithBackup itself.
  const interpret = (raw: string) => interpretBankAnswer(raw, rawText, statementText, prepared.removed, accountKind);
  const backed = await readItem(item, groqKey, BANK_STATEMENT_MODEL, BANK_STATEMENT_PROMPT_COMPACT, statementText,
    { ceiling: 6000, floor: 1200, claude: 12000 }, (raw) => statementReadProblem(interpret(raw), rawText), "low");
  return settleStatementRead(backed, interpret, rawText);
}

// One answer (from either reader) turned into a statement read, with the
// control checks. Pure: no calls out, so both readers' answers face the same
// checks and an answer can be re-interpreted for free.
function interpretBankAnswer(
  raw: string, rawText: string, statementText: string, removed: number, accountKind: string,
): StatementRead {
  const json = parseCompactStatement(raw);
  if (!json) return { ok: false, error: `compact parse produced no transactions. Head: ${raw.slice(0, 200)}` };

  // CONTROL CHECK. Two independent checks on the lines the model read:
  //   balances  opening + lines = closing, to the cent. Opening and closing
  //             come from the model AND, as a second opinion, straight from the
  //             statement text (balancesFromText); a pair is used only if the
  //             lines tie to it exactly.
  //   totals    the Account Summary totals of charges and of payments/credits.
  // A tie on balances is what the statement writer requires, so it decides.
  // When nothing ties, the text-driven sign repairs are tried one at a time and
  // a repair is kept ONLY if the lines then tie (balances, or failing those the
  // totals). Otherwise the parse goes on unchanged and the writer holds it — a
  // partial guess on money is worse than a clean stop.
  //   repair 1  card refunds misread as charges (the statement's credits blocks)
  //   repair 2  deposit-account withdrawals misread as deposits (trailing minus)
  let controlNote = "";
  let tied: boolean | null = null;
  let openingBalance: number | null = typeof json.opening_balance === "number" ? json.opening_balance : null;
  let closingBalance: number | null = typeof json.closing_balance === "number" ? json.closing_balance : null;
  {
    const sumOf = (ts: ReaderTxn[]) => ({
      charges: ts.filter((t) => t.amount < 0).reduce((a, t) => a + Math.abs(t.amount), 0),
      credits: ts.filter((t) => t.amount > 0).reduce((a, t) => a + t.amount, 0),
    });
    // Card balances are amounts owed: money in lowers them. Deposit and
    // investment balances rise with money in.
    const dir = accountKind === "credit" ? -1 : 1;
    // Read from the untrimmed text, so no trimming can hide the summary.
    const fromText = balancesFromText(rawText);
    const pairs: { open: number; close: number; label: string }[] = [];
    const addPair = (o: number | null, c: number | null, label: string) => {
      if (typeof o === "number" && typeof c === "number" && !pairs.some((p) => p.open === o && p.close === c)) {
        pairs.push({ open: o, close: c, label });
      }
    };
    addPair(openingBalance, closingBalance, "the balances the model read");
    addPair(openingBalance ?? fromText.open, closingBalance ?? fromText.close, "the balances, gaps filled from the statement text");
    addPair(fromText.open, fromText.close, "the balances printed in the statement text");
    const tiedPair = (ts: ReaderTxn[]) => {
      const net = ts.reduce((a, t) => a + t.amount, 0);
      return pairs.find((p) => Math.abs(p.open + dir * net - p.close) <= 0.01) ?? null;
    };
    const haveDeclared = json.declared_charges !== null || json.declared_credits !== null;
    const offDeclared = (ts: ReaderTxn[]) => {
      const s = sumOf(ts);
      return Math.round((Math.abs(s.charges - (json.declared_charges ?? s.charges))
        + Math.abs(s.credits - (json.declared_credits ?? s.credits))) * 100) / 100;
    };
    const ties = (ts: ReaderTxn[]) => pairs.length > 0 ? tiedPair(ts) !== null : (haveDeclared && offDeclared(ts) <= 0.01);

    const before = sumOf(json.transactions);
    console.log(`[drainer] control inputs: declared_charges=${json.declared_charges ?? "n/a"} `
      + `declared_credits=${json.declared_credits ?? "n/a"} parsed_charges=${before.charges.toFixed(2)} `
      + `parsed_credits=${before.credits.toFixed(2)} model_open=${openingBalance ?? "n/a"} model_close=${closingBalance ?? "n/a"} `
      + `text_open=${fromText.open ?? "n/a"} text_close=${fromText.close ?? "n/a"}`);

    if (pairs.length === 0 && !haveDeclared) {
      controlNote = "no balances or summary totals could be read, so nothing to check against";
    } else if (ties(json.transactions)) {
      tied = true;
      const p = tiedPair(json.transactions);
      controlNote = p
        ? `lines tie to ${p.label}: ${p.open} -> ${p.close}`
        : `lines tie to the Account Summary totals: charges ${before.charges.toFixed(2)}, credits ${before.credits.toFixed(2)}`;
    } else {
      const repairs: { name: string; run: () => { count: number; txns: ReaderTxn[] } }[] = [
        {
          name: "refunds misread as charges, fixed from the statement's credits block(s)",
          run: () => { const r = reclassifyCreditsFromText(statementText, json.transactions); return { count: r.flipped, txns: r.txns }; },
        },
        {
          name: "money in/out misread, fixed from the trailing minus the bank prints on withdrawals",
          run: () => { const r = resignFromTrailingMinus(statementText, json.transactions); return { count: r.changed, txns: r.txns }; },
        },
      ];
      const tried: string[] = [];
      let fixed = false;
      for (const rep of repairs) {
        const r = rep.run();
        tried.push(`${r.count} line(s) changed`);
        if (r.count > 0 && ties(r.txns)) {
          json.transactions = r.txns;
          const p = tiedPair(r.txns);
          controlNote = `repaired ${r.count} line(s): ${rep.name}; lines now tie to `
            + (p ? `${p.label}: ${p.open} -> ${p.close}` : "the Account Summary totals");
          fixed = true;
          tied = true;
          break;
        }
      }
      if (!fixed) {
        tied = false;
        controlNote = `lines DO NOT tie: parsed charges ${before.charges.toFixed(2)} vs declared `
          + `${json.declared_charges ?? "n/a"}, parsed credits ${before.credits.toFixed(2)} vs declared `
          + `${json.declared_credits ?? "n/a"}, balances tried ${pairs.map((p) => `${p.open}->${p.close}`).join(", ") || "none"}. `
          + `Repairs tried: ${tried.join("; ")} — none applied.`;
      }
    }
    // Whichever balance pair the lines tie to is the one written.
    const p = tiedPair(json.transactions);
    if (p) { openingBalance = p.open; closingBalance = p.close; }
    console.log(`[drainer] ${controlNote}`);
  }

  const period = json.statement_period;
  if (!period?.start || !period?.end) return { ok: false, error: "missing statement period in the answer" };
  return {
    ok: true,
    period,
    openingBalance,
    closingBalance,
    accountLast4: json.account_last4 ?? null,
    txns: json.transactions,
    tied,
    controlNote: removed > 0
      ? `${controlNote}${controlNote ? " | " : ""}fine print trimmed: ${rawText.length} -> ${statementText.length} chars`
      : controlNote,
  };
}

// -------------------------------------------------------------------------
// CareerPlug applicant drainer
// -------------------------------------------------------------------------
// Mirrors what processCareerplugMessage() does after a successful Groq call:
// parse applicants[] out of the JSON and call upsert_candidate_from_careerplug
// per applicant. Skips the resume-PDF path (queue items don't carry attachments);
// the RPC's email-based dedup layer will merge in resume data if the same
// applicant arrives cleanly later.
//
// Uses CAREERPLUG_MODEL (openai/gpt-oss-120b) instead of the queued
// model (usually gpt-oss-120b) to spread TPD load — gpt-oss-120b is the model
// that hits 200K TPD daily and drops these to the queue in the first place,
// so retrying on the same model recreates the problem.
async function drainCareerplugItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  // 1. Call Groq. Careerplug messages are small; 1500 max_tokens covers the
  // biggest daily digest we've observed.
  const llm = await readItem(item, groqKey, CAREERPLUG_MODEL, item.system_prompt, item.user_content,
    { ceiling: 1500, floor: 600, claude: 4000 }, notJsonProblem);
  if (!llm.ok) return { ok: false, error: llm.error ?? "read failed" };

  // 2. Parse JSON. Expect { "applicants": [ {...}, ... ] }
  let json: any;
  try { json = JSON.parse(stripFences(llm.raw)); }
  catch (e) { return { ok: false, error: `JSON parse failed: ${e}. Head: ${llm.raw.slice(0, 200)}` }; }

  const applicants: any[] = Array.isArray(json?.applicants) ? json.applicants : [];
  if (applicants.length === 0) {
    // LLM decided this isn't an applicant notification. Treat as success — no
    // work to do, don't need to retry.
    return { ok: true, applicantsUpserted: 0, applicantActions: [], note: "LLM returned zero applicants" };
  }

  // 3. Reconstruct source-message metadata from the user_content header lines
  // (parseWithLLM stores exactly what processCareerplugMessage passed in).
  const subject = item.user_content.match(/^SUBJECT:\s*(.+)$/m)?.[1]?.trim() ?? "";
  const fromEmail = item.user_content.match(/^FROM:\s*(.+)$/m)?.[1]?.trim() ?? "";
  const receivedAtISO = item.user_content.match(/^RECEIVED_AT \(ISO\):\s*(.+)$/m)?.[1]?.trim() ?? "";

  if (dryRun) {
    return { ok: true, applicantsUpserted: applicants.length, applicantActions: [], note: "dry_run" };
  }

  // 4. Upsert each applicant via the same RPC processCareerplugMessage uses.
  // Idempotency: RPC dedups by ingestion_metadata.source_message.gmail_message_id
  // first (we don't have that; queue doesn't preserve it), then falls back to
  // lower(email). So a same-email applicant already ingested via any path gets
  // matched and updated instead of duplicated.
  const actions: any[] = [];
  let upserted = 0;
  for (let idx = 0; idx < applicants.length; idx++) {
    const a = applicants[idx];
    const payload: Record<string, unknown> = {
      first_name: a.first_name ?? null,
      last_name:  a.last_name ?? null,
      email:      a.email ?? null,
      phone:      a.phone ?? null,
      position:   a.position ?? null,
      applied_at: a.applied_at ?? (receivedAtISO || new Date().toISOString()),
      resume_url: a.resume_url ?? null,
      resume_document_id: null,  // drainer path has no Gmail attachment access
      gmail_message_id: null,    // not preserved in llm_parse_queue schema
      careerplug_metadata: {
        prescreen_score: a.prescreen_score,
        is_fast_track:   a.is_fast_track,
        source_platform: a.source_platform,
        careerplug_applicant_id: a.careerplug_applicant_id,
        raw_line: a.raw_line,
        gmail_source_message_id: null,
        gmail_from: fromEmail,
        gmail_subject: subject,
        drained_from_queue: true,
        drainer_queue_id: item.id,
        drainer_drained_at: new Date().toISOString(),
      },
    };

    const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
      p_agency_id: item.agency_id,
      p_payload:   payload,
    });
    if (rpcErr) {
      actions.push({
        email: a.email,
        name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
        action: `rpc_error: ${rpcErr.message}`,
      });
      continue;
    }
    const res = (rpcData ?? {}) as { assessment_id?: string; action?: string };
    actions.push({
      email: a.email,
      name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
      action: res.action ?? "unknown",
      assessment_id: res.assessment_id,
    });
    if (res.action === "inserted" || res.action === "updated_by_email") upserted++;
  }

  return { ok: true, applicantsUpserted: upserted, applicantActions: actions };
}

// ── wrapup_organize ──────────────────────────────────────────────────────────
// Finishes a team wrap-up organize job that document-processor could not
// complete synchronously (almost always Groq over quota on a Friday afternoon).
//
// Requires target_ref.detail_id -- the weekly_cpr_team_detail row the organized
// text belongs to. Jobs queued before target_ref shipped (2026-08-07) have no
// pointer and cannot be completed here; they fail with a clear message rather
// than guessing at a row.
//
// STALENESS GUARD: the queued user_content embeds a <CURRENT_WRAPUP_TEXT>
// snapshot taken when the job was enqueued. If a LATER email for the same
// teammate/week was organized successfully in the meantime, the live row now
// holds strictly more content than this job's snapshot, and writing this job's
// output would DELETE that newer content. When live text and snapshot disagree,
// this handler refuses the write and raises an alert for a manual merge instead.
// Losing a teammate's words silently is worse than a visible stuck job.
//
// NOT DONE HERE: the missing-item nag email. Nagging needs Composio + the team
// roster and lives in document-processor's wrapup parser. A drained job that
// comes back incomplete records wrapup_done=false and the missing labels; the
// Friday 7 PM no-send check is what surfaces the gap to the team.
function wupExtractSnapshotFromUserContent(userContent: string): string | null {
  const m = userContent.match(/<CURRENT_WRAPUP_TEXT>\n([\s\S]*?)\n<\/CURRENT_WRAPUP_TEXT>/);
  if (!m) return null;
  const raw = m[1];
  return raw === "(none yet)" ? "" : raw;
}

// Safety check on one wrap-up answer, shared by the Claude backup and the guard below.
function wrapupAnswerProblem(raw: string): string | null {
  const notJson = notJsonProblem(raw);
  if (notJson) return notJson;
  const t = JSON.parse(stripFences(raw))?.organized_text;
  return typeof t === "string" && t.trim() ? null : "LLM returned empty organized_text";
}

async function drainWrapupOrganizeItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  const detailId = item.target_ref?.detail_id as string | undefined;
  if (!detailId) {
    return { ok: false, error: "target_ref.detail_id missing — job predates target_ref (2026-08-07) or was enqueued without a write target; cannot resolve which weekly_cpr_team_detail row to write" };
  }

  const llm = await readItem(item, groqKey, WRAPUP_MODEL, item.system_prompt, item.user_content,
    { ceiling: 2500, floor: 800, claude: 4000 }, wrapupAnswerProblem);
  if (!llm.ok) return { ok: false, error: llm.error ?? "read failed" };

  let parsed: any;
  try {
    parsed = JSON.parse(stripFences(llm.raw));
  } catch (e) {
    return { ok: false, error: `JSON parse failed: ${e instanceof Error ? e.message : String(e)}` };
  }

  const organizedText: string = typeof parsed?.organized_text === "string" ? parsed.organized_text : "";
  const emptyProblem = wrapupAnswerProblem(llm.raw);
  if (emptyProblem) return { ok: false, error: emptyProblem };
  const coverage = parsed?.coverage ?? {};
  const allCovered =
    coverage.item_1 === true && coverage.item_2 === true && coverage.item_3 === true &&
    coverage.item_4 === true && coverage.item_5 === true && coverage.item_6 === true;
  const missingLabels: string[] = Array.isArray(parsed?.missing_item_labels) ? parsed.missing_item_labels : [];

  if (dryRun) {
    return { ok: true, wrapupDone: allCovered, wrapupMissingItems: missingLabels, note: `dry run — would write ${organizedText.length} chars to weekly_cpr_team_detail ${detailId}` };
  }

  const { data: liveRow, error: liveErr } = await sb
    .from("weekly_cpr_team_detail")
    .select("id, wrapup_text")
    .eq("id", detailId)
    .maybeSingle();
  if (liveErr) return { ok: false, error: `detail read failed: ${liveErr.message}` };
  if (!liveRow) return { ok: false, error: `weekly_cpr_team_detail ${detailId} no longer exists` };

  const snapshot = wupExtractSnapshotFromUserContent(item.user_content);
  const liveText = (liveRow.wrapup_text ?? "") as string;
  if (liveText.trim() && snapshot !== null && liveText.trim() !== snapshot.trim()) {
    if ((item.attempts ?? 0) === 0) {
      await ensureWatcherTask({
        agencyId: item.agency_id,
        source: `wrapup_stale:${item.id}`,
        relatedId: null,
        title: "Queued wrap-up needs a manual merge",
        description: `Queued wrap-up job ${item.id} (${item.target_ref?.sender_first_name ?? "unknown teammate"}, week ${item.target_ref?.week_ending_date ?? "unknown"}) was organized against an older copy of the wrap-up text. The stored text has changed since, so writing this result would delete newer content. Merge by hand from Gmail message ${item.target_ref?.gmail_message_id ?? "unknown"}.`,
        priority: "medium",
        category: "processes",
      });
    }
    return { ok: false, error: "detail row advanced since this job was queued — refusing to overwrite newer wrap-up text; manual merge required (alert raised)" };
  }

  const { error: updErr } = await sb
    .from("weekly_cpr_team_detail")
    .update({ wrapup_text: organizedText, wrapup_done: allCovered, updated_at: new Date().toISOString() })
    .eq("id", detailId);
  if (updErr) return { ok: false, error: `detail update failed: ${updErr.message}` };

  return {
    ok: true,
    wrapupDone: allCovered,
    wrapupMissingItems: missingLabels,
    note: `wrote ${organizedText.length} chars to weekly_cpr_team_detail ${detailId}${allCovered ? "" : ` — ${missingLabels.length} item(s) still missing, no nag sent from the drainer`}`,
  };
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);

  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  const groqKey = await getSettingOrNull(agencyId, "groq_api_key");
  if (!groqKey) return jsonResponse({ ok: false, error: "groq_api_key not set" }, 400);

  const maxItems = Math.min(Math.max(parseInt(body?.max_items ?? "10", 10) || 10, 1), 50);
  const dryRun = body?.dry_run === true;

  // DRY-RUN BY ID (added 2026-09-26): re-read specific queue rows, whatever
  // their status, and report what the reader WOULD write — nothing is written
  // and nothing is claimed. Used to test the reader on real statements before
  // trusting a change. Refused without dry_run, so it can never bypass the
  // claim that stops two runs from writing the same statement.
  const queueIds: string[] = Array.isArray(body?.queue_ids) ? body.queue_ids.map(String).slice(0, 10) : [];
  if (queueIds.length > 0) {
    if (!dryRun) return jsonResponse({ ok: false, error: "queue_ids is only allowed with dry_run: true" }, 400);
    const { data: picked, error: pErr } = await sb
      .from("llm_parse_queue")
      .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts, target_ref")
      .eq("agency_id", agencyId)
      .in("id", queueIds)
      .in("purpose", SUPPORTED_PURPOSES);
    if (pErr) return jsonResponse({ ok: false, error: `queue read failed: ${pErr.message}` }, 500);
    const results: any[] = [];
    for (const item of (picked ?? []) as QueueItem[]) {
      const r = item.purpose === "parse_bank_statement"
        ? await drainBankStatementItem(item, groqKey, true)
        : item.purpose === "careerplug_applicant_extract"
          ? await drainCareerplugItem(item, groqKey, true)
          : await drainWrapupOrganizeItem(item, groqKey, true);
      results.push({ queue_id: item.id, ok: r.ok, error: r.error, note: r.note,
        statement_balance: r.statementBalance, transactions: r.transactionsInserted });
    }
    return jsonResponse({ ok: true, dry_run: true, by_id: true, items: results });
  }

  // Pull pending items for any supported purpose. Order by created_at so
  // oldest backlog drains first (fair-queue behavior across purposes).
  const { data: items, error: qErr } = await sb
    .from("llm_parse_queue")
    .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts, target_ref")
    .eq("agency_id", agencyId)
    .eq("status", "pending")
    .in("purpose", SUPPORTED_PURPOSES)
    .lt("attempts", 3)
    .order("created_at", { ascending: true })
    .limit(maxItems);

  if (qErr) return jsonResponse({ ok: false, error: `queue read failed: ${qErr.message}` }, 500);

  // Rows stuck in "processing" belong to a run that died without finishing
  // (crash, platform kill). Offer them back after a generous timeout — a live
  // statement run takes 2-3 minutes, so 10 is safely past any honest run.
  const STALE_PROCESSING_MINUTES = 10;
  const staleCutoff = new Date(Date.now() - STALE_PROCESSING_MINUTES * 60 * 1000).toISOString();
  const { data: staleItems } = await sb
    .from("llm_parse_queue")
    .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts, target_ref")
    .eq("agency_id", agencyId)
    .eq("status", "processing")
    .lt("last_attempt_at", staleCutoff)
    .in("purpose", SUPPORTED_PURPOSES)
    .lt("attempts", 3)
    .order("created_at", { ascending: true })
    .limit(maxItems);

  const pool = [...(items ?? []), ...(staleItems ?? [])];
  if (pool.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "no pending items" });
  }

  // ATOMIC CLAIM — added 2026-08-19 after the duplicate storm.
  //
  // A row used to stay "pending" the whole time it was being worked, so every
  // overlapping invocation — the 2-minute cron, a manual dispatch, or simply a
  // run that outlives one cron interval — claimed the SAME row and processed it
  // again. On AMEX 26-08 that wrote 66 statements rows in four minutes
  // (05:48–05:52) and the GL writer posted 63 of them to the ledger before it
  // was caught; every row had to be hand-deleted.
  //
  // Each row is now taken with one conditional update: pending -> processing.
  // Whoever flips it first owns it; every other run matches zero rows and moves
  // on. Dry runs never claim, so they cannot strand a row in "processing".
  const claimed: QueueItem[] = [];
  if (dryRun) {
    claimed.push(...(pool as QueueItem[]));
  } else {
    for (const cand of pool as QueueItem[]) {
      const fromStale = (staleItems ?? []).some((s) => s.id === cand.id);
      let claimQ = sb
        .from("llm_parse_queue")
        .update({ status: "processing", last_attempt_at: new Date().toISOString() })
        .eq("id", cand.id);
      claimQ = fromStale
        ? claimQ.eq("status", "processing").lt("last_attempt_at", staleCutoff)
        : claimQ.eq("status", "pending");
      const { data: got } = await claimQ.select("id");
      if ((got?.length ?? 0) === 1) claimed.push(cand);
    }
  }
  if (claimed.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "all candidates claimed by another run" });
  }

  const results: any[] = [];
  let totalTxns = 0;
  let totalApplicants = 0;
  let successes = 0;
  let failures = 0;
  let byPurpose: Record<string, { drained: number; ok: number; err: number }> = {};

  for (const item of claimed) {
    const purposeStats = byPurpose[item.purpose] ??= { drained: 0, ok: 0, err: 0 };
    purposeStats.drained += 1;

    let r: DrainResult;
    if (item.purpose === "parse_bank_statement") {
      r = await drainBankStatementItem(item, groqKey, dryRun);
    } else if (item.purpose === "careerplug_applicant_extract") {
      r = await drainCareerplugItem(item, groqKey, dryRun);
    } else if (item.purpose === "wrapup_organize") {
      r = await drainWrapupOrganizeItem(item, groqKey, dryRun);
    } else {
      // Shouldn't happen — SUPPORTED_PURPOSES filter guards this. Skip defensively.
      r = { ok: false, error: `unsupported purpose: ${item.purpose}` };
    }

    if (!dryRun) {
      // Bump attempts + record result. Rate limit (429) = transient, don't count as an attempt.
      const isRateLimit = !r.ok && /Groq HTTP 429/.test(r.error ?? "");
      // 413 and 429 look alike and need OPPOSITE responses. A 429 is "you are
      // going too fast" — wait and the identical payload succeeds. A 413 is
      // "this one request is too big" — it will fail identically forever, so
      // waiting is not a strategy and neither is retrying. Fail it on the first
      // attempt so the alert lands now instead of two cron ticks later. John
      // Kostov's 2026-08-28 wrap-up burned all three attempts on the same 413
      // and nobody heard about it until Peter noticed the CPR row was empty.
      const isTooLarge = !r.ok && /Groq HTTP 413/.test(r.error ?? "");
      if (r.ok) {
        await sb.from("llm_parse_queue").update({
          status: "succeeded",
          attempts: (item.attempts ?? 0) + 1,
          last_attempt_at: new Date().toISOString(),
          completed_at: new Date().toISOString(),
          result_raw: null,
          last_error: r.error ?? null,
        }).eq("id", item.id);
      } else if (isRateLimit) {
        // Transient rate limit — don't burn the attempts counter; cron will retry.
        await sb.from("llm_parse_queue").update({
          status: "pending",
          last_attempt_at: new Date().toISOString(),
          last_error: r.error ?? "rate limited",
        }).eq("id", item.id);
      } else {
        const newAttempts = isTooLarge ? 3 : (item.attempts ?? 0) + 1;
        const nowDead = newAttempts >= 3;
        await sb.from("llm_parse_queue").update({
          status: nowDead ? "failed" : "pending",
          attempts: newAttempts,
          last_attempt_at: new Date().toISOString(),
          last_error: r.error ?? "unknown",
        }).eq("id", item.id);

        // An item that exhausts its attempts is DEAD: nothing retries it, because
        // the claim query only reads status="pending". Until 2026-08-19 that
        // happened in total silence — this runner keeps reporting success (the
        // RUNNER worked; the ITEM failed), so no automation_failure alert ever
        // fired. AMEX Discretionary 26-08 went dead five minutes after arriving
        // and was only noticed two days later because the email was still sitting
        // unread in the inbox. Never rely on that again.
        if (nowDead) {
          let label = item.purpose;
          if (item.document_id) {
            const { data: deadDoc } = await sb
              .from("documents")
              .select("file_name")
              .eq("id", item.document_id)
              .maybeSingle();
            if (deadDoc?.file_name) label = deadDoc.file_name;
          }
          // The QUEUE item is dead, but until 2026-09-02 the DOCUMENT row went on
          // saying "queued_for_llm" forever, so the Documents view showed a statement
          // as still in progress days after nothing was ever going to touch it again.
          // Capital One 26-08 and Chase CC 26-08 both sat that way for two days. The
          // alert above fires either way; this is about the record Peter actually reads.
          if (item.document_id) {
            await sb.from("documents").update({
              processing_status: "error",
              notes: JSON.stringify({
                failed: "llm_parse",
                queue_item: item.id,
                purpose: item.purpose,
                error: r.error ?? "unknown",
                failed_at: new Date().toISOString(),
              }),
            }).eq("id", item.document_id);
          }
          await ensureWatcherTask({
            agencyId: item.agency_id,
            source: `llm_parse_item_dead:${item.id}`,
            title: isTooLarge
              ? `Parse payload too big, not retryable: ${label}`
              : `Parse gave up after 3 tries: ${label}`,
            description: isTooLarge
              ? `Queue item ${item.id} (${item.purpose}) was rejected for exceeding the model's `
                + `per-request token ceiling. Retrying cannot help — the same payload fails the same `
                + `way every time. The text needs to be trimmed at the source before it is queued. `
                + `Nothing downstream of it has been written. Error: ${r.error ?? "unknown"}`
              : `Queue item ${item.id} (${item.purpose}) failed 3 attempts and will not be retried `
                + `automatically. Nothing downstream of it has been written. Last error: ${r.error ?? "unknown"}`,
            priority: "medium",
            category: item.purpose === "parse_bank_statement" ? "finances" : "admin",
            relatedId: item.document_id ?? null,
          });
        }
      }
    }

    if (r.ok) {
      successes += 1;
      purposeStats.ok += 1;
      totalTxns += r.transactionsInserted ?? 0;
      totalApplicants += r.applicantsUpserted ?? 0;
    } else {
      failures += 1;
      purposeStats.err += 1;
    }

    results.push({
      queue_id: item.id,
      purpose: item.purpose,
      document_id: item.document_id,
      ok: r.ok,
      // Bank statement fields (undefined for careerplug):
      transactions_inserted: r.transactionsInserted,
      skipped_informational: r.skippedInformational,
      skipped_duplicates: r.skippedDuplicates,
      skipped_untyped: r.skippedUntyped,
      untyped_lines: r.untypedLines,
      statement_balance: r.statementBalance,
      // Careerplug fields (undefined for bank statements):
      applicants_upserted: r.applicantsUpserted,
      applicant_actions: r.applicantActions,
      // Wrap-up fields (undefined for other purposes):
      wrapup_done: r.wrapupDone,
      wrapup_missing_items: r.wrapupMissingItems,
      note: r.note,
      error: r.error,
    });
  }

  return jsonResponse({
    ok: true,
    drained: items.length,
    successes,
    failures,
    total_transactions_inserted: totalTxns,
    total_applicants_upserted: totalApplicants,
    by_purpose: byPurpose,
    dry_run: dryRun,
    items: results,
  });
});
