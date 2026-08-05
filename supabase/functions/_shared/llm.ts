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

import { getSettingOrNull } from "./supabase.ts";

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
}): Promise<GroqChatResult> {
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

  const attempts = 1 + Math.max(0, opts.retries ?? 0);
  let lastErr = "unknown";
  let lastStatus = 0;

  for (let attempt = 0; attempt < attempts; attempt++) {
    let res: Response;
    try {
      res = await fetch(GROQ_ENDPOINT, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${opts.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
    } catch (e) {
      return { ok: false, raw: "", error: `Groq fetch failed: ${(e as Error).message}`, httpStatus: 0 };
    }
    lastStatus = res.status;

    if ((res.status === 429 || res.status >= 500) && attempt < attempts - 1) {
      lastErr = `Groq HTTP ${res.status}`;
      await sleep(500 * Math.pow(2, attempt));
      continue;
    }

    const text = await res.text();
    if (!res.ok) {
      return { ok: false, raw: "", error: `Groq HTTP ${res.status}: ${text.slice(0, 400)}`, httpStatus: res.status };
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
  }

  return { ok: false, raw: "", error: `Groq exhausted retries: ${lastErr}`, httpStatus: lastStatus };
}
