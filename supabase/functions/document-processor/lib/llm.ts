// =========================================================================
// lib/llm.ts
// =========================================================================
// Single chokepoint for LLM calls inside the document-processor.
//
// CURRENT STATE: this BCC's composio_api_key returns 404 for
// COMPOSIO_SEARCH_GROQ_CHAT (deprecated/feature-gated on Composio's side).
// Until that's resolved at the platform level, in-runner LLM calls will
// always fall through to the queued-fallback path. The fallback queues the
// request in llm_parse_queue for workbench-side processing using the
// invoke_llm() helper (which IS available in the workbench layer; see
// Peter's handoff on the two-layer LLM model).
// =========================================================================

import { sb, stripFences } from "./supabase.ts";
import { callComposioNoAuth } from "./composio.ts";

const COMPOSIO_LLM_TOOL = "COMPOSIO_SEARCH_GROQ_CHAT";
const LLM_MODEL_DEFAULT = "llama-3.3-70b-versatile";

export interface ParseLLMOpts {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
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

export async function parseWithLLM(opts: ParseLLMOpts): Promise<ParseLLMResult> {
  // Step 1: try the Composio-hosted Groq path.
  try {
    const llm = await callComposioNoAuth({
      apiKey: opts.composioApiKey,
      userId: opts.composioUserId,
      toolSlug: COMPOSIO_LLM_TOOL,
      toolArguments: {
        model: opts.model ?? LLM_MODEL_DEFAULT,
        messages: [
          { role: "system", content: opts.systemPrompt },
          { role: "user", content: opts.userContent },
        ],
        temperature: 0.1,
        max_tokens: opts.maxTokens ?? 4000,
      },
    });

    if (llm.ok) {
      const raw =
        llm.data?.choices?.[0]?.message?.content ??
        llm.data?.content ??
        "";
      const cleaned = stripFences(typeof raw === "string" ? raw : JSON.stringify(raw));
      try {
        return { ok: true, json: JSON.parse(cleaned), raw: cleaned };
      } catch (_e) {
        // LLM returned non-JSON. Fall through to queue.
      }
    }
  } catch (_e) {
    // Network failure or any other exception → fall through to queue.
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
      error: `Composio LLM failed AND queue insert failed: ${error?.message ?? "unknown"}`,
    };
  }

  return { ok: false, queued: true, queueId: data.id };
}
