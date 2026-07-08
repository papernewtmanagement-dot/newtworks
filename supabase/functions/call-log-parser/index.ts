// =========================================================================
// call-log-parser / index.ts
// =========================================================================
// Parses eGain "Extension Activity" HTML attachments forwarded from
// peter.story.yrru@statefarm.com (forwarded from reports@egain.cloud).
//
// Format is stable. Deterministic HTML parse — no LLM.
//
// Flow:
//   1. GMAIL_FETCH_EMAILS (scoped query for daily call log emails)
//   2. For each unprocessed message:
//        a. GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID (full) to get attachments
//        b. GMAIL_GET_ATTACHMENT on the "Extension Activity.htm" attachment
//        c. Fetch HTML from S3 URL
//        d. Parse extension blocks + 12 metrics
//        e. Map extension code (6-char VA…) → team.email_sf → team_member_id
//        f. Upsert daily_call_activity rows
//        g. Star the Gmail message (idempotency marker)
//   3. Return { ok, processed_messages, rows_upserted, skipped, errors }
//
// Auth: verify_jwt=false; POST body must include shared_secret.
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const AGENCY_ID_FALLBACK = "126794dd-25ff-47d2-a436-724499733365";

interface RunBody {
  agency_id?: string;
  shared_secret?: string;
  gmail_query?: string;
  max_results?: number;
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
  activity_date: string;
  rows: ExtensionRow[];
}

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data, error } = await sb.from("settings").select("setting_value")
    .eq("agency_id", agencyId).eq("setting_key", key).maybeSingle();
  if (error) throw new Error(`settings ${key}: ${error.message}`);
  return data?.setting_value ?? null;
}

