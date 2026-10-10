// =========================================================================
// lib/llm.ts  (v4 — shared reader, Claude backup)
// =========================================================================
// Single chokepoint for AI reads inside the document-processor.
//
// v4 (2026-10-09): the Groq call, the token clamp and the "Groq first, Claude
// as backup" decision all live in ../../_shared/llm.ts (readWithBackup). This
// file used to carry its own Groq caller and its own copy of the clamp; both
// are gone so there is one of each.
//
// Order of readers:
//   1. Groq, paced against the per-minute token cap.
//   2. Claude (pay-per-use key, settings.anthropic_api_key) ONLY when Groq
//      errors, is busy, cuts off, returns non-JSON, or fails the caller's
//      check(). Same instructions, same extracted text, nothing else.
//   3. Queue row in llm_parse_queue for llm-queue-drainer (true last resort,
//      unless the caller set skipQueueOnFailure).
// =========================================================================

import { sb, stripFences, getSetting } from "../../_shared/supabase.ts";
import { getDefaultModel, fitMaxTokens, readWithBackup } from "../../_shared/llm.ts";

const GROQ_TIMEOUT_MS = 25000;

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
  // When true, a failed read returns { ok:false, queued:false } instead of
  // parking a row in llm_parse_queue. For callers that already have their own
  // fallback and would otherwise leave rows nobody drains.
  skipQueueOnFailure?: boolean;
  // Pointer to the row this job must write its result back to, stored on the
  // queue row as target_ref and read by llm-queue-drainer. Required for any
  // purpose whose write target is NOT implied by documentId or by the parsed
  // payload itself (2026-08-07, an undrainable wrapup_organize job).
  targetRef?: Record<string, unknown>;
  // When true, skip the direct read and queue the job for llm-queue-drainer.
  // For purposes whose ONLY reader is the drainer — bank, card and investment
  // statements since 2026-09-26. The drainer applies the same Groq-then-Claude
  // order with the statement checks.
  queueOnly?: boolean;
  // The parser's own safety check on the parsed answer: null when it is
  // usable, otherwise a short reason. A failed check sends the read to the
  // Claude backup. Answers that are not JSON always fail.
  check?: (json: any) => string | null;
}

export type ParseLLMResult =
  | { ok: true; json: any; raw: string }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

export async function parseWithLLM(opts: ParseLLMOpts): Promise<ParseLLMResult> {
  const model = opts.model ?? await getDefaultModel(opts.agencyId);
  let directError: string | null = null;

  if (!opts.queueOnly) {
    const groqKey = await getSetting(opts.agencyId, "groq_api_key");
    const read = await readWithBackup({
      agencyId: opts.agencyId,
      groqKey: groqKey || null,
      model,
      systemPrompt: opts.systemPrompt,
      userContent: opts.userContent,
      maxTokens: fitMaxTokens(opts.systemPrompt, opts.userContent, opts.maxTokens ?? 4000),
      claudeMaxTokens: Math.max(opts.maxTokens ?? 4000, 4000),
      groqTimeoutMs: GROQ_TIMEOUT_MS,
      claudeTimeoutMs: 60000,
      label: `purpose=${opts.purpose} document=${opts.documentId ?? "none"}`,
      check: (raw) => {
        let json: any;
        try { json = JSON.parse(stripFences(raw)); }
        catch (_e) { return `answer is not JSON: ${stripFences(raw).slice(0, 160)}`; }
        return opts.check ? opts.check(json) : null;
      },
    });
    if (read.ok) {
      const cleaned = stripFences(read.raw);
      if (read.reader === "claude") {
        console.log(`[document-processor] ${opts.purpose} read by the Claude backup (Groq: ${read.groqProblem})`);
      }
      return { ok: true, json: JSON.parse(cleaned), raw: cleaned };
    }
    directError = read.error;
  }

  // Last resort: queue for llm-queue-drainer, which only handles the purposes
  // it has handlers for. A caller whose purpose the drainer does not know
  // would leave rows pending forever (2026-08-04: 69 stranded rows), so those
  // callers set skipQueueOnFailure and take the plain failure instead.
  if (opts.skipQueueOnFailure) {
    return {
      ok: false,
      queued: false,
      error: `AI read failed (${directError ?? "unknown"}); queue skipped at caller's request`,
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
      error: `AI read failed (${directError ?? "queued only"}) AND queue insert failed: ${error?.message ?? "unknown"}`,
    };
  }

  return { ok: false, queued: true, queueId: data.id };
}
