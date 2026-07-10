// =========================================================================
// automation-runner  (BCC Master Template)
// =========================================================================
// v42 (2026-07-10): pg_net polling architecture retired again per the
// 2026-06-19 rule. INTERNAL branch splits on internal_handler prefix:
//   dispatch_<name>  -> direct fetch to /functions/v1/<name>
//   otherwise        -> run_internal_recipe RPC (pure-SQL, synchronous)
// Neither branch touches pg_net. See op-rule "Newtworks dispatch_* recipe
// convention" and op-rule "PostgREST cannot reliably read net._http_response".
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";
const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";

async function getDefaultModel(agencyId: string): Promise<string> {
  try { const v = await getSetting(agencyId, "groq_model_default"); return (v && v.trim()) || LLM_MODEL_FALLBACK; }
  catch (_e) { return LLM_MODEL_FALLBACK; }
}

async function sleep(ms: number): Promise<void> { return new Promise((r) => setTimeout(r, ms)); }

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data, error } = await sb.from("settings").select("setting_value").eq("agency_id", agencyId).eq("setting_key", key).maybeSingle();
  if (error) throw new Error(`settings read failed for agency ${agencyId} key ${key}: ${error.message}`);
  return data?.setting_value ?? null;
}

async function telegram(agencyId: string | null, text: string): Promise<void> {
  if (!agencyId) return;
  const botToken = await getSetting(agencyId, "telegram_bot_token");
  const chatId = await getSetting(agencyId, "telegram_chat_id");
  if (!botToken || !chatId) return;
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: true }),
    });
  } catch (_e) { /* non-fatal */ }
}

function jsonResponse(body: any, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), { status, headers: { "Content-Type": "application/json" } });
}

async function callComposio(opts: { apiKey: string; userId: string; connectedAccountId: string; toolSlug: string; toolArguments: Record<string, any>; }): Promise<{ ok: boolean; data: any; error: string | null; httpStatus: number }> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST", headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: opts.userId, connected_account_id: opts.connectedAccountId, arguments: opts.toolArguments }),
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok ? null : (parsed?.error?.message || parsed?.error || text.slice(0, 400));
  return { ok, data, error, httpStatus: res.status };
}

