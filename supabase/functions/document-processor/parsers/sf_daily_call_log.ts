// =========================================================================
// parsers/sf_daily_call_log.ts
// =========================================================================
// eGain "Extension Activity" HTML daily call log parser.
//
// Consolidated 2026-07-08 (v39) from the standalone `call-log-parser` edge
// function. Invoked by document-processor when the request body contains
// `mode: "call_log"` — bypasses the standard attachment intake pipeline
// because call log emails carry HTML attachments matched by filename,
// not by classifyDocument().
//
// Source: peter.story.yrru@statefarm.com forwards reports@egain.cloud emails.
// Format is stable. Deterministic HTML parse — no LLM.
//
// Flow:
//   1. GMAIL_FETCH_EMAILS with scoped call-log query (default: unstarred)
//   2. For each unprocessed message:
//        a. GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID (full) to get attachments
//        b. GMAIL_GET_ATTACHMENT on "Extension Activity.htm" (s3url)
//        c. Fetch HTML, parse extension blocks + 12 metrics
//        d. Map extension code (6-char SF VA...) -> team.email_sf -> team_member_id
//        e. Upsert daily_call_activity rows
//        f. Star the Gmail message (idempotency marker)
//        g. Archive the Gmail thread (remove INBOX label)
//   3. Return summary { ok, processed_messages, rows_upserted, skipped, errors, ... }
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import { sb } from "../lib/supabase.ts";
import { callComposio } from "../lib/composio.ts";

interface CallLogBody {
  agency_id?: string;
  shared_secret?: string;
  mode?: string;
  gmail_query?: string;
  max_results?: number;
}

interface CallLogCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}

interface Metrics {
  inbound_calls_external: number;
  inbound_talk_time_seconds: number;
  inbound_calls_internal: number;
  inbound_talk_time_internal_s: number;
  answered_calls_external: number;
  abandoned_calls_external: number;
  transferred_calls_external: number;
  voicemail_calls_external: number;
  outbound_calls_external: number;
  outbound_talk_time_seconds: number;
  outbound_calls_internal: number;
  outbound_talk_time_internal_s: number;
}

interface ExtensionRow {
  extension_raw: string;
  metrics: Metrics;
}

interface ParsedReport {
  activity_date: string; // YYYY-MM-DD (CT)
  rows: ExtensionRow[];
}

// ---------- HTML parsing (deterministic, stable eGain format) ----------

function hmsToSeconds(hms: string): number {
  const m = hms.trim().match(/^(\d+):(\d{2}):(\d{2})$/);
  if (!m) return 0;
  return parseInt(m[1], 10) * 3600 + parseInt(m[2], 10) * 60 + parseInt(m[3], 10);
}

function toCells(html: string): string[] {
  let t = html.replace(/<\/TR>/gi, "\n").replace(/<\/TD>/gi, "\t");
  t = t.replace(/<[^>]+>/g, "");
  t = t.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&");
  const cells: string[] = [];
  for (const line of t.split("\n")) {
    for (const c of line.split("\t")) {
      const s = c.trim();
      if (s) cells.push(s);
    }
  }
  return cells;
}

