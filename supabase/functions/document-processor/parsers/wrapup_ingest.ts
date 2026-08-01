// =========================================================================
// parsers/wrapup_ingest.ts
// =========================================================================
// Processes team wrap-up emails and CPR replies into a single wrapup_text
// column per (team_member_id, week_ending_date) on weekly_cpr_team_detail.
//
// Called via document-processor mode="wrapup".
//
// Flow per matched Gmail message:
//   1. Fetch full message (subject/headers/body).
//   2. Classify as one of:
//        - "nag_reply"  (subject "Re: [EXTERNAL] Wrap-up follow-up — X")
//        - "wrapup"     (subject contains wrap-up / wrapup / wrap up)
//        - "cpr_reply"  (subject "CPR RECAP — WEEK OF …")
//        - "unclassified" (skip + label)
//      Nag reply is checked FIRST because its subject would otherwise match
//      the generic wrap-up regex and get mis-routed to the reply's-week
//      Saturday instead of the ORIGINAL nagged week.
//   3. Resolve sender team_member (handles Fw: forwarding by parsing the
//      first inner "From:" line when the outer sender is us).
//   4. Resolve week_ending_date (Saturday):
//        - nag_reply → look up parent nag via In-Reply-To → RFC Message-ID
//          in wrapup_nag_log.nag_message_id_rfc; skip if not found.
//        - cpr_reply → look up parent CPR via In-Reply-To → RFC id in
//          weekly_cpr_reports.cpr_recap_message_id_rfc, fall back to the
//          legacy gmail_message_id column, skip if not found.
//        - wrapup   → nearest past Saturday from received timestamp CT,
//          BUT if that Saturday's CPR has already been sent to the team,
//          shift forward one week (email is for the current in-progress
//          week, not the just-closed one).
//   5. Pull existing wrapup_text + the six-item rubric from
//      get_wrapup_checklist_text().
//   6. LLM merges new email into current text, organized under the six
//      required sections; returns coverage[6] + missing_item_labels[].
//   7. Write organized text back; flip wrapup_done if all six covered.
//   8. If missing items and same missing-set hasn't been nagged this week,
//      send public nag email (whole team including Peter) + log. On send,
//      also capture the sent nag's RFC-2822 Message-ID so a future reply
//      can be routed back to this week via In-Reply-To.
//   9. Apply Wrapups Gmail label + remove INBOX.
// =========================================================================

// deno-lint-ignore-file no-explicit-any

import { sb } from "../lib/supabase.ts";
import { callComposio } from "../lib/composio.ts";
import { parseWithLLM } from "../lib/llm.ts";

const WRAPUPS_LABEL_ID = "Label_31";  // Gmail label "Wrapups" (paper.newt.management@gmail.com)

export interface WrapupCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}

export interface WrapupBody {
  gmail_query?: string;
  max_results?: number;
}

interface OneMessageResult {
  status: "processed" | "skipped" | "error";
  message_id: string;
  kind: "wrapup" | "cpr_reply" | "nag_reply" | "unclassified";
  team_member_id: string | null;
  week_ending_date: string | null;
  all_complete: boolean;
  missing_items: string[];
  nag_sent: boolean;
  error?: string;
}

// ---------- LLM prompt ----------

