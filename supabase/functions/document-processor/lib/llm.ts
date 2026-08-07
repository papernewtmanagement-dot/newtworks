// =========================================================================
// lib/llm.ts  (v3 — direct Groq API)
// =========================================================================
// Single chokepoint for LLM calls inside the document-processor.
//
// CHANGED IN v3: Switched from COMPOSIO_SEARCH_GROQ_CHAT (which 404s on this
// agency's composio_api_key) to calling Groq's HTTPS endpoint directly using
// a `groq_api_key` setting.
//
// Behavior on failure:
//   1. Direct Groq call returns 4xx/5xx OR network error → fall through
//   2. LLM returns non-JSON content → fall through
//   3. Fall-through: INSERT into llm_parse_queue for workbench-side retry
//
// The queue path is now a true last resort, not the steady-state.
// =========================================================================

import { sb, stripFences, getSetting } from "./supabase.ts";

const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";
const GROQ_TIMEOUT_MS = 25000;

// TIMEOUT HANDLING added 2026-08-06 (Task 4, build-instructions 2026-08-06).
// See lib/composio.ts's header comment for the full "why" -- same rationale
// applies here: a stuck Groq call should fail fast and catchably instead of
// riding the invocation to the platform's own wall-clock kill (observed as
// an uncaught-exception 546 after ~105-113s). No retry added on purpose.
async function writeGroqTimeoutAlert(elapsedMs: number, context: string): Promise<void> {
  try {
    await sb.from("alerts").insert({
      alert_type: "external_call_timeout",
      severity: "warning",
      title: "Groq call timed out",
      message: `Groq call did not respond within ${elapsedMs}ms and was aborted. Context: ${context}`,
      module_reference: "document-processor:groq_timeout",
      is_read: false,
      is_resolved: false,
    });
  } catch (_e) {
    // Best-effort; never let a failed alert insert mask the original timeout.
  }
}

// Reads settings.groq_model_default for the agency; falls back to LLM_MODEL_FALLBACK
// if the row is missing OR the settings read errors.
async function getDefaultModel(agencyId: string): Promise<string> {
  try {
    const v = await getSetting(agencyId, "groq_model_default");
    return (v && v.trim()) || LLM_MODEL_FALLBACK;
  } catch (_e) {
    return LLM_MODEL_FALLBACK;
  }
}

export interface ParseLLMOpts {
  agencyId: string;
  composioApiKey: string;     // kept for backward-compat with callers; unused here
  composioUserId: string;     // kept for backward-compat with callers; unused here
  systemPrompt: string;
  userContent: string;
  documentId: string | null;
  purpose: string;
  model?: string;
  maxTokens?: number;
  // When true, a failed Groq call returns { ok:false, queued:false } instead of
  // parking a row in llm_parse_queue. For callers that already have their own
  // fallback and would otherwise leave rows nobody drains — see the note on
  // Step 3 below.
  skipQueueOnFailure?: boolean;
  // Pointer to the row this job must write its result back to, stored on the
  // queue row as target_ref and read by llm-queue-drainer. Required for any
  // purpose whose write target is NOT implied by documentId or by the parsed
  // payload itself. Shape is purpose-specific — the drainer's handler for the
  // purpose defines it. Added 2026-08-07 after a queued wrapup_organize job
  // proved undrainable: nothing recorded which weekly_cpr_team_detail row it
  // belonged to, and the source email had already been archived.
  targetRef?: Record<string, unknown>;
}

export type ParseLLMResult =
  | { ok: true; json: any; raw: string }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

