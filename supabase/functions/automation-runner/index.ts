// =========================================================================
// automation-runner  (BCC Master Template)
// =========================================================================
// PURPOSE: Generic executor for any row in the automation_recipes table.
//   Triggered by:
//     (a) pg_cron tick via run_due_automation_recipes() in migration 011, or
//     (b) manual call from the Automations module in the BCC web app via
//         the run_automation_recipe(uuid) RPC.
//
//   For each invocation:
//     1. Load the recipe row by recipe_id (resolves agency_id)
//     2. Auth via shared_secret (matches settings.automation_runner_cron_secret
//        for the recipe's agency)
//     3. Mark the recipe as "running" (sets last_run_at to NOW())
//     4. Resolve Composio credentials from settings (agency-scoped)
//     5. Call the recipe's composio_action with input_config arguments
//     6. If groq_prompt is set, post the result data through Groq directly
//        (v15+: NOT through Composio's removed GROQ_CHAT tool) for structured
//        extraction.
//     7. Write parsed records to the recipe's output_table per output_config
//     8. v16+: If input_config.archive_after_parse, remove INBOX label from
//        each parsed message (Gmail recipes only) so parsers self-clean their
//        own emails.
//        v17+: Gmail body extraction strips parenthesized tracking URLs
//        before applying the per-message cap, so vendor emails (US Bank,
//        Amazon, etc.) surface their actual transaction text within budget.
//        v18+: For Gmail parsers with source_message_id uniqueness, the
//        runner pre-filters already-known messageIds before the LLM call.
//        If all fetched messages are dups, LLM is skipped entirely and the
//        emails are archived from inbox anyway. Saves tokens and prevents
//        the duplicate-key-failure loop where archive never fires.
//     9. Write a row to automation_run_log
//    10. Update the recipe's last_run_status
//    11. Telegram alert on failure (if Telegram creds present)
//
// PATTERN: Mirrors the Composio call shape in gmail-inbox-archiver and the
//   auth/log/Telegram structure in linkedin-poster from the Imaginary Farms
//   ops project. Same proven pattern, generalized over the recipe row, and
//   adapted for the master template's settings table (key/value, scoped by
//   agency_id) instead of the ops project's brand_kit table.
//
// CREDENTIALS REQUIRED IN public.settings (scoped by agency_id):
//   automation_runner_cron_secret  - random secret, also referenced by mig 011
//   composio_api_key               - Composio API key
//   composio_user_id               - Composio user ID for this agency
//   composio_<conn>_account_id     - one per connection used by recipes;
//                                    e.g. composio_gmail_account_id,
//                                    composio_facebook_account_id, etc.
//   telegram_bot_token             - OPTIONAL; failure alerts only
//   telegram_chat_id               - OPTIONAL; failure alerts only
//
// AUTH:
//   verify_jwt = false
//   POST body must contain shared_secret matching the agency's
//   automation_runner_cron_secret in settings. Body must also contain a
//   recipe_id; the function loads that recipe to resolve the agency_id
//   used for the credential lookup.
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
// 2026-06-18 v15: LLM calls bypass Composio entirely — direct to Groq.
// COMPOSIO_SEARCH_GROQ_CHAT was removed from the composio_search toolkit catalog,
// causing "Tool not found" errors when the runner invoked it. Direct calls use the
// existing groq_api_key in settings and Groq's native JSON-mode output.
const GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions";
// 2026-06-18 v15.2: Back to 70b after adding Gmail pre-processing.
// Pre-processing strips Gmail responses to ~5% of original size (decoded plain
// text body + subject/from/date only), so 70b's 12K TPM is now plenty.
// 70b gives better extraction quality than 8b for structured email parsing.
const LLM_MODEL_DEFAULT = "llama-3.3-70b-versatile";

function stripFences(s: string): string {
  return s.trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "")
    .trim();
}

async function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// --- helpers ------------------------------------------------------------

/**
 * Read a credential from public.settings, scoped to the given agency.
 * Returns null if no row exists for that (agency_id, setting_key) pair.
 */
async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(`settings read failed for agency ${agencyId} key ${key}: ${error.message}`);
  }
  return data?.setting_value ?? null;
}

async function telegram(agencyId: string | null, text: string): Promise<void> {
  if (!agencyId) return; // no agency context — can't look up creds
  const botToken = await getSetting(agencyId, "telegram_bot_token");
  const chatId = await getSetting(agencyId, "telegram_chat_id");
  if (!botToken || !chatId) return;
  try {
    await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: chatId,
        text,
        parse_mode: "HTML",
        disable_web_page_preview: true,
      }),
    });
  } catch (_e) { /* Telegram failures are non-fatal */ }
}

function jsonResponse(body: any, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<{ ok: boolean; data: any; error: string | null; httpStatus: number }> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
    body: JSON.stringify({
      user_id: opts.userId,
      connected_account_id: opts.connectedAccountId,
      arguments: opts.toolArguments,
    }),
  });
  const text = await res.text();
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = res.ok && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : (parsed?.error?.message || parsed?.error || text.slice(0, 400));
  return { ok, data, error, httpStatus: res.status };
}