const WRAPUP_ORGANIZE_PROMPT = `You are helping structure weekly wrap-up content for Peter Story's State Farm agency team. Each team member sends free-form emails during the week — either a formal Weekly Wrap-up email or a reply to Peter's Sunday CPR email. Your job is to fold each new email's content into the accumulated wrap-up text for that team member for that week, organized under the six required categories.

The six required categories come from the Daily Wrap-up manual's Weekly wrap-up email section. The exact rubric text will be included in the user message under <RUBRIC>.

INPUTS you receive in the user message:
- <RUBRIC>: the six-item checklist from the manual, verbatim.
- <SENDER_FIRST_NAME>: the team member's first name — for context only, do not address them in the output.
- <EMAIL_KIND>: either "wrapup" or "cpr_reply".
- <CURRENT_WRAPUP_TEXT>: what is currently stored (may be empty if this is the first email of the week). Already organized under the six categories if non-empty.
- <NEW_EMAIL_BODY>: the incoming email's plaintext body.

OUTPUT strictly this JSON shape (no markdown fences, no explanation):

{
  "organized_text": "1. …\\n<content>\\n\\n2. …\\n<content>\\n\\n3. …\\n<content>\\n\\n4. …\\n<content>\\n\\n5. …\\n<content>\\n\\n6. …\\n<content>",
  "coverage": {
    "item_1": true,
    "item_2": false,
    "item_3": true,
    "item_4": false,
    "item_5": true,
    "item_6": true
  },
  "missing_item_labels": ["Lapse/cancel trends", "1% sales points plan"]
}

RULES for organized_text:
1. Structure as SIX numbered sections. Each header line reads exactly:
     1. Personal life & annuity status updates
     2. Lapse/cancel trends + individual highlights
     3. Personal obstacles + solutions
     4. Plan for 1% increase in sales points next week
     5. Efficiency / pain-point recommendation
     6. Brags on teammates
2. Preserve wording from the source emails when possible. Do NOT paraphrase or embellish.
3. If a category has NO content across <CURRENT_WRAPUP_TEXT> + <NEW_EMAIL_BODY>, write EXACTLY the string "(none reported)" under the header. NEVER invent placeholder content. Plausible-sounding phrasings like "No X this week", "Nothing to report", "Did not take any cancellation calls", "No significant updates", "N/A" — if those exact words do not appear in the source, they are FABRICATION and must NOT be written. When in doubt, write "(none reported)".
4. If the new email adds material to a category that already had content, integrate (append if new, do not duplicate if a paraphrase of what's already there). Do NOT lose prior content.
5. Do NOT add signatures, disclaimers, closing lines, or content outside the six categories.
6. Do NOT include email metadata (dates, subjects, greetings) unless the content is materially useful.
7. Strip email signatures ("Thanks for trusting Peter Story State Farm…", block contact info, forwarded header stubs, etc.) from the source before folding in.
8. Preserve customer first names + last initials as written (e.g. "Delia C.") — cancellation stories often reference customers by name.
9. Zero-fabrication test: before writing ANY sentence under a section header, verify that the words either appear in the source OR are the exact literal string "(none reported)". Nothing else. Inventing content that sounds plausible is the most damaging failure mode of this parser — it makes teammates appear to have covered sections they never addressed. Prior real failure: a teammate's email had no section-2 content; the LLM wrote "Did not take any cancellation calls." under section 2. That line was fabricated — the words never appeared in the source. Correct output would have been "(none reported)".

RULES for coverage:
A section is covered if the teammate addressed it in their email in ANY way — including "N/A", "nothing to report", "no cancels this week", "no obstacles", or any deliberate acknowledgment that they read the section and answered it. Content quality is NOT the bar; presence of a genuine answer is. Do not penalize brief, sparse, or "nothing to report" answers — they count.

A section is NOT covered ONLY when the teammate did not address it at all in the source — i.e. the LLM output "(none reported)" for that section because there was no content to fold in from either <CURRENT_WRAPUP_TEXT> or <NEW_EMAIL_BODY>.

- item_1 covered if teammate addressed personal life and/or annuity status (any content, including "no updates").
- item_2 covered if teammate addressed cancellations/lapses/trends or highlights (any content, including "no cancels this week").
- item_3 covered if teammate addressed obstacles (any content, including "no obstacles").
- item_4 covered if teammate stated a plan (any content, however brief).
- item_5 covered if teammate stated an efficiency recommendation (any content, including "no suggestions").
- item_6 covered if teammate addressed teammate brags (any content, including "none this week").

The only false signal is "(none reported)" written by you because the source had nothing on that section.

missing_item_labels: for each item where coverage is false, include a short label from this set:
  ["Personal life & annuity updates", "Lapse/cancel trends", "Obstacles + solutions", "1% sales points plan", "Efficiency recommendation", "Brags on teammates"]

Return JSON only. No markdown fences.`;

// ---------- Public entry (mode dispatch) ----------

