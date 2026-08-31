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

// Two people send these and they title them differently, so both shapes are
// first-class. Reply/forward prefixes are stripped up front rather than being
// baked into each pattern.
const PREFIX_RE = /^(?:\s*(?:fwd?|re):\s*)+/i;

// Shape A — Marie: "Reference 2 - Maximus Moody". Number optional, hyphen or
// dash variants, anchored so an ordinary sentence containing the word
// "reference" cannot match.
const SUBJECT_LEADING_RE = /^reference\s*(\d+)?\s*[-–—:]\s*(.+?)\s*$/i;

// Shape B — Stephanie: "Rodney References", "Bryson Reference 2". The name
// comes first and is usually the first name alone.
const SUBJECT_TRAILING_RE = /^(.+?)\s*[-–—:]?\s*references?\s*(\d+)?\s*$/i;

// Shape B only. One to four capitalised words — that is what stops "please
// send references" being read as a candidate called "please send". Shape A
// needs no such guard: its own anchor already does the work.
const LOOKS_LIKE_A_NAME_RE = /^[A-Z][\p{L}'’.\-]*(?:\s+[A-Z][\p{L}'’.\-]*){0,3}$/u;

function parseReferenceSubject(
  subject: string,
): { candidateName: string; referenceNumber: number | null } | null {
  const bare = subject.replace(PREFIX_RE, "").trim();

  const a = SUBJECT_LEADING_RE.exec(bare);
  if (a) {
    return {
      candidateName: a[2].trim(),
      referenceNumber: a[1] ? parseInt(a[1], 10) : null,
    };
  }

  const b = SUBJECT_TRAILING_RE.exec(bare);
  if (b && LOOKS_LIKE_A_NAME_RE.test(b[1].trim())) {
    return {
      candidateName: b[1].trim(),
      referenceNumber: b[2] ? parseInt(b[2], 10) : null,
    };
  }

  return null;
}

// Team/Hiring. Processed reference threads leave the inbox and file here, and
// the search query excludes the label so a thread is never ingested twice even
// if the unique index were somehow bypassed.
const TEAM_HIRING_LABEL_ID = "Label_3169275797947586809";

// Gmail delivers a reference as a MIME tree: a text/plain part holding the
// write-up, a text/html part holding the SAME write-up again, and the sender's
// signature images. Composio's messageText field is not a safe source for the
// plain half. On the tool-set version this function resolves against it hands
// back plain and HTML glued together, so every row stored at roughly double
// size — 43,111 bytes for one forward whose real text is 8,313. Newer Composio
// tool sets return only the plain part, which is exactly why the identical call
// from an interactive session always looked correct and the stored rows were
// not. Reading the tree ourselves takes the version question off the table.
//
// Charset is read off the part instead of assumed: UTF-8 arrives from Gmail,
// us-ascii and Windows-1252 from Outlook, and decoding Outlook's curly quotes
// as UTF-8 turns them into mojibake.
function referencePartCharset(part: any): string {
  const contentType: string = (part?.headers ?? [])
    .find((h: any) => String(h?.name ?? "").toLowerCase() === "content-type")?.value ?? "";
  const m = /charset\s*=\s*"?([^";\s]+)"?/i.exec(contentType);
  return (m?.[1] ?? "utf-8").trim().toLowerCase();
}

function decodeReferencePart(data: string, declaredCharset: string): string {
  const b64 = String(data).replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  // The declared charset lies. Stephanie's Outlook labels this part
  // Windows-1252 and then sends UTF-8 bytes; trusting the label turned the
  // apostrophe in "Visit Agent's Page" into "a EUR (tm)" mojibake on the first
  // attempt at this fix. So UTF-8 is tried FIRST in fatal mode, which throws on
  // any byte sequence that is not valid UTF-8, and the declared label is used
  // only when the bytes genuinely are not UTF-8. Real Windows-1252 text with
  // high bytes fails the fatal decode and falls through correctly; plain
  // us-ascii is valid UTF-8 either way.
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    // Not UTF-8 after all — the label may be right.
  }
  try {
    return new TextDecoder(declaredCharset).decode(bytes);
  } catch {
    // Unknown or misspelled label must not lose the reference.
  }
  return new TextDecoder("utf-8").decode(bytes);
}

// Depth-first: Outlook nests text/plain two levels down inside
// multipart/related > multipart/alternative, Gmail puts it one level down.
function findReferencePart(node: any, wantedMimeType: string): any | null {
  if (!node) return null;
  if (String(node.mimeType ?? "").toLowerCase() === wantedMimeType && node?.body?.data) return node;
  for (const sub of node.parts ?? []) {
    const hit = findReferencePart(sub, wantedMimeType);
    if (hit) return hit;
  }
  return null;
}

function referenceBodyFromMessage(msg: any): string {
  const plain = findReferencePart(msg?.payload, "text/plain");
  if (plain) return decodeReferencePart(plain.body.data, referencePartCharset(plain));

  // No plain part at all — store the HTML and let the body_text generated
  // column strip it, rather than dropping the reference on the floor.
  const html = findReferencePart(msg?.payload, "text/html");
  if (html) return decodeReferencePart(html.body.data, referencePartCharset(html));

  return String(
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet ?? "",
  );
}