async function callGroqLLM(opts: { agencyId: string; groqApiKey: string; systemPrompt: string; userContent: string; model?: string; maxTokens?: number; }): Promise<{ ok: boolean; data: any; error: string | null }> {
  const model = opts.model ?? await getDefaultModel(opts.agencyId);
  const body = { model, messages: [{ role: "system", content: opts.systemPrompt }, { role: "user", content: opts.userContent }], temperature: 0, max_tokens: opts.maxTokens ?? 4096, response_format: { type: "json_object" } };
  let lastErr = "unknown";
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(GROQ_API_URL, { method: "POST", headers: { "Authorization": `Bearer ${opts.groqApiKey}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
    if ((res.status === 429 || res.status >= 500) && attempt < 2) { await sleep(500 * Math.pow(2, attempt)); continue; }
    const text = await res.text();
    let parsed: any = {};
    try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
    if (!res.ok) { lastErr = parsed?.error?.message || parsed?.error?.code || text.slice(0, 400); return { ok: false, data: null, error: `Groq HTTP ${res.status}: ${lastErr}` }; }
    const content = parsed?.choices?.[0]?.message?.content;
    if (!content) return { ok: false, data: null, error: "Groq returned empty content" };
    let extracted: any;
    try { extracted = JSON.parse(content); } catch (e) { return { ok: false, data: null, error: `Groq response not valid JSON: ${(e as Error).message}` }; }
    return { ok: true, data: extracted, error: null };
  }
  return { ok: false, data: null, error: `Groq exhausted retries: ${lastErr}` };
}

function decodeBase64Url(s: string): string {
  if (!s) return "";
  let n = s.replace(/-/g, "+").replace(/_/g, "/");
  while (n.length % 4 !== 0) n += "=";
  try { const bytes = Uint8Array.from(atob(n), (c) => c.charCodeAt(0)); return new TextDecoder("utf-8").decode(bytes); }
  catch { return ""; }
}

function findGmailPlainTextBody(payload: any): string {
  if (!payload) return "";
  if (payload.body?.data && (!payload.parts || payload.parts.length === 0)) {
    const d = decodeBase64Url(payload.body.data);
    if (/<[a-z][^>]*>/i.test(d)) return d.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
    return d;
  }
  const parts = payload.parts ?? [];
  const plain = parts.find((p: any) => p.mimeType === "text/plain");
  if (plain?.body?.data) return decodeBase64Url(plain.body.data);
  for (const p of parts) { if (p.parts) { const n = findGmailPlainTextBody(p); if (n) return n; } }
  const html = parts.find((p: any) => p.mimeType === "text/html");
  if (html?.body?.data) { const raw = decodeBase64Url(html.body.data); return raw.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<script[\s\S]*?<\/script>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim(); }
  return "";
}

function stripParenthesizedUrls(text: string): string { if (!text) return ""; return text.replace(/\s*\(\s*https?:\/\/[^)]+\)\s*/g, " ").replace(/\s+/g, " ").trim(); }

function extractGmailEssentials(composioData: any, perMessageBodyCap = 1000): any {
  const messages = Array.isArray(composioData) ? composioData : (composioData?.messages ?? composioData?.data?.messages ?? []);
  if (!Array.isArray(messages)) return composioData;
  return { total: messages.length, messages: messages.map((m: any) => {
    const headers = m.payload?.headers ?? [];
    const gh = (name: string) => (headers.find((x: any) => (x.name ?? "").toLowerCase() === name.toLowerCase())?.value ?? "");
    const pre = typeof m.messageText === "string" && m.messageText.length > 0 ? m.messageText : null;
    const raw = pre ?? findGmailPlainTextBody(m.payload);
    const body = stripParenthesizedUrls(raw).slice(0, perMessageBodyCap);
    return { messageId: m.messageId ?? m.id ?? "", threadId: m.threadId ?? "", subject: m.subject ?? gh("Subject"), from: m.sender ?? m.from ?? gh("From"), to: m.to ?? gh("To"), date: gh("Date") || m.internalDate || "", snippet: m.snippet ?? "", body };
  }) };
}

async function archiveProcessedGmailMessages(opts: { apiKey: string; userId: string; connectedAccountId: string; messageIds: string[]; additionalLabelsToAdd?: string[]; }): Promise<{ ok: boolean; archived: number; error: string | null }> {
  const ids = (opts.messageIds || []).filter((x): x is string => typeof x === "string" && x.length > 0);
  if (ids.length === 0) return { ok: true, archived: 0, error: null };
  let archived = 0; const errors: string[] = [];
  for (const msgId of ids) {
    const r = await callComposio({ apiKey: opts.apiKey, userId: opts.userId, connectedAccountId: opts.connectedAccountId, toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL", toolArguments: { message_id: msgId, remove_label_ids: ["INBOX"], ...(opts.additionalLabelsToAdd?.length ? { add_label_ids: opts.additionalLabelsToAdd } : {}) } });
    if (r.ok) archived += 1; else errors.push(`${msgId}: ${r.error}`);
  }
  if (errors.length > 0) return { ok: archived > 0, archived, error: `${errors.length}/${ids.length} failed: ${errors.slice(0, 3).join("; ")}` };
  return { ok: true, archived, error: null };
}

async function getComposioAccountId(agencyId: string, connection: string): Promise<string> {
  const key = `composio_${connection.toLowerCase()}_account_id`;
  const v = await getSetting(agencyId, key);
  if (!v) throw new Error(`Missing settings credential: ${key} (agency ${agencyId}).`);
  return v;
}

interface ParsedSfCrmAnalytics { source_message_id: string; week_ending_date: string | null; household_count: number | null; auto_pif: number | null; auto_premium: number | null; fire_pif: number | null; fire_premium: number | null; life_pif: number | null; life_premium: number | null; quarter_year: number | null; quarter_number: number | null; lead_sources: Array<{ source: string; won_households: number | null; won_premium: number | null }>; }
const SF_MONTH_NAMES = ["January","February","March","April","May","June","July","August","September","October","November","December"];
function _saturdayAfter(y: number, m: number, d: number): string { const dt = new Date(Date.UTC(y, m - 1, d)); dt.setUTCDate(dt.getUTCDate() + 1); return `${dt.getUTCFullYear()}-${String(dt.getUTCMonth()+1).padStart(2,"0")}-${String(dt.getUTCDate()).padStart(2,"0")}`; }
function _stripHtmlAndUrls(s: string): string { let o = s.replace(/<https?:\/\/[^>]+>/g, ""); o = o.replace(/<[^>]+>/g, " "); o = o.replace(/\r\n/g, "\n"); return o.replace(/\n{3,}/g, "\n\n"); }
function _parseMoney(s: string): number | null { if (s == null) return null; const c = s.replace(/[\$,]/g, "").trim(); if (!c) return null; const n = parseFloat(c); return isFinite(n) ? n : null; }
function _parseInt2(s: string): number | null { if (s == null) return null; const c = s.replace(/[,]/g, "").trim(); if (!c) return null; const n = parseInt(c, 10); return isFinite(n) ? n : null; }
function _extractWidget(body: string, label: string): string | null { const esc = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); const re = new RegExp(`${esc}\\s+([\\s\\S]*?)\\s+Last updated:`, "i"); const m = body.match(re); return m ? m[1].trim() : null; }
function parseSfCrmAnalyticsEmailOne(message: any): ParsedSfCrmAnalytics | null {
  const msgId: string = message.messageId || message.id || "";
  const text: string = message.body || message.messageText || message.snippet || "";
  if (!text) return null;
  const body = _stripHtmlAndUrls(text);
  let wed: string | null = null;
  const fri = body.match(/For Friday,\s+([A-Z][a-z]+)\s+(\d{1,2}),\s+(\d{4})/);
  if (fri) { const mi = SF_MONTH_NAMES.findIndex((mn) => mn.toLowerCase() === fri[1].toLowerCase()); if (mi >= 0) wed = _saturdayAfter(parseInt(fri[3],10), mi+1, parseInt(fri[2],10)); }
  const hh = _parseInt2(_extractWidget(body, "HH #") ?? ""); const aP = _parseInt2(_extractWidget(body, "Auto #") ?? ""); const aD = _parseMoney(_extractWidget(body, "Auto $") ?? ""); const fP = _parseInt2(_extractWidget(body, "Fire #") ?? ""); const fD = _parseMoney(_extractWidget(body, "Fire $") ?? ""); const lP = _parseInt2(_extractWidget(body, "Life #") ?? ""); const lD = _parseMoney(_extractWidget(body, "Life $") ?? "");
  let qy: number | null = null; let qn: number | null = null;
  if (fri) { const mo = SF_MONTH_NAMES.findIndex((mn) => mn.toLowerCase() === fri[1].toLowerCase()) + 1; qy = parseInt(fri[3],10); qn = Math.ceil(mo/3); }
  const names: string[] = [];
  const hhRe = /(?:^|\s)([A-Za-z][A-Za-z0-9.\-]+(?:\s[A-Za-z][A-Za-z0-9.\-]+)?) Won HH - Qtr/g;
  let mm; while ((mm = hhRe.exec(body)) !== null) { const n = mm[1].trim(); if (!names.includes(n)) names.push(n); }
  const lead_sources: ParsedSfCrmAnalytics["lead_sources"] = names.map((name) => ({ source: name, won_households: _parseInt2(_extractWidget(body, `${name} Won HH - Qtr`) ?? ""), won_premium: _parseMoney(_extractWidget(body, `${name} Won $ - Qtr`) ?? "") }));
  return { source_message_id: msgId, week_ending_date: wed, household_count: hh, auto_pif: aP, auto_premium: aD, fire_pif: fP, fire_premium: fD, life_pif: lP, life_premium: lD, quarter_year: qy, quarter_number: qn, lead_sources };
}
function parseSfCrmAnalyticsEmail(messages: any[]): any[] { if (!Array.isArray(messages)) return []; const out: any[] = []; for (const m of messages) { const p = parseSfCrmAnalyticsEmailOne(m); if (p && p.week_ending_date && p.household_count !== null) out.push(p); } return out; }
const INTERNAL_PARSERS: Record<string, (input: any) => any[]> = { sf_crm_analytics_email: (i: any) => parseSfCrmAnalyticsEmail(i?.messages ?? []) };

const _tableColumnsCache = new Map<string, Set<string>>();
async function getTableColumns(table: string): Promise<Set<string>> {
  const hit = _tableColumnsCache.get(table); if (hit) return hit;
  const { data, error } = await sb.rpc("get_table_columns_v1", { p_table_name: table });
  if (error) throw new Error(`get_table_columns_v1(${table}) failed: ${error.message}`);
  const cols = new Set<string>(((data as any[]) || []).map((r) => r.column_name));
  _tableColumnsCache.set(table, cols); return cols;
}
function pickKnownCols(rec: Record<string, any>, cols: Set<string>): Record<string, any> { const o: Record<string, any> = {}; for (const [k, v] of Object.entries(rec)) if (cols.has(k)) o[k] = v; return o; }

async function writeOutput(opts: { outputTable: string; outputConfig: any; records: any[]; agencyId: string | null; }): Promise<{ inserted: number; updated: number; secondary?: { table: string; inserted: number } }> {
  if (!Array.isArray(opts.records) || opts.records.length === 0) return { inserted: 0, updated: 0 };
  const cfg = opts.outputConfig || {};
  const primaryCols = await getTableColumns(opts.outputTable);
  const uniqueOn: string[] | undefined = cfg.unique_on || cfg.on_conflict_columns;
  const mergeStrategy: string = cfg.merge_strategy ? cfg.merge_strategy : (cfg.on_conflict === "update" ? "overwrite" : "ignore");
  const secondaryWrite: any = cfg.secondary_write;
  const secondaryRowsByIndex: any[][] = opts.records.map((r) => { if (secondaryWrite?.rows_from) { const v = (r as any)[secondaryWrite.rows_from]; return Array.isArray(v) ? v : []; } return []; });
  const primaryRecords: any[] = opts.records.map((r) => { const o: any = pickKnownCols(r, primaryCols); if (opts.agencyId && primaryCols.has("agency_id")) o.agency_id = opts.agencyId; if (cfg.source && primaryCols.has("source")) o.source = cfg.source; if (cfg.cadence && primaryCols.has("cadence")) o.cadence = cfg.cadence; if (cfg.snapshot_date_field && primaryCols.has("snapshot_date")) { const sd = (r as any)[cfg.snapshot_date_field]; if (sd !== undefined && sd !== null) o.snapshot_date = sd; } return o; });
  let primaryInserted = 0;
  if (uniqueOn && uniqueOn.length > 0) {
    if (mergeStrategy === "fill_nulls_only") {
      for (const rec of primaryRecords) {
        let q = sb.from(opts.outputTable).select("*");
        for (const col of uniqueOn) { if (rec[col] === undefined) throw new Error(`fill_nulls_only missing col ${col}`); q = q.eq(col, rec[col]); }
        const { data: existing, error: selErr } = await q.maybeSingle();
        if (selErr) throw new Error(`select failed: ${selErr.message}`);
        let merged: any; if (existing) { merged = { ...existing }; for (const [k, v] of Object.entries(rec)) if (merged[k] === null || merged[k] === undefined) merged[k] = v; } else merged = rec;
        if (primaryCols.has("updated_at")) merged.updated_at = new Date().toISOString();
        const { error: upErr } = await sb.from(opts.outputTable).upsert(merged, { onConflict: uniqueOn.join(","), ignoreDuplicates: false });
        if (upErr) throw new Error(`upsert failed: ${upErr.message}`);
        primaryInserted += 1;
      }
    } else if (mergeStrategy === "overwrite") {
      const { data, error } = await sb.from(opts.outputTable).upsert(primaryRecords, { onConflict: uniqueOn.join(","), ignoreDuplicates: false }).select("id");
      if (error) throw new Error(`upsert failed: ${error.message}`);
      primaryInserted = data?.length ?? 0;
    } else {
      const { data, error } = await sb.from(opts.outputTable).upsert(primaryRecords, { onConflict: uniqueOn.join(","), ignoreDuplicates: true }).select("id");
      if (error) throw new Error(`insert failed: ${error.message}`);
      primaryInserted = data?.length ?? 0;
    }
  } else {
    const { data, error } = await sb.from(opts.outputTable).insert(primaryRecords).select("id");
    if (error) throw new Error(`insert failed: ${error.message}`);
    primaryInserted = data?.length ?? 0;
  }
  let secondaryInserted = 0;
  if (secondaryWrite?.table && secondaryRowsByIndex.some((a) => a.length > 0)) {
    const secondaryCols = await getTableColumns(secondaryWrite.table);
    const secUniqueOn: string[] | undefined = secondaryWrite.on_conflict_columns || secondaryWrite.unique_on;
    const secMerge: string = secondaryWrite.merge_strategy || "ignore";
    const staticCols: Record<string, any> = secondaryWrite.static_columns || {};
    const secondaryRecords: any[] = [];
    for (let i = 0; i < opts.records.length; i++) {
      const orig = opts.records[i]; const rows = secondaryRowsByIndex[i];
      for (const row of rows) {
        const sec: any = pickKnownCols(row, secondaryCols);
        if (opts.agencyId && secondaryCols.has("agency_id")) sec.agency_id = opts.agencyId;
        for (const [k, v] of Object.entries(staticCols)) {
          if (k.endsWith("_field")) { const t = k.slice(0, -"_field".length); if (secondaryCols.has(t)) sec[t] = (orig as any)[v as string]; }
          else { if (secondaryCols.has(k)) sec[k] = v; }
        }
        secondaryRecords.push(sec);
      }
    }
    if (secondaryRecords.length > 0) {
      if (secUniqueOn && secUniqueOn.length > 0) {
        const { data, error } = await sb.from(secondaryWrite.table).upsert(secondaryRecords, { onConflict: secUniqueOn.join(","), ignoreDuplicates: secMerge === "ignore" }).select("id");
        if (error) throw new Error(`upsert secondary failed: ${error.message}`);
        secondaryInserted = data?.length ?? 0;
      } else {
        const { data, error } = await sb.from(secondaryWrite.table).insert(secondaryRecords).select("id");
        if (error) throw new Error(`insert secondary failed: ${error.message}`);
        secondaryInserted = data?.length ?? 0;
      }
    }
  }
  return { inserted: primaryInserted, updated: 0, ...(secondaryInserted > 0 && secondaryWrite?.table ? { secondary: { table: secondaryWrite.table, inserted: secondaryInserted } } : {}) };
}

async function executeRecipe(recipe: any, triggeredBy: string): Promise<any> {
  const started = Date.now();
  const recipeId = recipe.id as string;
  const agencyId = recipe.agency_id as string;
  await sb.from("automation_recipes").update({ last_run_at: new Date().toISOString(), last_run_status: "running" }).eq("id", recipeId);
  let runStatus = "success"; let errorMessage: string | null = null; let recordsProcessed = 0; let outputSummary = "";
  try {
    if (recipe.composio_action === "INTERNAL") {
      // v42: no pg_net. Split by handler prefix.
      if (recipe.internal_handler && recipe.internal_handler.startsWith("dispatch_")) {
        const edgeName = recipe.internal_handler.replace(/^dispatch_/, "").replace(/_/g, "-");
        const url = `${SUPABASE_URL}/functions/v1/${edgeName}`;
        const sharedSecret = await getSetting(agencyId, "automation_runner_cron_secret");
        if (!sharedSecret) throw new Error(`Cannot dispatch ${edgeName}: automation_runner_cron_secret missing for agency ${agencyId}`);
        const bodyPayload = { agency_id: agencyId, recipe_id: recipeId, shared_secret: sharedSecret, ...(recipe.input_config ?? {}) };
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 180_000);
        let fetchRes: Response;
        try {
          fetchRes = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SERVICE_ROLE_KEY}` }, body: JSON.stringify(bodyPayload), signal: controller.signal });
        } catch (fe) {
          const msg = fe instanceof Error ? fe.message : String(fe);
          if (msg.toLowerCase().includes("abort")) throw new Error(`${edgeName} did not respond within 180s (direct fetch aborted)`);
          throw new Error(`${edgeName} fetch failed: ${msg}`);
        } finally { clearTimeout(timeoutId); }
        const text = await fetchRes.text();
        let parsedBody: any = null; try { parsedBody = text ? JSON.parse(text) : null; } catch { parsedBody = null; }
        if (!fetchRes.ok) { const em = parsedBody?.error || parsedBody?.output_summary || (text ? text.slice(0, 400) : "no body"); throw new Error(`${edgeName} returned HTTP ${fetchRes.status}: ${em}`); }
        if (parsedBody) {
          recordsProcessed = (parsedBody.records_processed as number) ?? (parsedBody.summary?.processed as number) ?? (parsedBody.rows_upserted as number) ?? (parsedBody.processed_messages as number) ?? 0;
          outputSummary = (parsedBody.output_summary as string) ?? (parsedBody.summary ? `${edgeName} completed: ${JSON.stringify(parsedBody.summary).slice(0,300)}` : `${edgeName} completed (records_processed=${recordsProcessed})`);
        } else {
          outputSummary = `${edgeName} returned HTTP ${fetchRes.status} (empty body)`;
        }
      } else {
        const { data: internalResult, error: internalErr } = await sb.rpc("run_internal_recipe", { p_recipe_id: recipeId });
        if (internalErr) throw new Error(`run_internal_recipe failed: ${internalErr.message}`);
        recordsProcessed = (internalResult?.records_processed as number) ?? 0;
        outputSummary = (internalResult?.output_summary as string) ?? `INTERNAL recipe completed (no summary returned)`;
      }
      const durationSec = Math.round((Date.now() - started) / 1000);
      await sb.from("automation_run_log").insert({ agency_id: agencyId, recipe_id: recipeId, status: "success", records_processed: recordsProcessed, error_message: null, duration_seconds: durationSec, output_summary: outputSummary });
      await sb.from("automation_recipes").update({ last_run_status: "success" }).eq("id", recipeId);
      return { recipe_id: recipeId, recipe_name: recipe.recipe_name, status: "success", records_processed: recordsProcessed, duration_seconds: durationSec, triggered_by: triggeredBy, error: null };
    }

    // --- Composio-driven branch ---
    const composioApiKey = await getSetting(agencyId, "composio_api_key");
    if (!composioApiKey) throw new Error(`Missing composio_api_key (agency ${agencyId})`);
    const composioUserId = await getSetting(agencyId, "composio_user_id");
    if (!composioUserId) throw new Error(`Missing composio_user_id (agency ${agencyId})`);
    const connection = recipe.composio_connection;
    if (!connection) throw new Error(`Recipe ${recipe.recipe_name} has no composio_connection set.`);
    const accountId = await getComposioAccountId(agencyId, connection);
    const action = recipe.composio_action;
    if (!action) throw new Error(`Recipe ${recipe.recipe_name} has no composio_action set.`);
    const inputConfig = recipe.input_config || {};
    const RUNNER_ONLY_KEYS = new Set(["gmail_query","gmail_labels","archive_after_parse","archive_label_ids_to_add","dedupe_by","local_time","gl_firewall","output_table","drive_folders","apply_coding_rules","coding_rules_table"]);
    const composioArgs: Record<string, any> = {};
    for (const [k, v] of Object.entries(inputConfig)) if (!RUNNER_ONLY_KEYS.has(k)) composioArgs[k] = v;
    if (action === "GMAIL_FETCH_EMAILS") { if (inputConfig.gmail_query && !composioArgs.query) composioArgs.query = inputConfig.gmail_query; if (!composioArgs.user_id) composioArgs.user_id = "me"; if (recipe.internal_parser && composioArgs.include_payload === undefined) composioArgs.include_payload = true; }
    const composioResult = await callComposio({ apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId, toolSlug: action, toolArguments: composioArgs });
    if (!composioResult.ok) throw new Error(`Composio ${action} failed: ${composioResult.error}`);

    let parsedRecords: any[] = []; let alreadyKnownMessageIds: string[] = [];
    let usedInternalParser = false;
    if (recipe.internal_parser && INTERNAL_PARSERS[recipe.internal_parser]) {
      let inputData: any = composioResult.data;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS") {
        inputData = extractGmailEssentials(composioResult.data, 50000);
        const messages: any[] = Array.isArray(inputData?.messages) ? inputData.messages : [];
        const fetchedIds: string[] = messages.map((m: any) => m.messageId as string | undefined).filter((x: any): x is string => typeof x === "string" && x.length > 0);
        if (recipe.output_table && fetchedIds.length > 0) {
          const { data: existing, error: dedupErr } = await sb.from(recipe.output_table).select("source_message_id").in("source_message_id", fetchedIds);
          if (!dedupErr) { const knownSet = new Set((existing ?? []).map((r: any) => r.source_message_id as string)); if (knownSet.size > 0) { alreadyKnownMessageIds = fetchedIds.filter((id) => knownSet.has(id)); const nm = messages.filter((m: any) => !knownSet.has(m.messageId)); inputData = { total: nm.length, messages: nm }; } }
        }
      }
      const parserFn = INTERNAL_PARSERS[recipe.internal_parser];
      const records = parserFn(inputData); parsedRecords = Array.isArray(records) ? records : []; usedInternalParser = true;
    }
    if (!usedInternalParser && recipe.groq_prompt && recipe.output_table) {
      const groqApiKey = await getSetting(agencyId, "groq_api_key");
      if (!groqApiKey) throw new Error(`Missing groq_api_key (agency ${agencyId})`);
      let inputData: any = composioResult.data;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS") {
        inputData = extractGmailEssentials(composioResult.data);
        const messages: any[] = Array.isArray(inputData?.messages) ? inputData.messages : [];
        const fetchedIds: string[] = messages.map((m: any) => m.messageId as string | undefined).filter((x: any): x is string => typeof x === "string" && x.length > 0);
        if (fetchedIds.length > 0) {
          const { data: existing, error: dedupErr } = await sb.from(recipe.output_table).select("source_message_id").in("source_message_id", fetchedIds);
          if (!dedupErr) { const knownSet = new Set((existing ?? []).map((r: any) => r.source_message_id as string)); if (knownSet.size > 0) { alreadyKnownMessageIds = fetchedIds.filter((id) => knownSet.has(id)); const nm = messages.filter((m: any) => !knownSet.has(m.messageId)); inputData = { total: nm.length, messages: nm }; } }
        }
      }
      const msgsAfter = Array.isArray(inputData?.messages) ? inputData.messages.length : -1;
      if (msgsAfter === 0) { parsedRecords = []; }
      else {
        const inputForLLM = JSON.stringify(inputData).slice(0, 50000);
        const llmResult = await callGroqLLM({ agencyId: recipe.agency_id, groqApiKey, systemPrompt: recipe.groq_prompt + '\n\nReturn JSON: {"records": [...]}.', userContent: inputForLLM });
        if (!llmResult.ok) throw new Error(`LLM parsing failed: ${llmResult.error}`);
        parsedRecords = Array.isArray(llmResult.data?.records) ? llmResult.data.records : [];
      }
    } else if (recipe.output_table && Array.isArray(composioResult.data)) {
      parsedRecords = composioResult.data;
    }
    if (recipe.output_table && parsedRecords.length > 0) {
      const wr = await writeOutput({ outputTable: recipe.output_table, outputConfig: recipe.output_config || {}, records: parsedRecords, agencyId });
      recordsProcessed = wr.inserted + wr.updated;
      outputSummary = `${recordsProcessed} records written to ${recipe.output_table}`;
      if (wr.secondary) outputSummary += ` (+ ${wr.secondary.inserted} rows to ${wr.secondary.table})`;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        const newIds = parsedRecords.map((r: any) => r.source_message_id as string | undefined).filter((x): x is string => typeof x === "string" && x.length > 0);
        const allIds = Array.from(new Set([...newIds, ...alreadyKnownMessageIds]));
        if (allIds.length > 0) {
          const ar = await archiveProcessedGmailMessages({ apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId, messageIds: allIds, additionalLabelsToAdd: inputConfig.archive_label_ids_to_add as string[] | undefined });
          if (ar.ok) { outputSummary += ` — archived ${ar.archived} from inbox`; if (alreadyKnownMessageIds.length > 0) outputSummary += ` (${alreadyKnownMessageIds.length} were dups)`; }
          else { outputSummary += ` — ⚠️ archive failed: ${ar.error}`; await telegram(agencyId, `🟡 Post-parse archive failed for ${recipe.recipe_name}\n${(ar.error ?? "").slice(0,400)}`); }
        }
      }
    } else if (recipe.output_table && alreadyKnownMessageIds.length > 0) {
      outputSummary = `0 new records — ${alreadyKnownMessageIds.length} already processed historically`;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        const ar = await archiveProcessedGmailMessages({ apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId, messageIds: alreadyKnownMessageIds, additionalLabelsToAdd: inputConfig.archive_label_ids_to_add as string[] | undefined });
        if (ar.ok) outputSummary += ` — archived ${ar.archived} from inbox`;
        else outputSummary += ` — ⚠️ archive failed: ${ar.error}`;
      }
    } else if (recipe.output_table) {
      outputSummary = `0 records — no records to write`;
    } else {
      outputSummary = `Action ${action} executed successfully (no output_table)`;
      recordsProcessed = 1;
    }
  } catch (err) {
    runStatus = "failed";
    errorMessage = err instanceof Error ? err.message : String(err);
    outputSummary = `Failed: ${errorMessage.slice(0, 200)}`;
    await telegram(agencyId, `🛑 <b>Automation FAILED</b>\nRecipe: <b>${recipe.recipe_name}</b>\nError: ${errorMessage.slice(0, 400)}`);
  }
  const durationSec = Math.round((Date.now() - started) / 1000);
  await sb.from("automation_run_log").insert({ agency_id: agencyId, recipe_id: recipeId, status: runStatus, records_processed: recordsProcessed, error_message: errorMessage, duration_seconds: durationSec, output_summary: outputSummary });
  await sb.from("automation_recipes").update({ last_run_status: runStatus }).eq("id", recipeId);
  return { recipe_id: recipeId, recipe_name: recipe.recipe_name, status: runStatus, records_processed: recordsProcessed, duration_seconds: durationSec, triggered_by: triggeredBy, error: errorMessage };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed. Use POST." }, 405);
  let body: any = {};
  try { const text = await req.text(); body = text ? JSON.parse(text) : {}; } catch { return jsonResponse({ error: "Invalid JSON body" }, 400); }
  const recipeId: string | undefined = body.recipe_id;
  const triggeredBy: string = body.triggered_by || "manual";
  if (!recipeId) return jsonResponse({ error: "Missing recipe_id in body" }, 400);
  if (typeof body.shared_secret !== "string" || body.shared_secret.length === 0) return jsonResponse({ error: "Missing shared_secret in body" }, 401);
  const { data: recipe, error: recipeErr } = await sb.from("automation_recipes").select("*").eq("id", recipeId).maybeSingle();
  if (recipeErr || !recipe) return jsonResponse({ error: `Recipe ${recipeId} not found: ${recipeErr?.message || "no row"}` }, 404);
  if (!recipe.agency_id) return jsonResponse({ error: `Recipe ${recipeId} has no agency_id set.` }, 500);
  let expectedSecret: string | null;
  try { expectedSecret = await getSetting(recipe.agency_id, "automation_runner_cron_secret"); }
  catch (err) { const msg = err instanceof Error ? err.message : String(err); return jsonResponse({ error: `Auth lookup failed: ${msg}` }, 500); }
  if (!expectedSecret) return jsonResponse({ error: `Server missing settings.automation_runner_cron_secret for agency ${recipe.agency_id}` }, 500);
  if (body.shared_secret !== expectedSecret) return jsonResponse({ error: "Unauthorized: invalid shared_secret" }, 401);
  try {
    const result = await executeRecipe(recipe, triggeredBy);
    const status = result.status === "success" ? 200 : 500;
    return jsonResponse({ ok: result.status === "success", ...result }, status);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await telegram(recipe.agency_id, `🛑 automation-runner CRASHED\n${msg.slice(0, 300)}`);
    return jsonResponse({ ok: false, error: msg }, 500);
  }
});