export async function processWrapupMode(
  ctx: WrapupCtx,
  body: WrapupBody,
): Promise<{
  ok: boolean;
  processed_messages: number;
  skipped: number;
  errors: number;
  message_count: number;
  results: OneMessageResult[];
  error?: string;
}> {
  // Default query: from any team member (SF or personal) OR to us, and either
  //   subject contains wrap-up-like text OR it is a reply/forward to a CPR
  //   RECAP. -label:Wrapups excludes already-processed. -in:sent excludes
  //   Peter's own outgoing CPR sends. newer_than caps the scan window.
  const teamEmails = await loadTeamEmails(ctx.agencyId);
  if (teamEmails.length === 0) {
    return { ok: true, processed_messages: 0, skipped: 0, errors: 0, message_count: 0, results: [] };
  }
  const fromClause = teamEmails.map((e) => `from:${e}`).join(" OR ");
  const subjectMatch = `(subject:wrap-up OR subject:wrapup OR subject:"wrap up" OR subject:"CPR RECAP")`;
  const defaultQuery = `(${fromClause}) ${subjectMatch} -label:Wrapups -in:sent newer_than:21d`;

  const query = body.gmail_query ?? defaultQuery;
  const maxResults = body.max_results ?? 30;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: {
      query,
      max_results: maxResults,
      user_id: "me",
      include_payload: false,
      verbose: false,
    },
  });
  if (!listRes.ok) {
    return { ok: false, processed_messages: 0, skipped: 0, errors: 1, message_count: 0, results: [], error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: OneMessageResult[] = [];
  let processed = 0;
  let skipped = 0;
  let errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processOneWrapupMessage(ctx, msgId);
      results.push(r);
      if (r.status === "processed") processed++;
      else if (r.status === "skipped") skipped++;
      else errors++;
    } catch (e) {
      errors++;
      results.push({
        status: "error", message_id: msgId, kind: "unclassified",
        team_member_id: null, week_ending_date: null,
        all_complete: false, missing_items: [], nag_sent: false,
        error: e instanceof Error ? e.message : String(e),
      });
    }
    // Small breath between messages so Groq's per-minute quota doesn't
    // trip during backfill. Steady-state cron only sees 1-2 msgs per tick
    // so this is negligible in production.
    await new Promise((r) => setTimeout(r, 1500));
  }

  return { ok: true, processed_messages: processed, skipped, errors, message_count: messages.length, results };
}

// ---------- Per-message pipeline ----------