export async function processReferencesMode(
  ctx: ReferencesCtx,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  // The Team-Hiring label is NOT excluded any more. Stephanie sends a second
  // and third reference as replies on the SAME thread, and a new message
  // re-inboxes a thread without dropping the label it already carries — so
  // excluding the label made every follow-up reference permanently invisible.
  // The unique index on gmail_message_id is the real duplicate guard, and the
  // per-message check below skips an already-ingested one for the cost of one
  // indexed lookup. Both singular and plural, since Gmail treats the quoted
  // phrase literally.
  const query = (body.gmail_query as string | undefined)
    ?? `(subject:reference OR subject:references) -in:sent -in:trash newer_than:30d`;
  const maxResults = (body.max_results as number | undefined) ?? 50;

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

  // Gmail does not return these in date order, and reference numbers are
  // assigned by arrival when the subject does not carry one — so process
  // oldest first or the first referee to arrive can end up numbered second.
  messages.sort((a: any, b: any) =>
    String(a?.messageTimestamp ?? "").localeCompare(String(b?.messageTimestamp ?? ""))
  );

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
  const parsed = parseReferenceSubject(subject);
  if (!parsed) {
    // The Gmail query is broad on purpose; the patterns are the real gate. A
    // subject that merely contains "Reference" without either convention is
    // not a reference email — leave it exactly where it is.
    return { status: "skipped", message_id: messageId, candidate_name: null, candidate_id: null, reference_number: null, note: "subject does not match convention" };
  }
  const candidateName = parsed.candidateName;
  const referenceNumber = parsed.referenceNumber;

  const { data: existing } = await sb
    .from("hiring_candidate_references")
    .select("id")
    .eq("gmail_message_id", messageId)
    .maybeSingle();
  if (existing) {
    return { status: "skipped", message_id: messageId, candidate_name: candidateName, candidate_id: null, reference_number: referenceNumber, note: "already ingested" };
  }

  const bodyText: string = referenceBodyFromMessage(msg);
  if (!bodyText.trim()) {
    return { status: "error", message_id: messageId, candidate_name: candidateName, candidate_id: null, reference_number: referenceNumber, note: "empty body" };
  }

  const threadId: string = msg?.threadId ?? msg?.thread_id ?? "";
  const sender: string = msg?.from ?? msg?.sender ?? hget("From") ?? "";
  const receivedRaw: string = msg?.messageTimestamp ?? hget("Date") ?? "";
  const receivedAt = receivedRaw ? new Date(receivedRaw).toISOString() : null;

  // Full name first. Shape B usually carries the first name alone, so a
  // single-token name falls back to a first-name lookup. Still no fuzzy
  // matching of any kind: linking a reference to the WRONG candidate is far
  // worse than an unlinked row with a loud alert, so anything other than
  // exactly one hit stays NULL and gets flagged for a human.
  let candidates: { id: string }[] = [];
  const { data: byFullName } = await sb
    .from("hiring_candidates")
    .select("id, candidate_name")
    .eq("agency_id", ctx.agencyId)
    .ilike("candidate_name", candidateName);
  candidates = byFullName ?? [];

  if (candidates.length !== 1 && !candidateName.includes(" ")) {
    const { data: byFirstName } = await sb
      .from("hiring_candidates")
      .select("id, candidate_name")
      .eq("agency_id", ctx.agencyId)
      .ilike("first_name", candidateName);
    if ((byFirstName?.length ?? 0) > 0) candidates = byFirstName!;
  }
  const candidateId = candidates.length === 1 ? candidates[0].id : null;

  // Shape B carries no number. Assign the next one for this candidate so the
  // reference layer can still tell one referee from another. Messages are
  // processed oldest-first and inserted one at a time, so a run that ingests
  // three at once still numbers them in arrival order.
  let resolvedNumber = referenceNumber;
  if (resolvedNumber === null && candidateId) {
    const { data: prior } = await sb
      .from("hiring_candidate_references")
      .select("reference_number")
      .eq("candidate_id", candidateId);
    resolvedNumber = (prior ?? []).reduce(
      (max: number, r: any) => Math.max(max, r?.reference_number ?? 0),
      0,
    ) + 1;
  }

  const { error: insErr } = await sb.from("hiring_candidate_references").insert({
    agency_id: ctx.agencyId,
    candidate_id: candidateId,
    candidate_name_from_subject: candidateName,
    reference_number: resolvedNumber,
    gmail_thread_id: threadId,
    gmail_message_id: messageId,
    sender,
    received_at: receivedAt,
    subject,
    body: bodyText,
  });
  if (insErr) {
    return { status: "error", message_id: messageId, candidate_name: candidateName, candidate_id: candidateId, reference_number: resolvedNumber, note: `insert: ${insErr.message}` };
  }

  // A reference is a hiring-gate artifact — its arrival should be loud.
  await sb.from("alerts").insert({
    agency_id: ctx.agencyId,
    alert_type: candidateId ? "reference_received" : "reference_unmatched",
    severity: candidateId ? "info" : "warning",
    title: candidateId
      ? `Reference${resolvedNumber ? ` ${resolvedNumber}` : ""} received: ${candidateName}`
      : `Reference received for UNMATCHED name: ${candidateName}`,
    message: candidateId
      ? `Reference write-up ingested from ${sender} and linked to the candidate record.`
      : `Reference write-up ingested from ${sender}, but "${candidateName}" matched ${candidates.length} candidate records instead of exactly one. Stored unlinked — link it by hand.`,
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

  return { status: "processed", message_id: messageId, candidate_name: candidateName, candidate_id: candidateId, reference_number: resolvedNumber };
}
