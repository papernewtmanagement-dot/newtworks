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

import { sb, getSettingOrNull } from "./supabase.ts";

export const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
export const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";

// Reads settings.groq_model_default for the agency; falls back to
// LLM_MODEL_FALLBACK if the row is missing OR the settings read errors.
export async function getDefaultModel(agencyId: string): Promise<string> {
  const v = await getSettingOrNull(agencyId, "groq_model_default");
  return (v && v.trim()) || LLM_MODEL_FALLBACK;
}

// settings.groq_api_key, then the GROQ_API_KEY env var, then null.
export async function getGroqKey(agencyId: string): Promise<string | null> {
  const fromSettings = await getSettingOrNull(agencyId, "groq_api_key");
  if (fromSettings) return fromSettings;
  return Deno.env.get("GROQ_API_KEY") ?? null;
}

export interface GroqChatResult {
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

export async function callGroqChat(opts: {
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
export const CHARS_PER_TOKEN_EST = 3.4;
export function estimateTokens(s: string): number {
  return Math.ceil((s ?? "").length / CHARS_PER_TOKEN_EST);
}

// Groq caps EVERY request, prompt AND answer together, at 8,000 tokens on this
// tier. A caller's answer budget is a CEILING, not a reservation: fit it to
// what is left after the prompt. 413 (too big, fails forever) is not 429 (too
// fast, works after a wait). The one copy of this clamp; document-processor's
// parseWithLLM and llm-queue-drainer both call it (they each had their own
// until 2026-10-09).
export const GROQ_REQUEST_TOKEN_CAP = 8000;
export const GROQ_SAFETY_MARGIN = 300;
export function fitMaxTokens(systemPrompt: string, userContent: string, ceiling: number, floor = 400): number {
  const available = GROQ_REQUEST_TOKEN_CAP - estimateTokens(systemPrompt + userContent) - GROQ_SAFETY_MARGIN;
  return Math.max(floor, Math.min(ceiling, available));
}

export async function paceGroq(
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

export const CLAUDE_BACKUP_MODEL = "claude-sonnet-5-5";
const CLAUDE_ENDPOINT = "https://api.anthropic.com/v1/messages";

export async function getClaudeKey(agencyId: string): Promise<string | null> {
  return await getSettingOrNull(agencyId, "anthropic_api_key");
}

export async function callClaudeChat(opts: {
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

export interface BackedReadResult extends GroqChatResult {
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
export async function readWithBackup(opts: {
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