async function processOneWrapupMessage(
  ctx: WrapupCtx,
  messageId: string,
): Promise<OneMessageResult> {
  // 1. Fetch full message
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: {
      message_id: messageId,
      format: "full",
      user_id: "me",
    },
  });
  if (!msgRes.ok) {
    return {
      status: "error", message_id: messageId, kind: "unclassified",
      team_member_id: null, week_ending_date: null,
      all_complete: false, missing_items: [], nag_sent: false,
      error: `fetch: ${msgRes.error}`,
    };
  }
  const msg: any = msgRes.data?.response_data ?? msgRes.data ?? {};
  const headers = msg?.payload?.headers ?? [];
  const hget = (name: string): string => headers.find((h: any) => h?.name === name)?.value ?? "";

  const fromRaw: string = msg?.from ?? msg?.sender ?? hget("From");
  const subject: string = msg?.subject ?? hget("Subject");
  const inReplyTo: string = hget("In-Reply-To") || "";
  // Composio's GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID returns messageTimestamp
  // (ISO 8601 string) at the top level, and NOT internalDate. Fall back to
  // Date header parsing, then Date.now() as last resort (which corrupts week
  // routing — hence the multi-source fallback).
  const receivedAtISO: string =
    (typeof msg?.messageTimestamp === "string" && msg.messageTimestamp)
      || (msg?.internalDate ? new Date(Number(msg.internalDate)).toISOString() : "")
      || parseDateHeader(headers)
      || new Date().toISOString();
  const threadId: string | undefined = msg?.threadId ?? msg?.thread_id;

  const bodyText = wupExtractBestBody(msg);
  if (!bodyText || bodyText.trim().length < 20) {
    await labelAndArchive(ctx, messageId, threadId);
    return {
      status: "skipped", message_id: messageId, kind: "unclassified",
      team_member_id: null, week_ending_date: null,
      all_complete: false, missing_items: [], nag_sent: false,
      error: "empty body",
    };
  }

  // 2. Classify kind (wrapup / cpr_reply / unclassified)
  const kind: "wrapup" | "cpr_reply" | "nag_reply" | "unclassified" = await classifyKind(subject, inReplyTo);
  if (kind === "unclassified") {
    await labelAndArchive(ctx, messageId, threadId);
    return {
      status: "skipped", message_id: messageId, kind,
      team_member_id: null, week_ending_date: null,
      all_complete: false, missing_items: [], nag_sent: false,
      error: "subject did not match wrap-up or CPR reply pattern",
    };
  }

  // 3. Resolve sender team_member. Handle Fw: forwarding by parsing inner
  //    "From:" line when the outer sender is us OR subject is Fw:.
  const outerSenderEmail = extractEmail(fromRaw);
  let effectiveSenderEmail = outerSenderEmail;
  const isForward = /^fw:/i.test(subject.trim());
  const outerIsUs = outerSenderEmail && outerSenderEmail.endsWith("@gmail.com") && /paper\.newt/.test(outerSenderEmail);
  if (isForward || outerIsUs) {
    const innerFrom = parseInnerForwardFrom(bodyText);
    if (innerFrom) effectiveSenderEmail = innerFrom;
  }
  if (!effectiveSenderEmail) {
    await labelAndArchive(ctx, messageId, threadId);
    return {
      status: "skipped", message_id: messageId, kind,
      team_member_id: null, week_ending_date: null,
      all_complete: false, missing_items: [], nag_sent: false,
      error: "could not resolve sender email",
    };
  }

  const teamMember = await resolveTeamMemberByEmail(ctx.agencyId, effectiveSenderEmail);
  if (!teamMember) {
    await labelAndArchive(ctx, messageId, threadId);
    return {
      status: "skipped", message_id: messageId, kind,
      team_member_id: null, week_ending_date: null,
      all_complete: false, missing_items: [], nag_sent: false,
      error: `sender ${effectiveSenderEmail} not on active team roster`,
    };
  }

  // 4. Resolve week_ending_date. CPR reply: match In-Reply-To to
  //    weekly_cpr_reports.gmail_message_id. Wrapup: nearest past Saturday
  //    from received timestamp in America/Chicago.
  const weekEnding = await resolveWeekEnding(ctx.agencyId, kind, inReplyTo, receivedAtISO);
  if (!weekEnding) {
    await labelAndArchive(ctx, messageId, threadId);
    return {
      status: "skipped", message_id: messageId, kind,
      team_member_id: teamMember.id, week_ending_date: null,
      all_complete: false, missing_items: [], nag_sent: false,
      error: "could not resolve week_ending_date",
    };
  }

  // 5. Ensure weekly_cpr_team_detail row exists.
  const detailRow = await ensureDetailRow(ctx.agencyId, teamMember.id, weekEnding);
  if (!detailRow) {
    await labelAndArchive(ctx, messageId, threadId);
    return {
      status: "skipped", message_id: messageId, kind,
      team_member_id: teamMember.id, week_ending_date: weekEnding,
      all_complete: false, missing_items: [], nag_sent: false,
      error: "no weekly_cpr_team_detail row for this teammate + week",
    };
  }

  // 6. Fetch current wrapup_text + rubric
  const currentText = detailRow.wrapup_text || "";
  const rubricRes = await sb.rpc("get_wrapup_checklist_text", { p_agency_id: ctx.agencyId });
  if (rubricRes.error || !rubricRes.data) {
    return {
      status: "error", message_id: messageId, kind,
      team_member_id: teamMember.id, week_ending_date: weekEnding,
      all_complete: false, missing_items: [], nag_sent: false,
      error: `rubric fetch: ${rubricRes.error?.message ?? "empty"}`,
    };
  }
  const rubricText: string = rubricRes.data;

  // 7. LLM merge
  const llmUserContent =
    `<RUBRIC>\n${rubricText}\n</RUBRIC>\n\n` +
    `<SENDER_FIRST_NAME>${teamMember.first_name}</SENDER_FIRST_NAME>\n` +
    `<EMAIL_KIND>${kind}</EMAIL_KIND>\n\n` +
    `<CURRENT_WRAPUP_TEXT>\n${currentText || "(none yet)"}\n</CURRENT_WRAPUP_TEXT>\n\n` +
    `<NEW_EMAIL_BODY>\n${bodyText.slice(0, 12000)}\n</NEW_EMAIL_BODY>`;

  const parseRes = await parseWithLLM({
    agencyId: ctx.agencyId,
    composioApiKey: ctx.composioApiKey,
    composioUserId: ctx.composioUserId,
    systemPrompt: WRAPUP_ORGANIZE_PROMPT,
    userContent: llmUserContent,
    documentId: null,
    purpose: "wrapup_organize",
    maxTokens: 2500,
  });
  if (!parseRes.ok) {
    // Archive so the wrapup email exits the fetch pool. Without this, the
    // 30-min Weekly Wrapup cron re-fetches the same emails (John, Cassie,
    // Stephanie) all afternoon on Fridays and re-hammers Groq, which
    // amplifies quota drain and multiplies queue rows for the same message.
    // Queue item is the durable record; drainer picks it up when quota
    // recovers.
    await labelAndArchive(ctx, messageId, threadId);
    const err = "queued" in parseRes && parseRes.queued
      ? `LLM queued: ${parseRes.queueId}`
      : `LLM: ${("error" in parseRes) ? parseRes.error : "unknown"}`;
    return {
      status: "error", message_id: messageId, kind,
      team_member_id: teamMember.id, week_ending_date: weekEnding,
      all_complete: false, missing_items: [], nag_sent: false,
      error: err,
    };
  }
  const organizedText: string = parseRes.json?.organized_text ?? "";
  const coverage = parseRes.json?.coverage ?? {};
  const missingLabels: string[] = Array.isArray(parseRes.json?.missing_item_labels)
    ? parseRes.json.missing_item_labels
    : [];
  const allCovered =
    coverage.item_1 === true &&
    coverage.item_2 === true &&
    coverage.item_3 === true &&
    coverage.item_4 === true &&
    coverage.item_5 === true &&
    coverage.item_6 === true;

  // 8. Write back
  const updateRes = await sb
    .from("weekly_cpr_team_detail")
    .update({
      wrapup_text: organizedText,
      wrapup_done: allCovered,
      updated_at: new Date().toISOString(),
    })
    .eq("id", detailRow.id);
  if (updateRes.error) {
    return {
      status: "error", message_id: messageId, kind,
      team_member_id: teamMember.id, week_ending_date: weekEnding,
      all_complete: false, missing_items: missingLabels, nag_sent: false,
      error: `detail update: ${updateRes.error.message}`,
    };
  }

  // 9. Nag if missing items and same missing-set not already nagged
  let nagSent = false;
  if (!allCovered && missingLabels.length > 0) {
    nagSent = await sendNagIfNew(
      ctx, teamMember, weekEnding, missingLabels, messageId,
    );
  }

  // 10. Label + archive
  await labelAndArchive(ctx, messageId, threadId);

  return {
    status: "processed", message_id: messageId, kind,
    team_member_id: teamMember.id, week_ending_date: weekEnding,
    all_complete: allCovered, missing_items: missingLabels, nag_sent: nagSent,
  };
}