export function parseCallLogReport(html: string): ParsedReport {
  const cells = toCells(html);

  // 1. Activity date: "Data From M/D/YYYY 12:00:00 AM To M/D/YYYY 11:59:59 PM"
  let activityDate = "";
  for (const c of cells) {
    const m = c.match(/Data From\s+(\d{1,2})\/(\d{1,2})\/(\d{4})/i);
    if (m) {
      const mm = String(parseInt(m[1], 10)).padStart(2, "0");
      const dd = String(parseInt(m[2], 10)).padStart(2, "0");
      activityDate = `${m[3]}-${mm}-${dd}`;
      break;
    }
  }
  if (!activityDate) throw new Error("Could not find activity date in report");

  // 2. Header row index (first row containing "Inbound Calls (External)")
  let headerIdx = -1;
  for (let i = 0; i < cells.length; i++) {
    if (/Inbound Calls \(External\)/i.test(cells[i])) { headerIdx = i; break; }
  }
  if (headerIdx < 0) throw new Error("Could not find column headers");

  // 3. Walk cells after header. Each extension section:
  //    "<Extension_Name>" then "Extension Description Total:" then 12 metric values.
  //    Terminator: "Report Total:" or "Run by:".
  const rows: ExtensionRow[] = [];
  let i = headerIdx + 1;
  while (i < cells.length && !/^(Report Total:|Run by:)/i.test(cells[i])) {
    if (/^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+$/.test(cells[i]) ||
        cells[i] === "Not Applicable") {
      const extName = cells[i];
      i++;
      if (i < cells.length && /Extension Description Total:/i.test(cells[i])) i++;
      if (i + 12 > cells.length) break;
      const vals = cells.slice(i, i + 12);
      i += 12;

      const num = (s: string) => parseInt(s.replace(/[^\d-]/g, ""), 10) || 0;
      const metrics: Metrics = {
        inbound_calls_external:        num(vals[0]),
        inbound_talk_time_seconds:     hmsToSeconds(vals[1]),
        inbound_calls_internal:        num(vals[2]),
        inbound_talk_time_internal_s:  hmsToSeconds(vals[3]),
        answered_calls_external:       num(vals[4]),
        abandoned_calls_external:      num(vals[5]),
        transferred_calls_external:    num(vals[6]),
        voicemail_calls_external:      num(vals[7]),
        outbound_calls_external:       num(vals[8]),
        outbound_talk_time_seconds:    hmsToSeconds(vals[9]),
        outbound_calls_internal:       num(vals[10]),
        outbound_talk_time_internal_s: hmsToSeconds(vals[11]),
      };
      rows.push({ extension_raw: extName, metrics });
    } else {
      i++;
    }
  }

  return { activity_date: activityDate, rows };
}

// ---------- Extension -> team member mapping ----------
// Extension name format: "First_Last_VAXXXX" (last segment is the 6-char SF
// code that also appears in team.email_sf like "first.last.vaxxxx@statefarm.com").
async function mapExtension(agencyId: string, extensionRaw: string): Promise<string | null> {
  if (extensionRaw === "Not Applicable") return null;
  const parts = extensionRaw.split("_");
  const code = parts[parts.length - 1];
  if (!/^[A-Za-z0-9]{4,8}$/.test(code)) return null;
  const codeLower = code.toLowerCase();
  const { data, error } = await sb
    .from("team")
    .select("id, email_sf")
    .eq("agency_id", agencyId)
    .not("email_sf", "is", null)
    .ilike("email_sf", `%.${codeLower}@%`);
  if (error) return null;
  if (!data || data.length === 0) return null;
  return data[0].id;
}

// ---------- Per-message handler ----------