async function callGroqLLM(opts: {
  groqApiKey: string;
  systemPrompt: string;
  userContent: string;
  model?: string;
  maxTokens?: number;
}): Promise<{ ok: boolean; data: any; error: string | null }> {
  // v15: direct call to Groq's OpenAI-compatible chat completions endpoint.
  // Uses native JSON-mode (response_format: json_object) — Groq guarantees valid
  // JSON output, no markdown fences or prose. No stripFences pass needed.
  const body = {
    model: opts.model ?? LLM_MODEL_DEFAULT,
    messages: [
      { role: "system", content: opts.systemPrompt },
      { role: "user", content: opts.userContent },
    ],
    temperature: 0,
    max_tokens: opts.maxTokens ?? 4096,
    response_format: { type: "json_object" },
  };

  // Retry on 429/5xx with exponential backoff, max 3 attempts.
  let lastErr = "unknown";
  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(GROQ_API_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${opts.groqApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
    if ((res.status === 429 || res.status >= 500) && attempt < 2) {
      await sleep(500 * Math.pow(2, attempt));
      continue;
    }
    const text = await res.text();
    let parsed: any = {};
    try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
    if (!res.ok) {
      lastErr = parsed?.error?.message || parsed?.error?.code || text.slice(0, 400);
      return { ok: false, data: null, error: `Groq HTTP ${res.status}: ${lastErr}` };
    }
    const choice = parsed?.choices?.[0];
    const content = choice?.message?.content;
    if (!content) {
      return { ok: false, data: null, error: "Groq returned empty content" };
    }
    if (choice?.finish_reason === "length") {
      console.warn("[callGroqLLM] finish_reason=length — output may be truncated; consider raising max_tokens");
    }
    let extracted: any;
    try { extracted = JSON.parse(content); }
    catch (e) {
      return {
        ok: false,
        data: null,
        error: `Groq response was not valid JSON despite json_object mode: ${(e as Error).message}`,
      };
    }
    return { ok: true, data: extracted, error: null };
  }
  return { ok: false, data: null, error: `Groq call exhausted retries: ${lastErr}` };
}

// =====================================================================
// 2026-06-18 v15.2: Gmail pre-processing helpers
// Gmail FETCH_EMAILS responses include full base64-encoded HTML + plaintext
// + 50+ MIME headers per message — typically 15-25KB per message of mostly
// noise. The LLM only needs subject / from / date / plaintext body. These
// helpers extract just that, achieving ~95% token reduction before LLM call.
// =====================================================================

function decodeBase64Url(s: string): string {
  if (!s) return "";
  let normalized = s.replace(/-/g, "+").replace(/_/g, "/");
  while (normalized.length % 4 !== 0) normalized += "=";
  try {
    const bytes = Uint8Array.from(atob(normalized), (c) => c.charCodeAt(0));
    return new TextDecoder("utf-8").decode(bytes);
  } catch {
    return "";
  }
}

function findGmailPlainTextBody(payload: any): string {
  if (!payload) return "";
  // Single-part text message
  if (payload.body?.data && (!payload.parts || payload.parts.length === 0)) {
    const decoded = decodeBase64Url(payload.body.data);
    // If it looks like HTML, strip tags. Otherwise treat as plain.
    if (/<[a-z][^>]*>/i.test(decoded)) {
      return decoded.replace(/<style[\s\S]*?<\/style>/gi, " ")
                    .replace(/<script[\s\S]*?<\/script>/gi, " ")
                    .replace(/<[^>]+>/g, " ")
                    .replace(/&nbsp;/g, " ")
                    .replace(/\s+/g, " ")
                    .trim();
    }
    return decoded;
  }
  // Multipart: prefer text/plain
  const parts = payload.parts ?? [];
  const plain = parts.find((p: any) => p.mimeType === "text/plain");
  if (plain?.body?.data) return decodeBase64Url(plain.body.data);
  // Recurse into nested multipart (multipart/alternative inside multipart/mixed)
  for (const p of parts) {
    if (p.parts) {
      const nested = findGmailPlainTextBody(p);
      if (nested) return nested;
    }
  }
  // Fallback: strip HTML from text/html part
  const html = parts.find((p: any) => p.mimeType === "text/html");
  if (html?.body?.data) {
    const raw = decodeBase64Url(html.body.data);
    return raw.replace(/<style[\s\S]*?<\/style>/gi, " ")
              .replace(/<script[\s\S]*?<\/script>/gi, " ")
              .replace(/<[^>]+>/g, " ")
              .replace(/&nbsp;/g, " ")
              .replace(/\s+/g, " ")
              .trim();
  }
  return "";
}

// 2026-06-18 v15.4: Body cap 1500 → 1000 chars.
// At 1500, 15-msg requests landed at ~12.3K tokens (358 over Groq free-tier
// 12K TPM). 1000 chars per message gives ~5K-token headroom which lets
// max_results go up to ~20 messages per call. Transactional emails fit
// comfortably (~500-800 chars of post-stripped useful content).
// 2026-06-19 v17: Strip tracking URLs in parens (e.g. "Login ( http://... )")
// from email bodies before applying the per-message cap. Vendor emails (US Bank,
// Amazon, etc.) embed many tracking links inline that consume the entire 1000-char
// budget and hide the actual transaction text. After stripping, typical body
// content is ~5-10% of original size and the meaningful sentence ("account ending
// in 3977", "Your order shipped", etc.) fits comfortably under the cap.
function stripParenthesizedUrls(text: string): string {
  if (!text) return "";
  // Remove "( https?://... )" patterns with surrounding whitespace
  const noUrls = text.replace(/\s*\(\s*https?:\/\/[^)]+\)\s*/g, " ");
  // Collapse runs of whitespace (newlines, tabs, multiple spaces) into single spaces
  return noUrls.replace(/\s+/g, " ").trim();
}

function extractGmailEssentials(composioData: any, perMessageBodyCap = 1000): any {
  // composioResult.data may be the messages array directly, or wrapped under .messages
  const messages = Array.isArray(composioData)
    ? composioData
    : (composioData?.messages ?? composioData?.data?.messages ?? []);
  if (!Array.isArray(messages)) return composioData;

  return {
    total: messages.length,
    messages: messages.map((m: any) => {
      const headers = m.payload?.headers ?? [];
      const getHeader = (name: string): string => {
        const h = headers.find((x: any) => (x.name ?? "").toLowerCase() === name.toLowerCase());
        return h?.value ?? "";
      };
      // v17: strip parenthesized tracking URLs BEFORE applying the cap.
      // This avoids the failure mode where US Bank emails fit 2000+ chars of
      // tracking links into the first part of the body and push the transaction
      // text past the cap, causing the LLM to return null account_last4.
      const rawBody = findGmailPlainTextBody(m.payload);
      const body = stripParenthesizedUrls(rawBody).slice(0, perMessageBodyCap);
      return {
        messageId: m.messageId ?? m.id ?? "",
        threadId: m.threadId ?? "",
        subject: m.subject ?? getHeader("Subject"),
        from: m.sender ?? m.from ?? getHeader("From"),
        to: m.to ?? getHeader("To"),
        date: getHeader("Date") || m.internalDate || "",
        snippet: m.snippet ?? "",
        body,
      };
    }),
  };
}

/**
 * Resolve the Composio connected_account_id for a given connection slug.
 * Recipes specify composio_connection like "gmail" or "facebook"; this maps
 * to the corresponding settings key for the given agency.
 */
// =====================================================================
// 2026-06-19 v16: Post-parse Gmail archive helper.
// =====================================================================
async function archiveProcessedGmailMessages(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  messageIds: string[];
  additionalLabelsToAdd?: string[];
}): Promise<{ ok: boolean; archived: number; error: string | null }> {
  const ids = (opts.messageIds || []).filter(
    (x): x is string => typeof x === "string" && x.length > 0,
  );
  if (ids.length === 0) {
    return { ok: true, archived: 0, error: null };
  }
  const result = await callComposio({
    apiKey: opts.apiKey,
    userId: opts.userId,
    connectedAccountId: opts.connectedAccountId,
    toolSlug: "GMAIL_BATCH_MODIFY_MESSAGES",
    toolArguments: {
      messageIds: ids,
      removeLabelIds: ["INBOX"],
      ...(opts.additionalLabelsToAdd && opts.additionalLabelsToAdd.length > 0
        ? { addLabelIds: opts.additionalLabelsToAdd }
        : {}),
    },
  });
  if (!result.ok) {
    return { ok: false, archived: 0, error: result.error };
  }
  return { ok: true, archived: ids.length, error: null };
}

async function getComposioAccountId(agencyId: string, connection: string): Promise<string> {
  const key = `composio_${connection.toLowerCase()}_account_id`;
  const v = await getSetting(agencyId, key);
  if (!v) {
    throw new Error(
      `Missing settings credential: ${key} (agency ${agencyId}). The agent's Composio account for "${connection}" must be authorized and its account ID stored. See docs/AUTOMATIONS_INSTALL.md Step 3.`,
    );
  }
  return v;
}

/**
 * Write a parsed record array to the recipe's output_table, honoring the
 * full output_config schema:
 *
 *   {
 *     "source":               <string>,   // stamped on every primary row
 *     "cadence":              <string>,   // stamped on every primary row
 *     "snapshot_date_field":  <string>,   // copy this field on the record into snapshot_date
 *     "unique_on" | "on_conflict_columns": <string[]>,   // primary ON CONFLICT cols
 *     "merge_strategy": "overwrite" | "ignore" | "fill_nulls_only" (default "ignore"),
 *     "secondary_write": {
 *       "table":               <string>,
 *       "rows_from":           <string>,   // field on each primary record holding the array of child rows
 *       "on_conflict_columns": <string[]>,
 *       "merge_strategy":      "overwrite" | "ignore" | "fill_nulls_only",
 *       "static_columns": {
 *         "<col>":         <literal>,            // sec.<col> = <literal>
 *         "<col>_field":   <primary_field_name>  // sec.<col> = primary[<primary_field_name>]
 *       }
 *     }
 *   }
 *
 * Fields on each parsed record that don't match a real column on the target
 * table are STRIPPED before insert. This lets the LLM return helper fields
 * like `source_message_id`, `quarter_year`, `quarter_number`, `lead_sources`
 * without breaking the insert with "column not found" errors.
 */