// ---------- Helpers ----------

async function loadTeamEmails(agencyId: string): Promise<string[]> {
  const { data, error } = await sb
    .from("team")
    .select("email_sf, email_personal")
    .eq("agency_id", agencyId)
    .eq("category", "agency")
    .eq("is_active", true)
    .is("archived_at", null)
    .eq("is_admin_backoffice", false);
  if (error || !data) return [];
  const out: string[] = [];
  for (const r of data as any[]) {
    if (r.email_sf) out.push((r.email_sf as string).toLowerCase());
    if (r.email_personal) out.push((r.email_personal as string).toLowerCase());
  }
  return out;
}

async function classifyKind(
  subject: string,
  inReplyTo: string,
): Promise<"wrapup" | "cpr_reply" | "nag_reply" | "unclassified"> {
  const subjectLower = (subject || "").toLowerCase();
  // Nag reply MUST be checked FIRST — the subject "Re: [EXTERNAL] Wrap-up
  // follow-up — Name" matches the generic wrap-up regex, but it is a REPLY
  // TO A NAG about a PRIOR week, not a fresh wrap-up for the current week.
  // Routing it as "wrapup" causes timestamp-fallback to land on the wrong
  // Saturday and re-nag for pieces the teammate already covered elsewhere.
  if (/^\s*re:\s*(?:\[external\]\s*)?wrap[\s\-_]?up\s+follow[\s\-_]?up/i.test(subject)) {
    return "nag_reply";
  }
  // Explicit wrap-up subject
  if (/(wrap[\s\-_]?up|wrapup)/i.test(subject)) return "wrapup";
  // CPR reply — by subject
  if (/cpr recap/i.test(subject)) {
    // If it's the original send (not a reply/forward), it originated from us.
    // Classifier here only sees reply/forward (defaultQuery excludes -in:sent).
    return "cpr_reply";
  }
  return "unclassified";
}

function extractEmail(raw: string): string {
  if (!raw) return "";
  const angleMatch = raw.match(/<([^>]+)>/);
  if (angleMatch) return angleMatch[1].trim().toLowerCase();
  const bareMatch = raw.match(/[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}/);
  return bareMatch ? bareMatch[0].toLowerCase() : "";
}

// Parse forwarded-email header for the inner original sender. Looks for a
// "From: Name <email>" line inside the body (Outlook + Gmail conventions).
function parseInnerForwardFrom(body: string): string {
  const lines = body.split(/\r?\n/);
  for (const line of lines) {
    const m = line.match(/^\s*From:\s*(.+?)$/i);
    if (m) {
      const email = extractEmail(m[1]);
      if (email) return email;
    }
  }
  return "";
}

interface TeamMemberLite {
  id: string;
  first_name: string;
  last_name: string;
  email_sf: string;
  email_personal: string;
  role_level: string;
}

