// Reference email ingest ("references" mode) — created 2026-08-19.
//
// Marie phones a candidate's references and emails the write-up as PLAIN BODY
// TEXT with the subject "Reference N - <candidate name>". No attachment. The
// default document-processor door is gated on has:attachment, so for months
// these emails were invisible to every automation: two Maximus Moody
// references sat unread in the inbox while the candidate waited at
// meet-and-greet. This mode is the door for them, patterned on wrapup_ingest,
// the existing body-only precedent.
//
// Deliberately DETERMINISTIC — no language model anywhere in this path. The
// body IS the reference; Peter reads it verbatim on the candidate page. The
// subject line carries everything that needs extracting, and after the AMEX
// statement saga (2026-08-18/19) the bar for adding model-parsing to intake is
// "only when a regex genuinely cannot do it".

import { callComposio } from "../lib/composio.ts";
import { sb } from "../../_shared/supabase.ts";

export interface ReferencesCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}

interface OneRefResult {
  status: "processed" | "skipped" | "error";
  message_id: string;
  candidate_name: string | null;
  candidate_id: string | null;
  reference_number: number | null;
  note?: string;
}

// "Reference 2 - Maximus Moody", tolerant of Fwd:/Re: prefixes, hyphen or
// dash variants, and a missing number. Anchored so ordinary sentences that
// merely contain the word "reference" cannot match.
const SUBJECT_RE = /^\s*(?:(?:fwd|re):\s*)*reference\s*(\d+)?\s*[-–—:]\s*(.+?)\s*$/i;

// Team/Hiring. Processed reference threads leave the inbox and file here, and
// the search query excludes the label so a thread is never ingested twice even
// if the unique index were somehow bypassed.
const TEAM_HIRING_LABEL_ID = "Label_3169275797947586809";

export async function processReferencesMode(
  ctx: ReferencesCtx,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const query = (body.gmail_query as string | undefined)
    ?? `subject:"Reference" -label:Team-Hiring -in:sent -in:trash newer_than:30d`;
  const maxResults = (body.max_results as number | undefined) ?? 20;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query, max_results: maxResults, user_id: "me", include_payload: false, verbose: false },
  });
  if (!listRes.ok) {
    return { ok: false, processed: 0, skipped: 0, errors: 1, error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: OneRefResult[] = [];
  const archivedThreads = new Set<string>();
  let processed = 0, skipped = 0, errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processOneReferenceMessage(ctx, msgId, archivedThreads);
      results.push(r);
      if (r.status === "processed") processed++;
      else if (r.status === "skipped") skipped++;
      else errors++;
    } catch (e) {
      errors++;
      results.push({
        status: "error", message_id: msgId, candidate_name: null,
        candidate_id: null, reference_number: null,
        note: e instanceof Error ? e.message : String(e),
      });
    }
  }

  return { ok: true, message_count: messages.length, processed, skipped, errors, results };
}

async function processOneReferenceMessage(
  ctx: ReferencesCtx,
  messageId: string,
  archivedThreads: Set<string>,
): Promise<OneRefResult> {
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: { message_id: messageId, format: "full", user_id: "me" },
  });
  if (!msgRes.ok) {
    return { status: "error", message_id: messageId, candidate_name: null, candidate_id: null, reference_number: null, note: `fetch: ${msgRes.error}` };
  }
  const msg: any = msgRes.data?.response_data ?? msgRes.data ?? {};
  const headers = msg?.payload?.headers ?? [];
  const hget = (name: string): string => headers.find((h: any) => h?.name === name)?.value ?? "";

  const subject: string = msg?.subject ?? hget("Subject") ?? "";
  const sm = SUBJECT_RE.exec(subject);
  if (!sm) {
    // The Gmail query is broad on purpose; the regex is the real gate. A
    // subject that merely contains "Reference" without the convention is not a
    // reference email — leave it exactly where it is.
    return { status: "skipped", message_id: messageId, candidate_name: null, candidate_id: null, reference_number: null, note: "subject does not match convention" };
  }
  const referenceNumber = sm[1] ? parseInt(sm[1], 10) : null;
  const candidateName = sm[2].trim();

  const { data: existing } = await sb
    .from("hiring_candidate_references")
    .select("id")
    .eq("gmail_message_id", messageId)
    .maybeSingle();
  if (existing) {
    return { status: "skipped", message_id: messageId, candidate_name: candidateName, candidate_id: null, reference_number: referenceNumber, note: "already ingested" };
  }

  const bodyText: string =
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet ?? "";
  if (!bodyText.trim()) {
    return { status: "error", message_id: messageId, candidate_name: candidateName, candidate_id: null, reference_number: referenceNumber, note: "empty body" };
  }

  const threadId: string = msg?.threadId ?? msg?.thread_id ?? "";
  const sender: string = msg?.from ?? msg?.sender ?? hget("From") ?? "";
  const receivedRaw: string = msg?.messageTimestamp ?? hget("Date") ?? "";
  const receivedAt = receivedRaw ? new Date(receivedRaw).toISOString() : null;

  // Exact name match only. A fuzzy match that links a reference to the wrong
  // candidate is far worse than an unlinked row with a loud alert, so
  // ambiguity and misses both stay NULL and get flagged for a human.
  const { data: candidates } = await sb
    .from("hiring_candidates")
    .select("id, candidate_name")
    .eq("agency_id", ctx.agencyId)
    .ilike("candidate_name", candidateName);
  const candidateId = (candidates?.length ?? 0) === 1 ? candidates![0].id : null;

  const { error: insErr } = await sb.from("hiring_candidate_references").insert({
    agency_id: ctx.agencyId,
    candidate_id: candidateId,
    candidate_name_from_subject: candidateName,
    reference_number: referenceNumber,
    gmail_thread_id: threadId,
    gmail_message_id: messageId,
    sender,
    received_at: receivedAt,
    subject,
    body: bodyText,
  });
  if (insErr) {
    return { status: "error", message_id: messageId, candidate_name: candidateName, candidate_id: candidateId, reference_number: referenceNumber, note: `insert: ${insErr.message}` };
  }

  // A reference is a hiring-gate artifact — its arrival should be loud.
  await sb.from("alerts").insert({
    agency_id: ctx.agencyId,
    alert_type: candidateId ? "reference_received" : "reference_unmatched",
    severity: candidateId ? "info" : "warning",
    title: candidateId
      ? `Reference${referenceNumber ? ` ${referenceNumber}` : ""} received: ${candidateName}`
      : `Reference received for UNMATCHED name: ${candidateName}`,
    message: candidateId
      ? `Reference write-up ingested from ${sender} and linked to the candidate record.`
      : `Reference write-up ingested from ${sender}, but "${candidateName}" matched ${candidates?.length ?? 0} candidate records instead of exactly one. Stored unlinked — link it by hand.`,
    module_reference: "hiring",
    related_id: candidateId,
  });

  if (threadId && !archivedThreads.has(threadId)) {
    const arcRes = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
      toolArguments: {
        thread_id: threadId,
        remove_label_ids: ["INBOX"],
        add_label_ids: [TEAM_HIRING_LABEL_ID],
        user_id: "me",
      },
    });
    if (arcRes.ok) archivedThreads.add(threadId);
    else console.error(`[references] archive failed for thread ${threadId}: ${arcRes.error}`);
  }

  return { status: "processed", message_id: messageId, candidate_name: candidateName, candidate_id: candidateId, reference_number: referenceNumber };
}