// Module-level cache of public-schema table columns.
const _tableColumnsCache = new Map<string, Set<string>>();
async function getTableColumns(table: string): Promise<Set<string>> {
  const hit = _tableColumnsCache.get(table);
  if (hit) return hit;
  const { data, error } = await sb.rpc("get_table_columns_v1", { p_table_name: table });
  if (error) throw new Error(`get_table_columns_v1(${table}) failed: ${error.message}`);
  const cols = new Set<string>(((data as any[]) || []).map((r) => r.column_name));
  _tableColumnsCache.set(table, cols);
  return cols;
}

function pickKnownCols(rec: Record<string, any>, cols: Set<string>): Record<string, any> {
  const out: Record<string, any> = {};
  for (const [k, v] of Object.entries(rec)) {
    if (cols.has(k)) out[k] = v;
  }
  return out;
}

async function writeOutput(opts: {
  outputTable: string;
  outputConfig: any;
  records: any[];
  agencyId: string | null;
}): Promise<{ inserted: number; updated: number; secondary?: { table: string; inserted: number } }> {
  if (!Array.isArray(opts.records) || opts.records.length === 0) {
    return { inserted: 0, updated: 0 };
  }
  const cfg = opts.outputConfig || {};
  const primaryCols = await getTableColumns(opts.outputTable);

  // Accept both `unique_on` (legacy) and `on_conflict_columns` (newer).
  const uniqueOn: string[] | undefined = cfg.unique_on || cfg.on_conflict_columns;
  // Accept both `merge_strategy` (newer) and `on_conflict` (legacy "update" | "ignore").
  const mergeStrategy: string = cfg.merge_strategy
    ? cfg.merge_strategy
    : (cfg.on_conflict === "update" ? "overwrite" : "ignore");

  const secondaryWrite: any = cfg.secondary_write;

  // Snapshot the per-record secondary arrays BEFORE we filter fields off records.
  const secondaryRowsByIndex: any[][] = opts.records.map((r) => {
    if (secondaryWrite?.rows_from) {
      const v = (r as any)[secondaryWrite.rows_from];
      return Array.isArray(v) ? v : [];
    }
    return [];
  });

  // Build clean primary records: strip unknown fields, stamp agency_id/source/cadence/snapshot_date.
  const primaryRecords: any[] = opts.records.map((r) => {
    const out: any = pickKnownCols(r, primaryCols);
    if (opts.agencyId && primaryCols.has("agency_id")) out.agency_id = opts.agencyId;
    if (cfg.source && primaryCols.has("source")) out.source = cfg.source;
    if (cfg.cadence && primaryCols.has("cadence")) out.cadence = cfg.cadence;
    if (cfg.snapshot_date_field && primaryCols.has("snapshot_date")) {
      const sd = (r as any)[cfg.snapshot_date_field];
      if (sd !== undefined && sd !== null) out.snapshot_date = sd;
    }
    return out;
  });

  // ---- Primary write ------------------------------------------------------
  let primaryInserted = 0;
  if (uniqueOn && uniqueOn.length > 0) {
    if (mergeStrategy === "fill_nulls_only") {
      // PostgREST has no native "fill nulls only" upsert — do it per-record:
      //   SELECT existing, merge nulls from new, UPSERT.
      for (const rec of primaryRecords) {
        let q = sb.from(opts.outputTable).select("*");
        for (const col of uniqueOn) {
          if (rec[col] === undefined) throw new Error(`fill_nulls_only on ${opts.outputTable}: record missing unique col "${col}"`);
          q = q.eq(col, rec[col]);
        }
        const { data: existing, error: selErr } = await q.maybeSingle();
        if (selErr) throw new Error(`select from ${opts.outputTable} failed: ${selErr.message}`);

        let merged: any;
        if (existing) {
          merged = { ...existing };
          for (const [k, v] of Object.entries(rec)) {
            if (merged[k] === null || merged[k] === undefined) merged[k] = v;
          }
        } else {
          merged = rec;
        }
        if (primaryCols.has("updated_at")) merged.updated_at = new Date().toISOString();

        const { error: upErr } = await sb.from(opts.outputTable)
          .upsert(merged, { onConflict: uniqueOn.join(","), ignoreDuplicates: false });
        if (upErr) throw new Error(`upsert to ${opts.outputTable} failed: ${upErr.message}`);
        primaryInserted += 1;
      }
    } else if (mergeStrategy === "overwrite") {
      const { data, error } = await sb.from(opts.outputTable)
        .upsert(primaryRecords, { onConflict: uniqueOn.join(","), ignoreDuplicates: false })
        .select("id");
      if (error) throw new Error(`upsert to ${opts.outputTable} failed: ${error.message}`);
      primaryInserted = data?.length ?? 0;
    } else {
      const { data, error } = await sb.from(opts.outputTable)
        .upsert(primaryRecords, { onConflict: uniqueOn.join(","), ignoreDuplicates: true })
        .select("id");
      if (error) throw new Error(`insert to ${opts.outputTable} failed: ${error.message}`);
      primaryInserted = data?.length ?? 0;
    }
  } else {
    const { data, error } = await sb.from(opts.outputTable).insert(primaryRecords).select("id");
    if (error) throw new Error(`insert to ${opts.outputTable} failed: ${error.message}`);
    primaryInserted = data?.length ?? 0;
  }

  // ---- Secondary write ----------------------------------------------------
  let secondaryInserted = 0;
  if (secondaryWrite?.table && secondaryRowsByIndex.some((arr) => arr.length > 0)) {
    const secondaryCols = await getTableColumns(secondaryWrite.table);
    const secUniqueOn: string[] | undefined = secondaryWrite.on_conflict_columns || secondaryWrite.unique_on;
    const secMerge: string = secondaryWrite.merge_strategy || "ignore";
    const staticCols: Record<string, any> = secondaryWrite.static_columns || {};

    // For each primary record, build secondary rows from its child array.
    // staticCols convention:
    //   "foo_field": "bar"   ->  sec.foo = primary[bar]   (copy primary field)
    //   "foo":       "bar"   ->  sec.foo = "bar"          (literal)
    const secondaryRecords: any[] = [];
    for (let i = 0; i < opts.records.length; i++) {
      const orig = opts.records[i];
      const rows = secondaryRowsByIndex[i];
      for (const row of rows) {
        const sec: any = pickKnownCols(row, secondaryCols);
        if (opts.agencyId && secondaryCols.has("agency_id")) sec.agency_id = opts.agencyId;
        for (const [key, val] of Object.entries(staticCols)) {
          if (key.endsWith("_field")) {
            const targetCol = key.slice(0, -"_field".length);
            if (secondaryCols.has(targetCol)) sec[targetCol] = (orig as any)[val as string];
          } else {
            if (secondaryCols.has(key)) sec[key] = val;
          }
        }
        secondaryRecords.push(sec);
      }
    }

    if (secondaryRecords.length > 0) {
      if (secUniqueOn && secUniqueOn.length > 0) {
        if (secMerge === "fill_nulls_only") {
          for (const rec of secondaryRecords) {
            let q = sb.from(secondaryWrite.table).select("*");
            for (const col of secUniqueOn) {
              if (rec[col] === undefined) continue;
              q = q.eq(col, rec[col]);
            }
            const { data: existing } = await q.maybeSingle();
            let merged: any;
            if (existing) {
              merged = { ...existing };
              for (const [k, v] of Object.entries(rec)) {
                if (merged[k] === null || merged[k] === undefined) merged[k] = v;
              }
            } else {
              merged = rec;
            }
            if (secondaryCols.has("updated_at")) merged.updated_at = new Date().toISOString();
            const { error } = await sb.from(secondaryWrite.table)
              .upsert(merged, { onConflict: secUniqueOn.join(","), ignoreDuplicates: false });
            if (error) throw new Error(`upsert to ${secondaryWrite.table} failed: ${error.message}`);
            secondaryInserted += 1;
          }
        } else {
          const { data, error } = await sb.from(secondaryWrite.table)
            .upsert(secondaryRecords, {
              onConflict: secUniqueOn.join(","),
              ignoreDuplicates: secMerge === "ignore",
            })
            .select("id");
          if (error) throw new Error(`upsert to ${secondaryWrite.table} failed: ${error.message}`);
          secondaryInserted = data?.length ?? 0;
        }
      } else {
        const { data, error } = await sb.from(secondaryWrite.table).insert(secondaryRecords).select("id");
        if (error) throw new Error(`insert to ${secondaryWrite.table} failed: ${error.message}`);
        secondaryInserted = data?.length ?? 0;
      }
    }
  }

  return {
    inserted: primaryInserted,
    updated: 0,
    ...(secondaryInserted > 0 && secondaryWrite?.table
      ? { secondary: { table: secondaryWrite.table, inserted: secondaryInserted } }
      : {}),
  };
}