async function resolveTeamMemberByEmail(
  agencyId: string,
  email: string,
): Promise<TeamMemberLite | null> {
  const norm = email.trim().toLowerCase();
  const { data, error } = await sb
    .from("team")
    .select("id, first_name, last_name, email_sf, email_personal, role_level, is_active, archived_at, is_admin_backoffice, category")
    .eq("agency_id", agencyId)
    .or(`email_sf.eq.${norm},email_personal.eq.${norm}`)
    .limit(5);
  if (error || !data || data.length === 0) return null;
  // Prefer active, non-admin, agency-category rows
  const active = (data as any[]).find((r) =>
    r.is_active === true &&
    r.archived_at === null &&
    r.is_admin_backoffice === false &&
    r.category === "agency"
  );
  const chosen = active ?? data[0];
  return {
    id: chosen.id,
    first_name: chosen.first_name,
    last_name: chosen.last_name,
    email_sf: chosen.email_sf || "",
    email_personal: chosen.email_personal || "",
    role_level: chosen.role_level || "",
  };
}

// Given an ISO timestamp, returns the Saturday date (YYYY-MM-DD in
// America/Chicago) that the wrap-up email is targeting. Assumes:
//   Fri (idx=5) or Sat (idx=6) → THIS week's Saturday (Sat=today, Fri=+1)
//     Rationale: team writes their wrap-up on Fri afternoon / Sat morning
//     for the week that ends that same Saturday.
//   Sun (idx=0) → last Saturday (yesterday). Wrap-up landing after CPR
//     for the week that just closed.
//   Mon-Thu (idx=1..4) → last Saturday. Late wrap-up covering the
//     just-closed week.
// Parse RFC 2822 date header (e.g. "Fri, 10 Jul 2026 22:19:31 +0000") into
// ISO 8601. Returns "" if unparseable.
function parseDateHeader(headers: any[]): string {
  const dateHeader = headers?.find((h: any) => h?.name === "Date")?.value;
  if (!dateHeader || typeof dateHeader !== "string") return "";
  try {
    const d = new Date(dateHeader);
    if (isNaN(d.getTime())) return "";
    return d.toISOString();
  } catch { return ""; }
}

function wrapupTargetSaturdayCT(receivedAtISO: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    year: "numeric", month: "2-digit", day: "2-digit", weekday: "short",
  }).formatToParts(new Date(receivedAtISO));
  const y = parts.find(p => p.type === "year")!.value;
  const m = parts.find(p => p.type === "month")!.value;
  const d = parts.find(p => p.type === "day")!.value;
  const wd = parts.find(p => p.type === "weekday")!.value;
  const dayIdx: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const idx = dayIdx[wd] ?? 0;
  let daysOffset: number;
  if (idx === 6) daysOffset = 0;                // Sat: today
  else if (idx === 5) daysOffset = 1;           // Fri: +1 (tomorrow's Sat)
  else if (idx === 0) daysOffset = -1;          // Sun: yesterday
  else daysOffset = -(idx + 1);                 // Mon..Thu: back to last Sat
  const base = new Date(`${y}-${m}-${d}T12:00:00Z`);
  base.setUTCDate(base.getUTCDate() + daysOffset);
  return base.toISOString().slice(0, 10);
}

async function resolveWeekEnding(
  agencyId: string,
  kind: "wrapup" | "cpr_reply" | "nag_reply",
  inReplyTo: string,
  receivedAtISO: string,
): Promise<string | null> {
  const cleaned = (inReplyTo || "").replace(/[<>]/g, "").trim();

  // Nag reply: look up the parent nag by its stored RFC Message-ID. That
  // row's week_ending_date IS the week the nag was about. If we cannot
  // resolve it, DO NOT fall through to timestamp math — a nag reply about
  // week 7/11 that lands on 7/22 must not be routed to 7/18 just because
  // it arrived on a Wednesday. Return null → parser skips the message.
  if (kind === "nag_reply") {
    if (!cleaned) return null;
    const { data } = await sb
      .from("wrapup_nag_log")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("nag_message_id_rfc", cleaned)
      .maybeSingle();
    return data?.week_ending_date ?? null;
  }

  // CPR reply: try the new RFC Message-ID column first (canonical going
  // forward), then fall back to the historical gmail_message_id column for
  // pre-fix rows. If BOTH fail, return null rather than mis-routing via
  // timestamp math — same safety principle as nag_reply above.
  if (kind === "cpr_reply") {
    if (!cleaned) return null;
    const { data: rfcRow } = await sb
      .from("weekly_cpr_reports")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("cpr_recap_message_id_rfc", cleaned)
      .maybeSingle();
    if (rfcRow?.week_ending_date) return rfcRow.week_ending_date;
    const { data: gidRow } = await sb
      .from("weekly_cpr_reports")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("gmail_message_id", cleaned)
      .maybeSingle();
    return gidRow?.week_ending_date ?? null;
  }

  // Fresh wrap-up email: timestamp-based Saturday derivation is the default.
  // BUT — if the CPR RECAP for that Saturday has already been sent to the
  // team, the just-closed week is published; a wrap-up landing after that
  // is FOR THE CURRENT IN-PROGRESS WEEK, not a late submission for the
  // closed one. Shift forward one Saturday in that case.
  //
  // Why: teammates who send wrap-ups Mon-Thu (default rule routes back to
  // last Sat) can't be writing for a week whose CPR already went out — the
  // "late wrap-up" interpretation only makes sense while the prior CPR is
  // still in-draft. Once it's sent, the same email must be for this week.
  const baseSat = wrapupTargetSaturdayCT(receivedAtISO);
  const { data: baseCpr } = await sb
    .from("weekly_cpr_reports")
    .select("sent_to_team_at")
    .eq("agency_id", agencyId)
    .eq("week_ending_date", baseSat)
    .maybeSingle();
  if (baseCpr?.sent_to_team_at) {
    const nextSat = new Date(`${baseSat}T12:00:00Z`);
    nextSat.setUTCDate(nextSat.getUTCDate() + 7);
    return nextSat.toISOString().slice(0, 10);
  }
  return baseSat;
}

