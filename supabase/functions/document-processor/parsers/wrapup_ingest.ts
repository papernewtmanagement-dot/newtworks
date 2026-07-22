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
//   2. Classify as "wrapup" (subject wrap-up) or "cpr_reply" (In-Reply-To
//      matches weekly_cpr_reports.gmail_message_id OR subject "CPR RECAP —
//      WEEK OF …"). Anything else → skip + label.
//   3. Resolve sender team_member (handles Fw: forwarding by parsing the
//      first inner "From:" line when the outer sender is us).
//   4. Resolve week_ending_date (Saturday) from In-Reply-To parent CPR
//      row, else nearest past Saturday from received timestamp.
//   5. Pull existing wrapup_text + the six-item rubric from
//      get_wrapup_checklist_text().
//   6. LLM merges new email into current text, organized under the six
//      required sections; returns coverage[6] + missing_item_labels[].
//   7. Write organized text back; flip wrapup_done if all six covered.
//   8. If missing items and same missing-set hasn't been nagged this week,
//      send public nag email (whole team including Peter) + log.
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
  kind: "wrapup" | "cpr_reply" | "unclassified";
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
3. If a category has NO content across current text + new email, keep the header and write "(none reported)" underneath.
4. If the new email adds material to a category that already had content, integrate (append if new, do not duplicate if a paraphrase of what's already there). Do NOT lose prior content.
5. Do NOT add signatures, disclaimers, closing lines, or content outside the six categories.
6. Do NOT include email metadata (dates, subjects, greetings) unless the content is materially useful.
7. Strip email signatures ("Thanks for trusting Peter Story State Farm…", block contact info, forwarded header stubs, etc.) from the source before folding in.
8. Preserve customer first names + last initials as written (e.g. "Delia C.") — cancellation stories often reference customers by name.

RULES for coverage:
- item_1 covered ONLY if content mentions personal book status, pending applications, upcoming reviews, or similar concrete book-status detail. "(none reported)" does NOT count.
- item_2 covered ONLY if content names specific cancellations, lapses, trends, OR individual wins (with names/context).
- item_3 covered ONLY if the sender describes an obstacle AND proposes a solution. Naming an obstacle alone is insufficient.
- item_4 covered ONLY if the sender describes a concrete plan for next week (activities, focus areas, changes to approach). Vague intent alone is insufficient.
- item_5 covered ONLY if the sender proposes an efficiency or pain-point recommendation for the whole team.
- item_6 covered ONLY if the sender brags on ONE OR MORE teammates by name with a specific action or attribute (not generic "great team!").

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
  const internalDateMs = msg?.internalDate ? Number(msg.internalDate) : Date.now();
  const receivedAtISO: string = new Date(internalDateMs).toISOString();
  const threadId: string | undefined = msg?.threadId ?? msg?.thread_id;

  const bodyText = extractBestBody(msg);
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
  const kind: "wrapup" | "cpr_reply" | "unclassified" = await classifyKind(subject, inReplyTo);
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
): Promise<"wrapup" | "cpr_reply" | "unclassified"> {
  const subjectLower = (subject || "").toLowerCase();
  // Explicit wrap-up subject
  if (/(wrap[\s\-_]?up|wrapup)/i.test(subject)) return "wrapup";
  // CPR reply — by subject
  if (/cpr recap/i.test(subject)) {
    // If it's the original send (not a reply/forward), it originated from us.
    // Classifier here only sees reply/forward (defaultQuery excludes -in:sent).
    return "cpr_reply";
  }
  // CPR reply — by In-Reply-To header pointing at a known CPR send
  if (inReplyTo) {
    const cleaned = inReplyTo.replace(/[<>]/g, "").trim();
    // In-Reply-To is an RFC 2822 Message-ID (e.g. <CADef...@mail.gmail.com>).
    // Gmail's internal message id (used by weekly_cpr_reports.gmail_message_id)
    // is different — but we can look up by internal id via a separate fetch
    // if needed. For now, subject-based match is sufficient (CPR replies
    // almost always carry the CPR RECAP subject).
    if (cleaned.length > 0) {
      // no-op — subject check above handles the primary path
    }
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

// Nearest past Saturday (inclusive) from an ISO timestamp, evaluated in
// America/Chicago (agency week convention: Sun-Sat).
function nearestPastSaturdayCT(receivedAtISO: string): string {
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
  const daysToSubtract = idx === 6 ? 0 : (idx + 1);  // Sat=0, Sun=1 back to prior Sat, Mon=2, etc.
  const base = new Date(`${y}-${m}-${d}T12:00:00Z`);
  base.setUTCDate(base.getUTCDate() - daysToSubtract);
  return base.toISOString().slice(0, 10);
}

async function resolveWeekEnding(
  agencyId: string,
  kind: "wrapup" | "cpr_reply",
  inReplyTo: string,
  receivedAtISO: string,
): Promise<string | null> {
  if (kind === "cpr_reply" && inReplyTo) {
    const cleaned = inReplyTo.replace(/[<>]/g, "").trim();
    // Try direct match (Gmail sometimes uses its own internal id in In-Reply-To)
    const { data } = await sb
      .from("weekly_cpr_reports")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("gmail_message_id", cleaned)
      .maybeSingle();
    if (data?.week_ending_date) return data.week_ending_date;
  }
  return nearestPastSaturdayCT(receivedAtISO);
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

  // 5. Log to throttle table (raw send id may be in response)
  const sentGmailId: string | null =
    sendRes.data?.id ?? sendRes.data?.messageId ?? sendRes.data?.response_data?.id ?? null;
  await sb.from("wrapup_nag_log").insert({
    agency_id: ctx.agencyId,
    team_member_id: teamMember.id,
    week_ending_date: weekEnding,
    missing_items_hash: hash,
    missing_items: missingLabels,
    gmail_message_id: sentGmailId,
    trigger_email_id: triggerMessageId,
  });
  return true;
}

// ---------- Label + archive ----------

async function labelAndArchive(
  ctx: WrapupCtx,
  messageId: string,
  threadId: string | undefined,
): Promise<void> {
  try {
    if (threadId) {
      await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
        toolArguments: {
          thread_id: threadId,
          remove_label_ids: ["INBOX"],
          add_label_ids: [WRAPUPS_LABEL_ID],
          user_id: "me",
        },
      });
    } else {
      await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
        toolArguments: {
          message_id: messageId,
          label_ids: [WRAPUPS_LABEL_ID],
          user_id: "me",
        },
      });
    }
  } catch (e) {
    console.warn("wrapup label+archive threw (non-fatal):", e);
  }
}

// ---------- Body extraction ----------

function extractBestBody(msg: any): string {
  const direct: string | undefined =
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
  if (typeof direct === "string" && direct.trim().length > 20) return direct;

  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const plain = findPart(parts, "text/plain");
  if (plain) {
    const decoded = decodeBase64Url(plain?.body?.data ?? "");
    if (decoded && decoded.trim().length > 20) return decoded;
  }
  const html = findPart(parts, "text/html");
  if (html) {
    const decoded = decodeBase64Url(html?.body?.data ?? "");
    if (decoded) return stripHtml(decoded);
  }
  const bodyDirect = decodeBase64Url(msg?.payload?.body?.data ?? "");
  if (bodyDirect && bodyDirect.trim().length > 20) return bodyDirect;
  return "";
}

function findPart(parts: any[], mimeType: string): any {
  for (const p of parts) {
    if (p?.mimeType === mimeType) return p;
    if (p?.parts) {
      const nested = findPart(p.parts, mimeType);
      if (nested) return nested;
    }
  }
  return null;
}

function decodeBase64Url(s: string): string {
  if (!s) return "";
  try {
    const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - b64.length % 4) % 4);
    return atob(padded);
  } catch {
    return "";
  }
}

function stripHtml(html: string): string {
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