async function callComposio(apiKey: string, userId: string, toolSlug: string,
  args: Record<string, unknown>, connectedAccountId?: string): Promise<any> {
  const body: Record<string, unknown> = { user_id: userId, arguments: args };
  if (connectedAccountId) body.connected_account_id = connectedAccountId;
  const res = await fetch(`https://backend.composio.dev/api/v3/tools/execute/${toolSlug}`, {
    method: "POST",
    headers: { "x-api-key": apiKey, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok || j.successful === false) {
    throw new Error(`Composio ${toolSlug}: ${j.error ?? res.status}`);
  }
  return j.data ?? j;
}

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

function parseReport(html: string): ParsedReport {
  const cells = toCells(html);
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

  let headerIdx = -1;
  for (let i = 0; i < cells.length; i++) {
    if (/Inbound Calls \(External\)/i.test(cells[i])) { headerIdx = i; break; }
  }
  if (headerIdx < 0) throw new Error("Could not find column headers");

  const rows: ExtensionRow[] = [];
  let i = headerIdx + 1;
  const isTerminator = (s: string) => /^(Report Total:|Run by:|Data From)/i.test(s);
  const isExtensionName = (s: string) =>
    /^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+$/.test(s) || s === "Not Applicable";

  while (i < cells.length && !isTerminator(cells[i])) {
    if (isExtensionName(cells[i])) {
      const extName = cells[i];
      i++;
      if (i < cells.length && /Extension Description Total:/i.test(cells[i])) i++;
      if (i + 12 > cells.length) break;
      const vals = cells.slice(i, i + 12);
      i += 12;
      const num = (s: string) => parseInt(s.replace(/[^\d-]/g, ""), 10) || 0;
      rows.push({
        extension_raw: extName,
        metrics: {
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
        }
      });
    } else {
      i++;
    }
  }
  return { activity_date: activityDate, rows };
}

async function mapExtension(agencyId: string, extensionRaw: string): Promise<string | null> {
  if (extensionRaw === "Not Applicable") return null;
  const parts = extensionRaw.split("_");
  const code = parts[parts.length - 1];
  if (!/^[A-Za-z0-9]{4,8}$/.test(code)) return null;
  const codeLower = code.toLowerCase();
  const { data, error } = await sb.from("team").select("id, email_sf")
    .eq("agency_id", agencyId).not("email_sf", "is", null)
    .ilike("email_sf", `%.${codeLower}@%`);
  if (error || !data || data.length === 0) return null;
  return data[0].id;
}

async function processMessage(agencyId: string, apiKey: string, userId: string,
  gmailAccountId: string, messageId: string) {
  const msg = await callComposio(apiKey, userId, "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", {
    message_id: messageId, format: "full", user_id: "me",
  }, gmailAccountId);
  const attList = msg?.response_data?.attachmentList ?? msg?.attachmentList ?? [];
  const htmlAtt = attList.find((a: any) =>
    /Extension Activity\.htm/i.test(a.filename ?? "") ||
    (a.filename ?? "").toLowerCase().endsWith(".htm"));
  if (!htmlAtt) return { status: "skipped", error: "no Extension Activity.htm attachment" };

  const att = await callComposio(apiKey, userId, "GMAIL_GET_ATTACHMENT", {
    message_id: messageId, attachment_id: htmlAtt.attachmentId,
    file_name: htmlAtt.filename ?? "Extension Activity.htm", user_id: "me",
  }, gmailAccountId);
  const s3url = att?.file?.s3url;
  if (!s3url) return { status: "error", error: "no s3url from GMAIL_GET_ATTACHMENT" };

  const htmlRes = await fetch(s3url);
  if (!htmlRes.ok) return { status: "error", error: `s3 fetch ${htmlRes.status}` };
  const html = await htmlRes.text();

  let parsed;
  try { parsed = parseReport(html); }
  catch (e) { return { status: "error", error: `parse: ${e instanceof Error ? e.message : String(e)}` }; }

  let upserted = 0;
  for (const row of parsed.rows) {
    const teamMemberId = await mapExtension(agencyId, row.extension_raw);
    const record = {
      agency_id: agencyId,
      team_member_id: teamMemberId,
      activity_date: parsed.activity_date,
      extension_raw: row.extension_raw,
      ...row.metrics,
      source_gmail_message_id: messageId,
      updated_at: new Date().toISOString(),
    };
    const { error } = await sb.from("daily_call_activity")
      .upsert(record, { onConflict: "agency_id,extension_raw,activity_date" });
    if (error) { console.error(`upsert failed ${row.extension_raw}: ${error.message}`); continue; }
    upserted++;
  }

  try {
    await callComposio(apiKey, userId, "GMAIL_ADD_LABEL_TO_EMAIL", {
      message_id: messageId, label_ids: ["STARRED"], user_id: "me",
    }, gmailAccountId);
  } catch (e) { console.warn("star failed:", e); }

  return { status: "processed", date: parsed.activity_date, rowsUpserted: upserted };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "method not allowed" }), { status: 405 });
  let body: RunBody;
  try { body = await req.json(); } catch { return new Response(JSON.stringify({ error: "invalid JSON" }), { status: 400 }); }

  const agencyId = body.agency_id ?? AGENCY_ID_FALLBACK;
  const expectedSecret = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expectedSecret || body.shared_secret !== expectedSecret) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401 });
  }

  const composioApiKey = await getSetting(agencyId, "composio_api_key");
  const composioUserId = await getSetting(agencyId, "composio_user_id");
  const gmailAccountId = await getSetting(agencyId, "composio_gmail_account_id");
  if (!composioApiKey || !composioUserId || !gmailAccountId) {
    return new Response(JSON.stringify({ error: "missing composio settings" }), { status: 500 });
  }

  const query = body.gmail_query ??
    `from:reports@egain.cloud OR (from:statefarm.com subject:"Daily Call Log") -label:starred newer_than:3d has:attachment`;
  const maxResults = body.max_results ?? 10;

  let list;
  try {
    list = await callComposio(composioApiKey, composioUserId, "GMAIL_FETCH_EMAILS", {
      query, max_results: maxResults, user_id: "me", include_payload: false, verbose: false,
    }, gmailAccountId);
  } catch (e) {
    return new Response(JSON.stringify({ error: `gmail fetch: ${e instanceof Error ? e.message : String(e)}` }), { status: 500 });
  }

  const messages = list?.messages ?? list?.response_data?.messages ?? [];
  const results = [];
  let rowsUpserted = 0, processed = 0, skipped = 0, errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processMessage(agencyId, composioApiKey, composioUserId, gmailAccountId, msgId);
      results.push({ message_id: msgId, ...r });
      if (r.status === "processed") { processed++; rowsUpserted += r.rowsUpserted ?? 0; }
      else if (r.status === "skipped") skipped++;
      else errors++;
    } catch (e) {
      errors++;
      results.push({ message_id: msgId, status: "error", error: e instanceof Error ? e.message : String(e) });
    }
  }

  return new Response(JSON.stringify({
    ok: true, processed_messages: processed, rows_upserted: rowsUpserted,
    skipped, errors, message_count: messages.length, results,
  }), { status: 200, headers: { "content-type": "application/json" } });
});