interface DetailRowLite {
  id: string;
  wrapup_text: string | null;
  wrapup_done: boolean | null;
}

async function ensureDetailRow(
  agencyId: string,
  teamMemberId: string,
  weekEnding: string,
): Promise<DetailRowLite | null> {
  // 1. Look up weekly_cpr_reports row
  const { data: reportRow } = await sb
    .from("weekly_cpr_reports")
    .select("id")
    .eq("agency_id", agencyId)
    .eq("week_ending_date", weekEnding)
    .maybeSingle();
  if (!reportRow?.id) return null;

  // 2. Look up existing detail row
  const { data: existing } = await sb
    .from("weekly_cpr_team_detail")
    .select("id, wrapup_text, wrapup_done")
    .eq("agency_id", agencyId)
    .eq("weekly_cpr_report_id", reportRow.id)
    .eq("team_member_id", teamMemberId)
    .maybeSingle();
  if (existing?.id) return existing as DetailRowLite;

  // No detail row = teammate wasn't populated for that week (compute_outcome
  // hasn't run yet OR they weren't rostered). Skip — we don't create new
  // detail rows here; that's the CPR writer's job.
  return null;
}

// ---------- Nag email ----------

async function sendNagIfNew(
  ctx: WrapupCtx,
  teamMember: TeamMemberLite,
  weekEnding: string,
  missingLabels: string[],
  triggerMessageId: string,
): Promise<boolean> {
  // 1. Compute hash of missing set + look up throttle log
  const hashRes = await sb.rpc("wrapup_missing_items_hash", { p_missing: missingLabels });
  const hash: string = (hashRes.data as string) || "";
  if (!hash) return false;
  const { data: prior } = await sb
    .from("wrapup_nag_log")
    .select("id")
    .eq("agency_id", ctx.agencyId)
    .eq("team_member_id", teamMember.id)
    .eq("week_ending_date", weekEnding)
    .eq("missing_items_hash", hash)
    .maybeSingle();
  if (prior?.id) return false;  // Already nagged for this exact missing set

  // 2. Gather recipient list — all active agency + Peter (SF emails)
  const { data: teamRows } = await sb
    .from("team")
    .select("email_sf")
    .eq("agency_id", ctx.agencyId)
    .eq("category", "agency")
    .eq("is_active", true)
    .is("archived_at", null)
    .eq("is_admin_backoffice", false);
  const recipients = (teamRows || [])
    .map((r: any) => (r.email_sf || "").trim())
    .filter((e: string) => e.length > 0);
  if (recipients.length === 0) return false;

  // 3. Compose email
  const bullets = missingLabels.map((l) => `  • ${l}`).join("\n");
  const subject = `Wrap-up follow-up — ${teamMember.first_name}`;
  const bodyText =
`${teamMember.first_name}, your wrap-up for the week ending ${weekEnding} is looking good but the following required pieces still haven't landed:

${bullets}

Reply-all with those pieces when you get a chance — every complete wrap-up keeps the team's shared read of the week honest.

Rubric refresher (Weekly wrap-up email section of the Daily Wrap-up manual):
  1. Personal life & annuity status updates
  2. Lapse/cancel trends + individual highlights
  3. Personal obstacles + solutions
  4. Plan for a 1% increase in sales points next week
  5. Efficiency / pain-point recommendation
  6. Brags on teammates

— Newtworks (auto-sent — this fires when a wrap-up lands with pieces missing so we can catch it in the same week)
`;

  // 4. Send
  const sendRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolArguments: {
      recipient_email: recipients[0],
      cc: recipients.slice(1),
      subject,
      body: bodyText,
      is_html: false,
      user_id: "me",
    },
  });
  if (!sendRes.ok) {
    console.warn(`wrapup nag send failed for ${teamMember.first_name}: ${sendRes.error}`);
    return false;
  }

  // 5. Capture Gmail internal id AND RFC-2822 Message-ID (headers) from the
  //    send. The RFC id is what teammates' reply clients put in In-Reply-To,
  //    so storing it enables reliable reply-to-week routing on the next
  //    ingest run. Gmail's send-response body typically does NOT include
  //    the RFC id, so we do a follow-up metadata fetch on the sent message.
  const sentGmailId: string | null =
    sendRes.data?.id ?? sendRes.data?.messageId ?? sendRes.data?.response_data?.id ?? null;
  let rfcMsgId: string | null = null;
  if (sentGmailId) {
    try {
      const metaRes = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
        toolArguments: {
          message_id: sentGmailId,
          format: "metadata",
          user_id: "me",
        },
      });
      if (metaRes.ok) {
        const meta: any = metaRes.data?.response_data ?? metaRes.data ?? {};
        const headers: any[] = meta?.payload?.headers ?? [];
        const raw = headers.find((h: any) =>
          h?.name === "Message-ID" || h?.name === "Message-Id" || h?.name === "message-id"
        )?.value;
        if (raw && typeof raw === "string") {
          rfcMsgId = raw.replace(/[<>]/g, "").trim() || null;
        }
      }
    } catch (e) {
      console.warn("wrapup nag RFC Message-ID capture failed (non-fatal):", e);
    }
  }
  await sb.from("wrapup_nag_log").insert({
    agency_id: ctx.agencyId,
    team_member_id: teamMember.id,
    week_ending_date: weekEnding,
    missing_items_hash: hash,
    missing_items: missingLabels,
    gmail_message_id: sentGmailId,
    nag_message_id_rfc: rfcMsgId,
    trigger_email_id: triggerMessageId,
  });
  return true;
}