async function callGroqDirect(opts: {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userContent: string;
  maxTokens: number;
  context: string; // e.g. "purpose=resume_identity_extract document=<id>" -- for the timeout alert
}): Promise<{ ok: boolean; raw: string; error: string | null; httpStatus: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GROQ_TIMEOUT_MS);
  const startedAt = Date.now();
  try {
    const res = await fetch(GROQ_ENDPOINT, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${opts.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: opts.model,
        messages: [
          { role: "system", content: opts.systemPrompt },
          { role: "user", content: opts.userContent },
        ],
        temperature: 0.1,
        max_tokens: opts.maxTokens,
        // Groq supports response_format hinting for newer models; safe to omit.
      }),
      signal: controller.signal,
    });
    const text = await res.text();
    if (!res.ok) {
      return {
        ok: false,
        raw: "",
        error: `Groq HTTP ${res.status}: ${text.slice(0, 400)}`,
        httpStatus: res.status,
      };
    }
    let parsed: any;
    try { parsed = JSON.parse(text); }
    catch (e) {
      return { ok: false, raw: text, error: `Groq returned non-JSON envelope: ${String(e)}`, httpStatus: res.status };
    }
    const content = parsed?.choices?.[0]?.message?.content ?? "";
    if (!content || typeof content !== "string") {
      return { ok: false, raw: "", error: "Groq returned empty content", httpStatus: res.status };
    }
    return { ok: true, raw: content, error: null, httpStatus: res.status };
  } catch (e) {
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut) await writeGroqTimeoutAlert(elapsedMs, opts.context);
    const error = timedOut
      ? `Groq call timed out after ${elapsedMs}ms`
      : `Groq fetch failed: ${(e as Error).message}`;
    return { ok: false, raw: "", error, httpStatus: 0 };
  } finally {
    clearTimeout(timer);
  }
}

export async function parseWithLLM(opts: ParseLLMOpts): Promise<ParseLLMResult> {
  // Step 0: resolve the model once — settings.groq_model_default or fallback
  const model = opts.model ?? await getDefaultModel(opts.agencyId);

  // Step 1: load the Groq API key for this agency
  const groqKey = await getSetting(opts.agencyId, "groq_api_key");

  // Step 2: try the direct Groq call (if key is present)
  if (groqKey) {
    const llm = await callGroqDirect({
      apiKey: groqKey,
      model,
      systemPrompt: opts.systemPrompt,
      userContent: opts.userContent,
      maxTokens: opts.maxTokens ?? 4000,
      context: `purpose=${opts.purpose} document=${opts.documentId ?? "none"}`,
    });

    if (llm.ok) {
      const cleaned = stripFences(llm.raw);
      try {
        return { ok: true, json: JSON.parse(cleaned), raw: cleaned };
      } catch (_e) {
        // LLM returned non-JSON content. Fall through to queue with the raw
        // content recorded as user_content so workbench can salvage it later.
      }
    }
    // Any failure path falls through to the queue below.
  }

  // Step 3: queue for workbench-side processing (true last resort)
  //
  // Opt-out: llm-queue-drainer only handles the purposes it has handlers for.
  // A caller whose purpose the drainer does not know would leave rows pending
  // forever, inflating the queue with work nobody will ever pick up. Callers
  // that carry their own fallback set skipQueueOnFailure and take the plain
  // failure instead. (Found 2026-08-04: 69 stranded resume_identity_extract
  // rows from the first full resume backlog run.)
  if (opts.skipQueueOnFailure) {
    return {
      ok: false,
      queued: false,
      error: "Groq direct call failed; queue skipped at caller's request",
    };
  }

  const { data, error } = await sb
    .from("llm_parse_queue")
    .insert({
      agency_id: opts.agencyId,
      document_id: opts.documentId,
      purpose: opts.purpose,
      system_prompt: opts.systemPrompt,
      user_content: opts.userContent,
      model,
      status: "pending",
      target_ref: opts.targetRef ?? null,
    })
    .select("id")
    .single();

  if (error || !data) {
    return {
      ok: false,
      queued: false,
      error: `Groq direct call failed AND queue insert failed: ${error?.message ?? "unknown"}`,
    };
  }

  return { ok: false, queued: true, queueId: data.id };
}
