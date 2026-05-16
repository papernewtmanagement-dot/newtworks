// =========================================================================
// lib/llm.ts — v3 (direct Groq API)
// =========================================================================
// Single chokepoint for LLM calls inside the document-processor.
//
// CHANGE FROM v2: Bypasses COMPOSIO_SEARCH_GROQ_CHAT (which 404s for this
// agency's composio_api_key) and calls Groq's OpenAI-compatible endpoint
// directly with a dedicated groq_api_key stored in settings.
//
// Fallback path: if Groq is unreachable or returns non-JSON, the request is
// queued in llm_parse_queue for workbench-side processing — same shape as v2.
// =========================================================================

import { sb, stripFences, getSetting } from "./supabase.ts";

const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_DEFAULT = "llama-3.3-70b-versatile";

export interface ParseLLMOpts {
  agencyId: string;
  composioApiKey: string;   // kept for signature compat — unused
  composioUserId: string;   // kept for signature compat — unused
  systemPrompt: string;
  userContent: string;
  documentId: string | null;
  purpose: string;
  model?: string;
  maxTokens?: number;
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
}): Promise<{ ok: true; content: string } | { ok: false; error: string }> {
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
        response_format: { type: "json_object" },
      }),
    });

    if (!res.ok) {
      const txt = await res.text();
      return { ok: false, error: `Groq HTTP ${res.status}: ${txt.slice(0, 300)}` };
    }

    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content ?? "";
    if (!content) return { ok: false, error: "Groq returned empty content" };
    return { ok: true, content };
  } catch (e) {
    return { ok: false, error: `Groq network error: ${(e as Error).message}` };
  }
}

export async function parseWithLLM(opts: ParseLLMOpts): Promise<ParseLLMResult> {
  // Step 1: try direct Groq call.
  const groqApiKey = await getSetting(opts.agencyId, "groq_api_key");

  if (groqApiKey) {
    const llm = await callGroqDirect({
      apiKey: groqApiKey,
      model: opts.model ?? LLM_MODEL_DEFAULT,
      systemPrompt: opts.systemPrompt,
      userContent: opts.userContent,
      maxTokens: opts.maxTokens ?? 4000,
    });

    if (llm.ok) {
      const cleaned = stripFences(llm.content);
      try {
        return { ok: true, json: JSON.parse(cleaned), raw: cleaned };
      } catch (_e) {
        // Got a response but couldn't parse as JSON. Fall through to queue.
      }
    }
    // If !llm.ok, fall through to queue.
  }

  // Step 2: queue for workbench-side processing.
  const { data, error } = await sb
    .from("llm_parse_queue")
    .insert({
      agency_id: opts.agencyId,
      document_id: opts.documentId,
      purpose: opts.purpose,
      system_prompt: opts.systemPrompt,
      user_content: opts.userContent,
      model: opts.model ?? LLM_MODEL_DEFAULT,
      status: "pending",
    })
    .select("id")
    .single();

  if (error || !data) {
    return {
      ok: false,
      queued: false,
      error: `Groq failed AND queue insert failed: ${error?.message ?? "unknown"}`,
    };
  }

  return { ok: false, queued: true, queueId: data.id };
}