// ---------- Label + archive ----------

// Apply the Wrapups label + remove INBOX at the MESSAGE level (not thread
// level). CPR reply threads contain multiple replies from different
// teammates; thread-level labeling would archive/hide siblings that still
// Label the incoming Gmail message with our "Wrapups" label + remove from
// INBOX. Both signals so future wrapup ingest runs know these messages don't
// need to be processed. This uses GMAIL_ADD_LABEL_TO_EMAIL which only
// touches the one message.
async function labelAndArchive(
  ctx: WrapupCtx,
  messageId: string,
  _threadId: string | undefined,
): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: {
        message_id: messageId,
        remove_label_ids: ["INBOX"],
        add_label_ids: [WRAPUPS_LABEL_ID],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn("wrapup label+archive threw (non-fatal):", e);
  }
}

// ---------- Body extraction ----------

function wupExtractBestBody(msg: any): string {
  const direct: string | undefined =
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
  if (typeof direct === "string" && direct.trim().length > 20) return direct;

  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const plain = wupFindPart(parts, "text/plain");
  if (plain) {
    const decoded = wupDecodeBase64Url(plain?.body?.data ?? "");
    if (decoded && decoded.trim().length > 20) return decoded;
  }
  const html = wupFindPart(parts, "text/html");
  if (html) {
    const decoded = wupDecodeBase64Url(html?.body?.data ?? "");
    if (decoded) return wupStripHtml(decoded);
  }
  const bodyDirect = wupDecodeBase64Url(msg?.payload?.body?.data ?? "");
  if (bodyDirect && bodyDirect.trim().length > 20) return bodyDirect;
  return "";
}

function wupFindPart(parts: any[], mimeType: string): any {
  for (const p of parts) {
    if (p?.mimeType === mimeType) return p;
    if (p?.parts) {
      const nested = wupFindPart(p.parts, mimeType);
      if (nested) return nested;
    }
  }
  return null;
}

function wupDecodeBase64Url(s: string): string {
  if (!s) return "";
  try {
    const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - b64.length % 4) % 4);
    return atob(padded);
  } catch {
    return "";
  }
}

function wupStripHtml(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, "")
    .replace(/<script[\s\S]*?<\/script>/gi, "")
    .replace(/<\/(p|div|br|li|tr|h[1-6])>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