async function processMessage(
  ctx: CallLogCtx,
  messageId: string,
): Promise<{ status: string; date?: string; rowsUpserted?: number; error?: string }> {
  // 1. Get full message with attachments
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: { message_id: messageId, format: "full", user_id: "me" },
  });
  if (!msgRes.ok) return { status: "error", error: `GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID: ${msgRes.error}` };
  const msg: any = msgRes.data;

  const attList = msg?.response_data?.attachmentList ?? msg?.attachmentList ?? msg?.attachments ?? [];
  const htmlAtt = attList.find((a: any) =>
    /Extension Activity\.htm/i.test(a.filename ?? "") ||
    (a.filename ?? "").toLowerCase().endsWith(".htm")
  );
  if (!htmlAtt) return { status: "skipped", error: "no Extension Activity.htm attachment" };

  // 2. Download attachment (returns presigned s3 URL)
  const attRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: messageId,
      attachment_id: htmlAtt.attachmentId,
      file_name: htmlAtt.filename ?? "Extension Activity.htm",
      user_id: "me",
    },
  });
  if (!attRes.ok) return { status: "error", error: `GMAIL_GET_ATTACHMENT: ${attRes.error}` };
  const att: any = attRes.data;

  const s3url = att?.file?.s3url ?? att?.data?.file?.s3url;
  if (!s3url) return { status: "error", error: "no s3url from GMAIL_GET_ATTACHMENT" };

  const htmlFetch = await fetch(s3url);
  if (!htmlFetch.ok) return { status: "error", error: `s3 fetch ${htmlFetch.status}` };
  const html = await htmlFetch.text();

  // 3. Parse HTML
  let parsed: ParsedReport;
  try { parsed = parseCallLogReport(html); }
  catch (e) { return { status: "error", error: `parse: ${e instanceof Error ? e.message : String(e)}` }; }

  // 4. Map + upsert
  let upserted = 0;
  for (const row of parsed.rows) {
    const teamMemberId = await mapExtension(ctx.agencyId, row.extension_raw);
    const record = {
      agency_id: ctx.agencyId,
      team_member_id: teamMemberId,
      activity_date: parsed.activity_date,
      extension_raw: row.extension_raw,
      ...row.metrics,
      source_gmail_message_id: messageId,
      updated_at: new Date().toISOString(),
    };
    const { error } = await sb
      .from("daily_call_activity")
      .upsert(record, { onConflict: "agency_id,extension_raw,activity_date" });
    if (error) {
      console.error(`upsert failed for ${row.extension_raw}: ${error.message}`);
      continue;
    }
    upserted++;
  }

  // 5. Star the message (idempotency marker — subsequent runs skip via query)
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: { message_id: messageId, add_label_ids: ["STARRED"], user_id: "me" },
    });
  } catch (e) {
    console.warn("star failed (non-fatal):", e);
  }

  // 6. Archive the thread (remove INBOX label). Mirrors maybeArchiveThread()
  //    in index.ts — every successfully-processed doc gets its Gmail thread
  //    off Peter's inbox. Non-fatal on failure so the DB upsert still counts.
  const threadId: string | null =
    msg?.threadId ?? msg?.thread_id ?? msg?.response_data?.threadId ?? null;
  if (threadId) {
    try {
      const archiveRes = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
        toolArguments: {
          thread_id: threadId,
          remove_label_ids: ["INBOX"],
          add_label_ids: ["Label_29"], // "Call Logs"
          user_id: "me",
        },
      });
      if (!archiveRes.ok) {
        console.warn(`call_log archive (remove INBOX) failed: ${archiveRes.error}`);
      }
    } catch (e) {
      console.warn("call_log archive threw (non-fatal):", e);
    }
  } else {
    console.warn(`call_log archive skipped: no threadId on message ${messageId}`);
  }

  return { status: "processed", date: parsed.activity_date, rowsUpserted: upserted };
}

// ---------- Mode entry point (called from index.ts when body.mode === "call_log") ----------

export async function processCallLogMode(
  ctx: CallLogCtx,
  body: CallLogBody,
): Promise<{
  ok: boolean;
  processed_messages: number;
  rows_upserted: number;
  skipped: number;
  errors: number;
  message_count: number;
  results: any[];
  error?: string;
}> {
  const query = body.gmail_query ??
    `from:reports@egain.cloud OR (from:statefarm.com subject:"Daily Call Log") -label:starred newer_than:3d has:attachment`;
  const maxResults = body.max_results ?? 10;

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
    return {
      ok: false,
      processed_messages: 0, rows_upserted: 0, skipped: 0, errors: 1, message_count: 0,
      results: [],
      error: `gmail fetch: ${listRes.error}`,
    };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: any[] = [];
  let rowsUpserted = 0;
  let processed = 0;
  let skipped = 0;
  let errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processMessage(ctx, msgId);
      results.push({ message_id: msgId, ...r });
      if (r.status === "processed") {
        processed++;
        rowsUpserted += r.rowsUpserted ?? 0;
      } else if (r.status === "skipped") {
        skipped++;
      } else {
        errors++;
      }
    } catch (e) {
      errors++;
      results.push({ message_id: msgId, status: "error", error: e instanceof Error ? e.message : String(e) });
    }
  }

  return {
    ok: true,
    processed_messages: processed,
    rows_upserted: rowsUpserted,
    skipped,
    errors,
    message_count: messages.length,
    results,
  };
}