// --- Daily Briefing composer ----------------------------------------------
// Pulls live data from Supabase, formats markdown + HTML + KPI jsonb.
// Called from the recipe branch when internal_handler === 'daily_briefing_composer'.
// Output: { subject, body_html, body_markdown, kpis, sections_included, briefing_date }
async function composeDailyBriefing(agencyId: string, recipientEmail: string): Promise<any> {
  // Use America/Chicago for "today" - matches the 7am Central cron schedule
  const now = new Date();
  const chicagoStr = now.toLocaleString("en-US", { timeZone: "America/Chicago" });
  const chiDate = new Date(chicagoStr);
  const year = chiDate.getFullYear();
  const month = chiDate.getMonth() + 1; // 1-12
  const day = chiDate.getDate();
  const briefingDate = `${year}-${String(month).padStart(2,'0')}-${String(day).padStart(2,'0')}`;
  const daysInMonth = new Date(year, month, 0).getDate();
  const weekdayName = chiDate.toLocaleDateString("en-US", { weekday: "long" });
  const dateLabel = chiDate.toLocaleDateString("en-US", { month: "long", day: "numeric" });

  // Prior month for comparison
  const priorMonth = month === 1 ? 12 : month - 1;
  const priorYear = month === 1 ? year - 1 : year;

  // --- Parallel data fetches ---
  const [
    mtdRes,
    priorRes,
    tasksRes,
    alertsRes,
    complianceRes,
    staffRes,
    aippRes,
    producerRes,
  ] = await Promise.all([
    sb.from("comp_recap").select("amount").eq("agency_id", agencyId).eq("period_year", year).eq("period_month", month),
    sb.from("comp_recap").select("amount").eq("agency_id", agencyId).eq("period_year", priorYear).eq("period_month", priorMonth),
    sb.from("tasks").select("title,priority,due_date,status").eq("agency_id", agencyId).neq("status", "completed").order("priority").limit(10),
    sb.from("alerts").select("title,severity,due_date").eq("agency_id", agencyId).eq("is_resolved", false).order("created_at", { ascending: false }).limit(10),
    sb.from("compliance_calendar").select("title,due_date,status").eq("agency_id", agencyId).neq("status", "completed").gte("due_date", briefingDate).lte("due_date", `${year}-12-31`).order("due_date").limit(10),
    sb.from("team").select("id,license_pc,license_lh,license_ips").eq("agency_id", agencyId).eq("is_active", true),
    sb.from("aipp_tracking").select("program_year,target_amount,earned_ytd").eq("agency_id", agencyId).eq("program_year", year).maybeSingle(),
    sb.from("producer_production").select("id").eq("agency_id", agencyId).eq("period_year", year).limit(1),
  ]);

  const mtdRevenue = (mtdRes.data || []).reduce((s: number, r: any) => s + Number(r.amount || 0), 0);
  const mtdLines = (mtdRes.data || []).length;
  const priorRevenue = (priorRes.data || []).reduce((s: number, r: any) => s + Number(r.amount || 0), 0);
  const priorLines = (priorRes.data || []).length;
  const eomProjection = day > 0 ? (mtdRevenue / day) * daysInMonth : 0;
  const momDeltaPct = priorRevenue > 0 ? ((eomProjection - priorRevenue) / priorRevenue) * 100 : 0;

  const openTasks = tasksRes.data || [];
  const openTasksHigh = openTasks.filter((t: any) => t.priority === "high").length;
  const topTasks = openTasks.slice(0, 5);

  const activeAlerts = alertsRes.data || [];

  const compliance = (complianceRes.data || []).filter((c: any) => {
    const d = new Date(c.due_date);
    const today = new Date(briefingDate);
    const days = Math.round((d.getTime() - today.getTime()) / 86400000);
    return days >= 0 && days <= 60;
  });
  const compliance14 = compliance.filter((c: any) => {
    const days = Math.round((new Date(c.due_date).getTime() - new Date(briefingDate).getTime()) / 86400000);
    return days <= 14;
  });

  const staff = staffRes.data || [];
  const activeStaff = staff.length;
  const staffLicensed = staff.filter((s: any) => s.license_pc || s.license_lh || s.license_ips).length;

  const aipp = aippRes.data;
  const hasProducerData = (producerRes.data || []).length > 0;

  // --- Format money ---
  const money = (n: number) => `$${Math.round(n).toLocaleString()}`;

  // --- Subject ---
  const subject = `BCC Daily Briefing — ${weekdayName.slice(0,3)}, ${dateLabel} — MTD ${money(mtdRevenue)}, pacing ${money(eomProjection)}`;

  // --- Build sections ---
  const sectionsIncluded: string[] = ["greeting", "where_we_are"];

  // Watching list - dynamic
  const watching: string[] = [];
  if (priorRevenue > 0 && momDeltaPct < -15) {
    watching.push(`<strong>MTD pace vs ${priorMonth === 12 ? "December" : new Date(year, priorMonth-1, 1).toLocaleDateString("en-US", { month: "long" })}.</strong> We're tracking ${momDeltaPct.toFixed(0)}% vs last month — worth a real look if the gap holds through next week.`);
  }
  if (!aipp) {
    watching.push(`<strong>AIPP tracking is empty for ${year}.</strong> No target set. When you've got 10 minutes, let's seed it so I can give you a "pace vs goal" reading every morning.`);
  }
  if (!hasProducerData) {
    watching.push(`<strong>Producer Production table is empty.</strong> Once we backfill, I can give you a per-producer view in this briefing.`);
  }

  // --- Markdown body ---
  let md = `# Good morning, Peter

It's ${weekdayName}, ${dateLabel} — day ${day} of ${daysInMonth}. Coffee first, then the rundown.

`;
  md += `## Where we are this month

**MTD revenue:** ${money(mtdRevenue)} across ${mtdLines} line items.

`;
  if (priorRevenue > 0) {
    md += `Pacing toward roughly **${money(eomProjection)}** by month-end. Prior month closed at ${money(priorRevenue)} (${priorLines} lines), so we're tracking about **${momDeltaPct >= 0 ? "+" : ""}${momDeltaPct.toFixed(0)}%** vs last month.

`;
  } else {
    md += `Pacing toward roughly **${money(eomProjection)}** by month-end.

`;
  }

  if (topTasks.length > 0) {
    sectionsIncluded.push("todays_priorities");
    md += `## Today's priorities

You've got **${openTasks.length} open tasks**, ${openTasksHigh} high-priority. Top of the pile:

`;
    topTasks.forEach((t: any, i: number) => {
      md += `${i+1}. ${t.title}${t.priority === "high" ? " 🔴" : ""}
`;
    });
    md += `
`;
  }

  if (activeAlerts.length > 0) {
    sectionsIncluded.push("active_alerts");
    md += `## Active alerts

`;
    activeAlerts.slice(0, 5).forEach((a: any) => {
      md += `- ${a.severity === "critical" ? "🔴" : a.severity === "high" ? "🟠" : "🟡"} ${a.title}
`;
    });
    md += `
`;
  }

  if (compliance.length > 0) {
    sectionsIncluded.push("compliance_upcoming");
    md += `## Compliance — coming up

`;
    compliance.slice(0, 5).forEach((c: any) => {
      const days = Math.round((new Date(c.due_date).getTime() - new Date(briefingDate).getTime()) / 86400000);
      const icon = days <= 7 ? "🔴" : days <= 14 ? "🟡" : "🟢";
      md += `- ${icon} **In ${days} days (${c.due_date}):** ${c.title}
`;
    });
    md += `
`;
  }

  if (watching.length > 0) {
    sectionsIncluded.push("what_im_watching");
    md += `## What I'm watching

`;
    watching.forEach((w) => { md += `- ${w.replace(/<[^>]+>/g, "")}
`; });
    md += `
`;
  }

  sectionsIncluded.push("what_to_ask_me");
  md += `## What to ask me today

- "Show me April's comp_recap by category"
- "What's blocking the GL right now?"
- "Set up AIPP tracking for ${year}"

Going to be a good day. Talk soon.

— Claude`;

  // --- HTML body ---
  const sfRed = "#c8102e";
  let html = `<!DOCTYPE html><html><body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 640px; margin: 0 auto; padding: 24px; color: #1a1a1a; background: #fafafa; line-height: 1.55;">`;
  html += `<h1 style="margin: 0 0 16px; font-size: 24px; color: ${sfRed};">Good morning, Peter</h1>`;
  html += `<p style="font-size: 15px; color: #555;">${weekdayName}, ${dateLabel} — day ${day} of ${daysInMonth}. Coffee first, then the rundown.</p>`;

  html += `<h2 style="margin-top: 28px; font-size: 18px; border-bottom: 2px solid ${sfRed}; padding-bottom: 6px;">Where we are this month</h2>`;
  html += `<p><strong>MTD revenue:</strong> ${money(mtdRevenue)} across ${mtdLines} line items.</p>`;
  if (priorRevenue > 0) {
    const priorMonthName = new Date(priorYear, priorMonth-1, 1).toLocaleDateString("en-US", { month: "long" });
    html += `<p>Pacing toward roughly <strong>${money(eomProjection)}</strong> by month-end. ${priorMonthName} closed at ${money(priorRevenue)} (${priorLines} lines), so we're tracking about <strong>${momDeltaPct >= 0 ? "+" : ""}${momDeltaPct.toFixed(0)}%</strong> vs last month.</p>`;
  } else {
    html += `<p>Pacing toward roughly <strong>${money(eomProjection)}</strong> by month-end.</p>`;
  }

  html += `<table style="width:100%; border-collapse: collapse; margin: 16px 0; background: white; border-radius: 8px; overflow: hidden;">`;
  html += `<tr style="background: #f0f0f0;"><th style="text-align:left; padding: 10px 14px;">Metric</th><th style="text-align:right; padding: 10px 14px;">Today</th></tr>`;
  const row = (k: string, v: string) => `<tr><td style="padding: 8px 14px; border-top:1px solid #eee;">${k}</td><td style="text-align:right; padding: 8px 14px; border-top:1px solid #eee;">${v}</td></tr>`;
  html += row("MTD revenue", `<strong>${money(mtdRevenue)}</strong>`);
  html += row("EOM projection", money(eomProjection));
  if (priorRevenue > 0) html += row("Prior month actual", money(priorRevenue));
  html += row("Open tasks", `${openTasks.length} (${openTasksHigh} high)`);
  html += row("Active alerts", String(activeAlerts.length));
  html += row("Active staff", `${activeStaff} (${staffLicensed} licensed)`);
  html += `</table>`;

  if (topTasks.length > 0) {
    html += `<h2 style="margin-top: 28px; font-size: 18px; border-bottom: 2px solid ${sfRed}; padding-bottom: 6px;">Today's priorities</h2>`;
    html += `<p>You've got <strong>${openTasks.length} open tasks</strong>, ${openTasksHigh} high-priority. Top of the pile:</p><ol>`;
    topTasks.forEach((t: any) => {
      html += `<li>${t.priority === "high" ? "<strong>🔴 " : ""}${t.title}${t.priority === "high" ? "</strong>" : ""}</li>`;
    });
    html += `</ol>`;
  }

  if (activeAlerts.length > 0) {
    html += `<h2 style="margin-top: 28px; font-size: 18px; border-bottom: 2px solid ${sfRed}; padding-bottom: 6px;">Active alerts</h2><ul>`;
    activeAlerts.slice(0, 5).forEach((a: any) => {
      const icon = a.severity === "critical" ? "🔴" : a.severity === "high" ? "🟠" : "🟡";
      html += `<li>${icon} ${a.title}</li>`;
    });
    html += `</ul>`;
  }

  if (compliance.length > 0) {
    html += `<h2 style="margin-top: 28px; font-size: 18px; border-bottom: 2px solid ${sfRed}; padding-bottom: 6px;">Compliance — coming up</h2><ul>`;
    compliance.slice(0, 5).forEach((c: any) => {
      const days = Math.round((new Date(c.due_date).getTime() - new Date(briefingDate).getTime()) / 86400000);
      const color = days <= 7 ? "#dc2626" : days <= 14 ? "#d97706" : "#059669";
      html += `<li><strong style="color:${color};">In ${days} days (${c.due_date}):</strong> ${c.title}</li>`;
    });
    html += `</ul>`;
  }

  if (watching.length > 0) {
    html += `<h2 style="margin-top: 28px; font-size: 18px; border-bottom: 2px solid ${sfRed}; padding-bottom: 6px;">What I'm watching</h2><ul>`;
    watching.forEach((w) => { html += `<li>${w}</li>`; });
    html += `</ul>`;
  }

  html += `<h2 style="margin-top: 28px; font-size: 18px; border-bottom: 2px solid ${sfRed}; padding-bottom: 6px;">What to ask me today</h2>`;
  html += `<ul><li><em>"Show me ${priorMonth === 12 ? "December" : new Date(year, priorMonth-1, 1).toLocaleDateString("en-US", { month: "long" })}'s comp_recap by category"</em></li>`;
  html += `<li><em>"What's blocking the GL right now?"</em></li>`;
  html += `<li><em>"Set up AIPP tracking for ${year}"</em></li></ul>`;

  html += `<p style="margin-top: 32px; color: #888; font-size: 13px;">Going to be a good day. Talk soon.<br/>— Claude</p>`;
  html += `<hr style="border:none; border-top:1px solid #e5e5e5; margin:32px 0 12px;">`;
  html += `<p style="color:#aaa; font-size: 11px;">Generated by Paper Newt BCC — ${recipientEmail}</p>`;
  html += `</body></html>`;

  const kpis = {
    mtd_revenue: Number(mtdRevenue.toFixed(2)),
    mtd_line_count: mtdLines,
    eom_projection: Number(eomProjection.toFixed(2)),
    prior_month_revenue: Number(priorRevenue.toFixed(2)),
    mom_delta_pct: Number(momDeltaPct.toFixed(1)),
    open_tasks_total: openTasks.length,
    open_tasks_high: openTasksHigh,
    active_alerts: activeAlerts.length,
    compliance_due_30d: compliance.length,
    compliance_due_14d: compliance14.length,
    active_staff: activeStaff,
    staff_licensed: staffLicensed,
    aipp_target: aipp?.target_amount ?? null,
    aipp_earned_ytd: aipp?.earned_ytd ?? null,
    has_producer_data: hasProducerData,
  };

  return {
    briefing_date: briefingDate,
    subject,
    body_markdown: md,
    body_html: html,
    kpis,
    sections_included: sectionsIncluded,
  };
}

// --- core executor ------------------------------------------------------

async function executeRecipe(
  recipe: any,
  triggeredBy: string,
): Promise<any> {
  const started = Date.now();
  const recipeId = recipe.id as string;
  const agencyId = recipe.agency_id as string;

  // Optimistic concurrency lock: stamp last_run_at so the next pg_cron tick
  // won't re-fire this recipe in the same minute.
  await sb
    .from("automation_recipes")
    .update({ last_run_at: new Date().toISOString(), last_run_status: "running" })
    .eq("id", recipeId);

  let runStatus = "success";
  let errorMessage: string | null = null;
  let recordsProcessed = 0;
  let outputSummary = "";

  try {
    // --- INTERNAL recipe branch (no Composio call) ---
    // For recipes whose composio_action is the literal string 'INTERNAL', the
    // work happens entirely inside Postgres via the run_internal_recipe()
    // function defined in migration 012. Used by GL Entry Writer, Monthly
    // Close Monitor, Producer Underperformance Watcher, and any agency-
    // specific INTERNAL recipes added later.
    if (recipe.composio_action === "INTERNAL") {
      const { data: internalResult, error: internalErr } = await sb.rpc(
        "run_internal_recipe",
        { p_recipe_id: recipeId },
      );
      if (internalErr) {
        throw new Error(`run_internal_recipe failed: ${internalErr.message}`);
      }
      // run_internal_recipe returns jsonb { records_processed, output_summary,
      // request_id?, target_function? }
      recordsProcessed = (internalResult?.records_processed as number) ?? 0;
      outputSummary = (internalResult?.output_summary as string) ??
        `INTERNAL recipe completed (no summary returned)`;

      // -- pg_net dispatch reconciliation --
      // When internal_handler is one of the dispatch_* functions (e.g.
      // dispatch_email_archiver, dispatch_document_processor), the SQL call
      // fires an HTTP POST via pg_net which is ASYNC: the request only
      // actually fires after the RPC transaction commits, and the response
      // lands in net._http_response some time later. We detect this case by
      // the presence of `request_id` in the SQL result and then poll
      // public.get_pg_net_response() in SEPARATE RPC calls (= separate
      // transactions, which CAN see the worker's committed writes) until the
      // response arrives or we time out. The real status of the dispatched
      // edge function becomes the status of THIS recipe run.
      const requestId = internalResult?.request_id as number | undefined;
      const targetFn = (internalResult?.target_function as string | undefined) ?? "dispatched edge function";
      if (typeof requestId === "number") {
        const startedPolling = Date.now();
        const maxWaitMs = 90_000;
        const pollIntervalMs = 500;
        let resp: any = null;
        let pollCount = 0;
        // 2026-06-18 patch: poll immediately (no initial sleep), shorter interval,
        // and fall back to a direct net._http_response query after timeout to catch
        // cases where the RPC's connection-pool snapshot misses fast responses.
        while (Date.now() - startedPolling < maxWaitMs) {
          pollCount++;
          const { data: row, error: respErr } = await sb.rpc(
            "get_pg_net_response",
            { p_request_id: requestId },
          );
          if (respErr) {
            throw new Error(`get_pg_net_response failed for ${targetFn} request_id=${requestId}: ${respErr.message}`);
          }
          if (row && (row.status_code !== null || row.error_msg !== null || row.timed_out === true)) {
            resp = row;
            console.log(`[runner] ${targetFn} response captured on poll #${pollCount} after ${Date.now() - startedPolling}ms`);
            break;
          }
          await new Promise((r) => setTimeout(r, pollIntervalMs));
        }
        if (!resp) {
          // Fallback: try once more via direct schema query (bypasses any RPC caching).
          console.warn(`[runner] ${targetFn} polling timed out after ${pollCount} polls; trying direct fallback for request_id=${requestId}`);
          try {
            const { data: fallbackRow, error: fbErr } = await sb
              .schema("net" as any)
              .from("_http_response")
              .select("status_code,content,error_msg,timed_out,created")
              .eq("id", requestId)
              .maybeSingle();
            if (!fbErr && fallbackRow && (fallbackRow.status_code !== null || fallbackRow.error_msg !== null || fallbackRow.timed_out === true)) {
              resp = fallbackRow;
              console.log(`[runner] ${targetFn} response recovered via direct fallback for request_id=${requestId}`);
            }
          } catch (e) {
            console.warn(`[runner] direct fallback query failed: ${e instanceof Error ? e.message : String(e)}`);
          }
        }
        if (!resp) {
          throw new Error(`${targetFn} did not respond within ${maxWaitMs / 1000}s (request_id=${requestId}, polls=${pollCount}). Background job may still be running; check edge function logs.`);
        }
        if (resp.timed_out === true) {
          throw new Error(`${targetFn} timed out at the pg_net layer (request_id=${requestId})`);
        }
        if (resp.error_msg) {
          throw new Error(`${targetFn} HTTP error: ${resp.error_msg} (request_id=${requestId})`);
        }
        const httpStatus = resp.status_code as number;
        const bodyText = resp.content as string | null;
        let parsedBody: any = null;
        try { parsedBody = bodyText ? JSON.parse(bodyText) : null; } catch { parsedBody = null; }
        if (httpStatus >= 400) {
          const errMsg = parsedBody?.error || parsedBody?.output_summary || (bodyText ? bodyText.slice(0, 400) : "no body");
          throw new Error(`${targetFn} returned HTTP ${httpStatus}: ${errMsg}`);
        }
        // Success — surface the real edge-function-reported counts/summary
        if (parsedBody) {
          recordsProcessed = (parsedBody.records_processed as number) ??
            (parsedBody.summary?.processed as number) ?? recordsProcessed;
          outputSummary = (parsedBody.output_summary as string) ??
            (parsedBody.summary ? `${targetFn} completed: ${JSON.stringify(parsedBody.summary).slice(0, 300)}` : `${targetFn} returned HTTP ${httpStatus}`);
        } else {
          outputSummary = `${targetFn} returned HTTP ${httpStatus} (non-JSON body)`;
        }
      }

      // Write run log + update recipe status, then return early
      const durationSec = Math.round((Date.now() - started) / 1000);
      await sb.from("automation_run_log").insert({
        agency_id: agencyId,
        recipe_id: recipeId,
        status: "success",
        records_processed: recordsProcessed,
        error_message: null,
        duration_seconds: durationSec,
        output_summary: outputSummary,
      });
      await sb
        .from("automation_recipes")
        .update({ last_run_status: "success" })
        .eq("id", recipeId);

      return {
        recipe_id: recipeId,
        recipe_name: recipe.recipe_name,
        status: "success",
        records_processed: recordsProcessed,
        duration_seconds: durationSec,
        triggered_by: triggeredBy,
        error: null,
      };
    }


    // --- Daily Briefing composer branch ---
    // Recipes flagged with internal_handler='daily_briefing_composer' compose their
    // email body dynamically from live Supabase data before the standard Gmail send.
    if (recipe.internal_handler === 'daily_briefing_composer') {
      try {
        const inputCfg = recipe.input_config || {};
        const recipientEmail = inputCfg.recipient_email || 'paper.newt.management@gmail.com';
        const composed = await composeDailyBriefing(agencyId, recipientEmail);

        // Upsert into briefings table BEFORE sending so the row exists even if Gmail fails.
        const { error: briefingErr } = await sb.from('briefings').upsert({
          agency_id: agencyId,
          briefing_date: composed.briefing_date,
          sent_at: new Date().toISOString(),
          delivered: false,
          recipient_email: recipientEmail,
          subject: composed.subject,
          body_markdown: composed.body_markdown,
          body_html: composed.body_html,
          kpis: composed.kpis,
          sections_included: composed.sections_included,
        }, { onConflict: 'agency_id,briefing_date' });
        if (briefingErr) {
          console.error('[daily_briefing_composer] briefings upsert failed:', briefingErr.message);
        }

        // Rewrite input_config so the existing Gmail send path uses the composed content.
        recipe.input_config = {
          ...inputCfg,
          recipient_email: recipientEmail,
          subject: composed.subject,
          body: composed.body_html,
          is_html: true,
        };
        outputSummary = `Composed briefing for ${composed.briefing_date} (${composed.kpis.mtd_line_count} comp lines, ${composed.kpis.open_tasks_total} tasks, ${composed.kpis.compliance_due_30d} compliance items)`;
      } catch (composeErr) {
        // Compose failure should NOT block the daily email. Fall through to the
        // configured input_config (smoke-test body) so something still ships.
        const msg = composeErr instanceof Error ? composeErr.message : String(composeErr);
        console.error('[daily_briefing_composer] FAILED, falling back to static body:', msg);
        await telegram(agencyId, `🟡 <b>Daily briefing composer failed</b>\n${msg.slice(0, 300)}\n\nFallback body will be sent.`);
        // Mark sections_included so we know the fallback fired
        await sb.from('briefings').upsert({
          agency_id: agencyId,
          briefing_date: new Date().toISOString().slice(0,10),
          sent_at: new Date().toISOString(),
          delivered: false,
          recipient_email: recipe.input_config?.recipient_email || 'paper.newt.management@gmail.com',
          subject: recipe.input_config?.subject || 'BCC Daily Briefing (fallback)',
          body_markdown: '_Composer failed; static body was sent. See automation_run_log for details._',
          body_html: recipe.input_config?.body || '',
          kpis: { compose_error: msg.slice(0, 500) },
          sections_included: ['fallback'],
        }, { onConflict: 'agency_id,briefing_date' });
      }
    }

    // --- Resolve credentials ---
    const composioApiKey = await getSetting(agencyId, "composio_api_key");
    if (!composioApiKey) {
      throw new Error(`Missing settings credential: composio_api_key (agency ${agencyId})`);
    }
    const composioUserId = await getSetting(agencyId, "composio_user_id");
    if (!composioUserId) {
      throw new Error(`Missing settings credential: composio_user_id (agency ${agencyId})`);
    }

    const connection = recipe.composio_connection;
    if (!connection) {
      throw new Error(`Recipe ${recipe.recipe_name} has no composio_connection set.`);
    }
    const accountId = await getComposioAccountId(agencyId, connection);

    const action = recipe.composio_action;
    if (!action) {
      throw new Error(`Recipe ${recipe.recipe_name} has no composio_action set.`);
    }

    // --- Call Composio ---
    const inputConfig = recipe.input_config || {};
    // input_config can include keys like gmail_query, attachment_required, etc.
    // Recipes are responsible for using keys that map to the Composio tool's
    // expected arguments. The runner passes them through as-is.
    const composioResult = await callComposio({
      apiKey: composioApiKey,
      userId: composioUserId,
      connectedAccountId: accountId,
      toolSlug: action,
      toolArguments: inputConfig,
    });

    if (!composioResult.ok) {
      throw new Error(`Composio ${action} failed: ${composioResult.error}`);
    }

    let parsedRecords: any[] = [];
    // 2026-06-19 v18: Track Gmail messageIds already in output_table so we can
    // archive them from inbox even when we skip the LLM/insert path.
    let alreadyKnownMessageIds: string[] = [];

    // --- Optional: LLM parsing pass (v15: direct to Groq) ---
    if (recipe.groq_prompt && recipe.output_table) {
      // Default expectation: composioResult.data is array-shaped or has a top-level
      // collection (messages, items, results). Recipes that need a different shape
      // can include extraction hints in groq_prompt.
      const groqApiKey = await getSetting(agencyId, "groq_api_key");
      if (!groqApiKey) {
        throw new Error(`Missing settings credential: groq_api_key (agency ${agencyId}). Required for LLM parsing.`);
      }
      // 2026-06-18 v15.2: Gmail-specific pre-processing.
      // For Gmail recipes, strip raw API payloads (base64 bodies, 50+ headers, HTML
      // versions) down to just subject/from/date/plaintext body. ~95% token reduction.
      // Other toolkits pass through unchanged.
      let inputData: any = composioResult.data;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS") {
        inputData = extractGmailEssentials(composioResult.data);

        // v18: dedup precheck. Look up which fetched Gmail messageIds already exist
        // in output_table.source_message_id and exclude them from the LLM batch.
        // Avoids burning tokens on already-processed emails and prevents the
        // duplicate-key insert failures that previously left emails stuck in the
        // inbox in an infinite re-fetch loop.
        const messages: any[] = Array.isArray(inputData?.messages) ? inputData.messages : [];
        const fetchedIds: string[] = messages
          .map((m: any) => m.messageId as string | undefined)
          .filter((x: any): x is string => typeof x === "string" && x.length > 0);
        if (fetchedIds.length > 0) {
          const { data: existing, error: dedupErr } = await sb
            .from(recipe.output_table)
            .select("source_message_id")
            .in("source_message_id", fetchedIds);
          if (dedupErr) {
            console.warn(`[v18 dedup precheck] query failed for ${recipe.output_table}.source_message_id — proceeding without dedup: ${dedupErr.message}`);
          } else {
            const knownSet = new Set((existing ?? []).map((r: any) => r.source_message_id as string));
            if (knownSet.size > 0) {
              alreadyKnownMessageIds = fetchedIds.filter((id) => knownSet.has(id));
              const newMessages = messages.filter((m: any) => !knownSet.has(m.messageId));
              inputData = { total: newMessages.length, messages: newMessages };
              console.log(`[v18 dedup] ${alreadyKnownMessageIds.length} message(s) already in ${recipe.output_table}; LLM will see ${newMessages.length} new`);
            }
          }
        }
      }

      // v18: if dedup left zero new messages, skip the LLM call entirely.
      // alreadyKnownMessageIds will be archived in the post-parse archive block below.
      const messagesAfterDedup = Array.isArray(inputData?.messages) ? inputData.messages.length : -1;
      if (messagesAfterDedup === 0) {
        parsedRecords = [];
        console.log(`[v18] all fetched messages already processed; skipping LLM call (${alreadyKnownMessageIds.length} known)`);
      } else {
        const inputForLLM = JSON.stringify(inputData).slice(0, 50000);
        const llmResult = await callGroqLLM({
          groqApiKey,
          systemPrompt: recipe.groq_prompt +
            '\n\nReturn a JSON object: {"records": [...]} where records is an array of objects ready to insert into the output_table. Return {"records": []} if nothing applicable.',
          userContent: inputForLLM,
        });
        if (!llmResult.ok) {
          throw new Error(`LLM parsing failed: ${llmResult.error}`);
        }
        parsedRecords = Array.isArray(llmResult.data?.records) ? llmResult.data.records : [];
      }
    } else if (recipe.output_table && Array.isArray(composioResult.data)) {
      // No LLM step — write raw composio data if it's already record-shaped
      parsedRecords = composioResult.data;
    }

    // --- Write to output_table ---
    if (recipe.output_table && parsedRecords.length > 0) {
      const writeResult = await writeOutput({
        outputTable: recipe.output_table,
        outputConfig: recipe.output_config || {},
        records: parsedRecords,
        agencyId: agencyId,
      });
      recordsProcessed = writeResult.inserted + writeResult.updated;
      outputSummary = `${recordsProcessed} records written to ${recipe.output_table}`;
      if (writeResult.secondary) {
        outputSummary += ` (+ ${writeResult.secondary.inserted} rows to ${writeResult.secondary.table})`;
      }
      // --- v16: post-parse archive (v18: also includes already-known messageIds) ---
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        const newMessageIds = parsedRecords.map((r: any) => r.source_message_id as string | undefined).filter((x): x is string => typeof x === "string" && x.length > 0);
        const allMessageIds = Array.from(new Set([...newMessageIds, ...alreadyKnownMessageIds]));
        if (allMessageIds.length > 0) {
          const archiveResult = await archiveProcessedGmailMessages({
            apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId,
            messageIds: allMessageIds, additionalLabelsToAdd: inputConfig.archive_label_ids_to_add as string[] | undefined,
          });
          if (archiveResult.ok) {
            outputSummary += ` — archived ${archiveResult.archived} email${archiveResult.archived === 1 ? "" : "s"} from inbox`;
            if (alreadyKnownMessageIds.length > 0) {
              outputSummary += ` (${alreadyKnownMessageIds.length} were already-known dups)`;
            }
          } else {
            outputSummary += ` — ⚠️ archive failed: ${archiveResult.error}`;
            await telegram(agencyId, `🟡 <b>Post-parse archive failed</b>\nRecipe: <b>${recipe.recipe_name}</b>\n${(archiveResult.error ?? "").slice(0, 400)}`);
          }
        } else {
          outputSummary += ` — archive skipped (no source_message_id in records)`;
        }
      }
    } else if (recipe.output_table && alreadyKnownMessageIds.length > 0) {
      // v18: All fetched messages were already in output_table — nothing new to write,
      // but still archive them from inbox so they do not keep showing up in fetches.
      outputSummary = `0 new records — ${alreadyKnownMessageIds.length} message(s) already processed historically`;
      if (recipe.composio_action === "GMAIL_FETCH_EMAILS" && inputConfig.archive_after_parse === true) {
        const archiveResult = await archiveProcessedGmailMessages({
          apiKey: composioApiKey, userId: composioUserId, connectedAccountId: accountId,
          messageIds: alreadyKnownMessageIds,
          additionalLabelsToAdd: inputConfig.archive_label_ids_to_add as string[] | undefined,
        });
        if (archiveResult.ok) {
          outputSummary += ` — archived ${archiveResult.archived} from inbox`;
        } else {
          outputSummary += ` — ⚠️ archive failed: ${archiveResult.error}`;
          await telegram(agencyId, `🟡 <b>Post-parse archive failed</b>\nRecipe: <b>${recipe.recipe_name}</b>\n${(archiveResult.error ?? "").slice(0, 400)}`);
        }
      }
    } else if (recipe.output_table) {
      outputSummary = `0 records — Composio returned data but LLM parsing yielded no records to write`;
    } else {
      // No output_table: this is an action-only recipe (e.g. send email,
      // post to social, archive). Composio call success is the result.
      outputSummary = `Action ${action} executed successfully (no output_table)`;
      recordsProcessed = 1;
    }
  } catch (err) {
    runStatus = "failed";
    errorMessage = err instanceof Error ? err.message : String(err);
    outputSummary = `Failed: ${errorMessage.slice(0, 200)}`;
    await telegram(
      agencyId,
      `🛑 <b>Automation FAILED</b>\n\nRecipe: <b>${recipe.recipe_name}</b>\nError: ${errorMessage.slice(0, 400)}`,
    );
  }

  const durationSec = Math.round((Date.now() - started) / 1000);

  // --- Write run log ---
  await sb.from("automation_run_log").insert({
    agency_id: agencyId,
    recipe_id: recipeId,
    status: runStatus,
    records_processed: recordsProcessed,
    error_message: errorMessage,
    duration_seconds: durationSec,
    output_summary: outputSummary,
  });

  // --- Update recipe status ---
  await sb
    .from("automation_recipes")
    .update({ last_run_status: runStatus })
    .eq("id", recipeId);

  return {
    recipe_id: recipeId,
    recipe_name: recipe.recipe_name,
    status: runStatus,
    records_processed: recordsProcessed,
    duration_seconds: durationSec,
    triggered_by: triggeredBy,
    error: errorMessage,
  };
}

// --- HTTP handler -------------------------------------------------------

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed. Use POST." }, 405);
  }

  let body: any = {};
  try {
    const text = await req.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const recipeId: string | undefined = body.recipe_id;
  const triggeredBy: string = body.triggered_by || "manual";

  if (!recipeId) {
    return jsonResponse({ error: "Missing recipe_id in body" }, 400);
  }
  if (typeof body.shared_secret !== "string" || body.shared_secret.length === 0) {
    return jsonResponse({ error: "Missing shared_secret in body" }, 401);
  }

  // Load the recipe to resolve agency_id, then auth against that agency's
  // shared secret. Order matters: we cannot look up the secret without an
  // agency_id, and we cannot trust the body's recipe_id without the secret —
  // but the recipe row only contains a UUID + agency_id (no secrets), so
  // reading it before auth leaks nothing.
  const { data: recipe, error: recipeErr } = await sb
    .from("automation_recipes")
    .select("*")
    .eq("id", recipeId)
    .maybeSingle();

  if (recipeErr || !recipe) {
    return jsonResponse(
      { error: `Recipe ${recipeId} not found: ${recipeErr?.message || "no row"}` },
      404,
    );
  }

  if (!recipe.agency_id) {
    return jsonResponse(
      {
        error:
          `Recipe ${recipeId} has no agency_id set. Every recipe must belong to an agency so its credentials can be resolved from settings.`,
      },
      500,
    );
  }

  // Auth — agency-scoped
  let expectedSecret: string | null;
  try {
    expectedSecret = await getSetting(recipe.agency_id, "automation_runner_cron_secret");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return jsonResponse({ error: `Auth lookup failed: ${msg}` }, 500);
  }
  if (!expectedSecret) {
    return jsonResponse(
      {
        error:
          `Server missing settings.automation_runner_cron_secret for agency ${recipe.agency_id}`,
      },
      500,
    );
  }
  if (body.shared_secret !== expectedSecret) {
    return jsonResponse({ error: "Unauthorized: invalid shared_secret" }, 401);
  }

  try {
    const result = await executeRecipe(recipe, triggeredBy);
    const status = result.status === "success" ? 200 : 500;
    return jsonResponse({ ok: result.status === "success", ...result }, status);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    await telegram(
      recipe.agency_id,
      `🛑 <b>automation-runner CRASHED</b>\n${msg.slice(0, 300)}`,
    );
    return jsonResponse({ ok: false, error: msg }, 500);
  }
});
