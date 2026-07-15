// =========================================================================
// document-processor bundle (auto-generated)
// Source of truth: supabase/functions/document-processor/*.ts (multi-file).
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python scripts/bundle_document_processor.py`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { BlobReader, ZipReader, Uint8ArrayWriter } from "jsr:@zip-js/zip-js@2";
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";

// ==================== lib/supabase.ts ====================
// =========================================================================
// lib/supabase.ts
// =========================================================================
// Shared Supabase client for the document-processor Edge Function.
// Service role key — bypasses RLS.
// =========================================================================


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

export const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

export async function getSetting(
  agencyId: string,
  key: string,
): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(
      `settings read failed for agency ${agencyId} key ${key}: ${error.message}`,
    );
  }
  return data?.setting_value ?? null;
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```$/, "")
    .trim();
}

// ==================== lib/composio.ts ====================
// =========================================================================
// lib/composio.ts
// =========================================================================
// Composio HTTP wrapper. Mirrors callComposio() from automation-runner so
// behavior stays identical — same auth shape, same response unwrapping.
// =========================================================================

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

export interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

export async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<ComposioCallResult> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: {
      "x-api-key": opts.apiKey,
      "Content-Type": "application/json",
    },
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
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

export async function callComposioNoAuth(opts: {
  apiKey: string;
  userId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<ComposioCallResult> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: {
      "x-api-key": opts.apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      user_id: opts.userId,
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
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: res.status };
}

// ==================== lib/llm.ts ====================
// =========================================================================
// lib/llm.ts  (v3 — direct Groq API)
// =========================================================================
// Single chokepoint for LLM calls inside the document-processor.
//
// CHANGED IN v3: Switched from COMPOSIO_SEARCH_GROQ_CHAT (which 404s on this
// agency's composio_api_key) to calling Groq's HTTPS endpoint directly using
// a `groq_api_key` setting.
//
// Behavior on failure:
//   1. Direct Groq call returns 4xx/5xx OR network error → fall through
//   2. LLM returns non-JSON content → fall through
//   3. Fall-through: INSERT into llm_parse_queue for workbench-side retry
//
// The queue path is now a true last resort, not the steady-state.
// =========================================================================


const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";

// Reads settings.groq_model_default for the agency; falls back to LLM_MODEL_FALLBACK
// if the row is missing OR the settings read errors.
async function getDefaultModel(agencyId: string): Promise<string> {
  try {
    const v = await getSetting(agencyId, "groq_model_default");
    return (v && v.trim()) || LLM_MODEL_FALLBACK;
  } catch (_e) {
    return LLM_MODEL_FALLBACK;
  }
}

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
}

export type ParseLLMResult =
  | { ok: true; json: any; raw: string }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

async function callGroqDirect(opts: {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userContent: string;
  maxTokens: number;
}): Promise<{ ok: boolean; raw: string; error: string | null; httpStatus: number }> {
  try {
    const res = await fetch(GROQ_ENDPOINT, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${opts.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: opts.model,
        messages: [
          { role: "system", content: opts.systemPrompt },
          { role: "user", content: opts.userContent },
        ],
        temperature: 0.1,
        max_tokens: opts.maxTokens,
        // Groq supports response_format hinting for newer models; safe to omit.
      }),
    });
    const text = await res.text();
    if (!res.ok) {
      return {
        ok: false,
        raw: "",
        error: `Groq HTTP ${res.status}: ${text.slice(0, 400)}`,
        httpStatus: res.status,
      };
    }
    let parsed: any;
    try { parsed = JSON.parse(text); }
    catch (e) {
      return { ok: false, raw: text, error: `Groq returned non-JSON envelope: ${String(e)}`, httpStatus: res.status };
    }
    const content = parsed?.choices?.[0]?.message?.content ?? "";
    if (!content || typeof content !== "string") {
      return { ok: false, raw: "", error: "Groq returned empty content", httpStatus: res.status };
    }
    return { ok: true, raw: content, error: null, httpStatus: res.status };
  } catch (e) {
    return { ok: false, raw: "", error: `Groq fetch failed: ${(e as Error).message}`, httpStatus: 0 };
  }
}

export async function parseWithLLM(opts: ParseLLMOpts): Promise<ParseLLMResult> {
  // Step 0: resolve the model once — settings.groq_model_default or fallback
  const model = opts.model ?? await getDefaultModel(opts.agencyId);

  // Step 1: load the Groq API key for this agency
  const groqKey = await getSetting(opts.agencyId, "groq_api_key");

  // Step 2: try the direct Groq call (if key is present)
  if (groqKey) {
    const llm = await callGroqDirect({
      apiKey: groqKey,
      model,
      systemPrompt: opts.systemPrompt,
      userContent: opts.userContent,
      maxTokens: opts.maxTokens ?? 4000,
    });

    if (llm.ok) {
      const cleaned = stripFences(llm.raw);
      try {
        return { ok: true, json: JSON.parse(cleaned), raw: cleaned };
      } catch (_e) {
        // LLM returned non-JSON content. Fall through to queue with the raw
        // content recorded as user_content so workbench can salvage it later.
      }
    }
    // Any failure path falls through to the queue below.
  }

  // Step 3: queue for workbench-side processing (true last resort)
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
    })
    .select("id")
    .single();

  if (error || !data) {
    return {
      ok: false,
      queued: false,
      error: `Groq direct call failed AND queue insert failed: ${error?.message ?? "unknown"}`,
    };
  }

  return { ok: false, queued: true, queueId: data.id };
}

// ==================== classifier.ts ====================
// =========================================================================
// classifier.ts
// =========================================================================
// 1. classifyBankTxn(): matches a bank transaction against
//    gl_classification_rules (priority-ordered). The catch-all SUSPENSE rule
//    guarantees a result.
// 2. classifyDocument(): determines the docType from filename + sender.
//    Rules try sender-based matches first, then fall back to filename-only
//    pattern matches so files extracted from zips classify correctly
//    without sender context.
// =========================================================================


export interface BankTxn {
  payee: string;
  memo: string;
  signedAmount: number;
  sourceAccountCode: string;
}

export interface ClassificationResult {
  ruleId: string;
  ruleName: string;
  debitAccountCode: string;
  creditAccountCode: string;
  subCategoryLabel: string | null;
  confidence: "exact" | "high" | "medium" | "low" | "suspense";
  isSuspense: boolean;
}

interface RawRule {
  id: string;
  rule_name: string;
  match_priority: number;
  match_payee_regex: string | null;
  match_memo_regex: string | null;
  match_source_account: string | null;
  match_amount_min: number | null;
  match_amount_max: number | null;
  match_direction: string;
  debit_account_code: string;
  credit_account_code: string;
  sub_category_label: string | null;
  confidence: string;
}

let rulesCache: { agencyId: string; rules: RawRule[]; loadedAt: number } | null = null;
const CACHE_TTL_MS = 60_000;

async function loadRules(agencyId: string): Promise<RawRule[]> {
  const now = Date.now();
  if (rulesCache && rulesCache.agencyId === agencyId && now - rulesCache.loadedAt < CACHE_TTL_MS) {
    return rulesCache.rules;
  }
  const { data, error } = await sb
    .from("gl_classification_rules")
    .select("id, rule_name, match_priority, match_payee_regex, match_memo_regex, match_source_account, match_amount_min, match_amount_max, match_direction, debit_account_code, credit_account_code, sub_category_label, confidence")
    .eq("agency_id", agencyId)
    .eq("is_active", true)
    .order("match_priority", { ascending: true });
  if (error) throw new Error(`gl_classification_rules load failed: ${error.message}`);
  rulesCache = { agencyId, rules: (data ?? []) as RawRule[], loadedAt: now };
  return rulesCache.rules;
}

function safeRegexTest(pattern: string, text: string): boolean {
  try { return new RegExp(pattern, "i").test(text); } catch { return false; }
}

function ruleMatches(rule: RawRule, txn: BankTxn): boolean {
  const direction = txn.signedAmount > 0 ? "credit" : "debit";
  if (rule.match_direction !== "both" && rule.match_direction !== direction) return false;
  if (rule.match_payee_regex && !safeRegexTest(rule.match_payee_regex, txn.payee)) return false;
  if (rule.match_memo_regex && !safeRegexTest(rule.match_memo_regex, txn.memo)) return false;
  if (rule.match_source_account && rule.match_source_account !== txn.sourceAccountCode) return false;
  const amt = Math.abs(txn.signedAmount);
  if (rule.match_amount_min !== null && amt < rule.match_amount_min) return false;
  if (rule.match_amount_max !== null && amt > rule.match_amount_max) return false;
  return true;
}

function resolveSource(code: string, txn: BankTxn): string {
  return code === "__SOURCE__" ? txn.sourceAccountCode : code;
}

export async function classifyBankTxn(agencyId: string, txn: BankTxn): Promise<ClassificationResult> {
  const rules = await loadRules(agencyId);
  for (const rule of rules) {
    if (!ruleMatches(rule, txn)) continue;
    return {
      ruleId: rule.id,
      ruleName: rule.rule_name,
      debitAccountCode: resolveSource(rule.debit_account_code, txn),
      creditAccountCode: resolveSource(rule.credit_account_code, txn),
      subCategoryLabel: rule.sub_category_label,
      confidence: rule.confidence as ClassificationResult["confidence"],
      isSuspense: rule.confidence === "suspense",
    };
  }
  // Suspense: preserve source-account attribution on the appropriate leg so
  // bank/CC balance in journal_lines reflects unclassified activity. When the
  // agent classifies the item later, only the COA-SUSP leg swaps to the real
  // expense/income account.
  //   Outflow (money leaves bank/increases CC): DEBIT SUSP,   CREDIT source
  //   Inflow  (money enters bank/reduces CC):   DEBIT source, CREDIT SUSP
  const isOutflow = txn.signedAmount < 0;
  return {
    ruleId: "00000000-0000-0000-0000-000000000000",
    ruleName: "SUSPENSE (synthetic — no catch-all rule found)",
    debitAccountCode: isOutflow ? "COA-SUSP" : txn.sourceAccountCode,
    creditAccountCode: isOutflow ? txn.sourceAccountCode : "COA-SUSP",
    subCategoryLabel: "Pending agent classification",
    confidence: "suspense",
    isSuspense: true,
  };
}

export function invalidateRulesCache(): void { rulesCache = null; }

export type DocType =
  | "bank_statement_primary"
  | "bank_statement_secondary"
  | "bank_statement_pfa"
  | "comp_recap_1h"
  | "comp_recap_daily"
  | "deduction_statement"
  | "adp_payroll"
  | "surepayroll_payroll"
  | "commission_report"
  | "team_production"
  | "careerplug_applicant"
  | "archive_bundle"
  | "skip";

export interface DocClassifyInput {
  fromEmail: string;
  subject: string;
  fileName: string;
}

const docRules: Array<{ docType: DocType; test: (i: DocClassifyInput) => boolean }> = [
  // ----- SUREPAYROLL (v37 PDF 2026-07-07, v53 +CSV 2026-07-14) —
  //       SF-forwarded SurePayroll summary. Deterministic parsers for both
  //       formats: unpdf regex for PDF, header-mapped column parser for CSV. -----
  { docType: "surepayroll_payroll",
    test: (i) => /statefarm/i.test(i.fromEmail)
              && /payroll/i.test(i.subject + " " + i.fileName)
              && /\.(pdf|csv)$/i.test(i.fileName) },

  // ----- SUREPAYROLL non-parseable attachments (inline images) — SKIP silently.
  { docType: "skip",
    test: (i) => /statefarm/i.test(i.fromEmail)
              && /payroll/i.test(i.subject)
              && !/\.(pdf|csv)$/i.test(i.fileName) },

  // ----- ARCHIVE — any .zip is unpacked, contents reclassified individually -----
  { docType: "archive_bundle",
    test: (i) => /\.zip$/i.test(i.fileName) },

  // ----- CAREERPLUG APPLICANT (2026-07-13) — resume PDF attached to a
  //       CareerPlug new-applicant notification. The parent notification
  //       email is handled by processCareerplugMode (called via body.mode
  //       === "careerplug"), which owns applicant intake. This rule catches
  //       the case where a resume PDF also arrives through the standard
  //       attachment pipeline; classifying as careerplug_applicant routes
  //       it to a lightweight handler (see index.ts). -----
  { docType: "careerplug_applicant",
    test: (i) => /careerplug/i.test(i.fromEmail) &&
                 /\.pdf$/i.test(i.fileName) &&
                 /resume|cv|applicant/i.test(i.fileName + " " + i.subject) },

  // ----- FROST PFA STATEMENT (2026-07-09) — must come BEFORE the generic
  //       bank statement rules. Sender = Frost Bank; subject/filename mentions
  //       "PFA", "premium fund", or the PFA account number 020715816. -----
  { docType: "bank_statement_pfa",
    test: (i) => /frost/i.test(i.fromEmail + " " + i.subject) &&
                 /(pfa|premium\s?fund|020715816)/i.test(i.subject + " " + i.fileName) },
  { docType: "bank_statement_pfa",
    test: (i) => /020715816/.test(i.subject + " " + i.fileName) },

  // ----- BANK / CC STATEMENTS — sender drives classification -----
  { docType: "bank_statement_primary",
    test: (i) => /usbank|us[\s_-]?bank|usbank\.com/i.test(i.fromEmail + " " + i.subject) &&
                 /statement|estatement/i.test(i.fileName + " " + i.subject) },
  { docType: "bank_statement_secondary",
    test: (i) => /(chase|bankofamerica|trb|truist|wells\s?fargo|amex|american[\s_-]?express|capital[\s_-]?one|citi|spark)/i.test(i.fromEmail + " " + i.subject) &&
                 /statement|estatement/i.test(i.fileName + " " + i.subject) },

  // ----- STATE FARM COMP RECAP — sender path (live SF emails) -----
  { docType: "comp_recap_1h",
    test: (i) => /statefarm|sf\s?agent|sf[\s.-]?ach/i.test(i.fromEmail + " " + i.subject) &&
                 /1h|hour|hourly/i.test(i.subject + " " + i.fileName) },
  { docType: "comp_recap_daily",
    test: (i) => /statefarm/i.test(i.fromEmail) &&
                 /comp\s?recap|daily\s?comp/i.test(i.subject + " " + i.fileName) },

  // ----- STATE FARM COMP RECAP — filename-only fallback (zip contents,
  //       Marie's forwarded emails). Pattern: "YY_MM_DD Compensation.pdf" -----
  { docType: "comp_recap_daily",
    test: (i) => /^\d{2}_\d{2}_\d{2}\s+Compensation\.pdf$/i.test(filenameBase(i.fileName)) },
  { docType: "comp_recap_daily",
    test: (i) => /Compensation\.pdf$/i.test(i.fileName) && /\d{2}_\d{2}_\d{2}/.test(i.fileName) },

  // ----- DEDUCTION STATEMENT — sender path -----
  { docType: "deduction_statement",
    test: (i) => /statefarm/i.test(i.fromEmail) && /deduction/i.test(i.subject + " " + i.fileName) },
  // ----- DEDUCTION STATEMENT — filename-only fallback for zip contents -----
  { docType: "deduction_statement",
    test: (i) => /^\d{2}_\d{2}_\d{2}\s+Deductions?(\s+Misc)?\.pdf$/i.test(filenameBase(i.fileName)) },
  { docType: "deduction_statement",
    test: (i) => /Deductions?(\s+Misc)?\.pdf$/i.test(i.fileName) && /\d{2}_\d{2}_\d{2}/.test(i.fileName) },

  // ----- ADP / GUSTO PAYROLL — sender path -----
  { docType: "adp_payroll",
    test: (i) => /adp\.com|workforcenow|gusto/i.test(i.fromEmail + " " + i.subject) },
  // ----- PAYROLL — filename-only fallback for zip contents -----
  { docType: "adp_payroll",
    test: (i) => /\b(payroll|paystub|pay[\s_-]?run|paycheck)\b/i.test(filenameBase(i.fileName)) },

  // ----- COMMISSION REPORT (specific) -----
  { docType: "commission_report",
    test: (i) => /commission/i.test(i.subject + " " + i.fileName) &&
                 !/comp\s?recap/i.test(i.subject) },

  // ----- TEAM PRODUCTION REPORT -----
  { docType: "team_production",
    test: (i) => /production\s?report|team\s?production/i.test(i.subject + " " + i.fileName) },
];

function filenameBase(p: string): string {
  // strip any leading folder prefix (e.g. "2025/25_03_11 Compensation.pdf")
  const lastSlash = p.lastIndexOf("/");
  return lastSlash >= 0 ? p.slice(lastSlash + 1) : p;
}

export function classifyDocument(input: DocClassifyInput): DocType {
  for (const r of docRules) {
    if (r.test(input)) return r.docType;
  }
  return "skip";
}

// ----- helpers used by orchestrator for zip contents -----

/**
 * Infer the document date (YYYY-MM-DD) from a filename of the form
 * "YY_MM_DD Compensation.pdf" or "2025/25_03_11 Compensation.pdf".
 * Returns null if no date pattern is found.
 *
 * Used for Drive folder routing and as a fallback when an extracted file
 * has no email receivedAt to lean on.
 */
export function inferDateFromFilename(fileName: string): string | null {
  const base = filenameBase(fileName);
  const m = base.match(/(\d{2})_(\d{2})_(\d{2})/);
  if (!m) return null;
  const yy = parseInt(m[1], 10);
  const mm = parseInt(m[2], 10);
  const dd = parseInt(m[3], 10);
  if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null;
  // Two-digit years 00-79 → 2000s, 80-99 → 1900s (irrelevant for our purposes)
  const yyyy = yy < 80 ? 2000 + yy : 1900 + yy;
  return `${yyyy}-${String(mm).padStart(2, "0")}-${String(dd).padStart(2, "0")}`;
}

// ==================== gl-poster.ts ====================
// =========================================================================
// gl-poster.ts
// =========================================================================
// Writes balanced double-entry journal entries from classified bank txns.
// Two-step: INSERT header to journal_entries, then 2 rows in journal_lines.
//
// Idempotency: every JE carries a deterministic reference_number derived
// from (source_account, txn_date, signed_amount, payee_hash). Re-inserting
// the same bank txn is a no-op.
// =========================================================================


export interface PostGLInput {
  agencyId: string;
  txn: BankTxn;
  txnDate: string;
  classification: ClassificationResult;
  sourceDocumentId: string | null;
}

export interface PostGLResult {
  journalEntryId: string | null;
  skipped: boolean;
  skipReason: string | null;
  isSuspense: boolean;
}

// In-memory counter to disambiguate multiple bank txns that share the same
// (source, date, amount, payee-short) fingerprint (e.g., 5 identical Plarium
// $32.39 charges on the same day). First occurrence uses the base reference;
// subsequent occurrences append :2, :3, etc. Preserves idempotency across
// re-runs of the same document since txn order is stable.
//
// MUST be reset at the start of processing each document via
// resetReferenceCounters(); otherwise counter state leaks across docs and a
// later doc's identical-fingerprint txn gets a spurious :N suffix.
const refCounters = new Map<string, number>();

export function resetReferenceCounters(): void {
  refCounters.clear();
}

function makeReference(input: PostGLInput): string {
  const payeeShort = (input.txn.payee || "")
    .toLowerCase()
    .replace(/[^a-z0-9]/g, "")
    .slice(0, 20);
  const amtCents = Math.round(Math.abs(input.txn.signedAmount) * 100);
  const base = `dp:${input.txn.sourceAccountCode}:${input.txnDate}:${amtCents}:${payeeShort}`;
  const count = (refCounters.get(base) ?? 0) + 1;
  refCounters.set(base, count);
  return count === 1 ? base : `${base}:${count}`;
}

async function lookupAccountId(agencyId: string, accountCode: string): Promise<string | null> {
  const { data, error } = await sb
    .from("chart_of_accounts")
    .select("id")
    .eq("agency_id", agencyId)
    .eq("account_code", accountCode)
    .maybeSingle();
  if (error) throw new Error(`COA lookup failed for ${accountCode}: ${error.message}`);
  return data?.id ?? null;
}

export async function postJournalEntry(input: PostGLInput): Promise<PostGLResult> {
  const reference = makeReference(input);

  const { data: existing } = await sb
    .from("journal_entries")
    .select("id")
    .eq("agency_id", input.agencyId)
    .eq("reference_number", reference)
    .maybeSingle();
  if (existing?.id) {
    return {
      journalEntryId: existing.id,
      skipped: true,
      skipReason: "duplicate reference_number",
      isSuspense: input.classification.isSuspense,
    };
  }

  const debitId = await lookupAccountId(input.agencyId, input.classification.debitAccountCode);
  const creditId = await lookupAccountId(input.agencyId, input.classification.creditAccountCode);
  if (!debitId || !creditId) {
    throw new Error(`Account code not found: debit=${input.classification.debitAccountCode} credit=${input.classification.creditAccountCode}`);
  }

  const description = input.classification.subCategoryLabel
    ? `${input.txn.payee} — ${input.classification.subCategoryLabel}`
    : input.txn.payee;

  const { data: je, error: jeErr } = await sb
    .from("journal_entries")
    .insert({
      agency_id: input.agencyId,
      entry_date: input.txnDate,
      entry_type: "bank_txn",
      reference_number: reference,
      description,
      memo: input.txn.memo || null,
      source: "document_processor",
      document_id: input.sourceDocumentId,
      classification_status: input.classification.isSuspense ? "pending_review" : "classified",
      suspense_reason: input.classification.isSuspense ? "no_rule_match" : null,
      rule_id_used: input.classification.ruleId.startsWith("00000000") ? null : input.classification.ruleId,
      classified_by: input.classification.isSuspense ? null : "rule",
      classified_at: input.classification.isSuspense ? null : new Date().toISOString(),
    })
    .select("id")
    .single();
  if (jeErr || !je) throw new Error(`journal_entries insert failed: ${jeErr?.message ?? "unknown"}`);

  const amount = Math.abs(input.txn.signedAmount);

  const { error: linesErr } = await sb.from("journal_lines").insert([
    { journal_entry_id: je.id, agency_id: input.agencyId, account_id: debitId,  debit: amount, credit: 0,      description },
    { journal_entry_id: je.id, agency_id: input.agencyId, account_id: creditId, debit: 0,      credit: amount, description },
  ]);
  if (linesErr) {
    await sb.from("journal_entries").delete().eq("id", je.id);
    throw new Error(`journal_lines insert failed: ${linesErr.message}`);
  }

  if (!input.classification.ruleId.startsWith("00000000")) {
    await sb
      .from("gl_classification_rules")
      .update({ last_used_at: new Date().toISOString() })
      .eq("id", input.classification.ruleId);
  }

  return { journalEntryId: je.id, skipped: false, skipReason: null, isSuspense: input.classification.isSuspense };
}

// ==================== suspense.ts ====================
// =========================================================================
// suspense.ts
// =========================================================================
// For each JE that landed in COA-SUSP, create a task in the tasks table so
// the agent can classify it. Task includes up to 3 LLM-ranked best guesses.
//
// Priority by amount:  >$500=high, $100-500=medium, <$100=low
// =========================================================================


export interface SuspenseTaskInput {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  journalEntryId: string;
  txn: BankTxn;
  txnDate: string;
}

function priorityForAmount(amount: number): "high" | "medium" | "low" {
  if (amount > 500) return "high";
  if (amount >= 100) return "medium";
  return "low";
}

async function loadRuleSummaries(agencyId: string) {
  const { data } = await sb
    .from("gl_classification_rules")
    .select("id, rule_name, debit_account_code, credit_account_code, sub_category_label, confidence")
    .eq("agency_id", agencyId)
    .eq("is_active", true)
    .neq("confidence", "suspense")
    .order("match_priority", { ascending: true });
  return (data ?? []).map((r: any) => ({
    id: r.id, name: r.rule_name, debit: r.debit_account_code,
    credit: r.credit_account_code, sub: r.sub_category_label,
  }));
}

async function generateBestGuesses(input: SuspenseTaskInput): Promise<string> {
  const rules = await loadRuleSummaries(input.agencyId);
  if (rules.length === 0) return "(no existing rules to compare against)";

  const systemPrompt =
    "You are an accounting assistant for a State Farm insurance agency. " +
    "You are shown a bank transaction and a list of existing classification rules. " +
    "Pick the THREE most likely correct rules to apply, ranked best first. " +
    "Reply with raw JSON only (no fences, no prose) in this exact shape: " +
    `{"guesses":[{"rule_id":"<uuid>","reason":"<brief>"},{"rule_id":"<uuid>","reason":"<brief>"},{"rule_id":"<uuid>","reason":"<brief>"}]}`;

  const userContent =
    `Transaction:\n` +
    `  Date: ${input.txnDate}\n` +
    `  Payee: ${input.txn.payee}\n` +
    `  Memo: ${input.txn.memo}\n` +
    `  Amount: ${input.txn.signedAmount.toFixed(2)} (${input.txn.signedAmount > 0 ? "in" : "out"})\n` +
    `  Source account: ${input.txn.sourceAccountCode}\n\n` +
    `Existing rules (id — name — debit/credit — sub):\n` +
    rules.map((r) => `  ${r.id} — ${r.name} — ${r.debit}/${r.credit} — ${r.sub ?? ""}`).join("\n");

  const result = await parseWithLLM({
    agencyId: input.agencyId,
    composioApiKey: input.composioApiKey,
    composioUserId: input.composioUserId,
    systemPrompt, userContent,
    documentId: null,
    purpose: "suspense_guesses",
    maxTokens: 800,
  });

  if (result.ok) {
    const guesses = (result.json?.guesses ?? []).slice(0, 3);
    const byId = new Map(rules.map((r) => [r.id, r]));
    return guesses.map((g: any, i: number) => {
      const r = byId.get(g.rule_id);
      if (!r) return `  ${i + 1}. (rule not found)`;
      return `  ${i + 1}. ${r.name} → debit ${r.debit}, credit ${r.credit}\n      Reason: ${g.reason ?? ""}`;
    }).join("\n");
  }

  // Fallback: lexical match
  const payeeLower = input.txn.payee.toLowerCase();
  const memoLower = input.txn.memo.toLowerCase();
  const scored = rules.map((r) => {
    let score = 0;
    for (const word of r.name.toLowerCase().split(/\W+/).filter(Boolean)) {
      if (payeeLower.includes(word)) score += 2;
      if (memoLower.includes(word)) score += 1;
    }
    return { r, score };
  }).sort((a, b) => b.score - a.score).slice(0, 3);

  if (scored[0]?.score === 0) return "(no lexical matches — please classify manually)";
  return scored.map((s, i) =>
    `  ${i + 1}. ${s.r.name} → debit ${s.r.debit}, credit ${s.r.credit}`
  ).join("\n");
}

export async function createSuspenseTask(input: SuspenseTaskInput): Promise<{ taskId: string }> {
  const amount = Math.abs(input.txn.signedAmount);
  const direction = input.txn.signedAmount > 0 ? "in" : "out";
  const guesses = await generateBestGuesses(input);

  const title = `Classify: $${amount.toFixed(2)} ${direction} — ${input.txn.payee.slice(0, 50)}`;
  const description =
    `Suspense queue item — needs classification.\n\n` +
    `Date: ${input.txnDate}\n` +
    `Payee: ${input.txn.payee}\n` +
    `Memo: ${input.txn.memo}\n` +
    `Amount: $${amount.toFixed(2)} (${direction})\n` +
    `Source: ${input.txn.sourceAccountCode}\n` +
    `JE: ${input.journalEntryId}\n\n` +
    `Best guesses:\n${guesses}\n\n` +
    `Reply in chat with the number, the rule name, or your own classification. ` +
    `I'll update the JE and add a new rule so this never hits suspense again.`;

  const { data, error } = await sb
    .from("tasks")
    .insert({
      agency_id: input.agencyId,
      title, description,
      created_by: "document_processor",
      priority: priorityForAmount(amount),
      status: "open",
      module_reference: "financials/suspense",
      related_id: input.journalEntryId,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`suspense task insert failed: ${error?.message ?? "unknown"}`);
  return { taskId: data.id };
}

// ==================== parsers/bank.ts ====================
// =========================================================================
// parsers/bank.ts
// =========================================================================
// Parses bank statement text into a list of normalized transactions ready
// for classification + GL posting. Uses parseWithLLM which falls back to a
// queue if the in-runner LLM call fails.
// =========================================================================


export interface ParsedBankStatement {
  ok: true;
  statementPeriod: { start: string; end: string };
  accountLast4: string | null;
  transactions: Array<{ date: string; txn: BankTxn }>;
}

export type ParseBankResult =
  | ParsedBankStatement
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT_BANK = `
You are a parser for U.S. bank statements. You will be given the text of one
statement covering a single account. Extract the statement period, the
account's last 4 digits, and every transaction in this exact JSON shape — no
prose, no markdown fences, no explanation:

{
  "statement_period": { "start": "YYYY-MM-DD", "end": "YYYY-MM-DD" },
  "account_last4": "<4 digits or null>",
  "transactions": [
    {
      "date": "YYYY-MM-DD",
      "payee": "<vendor / merchant / counterparty>",
      "memo": "<any additional description; empty string if none>",
      "amount": <number; NEGATIVE for money out, POSITIVE for money in>
    }
  ]
}

Rules:
- Skip beginning balance, ending balance, and "Total" summary lines.
- Skip non-transactional informational lines.
- Combine multi-line transaction descriptions into the single payee/memo pair.
- Use ISO dates only.
- All amounts as JSON numbers, never strings.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parseBankStatement(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  sourceAccountCode: string;
  statementText: string;
  documentId: string | null;
}): Promise<ParseBankResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT_BANK,
    userContent: opts.statementText,
    documentId: opts.documentId,
    purpose: "parse_bank_statement",
    maxTokens: 6000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const json = result.json;
  const period = json?.statement_period;
  if (!period?.start || !period?.end) {
    return { ok: false, queued: false, error: "LLM response missing statement_period.start or .end" };
  }

  const rawTxns: any[] = Array.isArray(json?.transactions) ? json.transactions : [];
  const transactions: Array<{ date: string; txn: BankTxn }> = [];
  for (const t of rawTxns) {
    if (!t || typeof t.amount !== "number" || !t.date) continue;
    const payee = String(t.payee ?? "").trim();
    if (!payee) continue;
    transactions.push({
      date: String(t.date),
      txn: {
        payee,
        memo: String(t.memo ?? "").trim(),
        signedAmount: t.amount,
        sourceAccountCode: opts.sourceAccountCode,
      },
    });
  }

  return {
    ok: true,
    statementPeriod: { start: period.start, end: period.end },
    accountLast4: json?.account_last4 ?? null,
    transactions,
  };
}

// ==================== parsers/comp_recap.ts ====================
// =========================================================================
// parsers/comp_recap.ts (v2 — deterministic regex parser)
// =========================================================================
// Parses State Farm semi-monthly agency compensation recap PDFs into
// structured comp_recap rows.
//
// REPLACES the prior LLM-based parser (v1, 2026-05). Decision rationale:
//   - The SF recap format has been stable for 30+ years.
//   - The LLM-based approach produced two recurring failures:
//       (1) silent payload truncation on bigger comp PDFs (>~2K char output)
//           leaving rows missing or malformed JSON;
//       (2) wrong-column extraction on deduction docs (LLM grabbed the
//           YEAR-TO-DATE column instead of CURRENT).
//   - The format is fully mechanical: a line with ONE money number is YTD
//     only (skipped); a line with TWO money numbers is CURRENT then YTD
//     (current captured).
//
// VERIFIED RECONCILIATIONS:
//   - June 1-15 2026: 22 rows, Texas current $19,488.67,
//     total $19,677.49 (matches SF NET PAYABLE $19,220.32 after deductions).
//   - May 16-31 2026: 20 rows, Texas current $26,899.94,
//     total $26,900.75 (matches SF NET PAYABLE $25,614.19 after deductions).
//
// FORMAT REFERENCE (real example):
//   "1RECAPITULATION OF AGENCY COMPENSATION AND REIMBURSEMENTS FOR JUNE 1-15, 2026"
//   "1ARKANSAS CODE 04-1BDD"                       <- state header
//   "1COMPANY DESCRIPTION CURRENT YEAR-TO-DATE"
//   "1MUTL AUTO NEW BUSINESS .50-"                 <- YTD only, skip
//   "1 AUTO RENEWAL SERVICE .19- 200.12"           <- current=-0.19 (under MUTL)
//   "1 TOTAL MUTL ******** .19- *** 199.62"        <- subtotal, skip
//   "1SFL FIRST YEAR WRITING 3.92 23.52"            <- new company starts: SFL
//   ...repeating per state, ending with Texas (no explicit "TEXAS CODE" header)
// =========================================================================


export interface CompRecapRow {
  period_year: number;
  period_month: number;
  period_day: number;
  comp_type: string;          // "1H" (days 1-15) or "2H" (days 16-EOM)
  comp_category: string;
  description: string;
  amount: number;
  is_aipp_eligible: boolean;
  is_scorecard_eligible: boolean;
}

export type ParseCompRecapResult =
  | { ok: true; rows: CompRecapRow[]; written: number; period: PeriodInfo; texas_current_total: number }
  | { ok: false; error: string };

interface PeriodInfo { year: number; month: number; day: number; comp_type: "1H" | "2H" }

// --- Period header ----------------------------------------------------------
const MONTHS: Record<string, number> = {
  JANUARY: 1, FEBRUARY: 2, MARCH: 3, APRIL: 4, MAY: 5, JUNE: 6,
  JULY: 7, AUGUST: 8, SEPTEMBER: 9, OCTOBER: 10, NOVEMBER: 11, DECEMBER: 12,
};
function parsePeriod(text: string): PeriodInfo | null {
  const m = text.match(/FOR\s+([A-Z]+)\s+(\d+)\s*-\s*(\d+),\s*(\d{4})/i);
  if (!m) return null;
  const month = MONTHS[m[1].toUpperCase()];
  if (!month) return null;
  const startDay = parseInt(m[2], 10);
  const endDay = parseInt(m[3], 10);
  const year = parseInt(m[4], 10);
  return { year, month, day: endDay, comp_type: startDay === 1 ? "1H" : "2H" };
}

// --- State header / description prefix --------------------------------------
const STATE_CODE: Record<string, string> = {
  ARKANSAS: "AR (04)", "NEW MEXICO": "NM (31)", OKLAHOMA: "OK (36)", TEXAS: "",
};
function detectStateHeader(raw: string): string | null {
  const cleaned = raw.replace(/^1\s*/, "").trim();
  for (const [name, prefix] of Object.entries(STATE_CODE)) {
    if (cleaned.startsWith(name + " CODE ")) return prefix;
  }
  return null;
}

// --- Company tracking -------------------------------------------------------
// Lines like "1MUTL AUTO NEW BUSINESS ..." start a new company section; the
// "MUTL" tag persists for subsequent continuation lines that start with "1 ".
const COMPANY_TAGS = new Set(["MUTL", "SFL", "FIRE", "LLYD", "TCM", "IPSI", "SFVC", "SFCL", "GFA"]);
const COMPANY_TAG_RE = /^1([A-Z]+)\s+/;
function detectCompany(raw: string): string | null {
  const m = raw.match(COMPANY_TAG_RE);
  if (!m) return null;
  return COMPANY_TAGS.has(m[1]) ? m[1] : null;
}

// Companies whose rows ALWAYS belong to a fixed comp_category, regardless of
// description (e.g. all IPSI/SFVC items are investment products → ips_renewal).
const COMPANY_CATEGORY: Record<string, { category: string; aipp: boolean }> = {
  IPSI: { category: "ips_renewal", aipp: false },
  SFVC: { category: "ips_renewal", aipp: false },
};

// --- Amount parser ----------------------------------------------------------
function parseAmount(s: string): number | null {
  const cleaned = s.replace(/,/g, "").trim();
  const negative = cleaned.endsWith("-");
  const num = parseFloat(negative ? cleaned.slice(0, -1) : cleaned);
  if (isNaN(num)) return null;
  return negative ? -num : num;
}

// --- Description → category mapping -----------------------------------------
interface CatRule { test: RegExp; category: string; aipp: boolean }
const CATEGORY_RULES: CatRule[] = [
  // Health
  { test: /HEALTH NEW BUSINESS/i,                category: "health_new",    aipp: false },
  { test: /HEALTH RENEWAL SERVICE/i,             category: "health_renewal",aipp: false },
  { test: /MED SUPP/i,                           category: "health_renewal",aipp: false },
  // Life (SFL — traditional life)
  { test: /FIRST YEAR WRITING/i,                 category: "life_new",      aipp: false },
  { test: /RENEWAL WRITING/i,                    category: "life_renewal",  aipp: false },
  { test: /^SERVICING$/i,                        category: "life_renewal",  aipp: false }, // SFL bare-word SERVICING
  // Fire — Lloyds + TCM-fire + generic FIRE (order matters: Lloyds first)
  { test: /LLYD NEW BUSINESS|LLOYDS NEW/i,       category: "fire_new",      aipp: true  },
  { test: /RENEWAL SERVICE - LLOYDS/i,           category: "fire_renewal",  aipp: true  },
  { test: /TCM FIRE NEW BUSINESS/i,              category: "fire_new",      aipp: true  },
  { test: /TCM FIRE RENEWAL SERVICE/i,           category: "fire_renewal",  aipp: true  },
  { test: /FIRE NEW BUSINESS/i,                  category: "fire_new",      aipp: true  },
  { test: /FIRE RENEWAL SERVICE/i,               category: "fire_renewal",  aipp: true  },
  // Auto
  { test: /TCM AUTO NEW BUSINESS/i,              category: "auto_new",      aipp: true  },
  { test: /TCM AUTO RENEWAL SERVICE/i,           category: "auto_renewal",  aipp: true  },
  { test: /AUTO NEW BUSINESS/i,                  category: "auto_new",      aipp: true  },
  { test: /AUTO NEW\s*-\s*AMD/i,                 category: "auto_new",      aipp: true  },
  { test: /AUTO RENEWAL SERVICE/i,               category: "auto_renewal",  aipp: true  },
  { test: /AUTO RENEWAL\s*-\s*AMD/i,             category: "auto_renewal",  aipp: true  },
  // SF Classic (historical classification: auto_new)
  { test: /SF CLASSIC NEW BUSINESS/i,            category: "auto_new",      aipp: false },
  // GFA — US Bank deposits (banking referral, not insurance)
  { test: /US BANK NEW DEPOSIT/i,                category: "other",         aipp: false },
];

function classifyLine(desc: string, company: string | null): { category: string; aipp: boolean } {
  // Company-context wins (covers continuation lines like "IPS BROKERAGE
  // ACCOUNTS TRAIL COMMISSIONS" under SFVC that don't carry the SFVC token).
  if (company && COMPANY_CATEGORY[company]) return COMPANY_CATEGORY[company];
  for (const rule of CATEGORY_RULES) if (rule.test.test(desc)) return { category: rule.category, aipp: rule.aipp };
  return { category: "other", aipp: false };
}

// --- Skip patterns ----------------------------------------------------------
const SKIP_RE: RegExp[] = [
  /^1RECAPS/i, /^1\s*STATE FARM INSURANCE/i, /^1\s*ONE STATE FARM/i,
  /^1\s*BLOOMINGTON/i, /^1\s*RECAPITULATION/i, /^1NAME/i, /^1\s*ASSIGNED/i,
  /^1\s*\*\s*\*\s*\*/i,                  // section dividers
  /^1[A-Z\s]+CODE \d{2}-\dBDD\s*$/i,         // state header lines (handled separately)
  /^1COMPANY DESCRIPTION/i,
  /TOTAL\s+\w+\s+\*{4,}/i,                  // "TOTAL MUTL ********" subtotals
  /^1TOTAL\s+\*{4,}/i,                       // grand totals
];

// --- Line extractor ---------------------------------------------------------
// Captures lines with one or two money columns at end of line.
//   "1 AUTO RENEWAL SERVICE .19- 200.12"     → cur=-0.19, ytd=200.12
//   "1MUTL AUTO NEW BUSINESS 1,170.06 ..."   → cur=1170.06
//   "1MUTL AUTO NEW BUSINESS .50-"           → 1 column → YTD only → skip
const LINE_RE = /^1\s*(.+?)\s+([\d,]*\.\d{2}-?)(?:\s+([\d,]*\.\d{2}-?))?\s*$/;

interface ProdLine { description: string; current: number; ytd: number | null }
function parseProductionLine(raw: string): ProdLine | null {
  for (const re of SKIP_RE) if (re.test(raw)) return null;
  const m = raw.match(LINE_RE);
  if (!m) return null;
  if (!m[3]) return null;  // one-number line = YTD only, skip
  const current = parseAmount(m[2]);
  const ytd = parseAmount(m[3]);
  if (current === null || ytd === null) return null;
  return { description: m[1].trim(), current, ytd };
}

// "TCM TCM AUTO NEW BUSINESS" → "TCM AUTO NEW BUSINESS"
// First two whitespace-separated tokens identical → drop one.
function dedupeLeadingWords(desc: string): string {
  const parts = desc.split(/\s+/);
  if (parts.length >= 2 && parts[0] === parts[1]) return parts.slice(1).join(" ");
  return desc;
}

// --- Main parser ------------------------------------------------------------
export function parseCompRecapText(text: string): {
  rows: CompRecapRow[];
  period: PeriodInfo;
  texas_current_total: number;
} {
  const period = parsePeriod(text);
  if (!period) throw new Error("Could not identify period header (FOR <MONTH> X-Y, YYYY) in PDF text.");

  // PDFs include literal "\n" sequences AND real newlines after smart_file_extract.
  const lines = text.split(/\r?\n|\\n/);
  let statePrefix = "";        // empty = Texas default
  let currentCompany: string | null = null;
  let inPaymentSection = false;
  const rows: CompRecapRow[] = [];
  let texasTotal = 0;

  for (const raw of lines) {
    // *** PRODUCTION *** boundary resets state (Texas section has no explicit
    // state header) and clears company context.
    if (/\*\s*P\s*R\s*O\s*D\s*U\s*C\s*T\s*I\s*O\s*N/i.test(raw)) {
      inPaymentSection = false; statePrefix = ""; currentCompany = null; continue;
    }
    if (/\*\s*P\s*A\s*Y\s*M\s*E\s*N\s*T\s+S\s*E\s*C\s*T\s*I\s*O\s*N/i.test(raw)) {
      inPaymentSection = true; currentCompany = null; continue;
    }
    if (/\*\s*I\s*N\s*F\s*O\s*R\s*M\s*A\s*T\s*I\s*O\s*N/i.test(raw)) {
      inPaymentSection = true; currentCompany = null; continue;
    }
    if (inPaymentSection) continue;

    const sp = detectStateHeader(raw);
    if (sp !== null) { statePrefix = sp; currentCompany = null; continue; }

    // Update company context if the line starts a new company section
    const newCo = detectCompany(raw);
    if (newCo) currentCompany = newCo;

    const line = parseProductionLine(raw);
    if (!line) continue;
    if (line.current === 0) continue;

    const desc = dedupeLeadingWords(line.description);
    const description = statePrefix ? `${statePrefix} ${desc}` : desc;
    const { category, aipp } = classifyLine(desc, currentCompany);
    rows.push({
      period_year: period.year,
      period_month: period.month,
      period_day: period.day,
      comp_type: period.comp_type,
      comp_category: category,
      description,
      amount: line.current,
      is_aipp_eligible: aipp,
      is_scorecard_eligible: false,
    });
    if (statePrefix === "") texasTotal += line.current;
  }

  return { rows, period, texas_current_total: texasTotal };
}

// --- DB-writing wrapper -----------------------------------------------------
export async function parseCompRecap(opts: {
  agencyId: string;
  documentId: string;
  statementText: string;
}): Promise<ParseCompRecapResult> {
  let parsed;
  try {
    parsed = parseCompRecapText(opts.statementText);
  } catch (e) {
    return { ok: false, error: `comp_recap parse failed: ${e instanceof Error ? e.message : String(e)}` };
  }
  if (parsed.rows.length === 0) {
    return { ok: false, error: "Parser yielded no rows (PDF malformed or no current-period activity)." };
  }
  // Idempotency: clear any prior rows from this source_document_id, then insert.
  await sb.from("comp_recap").delete().eq("source_document_id", opts.documentId);
  const { error } = await sb.from("comp_recap").insert(
    parsed.rows.map((r) => ({
      agency_id: opts.agencyId,
      period_year: r.period_year,
      period_month: r.period_month,
      period_day: r.period_day,
      comp_type: r.comp_type,
      comp_category: r.comp_category,
      description: r.description,
      amount: r.amount,
      is_aipp_eligible: r.is_aipp_eligible,
      is_scorecard_eligible: r.is_scorecard_eligible,
      source_document_id: opts.documentId,
    })),
  );
  if (error) return { ok: false, error: `comp_recap insert failed: ${error.message}` };

  return { ok: true, rows: parsed.rows, written: parsed.rows.length,
           period: parsed.period, texas_current_total: parsed.texas_current_total };
}

// ==================== parsers/deduction.ts ====================
// =========================================================================
// parsers/deduction.ts (v2 — deterministic regex parser)
// =========================================================================
// Parses State Farm semi-monthly deduction statements into comp_recap rows
// with negative amounts.
//
// REPLACES the prior LLM-based parser (v1, 2026-05). Key bug it fixes:
// the LLM consistently extracted the YEAR-TO-DATE column instead of CURRENT,
// producing 22x overstatement of period deductions.
//
// VERIFIED RECONCILIATIONS:
//   - June 1-15 2026: 3 rows, total -$457.17 (matches comp PDF
//     "LESS DEDUCTIONS 457.17-").
//   - May 16-31 2026: 5 rows, total -$1,286.56 (matches comp PDF
//     "LESS DEDUCTIONS 1,286.56-").
//
// FORMAT REFERENCE (real example):
//   "1 STATEMENTS OF DEDUCTIONS AND ADDITIONS"
//   "1 MAY 31, 2026"                           <- date header
//   "1 CURRENT YEAR TO"
//   "1 AMOUNT DATE"
//   "1 CREDIT UNION 338.03 1,690.15"           <- cur=338.03 → -338.03
//   "1 ADVISORY RENEWAL FEE-AGENT 0.00 15.00"  <- cur=0, skip
//   "1 TOTAL DEDUCTIONS 1,286.56 9,969.74"     <- summary, skip
// =========================================================================


export interface DeductionRow {
  period_year: number;
  period_month: number;
  period_day: number;
  comp_type: string;
  comp_category: string;
  description: string;
  amount: number;  // always negative
}

export type ParseDeductionResult =
  | { ok: true; rows: DeductionRow[]; written: number; total: number }
  | { ok: false; error: string };

const MONTHS_D: Record<string, number> = {
  JANUARY: 1, FEBRUARY: 2, MARCH: 3, APRIL: 4, MAY: 5, JUNE: 6,
  JULY: 7, AUGUST: 8, SEPTEMBER: 9, OCTOBER: 10, NOVEMBER: 11, DECEMBER: 12,
};

function parseDeductionDate(text: string): { year: number; month: number; day: number; comp_type: "1H" | "2H" } | null {
  const m = text.match(/([A-Z]+)\s+(\d{1,2}),\s*(\d{4})/i);
  if (!m) return null;
  const month = MONTHS_D[m[1].toUpperCase()];
  if (!month) return null;
  const day = parseInt(m[2], 10);
  const year = parseInt(m[3], 10);
  return { year, month, day, comp_type: day <= 15 ? "1H" : "2H" };
}

interface DCatRule { test: RegExp; category: string }
const DEDUCTION_CATEGORIES: DCatRule[] = [
  { test: /ECHO CO-OP|DIRECT MAIL|ADVERTISING/i,                      category: "deduction_advertising" },
  { test: /APPOINTMENT|LICENSE|ADVISORY RENEWAL|FINRA|EXAM FEE/i,     category: "deduction_license"     },
  { test: /AGENT EQUIPMENT|MYSFDOMAIN|TECHNOLOGY|COMPUTER|SOFTWARE/i, category: "deduction_technology"  },
];
function classifyDeduction(desc: string): string {
  for (const r of DEDUCTION_CATEGORIES) if (r.test.test(desc)) return r.category;
  return "deduction_other";
}

function parseAmt(s: string): number | null {
  const cleaned = s.replace(/,/g, "").trim();
  const negative = cleaned.endsWith("-");
  const num = parseFloat(negative ? cleaned.slice(0, -1) : cleaned);
  if (isNaN(num)) return null;
  return negative ? -num : num;
}

const DED_LINE_RE = /^1\s+(.+?)\s+([\d,]+\.\d{2})\s+([\d,]+\.\d{2})\s*$/;
const DED_SKIP: RegExp[] = [
  /^1DEDUCTION/i, /^1\s+STATE FARM/i, /^1\s+SEMI MONTHLY/i,
  /^1\s+STATEMENTS OF/i, /^1\s+STATE \d/i, /^1\s+\dBDD\s/i,
  /^1\s+-+DEDUCTIONS-+/i, /^1\s+THESE AMOUNTS/i,
  /^1\s+CURRENT YEAR/i, /^1\s+AMOUNT DATE/i,
  /^1\s+TOTAL DEDUCTIONS/i,
];

export function parseDeductionText(text: string): {
  rows: DeductionRow[];
  period: { year: number; month: number; day: number; comp_type: "1H" | "2H" };
  current_total: number;
} {
  const period = parseDeductionDate(text);
  if (!period) throw new Error("Could not identify date header in deduction PDF.");
  const lines = text.split(/\r?\n|\\n/);
  const rows: DeductionRow[] = [];
  let total = 0;
  for (const raw of lines) {
    if (DED_SKIP.some((re) => re.test(raw))) continue;
    const m = raw.match(DED_LINE_RE);
    if (!m) continue;
    const description = m[1].trim();
    const current = parseAmt(m[2]);
    if (current === null || current === 0) continue;
    const amount = -Math.abs(current);  // always negative
    rows.push({
      period_year: period.year,
      period_month: period.month,
      period_day: period.day,
      comp_type: period.comp_type,
      comp_category: classifyDeduction(description),
      description,
      amount,
    });
    total += amount;
  }
  return { rows, period, current_total: total };
}

export async function parseDeductionStatement(opts: {
  agencyId: string;
  documentId: string;
  statementText: string;
}): Promise<ParseDeductionResult> {
  let parsed;
  try {
    parsed = parseDeductionText(opts.statementText);
  } catch (e) {
    return { ok: false, error: `deduction parse failed: ${e instanceof Error ? e.message : String(e)}` };
  }
  if (parsed.rows.length === 0) {
    return { ok: false, error: "Parser yielded no rows. Either no current-period deductions or PDF malformed." };
  }
  await sb.from("comp_recap").delete().eq("source_document_id", opts.documentId);
  const { error } = await sb.from("comp_recap").insert(
    parsed.rows.map((r) => ({
      agency_id: opts.agencyId,
      period_year: r.period_year,
      period_month: r.period_month,
      period_day: r.period_day,
      comp_type: r.comp_type,
      comp_category: r.comp_category,
      description: r.description,
      amount: r.amount,
      is_aipp_eligible: false,
      is_scorecard_eligible: false,
      source_document_id: opts.documentId,
    })),
  );
  if (error) return { ok: false, error: `comp_recap (deduction) insert failed: ${error.message}` };
  return { ok: true, rows: parsed.rows, written: parsed.rows.length, total: parsed.current_total };
}

// ==================== parsers/payroll.ts ====================
// =========================================================================
// parsers/payroll.ts
// =========================================================================
// Parses ADP / Gusto / WorkforceNow payroll run notifications. Inserts one
// payroll_runs row and one payroll_detail row per employee.
//
// Detail-only — no GL posts. GL Entry Writer reconciles payroll separately.
// =========================================================================


export interface PayrollDetailRow {
  staff_name: string;       // used to resolve team_member_id via team table
  gross_pay: number;
  federal_tax: number;
  state_tax: number;
  social_security: number;
  medicare: number;
  other_deductions: number;
  net_pay: number;
  employment_type: string;  // "W2" | "1099" | "OWNER"
}

export interface PayrollRunHeader {
  pay_period_start: string; // YYYY-MM-DD
  pay_period_end: string;
  pay_date: string;
  payroll_provider: string; // ADP | Gusto | etc.
  gross_payroll: number;
  employer_taxes: number;
  net_payroll: number;
}

export type ParsePayrollResult =
  | { ok: true; run: PayrollRunHeader; detailCount: number }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT_PAYROLL = `
You are a parser for U.S. payroll provider documents (ADP, Gusto,
WorkforceNow). You will be given the text of one payroll run document.
Extract the run-level header AND every employee detail line.

Return raw JSON in this exact shape — no fences, no prose:
{
  "run": {
    "pay_period_start": "YYYY-MM-DD",
    "pay_period_end": "YYYY-MM-DD",
    "pay_date": "YYYY-MM-DD",
    "payroll_provider": "ADP" | "Gusto" | "WorkforceNow" | "Other",
    "gross_payroll": <number>,
    "employer_taxes": <number>,
    "net_payroll": <number>
  },
  "details": [
    {
      "staff_name": "<First Last>",
      "gross_pay": <number>,
      "federal_tax": <number>,
      "state_tax": <number>,
      "social_security": <number>,
      "medicare": <number>,
      "other_deductions": <number>,
      "net_pay": <number>,
      "employment_type": "W2" | "1099" | "OWNER"
    }
  ]
}

Rules:
- Use ISO dates.
- All amounts positive (positive taxes mean the amount withheld).
- If a field is unclear, use 0.
- One detail row per employee, even if they got multiple line items in the document.
- Output raw JSON, never wrap it in code fences.
`.trim();

export async function parsePayrollRun(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string;
  statementText: string;
}): Promise<ParsePayrollResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT_PAYROLL,
    userContent: opts.statementText,
    documentId: opts.documentId,
    purpose: "parse_payroll_run",
    maxTokens: 6000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const run = result.json?.run;
  if (!run?.pay_period_start || !run?.pay_period_end || !run?.pay_date) {
    return { ok: false, queued: false, error: "payroll header missing required dates" };
  }

  const rawDetails: any[] = Array.isArray(result.json?.details) ? result.json.details : [];

  // Idempotency: drop any prior run AND its details for this source_document_id
  const { data: priorRuns } = await sb
    .from("payroll_runs")
    .select("id")
    .eq("source_document_id", opts.documentId);
  if (priorRuns && priorRuns.length > 0) {
    const priorIds = priorRuns.map((r: any) => r.id);
    await sb.from("payroll_detail").delete().in("payroll_run_id", priorIds);
    await sb.from("payroll_runs").delete().in("id", priorIds);
  }

  const { data: runRow, error: runErr } = await sb
    .from("payroll_runs")
    .insert({
      agency_id: opts.agencyId,
      pay_period_start: run.pay_period_start,
      pay_period_end: run.pay_period_end,
      pay_date: run.pay_date,
      payroll_provider: run.payroll_provider ?? "Unknown",
      gross_payroll: run.gross_payroll ?? 0,
      employer_taxes: run.employer_taxes ?? 0,
      net_payroll: run.net_payroll ?? 0,
      status: "imported",
      source_document_id: opts.documentId,
    })
    .select("id")
    .single();
  if (runErr || !runRow) return { ok: false, queued: false, error: `payroll_runs insert failed: ${runErr?.message ?? "unknown"}` };

  // Resolve staff names → team_member_id (best-effort, null if no match)
  const detailRows = [];
  for (const d of rawDetails) {
    const staffName = String(d?.staff_name ?? "").trim();
    if (!staffName) continue;
    let staffId: string | null = null;
    const { data: matchedStaff } = await sb
      .from("team")
      .select("id")
      .eq("agency_id", opts.agencyId)
      .ilike("name", staffName)
      .maybeSingle();
    staffId = matchedStaff?.id ?? null;

    detailRows.push({
      payroll_run_id: runRow.id,
      agency_id: opts.agencyId,
      team_member_id: staffId,
      gross_pay: Number(d?.gross_pay ?? 0),
      federal_tax: Number(d?.federal_tax ?? 0),
      state_tax: Number(d?.state_tax ?? 0),
      social_security: Number(d?.social_security ?? 0),
      medicare: Number(d?.medicare ?? 0),
      other_deductions: Number(d?.other_deductions ?? 0),
      net_pay: Number(d?.net_pay ?? 0),
      employment_type: String(d?.employment_type ?? "W2").toUpperCase(),
    });
  }

  if (detailRows.length > 0) {
    const { error: detErr } = await sb.from("payroll_detail").insert(detailRows);
    if (detErr) return { ok: false, queued: false, error: `payroll_detail insert failed: ${detErr.message}` };
  }

  return {
    ok: true,
    run: {
      pay_period_start: run.pay_period_start,
      pay_period_end: run.pay_period_end,
      pay_date: run.pay_date,
      payroll_provider: run.payroll_provider ?? "Unknown",
      gross_payroll: Number(run.gross_payroll ?? 0),
      employer_taxes: Number(run.employer_taxes ?? 0),
      net_payroll: Number(run.net_payroll ?? 0),
    },
    detailCount: detailRows.length,
  };
}

// ==================== parsers/production.ts ====================
// =========================================================================
// parsers/production.ts
// =========================================================================
// Parses TWO related document types into the same destination table:
//   - commission_report: per-producer commission summary (monthly)
//   - team_production:   monthly producer × LOB premium issued
// Both feed producer_production, which drives the Performance tab and AIPP
// pace tracking. Detail-only — no GL posts.
//
// GRAIN: one row per (team_member_id, period_year, period_month, line_of_business),
// enforced by a UNIQUE constraint. This table tracks NEW production issued
// (premium_type is always "new"); renewal premium is modeled downstream via
// the lapse rate, not stored here. Do not split new/renewal into separate
// rows — that would violate the unique constraint.
//
// AIPP qualification is derived in code, never trusted to the LLM:
//   is_aipp_qualifying = LOB in (auto, fire)   [new P&C]
// (AIPP = 5% of qualifying NEW P&C production.)
// =========================================================================


const CANONICAL_LOB = ["auto", "fire", "life", "health", "bank", "annuity", "other"] as const;
type Lob = (typeof CANONICAL_LOB)[number];
const AIPP_QUALIFYING_LOB = new Set<Lob>(["auto", "fire"]);

export interface ProductionRow {
  staff_name: string;        // as it appears in the document
  period_year: number;
  period_month: number;
  line_of_business: Lob;
  policies_issued: number;
  premium_issued: number;
  notes: string | null;
}

export type ParseProductionResult =
  | { ok: true; rows: ProductionRow[]; written: number; unmatchedStaff: string[] }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT_PRODUCTION = `
You are a parser for State Farm producer production / commission reports.
Extract every producer × line-of-business × month row.

For each row, return:
  - staff_name (full name as it appears in the document; keep the document's spelling)
  - period_year (integer, 4-digit)
  - period_month (integer 1-12)
  - line_of_business (one of, lowercase exact: "auto", "fire", "life", "health", "bank", "annuity", "other")
  - policies_issued (integer; if not reported, use 0)
  - premium_issued (number; NEW premium dollars issued for this row)
  - notes (optional 1-line context, or empty string)

Return raw JSON only:
{
  "rows": [
    { "staff_name": "Jane Doe", "period_year": 2026, "period_month": 5,
      "line_of_business": "auto", "policies_issued": 12,
      "premium_issued": 18450.00, "notes": "" }
  ]
}

Rules:
- Extract NEW production only. Ignore renewal / in-force premium columns.
- Skip headers, totals, page footers, and any "agency total" / "office total" rows.
- One row per (producer, line_of_business, month) combo.
- If a producer has multiple LOBs, return multiple rows (do not aggregate).
- Use integer policy counts.
- Output raw JSON, never wrap it in code fences.
`.trim();

function canonicalLob(raw: unknown): Lob {
  const v = String(raw ?? "").trim().toLowerCase();
  if ((CANONICAL_LOB as readonly string[]).includes(v)) return v as Lob;
  // common aliases
  if (["p&c", "pc", "property", "homeowners", "home", "renters"].includes(v)) return "fire";
  if (["vehicle", "car", "automobile"].includes(v)) return "auto";
  return "other";
}

// Build a normalized name → team_member_id index for the agency's active team.
// Handles "First Last", "Last, First", case, and extra whitespace.
function normName(s: string): string {
  return s.toLowerCase().replace(/[.,]/g, " ").replace(/\s+/g, " ").trim();
}

async function buildStaffIndex(agencyId: string): Promise<Map<string, string>> {
  const { data, error } = await sb
    .from("team")
    .select("id, first_name, last_name")
    .eq("agency_id", agencyId)
    .eq("is_active", true);
  if (error) throw new Error(`staff lookup failed: ${error.message}`);

  const idx = new Map<string, string>();
  for (const s of data ?? []) {
    const first = String(s.first_name ?? "").trim();
    const last = String(s.last_name ?? "").trim();
    if (!s.id) continue;
    const keys = [
      `${first} ${last}`,   // First Last
      `${last} ${first}`,   // Last First  (covers "Last, First" after normalization)
      `${last}`,            // surname-only fallback (last resort)
    ];
    for (const k of keys) {
      const nk = normName(k);
      if (nk && !idx.has(nk)) idx.set(nk, s.id as string);
    }
  }
  return idx;
}

function resolveStaffId(idx: Map<string, string>, docName: string): string | null {
  const n = normName(docName);
  if (idx.has(n)) return idx.get(n)!;
  // try reversed token order (handles "Last First" vs "First Last")
  const parts = n.split(" ");
  if (parts.length >= 2) {
    const rev = normName(parts.slice().reverse().join(" "));
    if (idx.has(rev)) return idx.get(rev)!;
    // first + last only, dropping any middle token
    const fl = normName(`${parts[0]} ${parts[parts.length - 1]}`);
    if (idx.has(fl)) return idx.get(fl)!;
  }
  return null;
}

export async function parseProductionReport(opts: {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  documentId: string;
  reportVariant: "commission_report" | "team_production";
  statementText: string;
}): Promise<ParseProductionResult> {
  const result = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT_PRODUCTION,
    userContent: `Report variant: ${opts.reportVariant}\n\n${opts.statementText}`,
    documentId: opts.documentId,
    purpose: `parse_${opts.reportVariant}`,
    maxTokens: 6000,
  });

  if (!result.ok) {
    if (result.queued) return { ok: false, queued: true, queueId: result.queueId };
    return { ok: false, queued: false, error: result.error };
  }

  const rawRows: any[] = Array.isArray(result.json?.rows) ? result.json.rows : [];
  const rows: ProductionRow[] = [];
  for (const r of rawRows) {
    if (typeof r?.premium_issued !== "number") continue;
    if (typeof r?.period_year !== "number" || typeof r?.period_month !== "number") continue;
    const year = Math.trunc(r.period_year);
    const month = Math.trunc(r.period_month);
    if (year < 2000 || year > 2100) continue;
    if (month < 1 || month > 12) continue;
    const name = String(r?.staff_name ?? "").trim();
    if (!name) continue;
    rows.push({
      staff_name: name,
      period_year: year,
      period_month: month,
      line_of_business: canonicalLob(r.line_of_business),
      policies_issued: Number.isFinite(r.policies_issued) ? Math.trunc(r.policies_issued) : 0,
      premium_issued: r.premium_issued,
      notes: r.notes ? String(r.notes).slice(0, 500) : null,
    });
  }

  if (rows.length === 0) {
    return { ok: false, queued: false, error: "LLM returned no parseable rows" };
  }

  // Resolve staff names → team_member_id. producer_production REQUIRES team_member_id (NOT NULL).
  // Rows for unmatched producers are skipped and reported back.
  const staffIdx = await buildStaffIndex(opts.agencyId);
  const unmatched: string[] = [];
  const insertRows = [];
  for (const r of rows) {
    const staffId = resolveStaffId(staffIdx, r.staff_name);
    if (!staffId) {
      if (!unmatched.includes(r.staff_name)) unmatched.push(r.staff_name);
      continue;
    }
    const isAipp = AIPP_QUALIFYING_LOB.has(r.line_of_business);
    insertRows.push({
      agency_id: opts.agencyId,
      team_member_id: staffId,
      period_year: r.period_year,
      period_month: r.period_month,
      line_of_business: r.line_of_business,
      policies_issued: r.policies_issued,
      premium_issued: r.premium_issued,
      premium_type: "new",
      is_aipp_qualifying: isAipp,
      source: "auto_parsed",
      notes: r.notes,
      source_document_id: opts.documentId,
    });
  }

  // Idempotency:
  //  - delete prior rows from THIS source document (handles row removal on re-parse)
  //  - upsert on the unique business key so a corrected report from a DIFFERENT
  //    document updates the existing producer/month/LOB row instead of erroring
  await sb.from("producer_production").delete().eq("source_document_id", opts.documentId);

  if (insertRows.length > 0) {
    const { error } = await sb
      .from("producer_production")
      .upsert(insertRows, {
        onConflict: "agency_id,team_member_id,period_year,period_month,line_of_business",
      });
    if (error) return { ok: false, queued: false, error: `producer_production upsert failed: ${error.message}` };
  }

  return { ok: true, rows, written: insertRows.length, unmatchedStaff: unmatched };
}

// ==================== parsers/surepayroll.ts ====================
// =========================================================================
// parsers/surepayroll.ts
// =========================================================================
// SurePayroll (State Farm-forwarded) payroll summary parser.
// Deterministic regex — no LLM. Handles unpdf's specific output format
// (right-to-left reading, no whitespace between amounts and labels).
// Writes payroll_runs + payroll_detail with full jsonb per-item breakdowns,
// denormalizes into weekly_cpr_team_detail for the CPR week ending the first
// Saturday >= check_date, auto-resolves pending payroll_run alerts, stars the
// source email. Consolidated from standalone `payroll-email-parser` v9 (2026-07-07).
// =========================================================================


interface SPItem { period: number; ytd: number; hours?: number; }
interface SPEmployeeBlock {
  last_name: string; first_name: string; income_state: string;
  net_pay: number; period_gross: number; ytd_gross: number;
  period_hours: number | null;
  earnings_items: Record<string, SPItem>;
  deduction_items: Record<string, SPItem>;
  employer_items: Record<string, SPItem>;
}
export interface ParsedSurePayroll {
  employer_entity_name: string; pay_period_start: string; pay_period_end: string;
  check_date: string; transmit_date: string | null;
  employees: SPEmployeeBlock[];
  totals: { period_gross: number; period_employee_taxes: number; period_employee_deductions: number; period_employer_taxes: number; net_pay: number; total_cash_requirement: number; };
}

const SP_MONTH_LOOKUP: Record<string, number> = { Jan:1,Feb:2,Mar:3,Apr:4,May:5,Jun:6,Jul:7,Aug:8,Sep:9,Oct:10,Nov:11,Dec:12 };

function spParseMoney(s: string): number {
  const clean = s.replace(/[,$\s]/g, "").trim();
  const neg = clean.endsWith("-");
  const n = parseFloat(neg ? clean.slice(0, -1) : clean);
  return isNaN(n) ? 0 : (neg ? -n : n);
}
function spDateToNum(m: string, d: number, y: number): number { return y * 10000 + SP_MONTH_LOOKUP[m] * 100 + d; }
function spToIso(m: string, d: number, y: number): string { return `${y}-${String(SP_MONTH_LOOKUP[m]).padStart(2, "0")}-${String(d).padStart(2, "0")}`; }

const SP_DEDUCTION_LABELS = new Set(["FED WTH", "FICA", "MEDFICA", "DENTAL", "MEDICAL", "VISION", "MISC 1T", "VACHILD"]);
const SP_EMPLOYER_LABELS = new Set(["CO FICA", "CO MEDC", "FUTA", "TX ETIA", "TXEMPL", "FEES"]);

function spClassifyLabel(label: string): "deduction" | "employer" | "earning" {
  if (SP_DEDUCTION_LABELS.has(label) || /^STATE-[A-Z]{2}$/.test(label)) return "deduction";
  if (SP_EMPLOYER_LABELS.has(label) || /^CO UNEM-[A-Z]{2}$/.test(label)) return "employer";
  return "earning";
}

export function parseSurePayrollText(text: string): ParsedSurePayroll {
  if (!/PAPERNEWT\s+LLC/i.test(text) || !/Payroll\s+Summary/i.test(text)) {
    throw new Error("PDF does not look like a PAPERNEWT SurePayroll summary");
  }
  const dateRe = /([A-Z][a-z]{2})\s+(\d{1,2}),\s+(\d{4})/g;
  const dates: Array<{ m: string; d: number; y: number; num: number }> = [];
  let dm: RegExpExecArray | null;
  while ((dm = dateRe.exec(text)) !== null) {
    dates.push({ m: dm[1], d: parseInt(dm[2], 10), y: parseInt(dm[3], 10), num: spDateToNum(dm[1], parseInt(dm[2], 10), parseInt(dm[3], 10)) });
  }
  const uniq = Array.from(new Map(dates.map(d => [d.num, d])).values()).sort((a, b) => a.num - b.num);
  if (uniq.length < 3) throw new Error(`Only ${uniq.length} unique dates found; need 3+`);
  const pay_period_start = spToIso(uniq[0].m, uniq[0].d, uniq[0].y);
  const pay_period_end = spToIso(uniq[1].m, uniq[1].d, uniq[1].y);
  const check_date = spToIso(uniq[2].m, uniq[2].d, uniq[2].y);

  let transmit_date: string | null = null;
  const trM = text.match(/AMOUNT\s+TRANSMITTED\s+ON\s+(\d{2})\/(\d{2})\/(\d{4})/i);
  if (trM) transmit_date = `${trM[3]}-${trM[1]}-${trM[2]}`;

  const totalsIdx = text.indexOf("PAYROLL SUMMARY TOTALS");
  const employeeSection = totalsIdx >= 0 ? text.slice(0, totalsIdx) : text;

  const nameRe = /Unemployment\s+State:\s+[A-Z]{2}\s+([A-Z][A-Z\-\s]+?),\s+([A-Z][A-Z\-\s]+?)\s+EMPLOYER\s+TAXES/g;
  const nameMatches: Array<{ last: string; first: string; index: number; end: number }> = [];
  let nm: RegExpExecArray | null;
  while ((nm = nameRe.exec(employeeSection)) !== null) {
    nameMatches.push({ last: nm[1].trim(), first: nm[2].trim(), index: nm.index, end: nm.index + nm[0].length });
  }

  const totalMarkerRe = /TOTAL:/g;
  const totalPositions: number[] = [];
  let tm: RegExpExecArray | null;
  while ((tm = totalMarkerRe.exec(employeeSection)) !== null) totalPositions.push(tm.index);

  const employees: SPEmployeeBlock[] = [];
  for (let i = 0; i < nameMatches.length; i++) {
    const nameStart = nameMatches[i].index;
    const empTotal = totalPositions.find(p => p > nameStart) ?? employeeSection.length;
    const prevTotal = i > 0 ? (totalPositions.find(p => p > nameMatches[i-1].index) ?? 0) : 0;
    const blockStart = i === 0 ? 0 : prevTotal + "TOTAL:".length;
    const blockEnd = empTotal;
    const block = employeeSection.slice(blockStart, blockEnd);
    employees.push(parseSurePayrollEmployeeBlock(nameMatches[i].last, nameMatches[i].first, block));
  }

  const grandTotalsBlock = totalsIdx >= 0 ? text.slice(totalsIdx) : "";
  const netPayM = grandTotalsBlock.match(/NET\s+PAY\s+\$([\d,]+\.\d{2})/i);
  const totalCashM = grandTotalsBlock.match(/TOTAL\s+CASH\s+REQUIREMENTS\s+\$([\d,]+\.\d{2})/i);
  const eeTaxKeys = ["FED WTH", "FICA", "MEDFICA"];
  const totals = {
    period_gross: employees.reduce((s, e) => s + e.period_gross, 0),
    period_employee_taxes: employees.reduce((s, e) => s + eeTaxKeys.reduce((a, k) => a + (e.deduction_items[k]?.period ?? 0), 0) + Object.entries(e.deduction_items).filter(([k]) => /^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employee_deductions: employees.reduce((s, e) => s + Object.entries(e.deduction_items).filter(([k]) => !eeTaxKeys.includes(k) && !/^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employer_taxes: employees.reduce((s, e) => s + Object.values(e.employer_items).reduce((a, b) => a + b.period, 0), 0),
    net_pay: netPayM ? spParseMoney(netPayM[1]) : employees.reduce((s, e) => s + e.net_pay, 0),
    total_cash_requirement: totalCashM ? spParseMoney(totalCashM[1]) : 0,
  };
  return { employer_entity_name: "PAPERNEWT LLC", pay_period_start, pay_period_end, check_date, transmit_date, employees, totals };
}

function parseSurePayrollEmployeeBlock(last: string, first: string, block: string): SPEmployeeBlock {
  const emp: SPEmployeeBlock = {
    last_name: last, first_name: first, income_state: "",
    net_pay: 0, period_gross: 0, ytd_gross: 0, period_hours: null,
    earnings_items: {}, deduction_items: {}, employer_items: {},
  };
  const stM = block.match(/Income\s+Tax\s+State:\s+([A-Z]{2})/);
  if (stM) emp.income_state = stM[1];
  const npM = block.match(/NET\s+PAY\s+Direct\s+Deposit\s+\$([\d,]+\.\d{2})/i);
  if (npM) emp.net_pay = spParseMoney(npM[1]);

  const netPayStart = npM ? block.indexOf(npM[0]) : -1;
  const netPayEnd = npM ? netPayStart + npM[0].length : -1;

  const dollarRe = /\$(-?[\d,]+\.\d{2})/g;
  const dollars: Array<{ index: number; value: number }> = [];
  let dm: RegExpExecArray | null;
  while ((dm = dollarRe.exec(block)) !== null) {
    if (dm.index >= netPayStart && dm.index < netPayEnd) continue;
    dollars.push({ index: dm.index, value: spParseMoney(dm[1]) });
  }
  if (dollars.length > 0) {
    let biggestIdx = 0;
    for (let i = 1; i < dollars.length; i++) if (dollars[i].value > dollars[biggestIdx].value) biggestIdx = i;
    emp.ytd_gross = dollars[biggestIdx].value;
    emp.period_gross = biggestIdx + 1 < dollars.length ? dollars[biggestIdx + 1].value : 0;
  }

  const tripleRe = /\$(-?[\d,]+\.\d{2})\$(-?[\d,]+\.\d{2})([^$]+?)(?=\$|\s*$)/g;
  let m: RegExpExecArray | null;
  while ((m = tripleRe.exec(block)) !== null) {
    const ytd = spParseMoney(m[1]);
    const per = spParseMoney(m[2]);
    const raw = m[3];
    let hours: number | undefined = undefined;
    let label = raw.trim();
    const hm = raw.match(/^(\d{1,3}\.\d{2})([A-Za-z\-].+)$/);
    if (hm) { hours = parseFloat(hm[1]); label = hm[2].trim(); }
    label = label.replace(/\s+/g, " ").trim();
    if (!label || /^\d+\.\d{2}$/.test(label) || label === "TOTAL:" || label.endsWith("TOTAL:") || label.includes("TOTAL:")) continue;
    if (/^(EMPLOYER|EMPLOYEE|EARNINGS|VALUES|ITEM|PERIOD|YTD|NET PAY|Income|Unemployment|Report)/i.test(label)) continue;
    const kind = spClassifyLabel(label);
    const item: SPItem = { period: per, ytd };
    if (hours !== undefined) item.hours = hours;
    if (kind === "deduction") emp.deduction_items[label] = item;
    else if (kind === "employer") emp.employer_items[label] = item;
    else {
      emp.earnings_items[label] = item;
      if (hours !== undefined && emp.period_hours === null) emp.period_hours = hours;
    }
  }
  return emp;
}

// =========================================================================
// CSV parser (2026-07-14) — SurePayroll now also delivers per-week CSVs.
// Header row is stable across weeks (verified across 8 files 5/22–7/17).
// Numeric columns only in data rows (no embedded commas), but we tolerate
// quoted fields defensively. CSV carries NO YTD data — YTD backfill happens
// downstream in processSurePayrollParsed by summing prior payroll_detail
// gross_pay rows within the calendar year.
// =========================================================================

function parseCsvLine(line: string): string[] {
  // Handles quoted fields; unquoted fields split on commas.
  const out: string[] = [];
  let cur = "";
  let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQ) {
      if (c === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; } else { inQ = false; }
      } else { cur += c; }
    } else {
      if (c === ",") { out.push(cur); cur = ""; }
      else if (c === '"') { inQ = true; }
      else { cur += c; }
    }
  }
  out.push(cur);
  return out.map(s => s.trim());
}

function mdyToIso(s: string): string {
  // "7/17/2026" -> "2026-07-17"
  const m = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!m) throw new Error(`Bad date: ${s}`);
  return `${m[3]}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
}

function num(s: string | undefined): number {
  if (s === undefined || s === null || s === "") return 0;
  const n = parseFloat(s.replace(/[,$\s]/g, ""));
  return isNaN(n) ? 0 : n;
}

export function parseSurePayrollCsvText(text: string): ParsedSurePayroll {
  // Normalize line endings; drop empty trailing lines
  const lines = text.replace(/\r\n?/g, "\n").split("\n").filter(l => l.trim().length > 0);
  if (lines.length < 2) throw new Error(`CSV has only ${lines.length} line(s); need header + at least one row`);

  const header = parseCsvLine(lines[0]);
  const idx: Record<string, number> = {};
  for (let i = 0; i < header.length; i++) idx[header[i]] = i;

  const need = (col: string): number => {
    if (!(col in idx)) throw new Error(`CSV missing required column: "${col}"`);
    return idx[col];
  };

  // Required columns (fail loudly if header shifts)
  const cFirst    = need("First Name");
  const cLast     = need("Last Name");
  const cUnState  = need("Unemployment State");
  const cInState  = need("Income Tax State");
  const cCheck    = need("Check Date");
  const cPStart   = need("Period Start");
  const cPEnd     = need("Period End");
  const cGross    = need("Gross Wage");
  const cNet      = need("Net Pay");

  // Optional columns — safe fallback to -1 (empty)
  const optIdx = (col: string) => (col in idx ? idx[col] : -1);
  const cHrsReg   = optIdx("Hours - Regular");
  const cHrsOt    = optIdx("Hours - OT");
  const cHrsVac   = optIdx("Hours - Vacation");
  const cHrsSick  = optIdx("Hours - Sick");
  const cHrsOther = optIdx("Hours - Other");
  const cEarnSal  = optIdx("Earning - Salary");
  const cEarnHr   = optIdx("Earning - Hourly");
  const cEarnCom  = optIdx("Earning - Commission");
  const cEarnBon  = optIdx("Earning - Bonus");
  const cEarnOt   = optIdx("Earning - OT");
  const cEarnReim = optIdx("Earning - Reimbursements");
  const cEarnOth  = optIdx("Earning - Other");
  const cBenHea   = optIdx("Employee Benefit - Health");
  const cBenDen   = optIdx("Employee Benefit - Dental");
  const cBenVis   = optIdx("Employee Benefit - Vision");
  const cBen401   = optIdx("Employee Benefit - 401K");
  const cBenHsa   = optIdx("Employee Benefit - HSA");
  const cBenIra   = optIdx("Employee Benefit - IRA");
  const cBenLif   = optIdx("Employee Benefit - Life");
  const cBenFsa   = optIdx("Employee Benefit - FSA");
  const cDedGar   = optIdx("Employee Deduction - Garnishment");
  const cDedOth   = optIdx("Employee Deduction - Other");
  const cTaxDis   = optIdx("Employee Tax - Disability");
  const cTaxFed   = optIdx("Employee Tax - FED WTH");
  const cTaxFica  = optIdx("Employee Tax - FICA");
  const cTaxMed   = optIdx("Employee Tax - MEDFICA");
  const cTaxSt    = optIdx("Employee Tax - State");
  const cTaxOth   = optIdx("Employee Tax - Other");
  const cErFica   = optIdx("Employer Tax - FICA");
  const cErMed    = optIdx("Employer Tax - MEDC");
  const cErUnem   = optIdx("Employer Tax - Unemployment");
  const cErTaxOth = optIdx("Employer Tax - Other");
  const cErDed    = optIdx("Employer Deductions");

  const getStr = (row: string[], i: number): string => (i >= 0 && i < row.length ? row[i] : "");
  const getNum = (row: string[], i: number): number => num(getStr(row, i));

  const employees: SPEmployeeBlock[] = [];
  const checkDates: string[] = [];
  const periodStarts: string[] = [];
  const periodEnds: string[] = [];

  for (let li = 1; li < lines.length; li++) {
    const row = parseCsvLine(lines[li]);
    if (row.length < 6) continue; // skip incomplete lines defensively

    const first = getStr(row, cFirst).trim();
    const last  = getStr(row, cLast).trim();
    if (!first || !last) continue;

    checkDates.push(mdyToIso(getStr(row, cCheck)));
    periodStarts.push(mdyToIso(getStr(row, cPStart)));
    periodEnds.push(mdyToIso(getStr(row, cPEnd)));

    const inState  = getStr(row, cInState).toUpperCase();
    const unState  = getStr(row, cUnState).toUpperCase();

    const hrsReg   = getNum(row, cHrsReg);
    const hrsOt    = getNum(row, cHrsOt);
    const hrsVac   = getNum(row, cHrsVac);
    const hrsSick  = getNum(row, cHrsSick);
    const hrsOther = getNum(row, cHrsOther);

    const earnSal  = getNum(row, cEarnSal);
    const earnHr   = getNum(row, cEarnHr);
    const earnCom  = getNum(row, cEarnCom);
    const earnBon  = getNum(row, cEarnBon);
    const earnOt   = getNum(row, cEarnOt);
    const earnReim = getNum(row, cEarnReim);
    const earnOth  = getNum(row, cEarnOth);

    const emp: SPEmployeeBlock = {
      first_name: first,
      last_name: last,
      income_state: inState,
      net_pay: getNum(row, cNet),
      period_gross: getNum(row, cGross),
      ytd_gross: 0, // CSV has no YTD; downstream backfill computes it
      period_hours: hrsReg + hrsOt, // productive hours; vacation/sick/other tracked separately
      earnings_items: {
        SALARY:         { period: earnSal,  ytd: 0, hours: earnSal > 0 ? hrsReg : 0 },
        HOURLY:         { period: earnHr,   ytd: 0, hours: earnHr  > 0 ? hrsReg : 0 },
        COMMISSION:     { period: earnCom,  ytd: 0 },
        BONUS:          { period: earnBon,  ytd: 0 },
        OT:             { period: earnOt,   ytd: 0, hours: hrsOt },
        REIMBURSEMENTS: { period: earnReim, ytd: 0 },
        OTHER:          { period: earnOth,  ytd: 0 },
        VACATION_HRS:   { period: 0,        ytd: 0, hours: hrsVac },
        SICK_HRS:       { period: 0,        ytd: 0, hours: hrsSick },
        OTHER_HRS:      { period: 0,        ytd: 0, hours: hrsOther },
      },
      deduction_items: {
        HEALTH:      { period: getNum(row, cBenHea), ytd: 0 },
        DENTAL:      { period: getNum(row, cBenDen), ytd: 0 },
        VISION:      { period: getNum(row, cBenVis), ytd: 0 },
        "401K":      { period: getNum(row, cBen401), ytd: 0 },
        HSA:         { period: getNum(row, cBenHsa), ytd: 0 },
        IRA:         { period: getNum(row, cBenIra), ytd: 0 },
        LIFE:        { period: getNum(row, cBenLif), ytd: 0 },
        FSA:         { period: getNum(row, cBenFsa), ytd: 0 },
        GARNISHMENT: { period: getNum(row, cDedGar), ytd: 0 },
        OTHER_DED:   { period: getNum(row, cDedOth), ytd: 0 },
        DISABILITY:  { period: getNum(row, cTaxDis), ytd: 0 },
        "FED WTH":   { period: getNum(row, cTaxFed), ytd: 0 },
        FICA:        { period: getNum(row, cTaxFica), ytd: 0 },
        MEDFICA:     { period: getNum(row, cTaxMed), ytd: 0 },
        TAX_OTHER:   { period: getNum(row, cTaxOth), ytd: 0 },
        [`STATE-${inState || "XX"}`]: { period: getNum(row, cTaxSt), ytd: 0 },
      },
      employer_items: {
        "CO FICA":                    { period: getNum(row, cErFica),  ytd: 0 },
        "CO MEDC":                    { period: getNum(row, cErMed),   ytd: 0 },
        [`CO UNEM-${unState || "XX"}`]: { period: getNum(row, cErUnem),  ytd: 0 },
        ER_OTHER:                     { period: getNum(row, cErTaxOth),ytd: 0 },
        ER_DED:                       { period: getNum(row, cErDed),   ytd: 0 },
      },
    };
    employees.push(emp);
  }

  if (employees.length === 0) throw new Error("CSV had header but no valid employee rows");

  // Compute totals (mirror the PDF path exactly)
  const eeTaxKeys = ["FED WTH", "FICA", "MEDFICA"];
  const totals = {
    period_gross: employees.reduce((s, e) => s + e.period_gross, 0),
    period_employee_taxes: employees.reduce((s, e) =>
      s + eeTaxKeys.reduce((a, k) => a + (e.deduction_items[k]?.period ?? 0), 0)
        + Object.entries(e.deduction_items).filter(([k]) => /^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employee_deductions: employees.reduce((s, e) =>
      s + Object.entries(e.deduction_items).filter(([k]) => !eeTaxKeys.includes(k) && !/^STATE-/.test(k)).reduce((a, [, v]) => a + v.period, 0), 0),
    period_employer_taxes: employees.reduce((s, e) =>
      s + Object.values(e.employer_items).reduce((a, b) => a + b.period, 0), 0),
    net_pay: employees.reduce((s, e) => s + e.net_pay, 0),
    total_cash_requirement: 0, // not present in CSV
  };

  // Dates: min start, max end, max check (rows all share the same values in observed CSVs)
  const minStart = periodStarts.sort()[0];
  const maxEnd = periodEnds.sort().reverse()[0];
  const maxCheck = checkDates.sort().reverse()[0];

  return {
    employer_entity_name: "PAPERNEWT LLC",
    pay_period_start: minStart,
    pay_period_end: maxEnd,
    check_date: maxCheck,
    transmit_date: null, // not in CSV
    employees,
    totals,
  };
}


async function spMatchTeamMember(last: string, first: string): Promise<{ id: string; agency_id: string | null } | null> {
  const { data, error } = await sb.from("team").select("id, agency_id").ilike("last_name", last).ilike("first_name", first).maybeSingle();
  if (error || !data) return null;
  return { id: data.id, agency_id: data.agency_id };
}

function spTargetCprWeekEnding(checkDate: string): string {
  const d = new Date(checkDate + "T00:00:00Z");
  const dow = d.getUTCDay();
  d.setUTCDate(d.getUTCDate() + ((6 - dow + 7) % 7));
  return d.toISOString().slice(0, 10);
}

interface SPProcessResult {
  ok: boolean;
  error?: string;
  payroll_run_id?: string;
  merged_existing?: boolean;
  employees_written?: number;
  unmatched_employees?: string[];
  cpr_week_updated?: string;
  alerts_resolved?: number;
}

export async function processSurePayrollParsed(opts: {
  agencyId: string;
  documentId: string;
  gmailMessageId: string;
  gmailThreadId: string;
  parsed: ParsedSurePayroll;
  sourceText: string;
  sourceFormat: "pdf" | "csv";
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}): Promise<SPProcessResult> {
  const parsed = opts.parsed;

  // Payroll records live under PaperNewt LLC (employer of record for W-2 tax
  // purposes). Cash movement JEs stay on Peter Story State Farm. (2026-07-15)
  const businessEntityId = "b1111111-1111-1111-1111-111111111111";

  const { data: existingByPeriod } = await sb.from("payroll_runs").select("id").eq("agency_id", opts.agencyId).eq("pay_period_end", parsed.pay_period_end).maybeSingle();

  const runFields = {
    agency_id: opts.agencyId, business_entity_id: businessEntityId,
    pay_period_start: parsed.pay_period_start, pay_period_end: parsed.pay_period_end,
    pay_date: parsed.check_date, transmit_date: parsed.transmit_date,
    payroll_provider: "SurePayroll",
    gross_payroll: parsed.totals.period_gross, employer_taxes: parsed.totals.period_employer_taxes, net_payroll: parsed.totals.net_pay,
    total_employee_taxes: parsed.totals.period_employee_taxes, total_employer_taxes: parsed.totals.period_employer_taxes,
    total_employee_deductions: parsed.totals.period_employee_deductions, total_cash_requirement: parsed.totals.total_cash_requirement,
    status: "imported", gmail_message_id: opts.gmailMessageId, gmail_thread_id: opts.gmailThreadId,
    source_document_id: opts.documentId,
    raw_pdf_text: opts.sourceText.slice(0, 20000), parsed_at: new Date().toISOString(),
    notes: `Auto-ingested via document-processor SurePayroll ${opts.sourceFormat.toUpperCase()} parser. ${parsed.employees.length} employees.`,
  };

  let runRowId: string;
  let mergedExisting = false;
  if (existingByPeriod?.id) {
    // On UPDATE, do NOT touch business_entity_id — the trigger only runs on
    // INSERT, and blanket UPDATE would blank the field if we pass null. Whatever
    // entity the row was originally stamped with wins.
    const { business_entity_id: _drop, ...updateFields } = runFields;
    const { error: updErr } = await sb.from("payroll_runs").update(updateFields).eq("id", existingByPeriod.id);
    if (updErr) return { ok: false, error: `payroll_runs update: ${updErr.message}` };
    runRowId = existingByPeriod.id;
    mergedExisting = true;
  } else {
    const { data: runRow, error: runErr } = await sb.from("payroll_runs").insert(runFields).select("id").single();
    if (runErr || !runRow) {
      if ((runErr as any)?.code === "23505") return { ok: false, error: "unique constraint violation (concurrent write?)" };
      return { ok: false, error: `payroll_runs insert: ${runErr?.message}` };
    }
    runRowId = runRow.id;
  }

  // Read back business_entity_id from the parent row so detail rows stay
  // consistent (whether INSERT stamped it via trigger or UPDATE preserved it).
  const { data: runRowEntity } = await sb.from("payroll_runs").select("business_entity_id").eq("id", runRowId).maybeSingle();
  const detailBusinessEntityId = runRowEntity?.business_entity_id ?? null;

  const unmatched: string[] = [];
  const detailRows: any[] = [];
  const cprBreakdownByTeamId: Record<string, any> = {};
  const eeTaxKeys = ["FED WTH", "FICA", "MEDFICA"];

  for (const e of parsed.employees) {
    const match = await spMatchTeamMember(e.last_name, e.first_name);
    if (!match) { unmatched.push(`${e.first_name} ${e.last_name}`); continue; }

    const stateTax = Object.entries(e.deduction_items).filter(([k]) => /^STATE-/.test(k)).reduce((s, [, v]) => s + v.period, 0);
    const otherDed = Object.entries(e.deduction_items).filter(([k]) => !eeTaxKeys.includes(k) && !/^STATE-/.test(k)).reduce((s, [, v]) => s + v.period, 0);
    const employerSum = Object.values(e.employer_items).reduce((s, v) => s + v.period, 0);

    const earningsPeriodTotal = Object.values(e.earnings_items).reduce((s, v) => s + v.period, 0);
    const earningsYtdTotal    = Object.values(e.earnings_items).reduce((s, v) => s + v.ytd, 0);
    const dedPeriodTotal      = Object.values(e.deduction_items).reduce((s, v) => s + v.period, 0);
    const dedYtdTotal         = Object.values(e.deduction_items).reduce((s, v) => s + v.ytd, 0);
    const empPeriodTotal      = Object.values(e.employer_items).reduce((s, v) => s + v.period, 0);
    const empYtdTotal         = Object.values(e.employer_items).reduce((s, v) => s + v.ytd, 0);

    // YTD backfill: PDF path parses per-item YTD from source. CSV path does not
    // — compute cumulative YTD gross from prior payroll_detail rows in the same
    // calendar year (excluding this run). Required for weekly_cpr_team_detail.
    let effectiveYtdGross = e.ytd_gross;
    let effectiveEarningsYtd = earningsYtdTotal;
    if (opts.sourceFormat === "csv" || effectiveYtdGross === 0) {
      const yearStart = `${parsed.check_date.slice(0, 4)}-01-01`;
      const { data: priorRows } = await sb
        .from("payroll_detail")
        .select("gross_pay, payroll_runs!inner(pay_date)")
        .eq("team_member_id", match.id)
        .eq("agency_id", opts.agencyId)
        .gte("payroll_runs.pay_date", yearStart)
        .lt("payroll_runs.pay_date", parsed.check_date);
      const priorGross = (priorRows ?? []).reduce((s: number, r: any) => s + parseFloat(r.gross_pay ?? 0), 0);
      effectiveYtdGross = Math.round((priorGross + e.period_gross) * 100) / 100;
      effectiveEarningsYtd = effectiveYtdGross;
    }

    detailRows.push({
      payroll_run_id: runRowId, agency_id: opts.agencyId, business_entity_id: detailBusinessEntityId, team_member_id: match.id,
      gross_pay: e.period_gross, federal_tax: e.deduction_items["FED WTH"]?.period ?? 0, state_tax: stateTax,
      social_security: e.deduction_items["FICA"]?.period ?? 0, medicare: e.deduction_items["MEDFICA"]?.period ?? 0,
      other_deductions: otherDed, net_pay: e.net_pay, employment_type: "W2",
      ytd_gross: effectiveYtdGross, employer_taxes: employerSum,
      raw_earnings: { state: e.income_state, period_hours: e.period_hours, items: e.earnings_items, period_total: earningsPeriodTotal, ytd_total: effectiveEarningsYtd },
      raw_deductions: { items: e.deduction_items, period_total: dedPeriodTotal, ytd_total: dedYtdTotal },
      raw_employer_taxes: { items: e.employer_items, period_total: empPeriodTotal, ytd_total: empYtdTotal },
    });

    if (match.agency_id === opts.agencyId) {
      cprBreakdownByTeamId[match.id] = {
        period_hours: e.period_hours,
        items: e.earnings_items,
        period_total: earningsPeriodTotal,
        ytd_total: effectiveEarningsYtd,
      };
    }
  }
  if (detailRows.length > 0) {
    const { error: detErr } = await sb.from("payroll_detail").upsert(detailRows, { onConflict: "payroll_run_id,team_member_id", ignoreDuplicates: false });
    if (detErr) return { ok: false, error: `payroll_detail upsert: ${detErr.message}`, payroll_run_id: runRowId };
  }

  const cprWeekEnd = spTargetCprWeekEnding(parsed.check_date);
  const { data: cprReport } = await sb.from("weekly_cpr_reports").select("id").eq("agency_id", opts.agencyId).eq("week_ending_date", cprWeekEnd).maybeSingle();
  if (cprReport?.id) {
    for (const [teamMemberId, breakdown] of Object.entries(cprBreakdownByTeamId)) {
      const ytdGross = (breakdown as any).ytd_total;
      await sb.from("weekly_cpr_team_detail").update({
        payroll_ytd_paid: ytdGross,
        payroll_ytd_breakdown: breakdown,
      }).eq("agency_id", opts.agencyId).eq("weekly_cpr_report_id", cprReport.id).eq("team_member_id", teamMemberId);
    }
  }

  const { data: alertsResolved } = await sb.from("alerts").update({ is_resolved: true, resolved_at: new Date().toISOString() }).eq("agency_id", opts.agencyId).eq("module_reference", "payroll_run").eq("is_resolved", false).lte("due_date", parsed.check_date).select("id");

  await callComposio({
    apiKey: opts.composioApiKey, userId: opts.composioUserId, connectedAccountId: opts.gmailAccountId,
    toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
    toolArguments: { message_id: opts.gmailMessageId, add_label_ids: ["STARRED"], user_id: "me" },
  }).catch(() => {});

  return {
    ok: true, payroll_run_id: runRowId, merged_existing: mergedExisting,
    employees_written: detailRows.length, unmatched_employees: unmatched,
    cpr_week_updated: cprReport?.id ? cprWeekEnd : undefined,
    alerts_resolved: alertsResolved?.length ?? 0,
  };
}

// ==================== parsers/sf_daily_call_log.ts ====================
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

// ==================== parsers/pfa_statement.ts ====================
// =========================================================================
// parsers/pfa_statement.ts
// =========================================================================
// Frost Bank Premium Fund Account (PFA) statement parser.
//
// Inserts one pfa_bank_statements row per statement PDF, then auto-matches
// each statement line against uncleared pfa_transactions rows:
//   - Match on amount + direction + transaction_type + date (± 5 day window)
//   - For deposits, prefer transaction_number (check#) match if present
// Unmatched lines get NEW pfa_transactions rows inserted (imported_from_excel
// stays false, customer_name = NULL for compliance masking, notes carries the
// statement description). An alert is created listing anything unmatched.
//
// Once ingested, the pfa_monthly_nag alert auto-resolves (see pfa_monthly_nag
// RPC — it looks for a pfa_bank_statements row with statement_period_end
// matching the target month).
// =========================================================================


interface PfaStatementLine {
  date: string;                         // YYYY-MM-DD
  type: "deposit" | "withdrawal";
  amount: number;                       // always positive
  description: string;
  check_number: string | null;
}

interface ParsedPfaStatement {
  statement_period_start: string;
  statement_period_end: string;
  opening_balance: number;
  closing_balance: number;
  transactions: PfaStatementLine[];
}

export interface PfaStatementProcessResult {
  statementId: string;
  totalLines: number;
  matched: number;
  inserted: number;
  unmatchedLines: PfaStatementLine[];
}

export type PfaStatementResult =
  | { ok: true; result: PfaStatementProcessResult }
  | { ok: false; queued: true; queueId: string }
  | { ok: false; queued: false; error: string };

const SYSTEM_PROMPT_PFA_STATEMENT = `
You are a parser for Frost Bank Premium Fund Account (PFA) statements. Extract
the statement period, opening + closing balances, and every transaction line.

Return raw JSON only — no fences, no prose:
{
  "statement_period_start": "YYYY-MM-DD",
  "statement_period_end": "YYYY-MM-DD",
  "opening_balance": <number>,
  "closing_balance": <number>,
  "transactions": [
    {
      "date": "YYYY-MM-DD",
      "type": "deposit" | "withdrawal",
      "amount": <positive number>,
      "description": "<vendor / memo / counterparty>",
      "check_number": "<check number if the description contains one, else null>"
    }
  ]
}

Rules:
- Skip beginning/ending balance summary rows and any "Total" lines.
- Skip page headers, footers, informational marketing text.
- Use ISO dates.
- "deposit" = money into the account (credit). "withdrawal" = money out (debit).
- All amounts as positive numbers; direction is captured in "type".
- If a description contains a check number (e.g. "CHECK 593978" or "#593978"),
  extract the number into check_number (digits only, no # or "check" prefix).
- Combine multi-line transaction descriptions into a single description string.
- Output raw JSON, never wrap in code fences.
`.trim();

// Amount tolerance is EXACT — Frost doesn't round, Newtworks doesn't round.
// Any drift is real signal, not something to hide.
const DATE_WINDOW_DAYS = 5;

function isoDate(d: Date): string { return d.toISOString().slice(0, 10); }
function shiftDate(iso: string, deltaDays: number): string {
  const d = new Date(iso + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return isoDate(d);
}

// Deterministic pick of withdrawal subtype from the statement description.
function classifyWithdrawalType(description: string): string {
  const d = description.toLowerCase();
  if (/state\s*farm|sf\s*ach|preauth/.test(d)) return "State Farm EFT";
  if (/nsf|overdraft/.test(d)) return "NSF/Overdraft Fee";
  if (/service|monthly|maintenance|fee/.test(d)) return "Bank Service Fee";
  if (/return/.test(d)) return "Returned Check";
  return "Misc Withdrawal";
}

export async function processPfaStatement(opts: {
  agencyId: string;
  documentId: string;
  pdfText: string;
  composioApiKey: string;
  composioUserId: string;
}): Promise<PfaStatementResult> {
  // 1) LLM parse
  const llmResult = await parseWithLLM({
    agencyId: opts.agencyId,
    composioApiKey: opts.composioApiKey,
    composioUserId: opts.composioUserId,
    systemPrompt: SYSTEM_PROMPT_PFA_STATEMENT,
    userContent: opts.pdfText,
    documentId: opts.documentId,
    purpose: "parse_pfa_statement",
    maxTokens: 6000,
  });
  if (!llmResult.ok) {
    if (llmResult.queued) return { ok: false, queued: true, queueId: llmResult.queueId };
    return { ok: false, queued: false, error: llmResult.error };
  }
  const parsed = llmResult.json as ParsedPfaStatement;
  if (!parsed?.statement_period_start || !parsed?.statement_period_end) {
    return { ok: false, queued: false, error: "LLM output missing statement period" };
  }
  if (typeof parsed.opening_balance !== "number" || typeof parsed.closing_balance !== "number") {
    return { ok: false, queued: false, error: "LLM output missing opening/closing balance" };
  }

  // 2) Resolve PFA account
  const { data: pfaAccount, error: acctErr } = await sb
    .from("pfa_accounts")
    .select("id")
    .eq("agency_id", opts.agencyId)
    .eq("is_active", true)
    .maybeSingle();
  if (acctErr || !pfaAccount?.id) {
    return { ok: false, queued: false, error: "No active PFA account for agency" };
  }
  const pfaAccountId = pfaAccount.id as string;

  const txns: PfaStatementLine[] = Array.isArray(parsed.transactions) ? parsed.transactions : [];

  // 3) Idempotency: if a statement already exists for this period, wipe the
  //    downstream state so re-processing is safe.
  const { data: existingStmt } = await sb
    .from("pfa_bank_statements")
    .select("id")
    .eq("pfa_account_id", pfaAccountId)
    .eq("statement_period_end", parsed.statement_period_end)
    .maybeSingle();
  if (existingStmt?.id) {
    // Un-clear anything cleared inside this period
    await sb
      .from("pfa_transactions")
      .update({ cleared: false, cleared_date: null })
      .eq("pfa_account_id", pfaAccountId)
      .gte("cleared_date", parsed.statement_period_start)
      .lte("cleared_date", parsed.statement_period_end);
    // Delete any auto-imported rows tied to that previous statement
    await sb
      .from("pfa_transactions")
      .delete()
      .eq("pfa_account_id", pfaAccountId)
      .like("notes", `Imported from statement ${existingStmt.id}%`);
    // Delete the statement row itself
    await sb.from("pfa_bank_statements").delete().eq("id", existingStmt.id);
  }

  // 4) Insert the statement header
  const deposits = txns.filter(t => t.type === "deposit");
  const withdrawals = txns.filter(t => t.type === "withdrawal");
  const depositTotal = deposits.reduce((s, t) => s + t.amount, 0);
  const withdrawalTotal = withdrawals.reduce((s, t) => s + t.amount, 0);

  const { data: stmtRow, error: stmtErr } = await sb
    .from("pfa_bank_statements")
    .insert({
      pfa_account_id: pfaAccountId,
      statement_period_start: parsed.statement_period_start,
      statement_period_end: parsed.statement_period_end,
      opening_balance: parsed.opening_balance,
      closing_balance: parsed.closing_balance,
      deposit_count: deposits.length,
      deposit_total: depositTotal,
      withdrawal_count: withdrawals.length,
      withdrawal_total: withdrawalTotal,
      source_document_id: opts.documentId,
      imported_at: new Date().toISOString(),
    })
    .select("id")
    .single();
  if (stmtErr || !stmtRow?.id) {
    return { ok: false, queued: false, error: `pfa_bank_statements insert failed: ${stmtErr?.message}` };
  }
  const statementId = stmtRow.id as string;

  // 5) Match each statement line to an uncleared pfa_transactions row.
  //    Exact amount match; date window ± DATE_WINDOW_DAYS around the statement line date.
  let matched = 0;
  let inserted = 0;
  const unmatchedLines: PfaStatementLine[] = [];

  const depositTypes = ["Deposit", "Personal Deposit", "Other Credit"];
  const withdrawalTypes = ["State Farm EFT", "Bank Service Fee", "Personal Deposit", "Returned Check", "NSF/Overdraft Fee", "Misc Withdrawal", "Other Credit"];

  for (const line of txns) {
    const isDeposit = line.type === "deposit";
    const dateMin = shiftDate(line.date, -DATE_WINDOW_DAYS);
    const dateMax = shiftDate(line.date, +DATE_WINDOW_DAYS);
    const amountCol = isDeposit ? "credit_amount" : "debit_amount";
    const typesToTry = isDeposit ? depositTypes : withdrawalTypes;

    let matchedRowId: string | null = null;

    // Attempt A: deposit with check number → check-number-first match
    if (isDeposit && line.check_number) {
      const { data: hit } = await sb
        .from("pfa_transactions")
        .select("id")
        .eq("pfa_account_id", pfaAccountId)
        .eq("cleared", false)
        .is("voided_at", null)
        .eq("transaction_type", "Deposit")
        .eq(amountCol, line.amount)
        .eq("transaction_number", line.check_number)
        .gte("transaction_date", dateMin)
        .lte("transaction_date", dateMax)
        .order("transaction_date", { ascending: true })
        .limit(1);
      if (hit && hit.length > 0) matchedRowId = hit[0].id;
    }

    // Attempt B: amount + type + date window
    if (!matchedRowId) {
      const { data: hit } = await sb
        .from("pfa_transactions")
        .select("id")
        .eq("pfa_account_id", pfaAccountId)
        .eq("cleared", false)
        .is("voided_at", null)
        .in("transaction_type", typesToTry)
        .eq(amountCol, line.amount)
        .gte("transaction_date", dateMin)
        .lte("transaction_date", dateMax)
        .order("transaction_date", { ascending: true })
        .limit(1);
      if (hit && hit.length > 0) matchedRowId = hit[0].id;
    }

    if (matchedRowId) {
      const { error: updErr } = await sb
        .from("pfa_transactions")
        .update({ cleared: true, cleared_date: line.date })
        .eq("id", matchedRowId);
      if (!updErr) { matched++; continue; }
    }

    // Attempt C: no match — insert a new row (unattributed) so recon can balance
    const insertRow: Record<string, unknown> = {
      pfa_account_id: pfaAccountId,
      transaction_date: line.date,
      transaction_number: line.check_number ?? null,
      cleared: true,
      cleared_date: line.date,
      customer_name: null,   // constraint requires masked format if non-null
      policy_type: null,
      imported_from_excel: false,
      notes: `Imported from statement ${statementId}: ${line.description}`.slice(0, 500),
    };
    if (isDeposit) {
      insertRow.transaction_type = "Deposit";
      insertRow.credit_amount = line.amount;
      insertRow.debit_amount = null;
    } else {
      insertRow.transaction_type = classifyWithdrawalType(line.description);
      insertRow.debit_amount = line.amount;
      insertRow.credit_amount = null;
    }
    const { error: insErr } = await sb.from("pfa_transactions").insert(insertRow);
    if (insErr) {
      // Log but keep going — one bad line shouldn't kill the whole ingest.
      console.error(`pfa_statement unmatched insert failed for line ${JSON.stringify(line)}: ${insErr.message}`);
      continue;
    }
    inserted++;
    unmatchedLines.push(line);
  }

  // 6) Alert if anything was unmatched
  if (unmatchedLines.length > 0) {
    const previewLines = unmatchedLines.slice(0, 8).map(l =>
      `- $${l.amount.toFixed(2)} ${l.type} on ${l.date}` +
      (l.check_number ? ` #${l.check_number}` : "") +
      `: ${l.description.slice(0, 60)}`
    ).join("\n");
    const overflow = unmatchedLines.length > 8 ? `\n... and ${unmatchedLines.length - 8} more` : "";
    await sb.from("alerts").insert({
      agency_id: opts.agencyId,
      alert_type: "pfa_statement_unmatched",
      severity: "warning",
      title: `PFA statement ${parsed.statement_period_end}: ${unmatchedLines.length} unmatched line${unmatchedLines.length === 1 ? "" : "s"}`,
      message: `The Frost PFA statement for period ending ${parsed.statement_period_end} had ${unmatchedLines.length} transaction line(s) that couldn't be matched to existing pfa_transactions rows. New rows were auto-inserted (customer name null) so the reconciliation can balance — but you should review them in Deposits → Ledger and confirm they're right.\n\nFirst few:\n${previewLines}${overflow}`,
      module_reference: `pfa_statement_unmatched:${statementId}`,
      is_read: false,
      is_resolved: false,
      created_at: new Date().toISOString(),
    });
  }

  return {
    ok: true,
    result: {
      statementId,
      totalLines: txns.length,
      matched,
      inserted,
      unmatchedLines,
    },
  };
}

// ==================== parsers/careerplug_applicant.ts ====================
// =========================================================================
// parsers/careerplug_applicant.ts
// =========================================================================
// CareerPlug applicant notification email intake.
//
// Called from index.ts when body.mode === "careerplug". Bypasses the
// standard attachment intake pipeline because CareerPlug notifications
// carry applicant data in the email BODY, not as attachments (though a
// resume PDF may be attached — handled opportunistically).
//
// Two notification formats CareerPlug sends:
//   - Individual applicant: "New Applicant: <Name> applied for <Job>"
//                            → one applicant per email
//   - Daily Applicant Digest: "Daily Applicant Digest for <Date>"
//                            → multiple applicants grouped by job
//
// Since we have not yet observed real-world samples of these emails,
// this parser uses an LLM-first extraction. Once real samples arrive and
// the format stabilizes, a deterministic HTML/text regex path can be
// added as a fast-path with LLM as fallback.
//
// Flow:
//   1. GMAIL_FETCH_EMAILS with careerplug query (unstarred, no has:attachment)
//   2. For each unprocessed message:
//        a. GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID (full) to get body + attachments
//        b. LLM parse body -> array of applicants
//        c. For each applicant:
//             - If message has resume PDF attachment: download + upload to
//               Drive, insert documents row, capture resume_document_id
//             - Call upsert_candidate_from_careerplug RPC (idempotent)
//        d. Star the Gmail message (idempotency marker)
//        e. Archive the thread (remove INBOX label)
//   3. Return summary { ok, processed_messages, applicants_upserted, ... }
// =========================================================================

// deno-lint-ignore-file no-explicit-any

interface CareerplugBody {
  agency_id?: string;
  shared_secret?: string;
  mode?: string;
  gmail_query?: string;
  max_results?: number;
}

interface CareerplugCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
}

interface ExtractedApplicant {
  first_name: string | null;
  last_name:  string | null;
  email:      string | null;
  phone:      string | null;
  position:   string | null;
  applied_at: string | null;         // ISO 8601 if we can determine
  prescreen_score:  number | null;   // 0-100 if CareerPlug shows one
  is_fast_track:    boolean | null;
  source_platform:  string | null;   // "Indeed" | "ZipRecruiter" | "LinkedIn" | ...
  resume_url:       string | null;   // Public URL if present in the email
  careerplug_applicant_id: string | null;
  raw_line: string | null;           // optional: verbatim snippet for debug
}

// ---------- Applicant storage destinations ----------
// Gmail label + Drive folder for ingested CareerPlug applicants. Created
// 2026-07-14 via Gmail:create_label + Google Drive:create_file. Hardcoded
// here (not in settings) because these IDs never change once created — if
// they ever DO get recreated, update these two lines.
const APPLICANTS_GMAIL_LABEL_ID  = "Label_20";                          // "Applicants" label in paper.newt.management@gmail.com
const APPLICANTS_DRIVE_FOLDER_ID = "1GI0h2mEiuGb7BmQevkqpqQ9WM1CWVK4K"; // "Applicants" folder in paper.newt.management Drive root

// ---------- LLM extraction prompt ----------

const CAREERPLUG_EXTRACT_PROMPT = `You are extracting applicant data from a CareerPlug hiring platform notification email for a State Farm insurance agency.

CareerPlug sends TWO kinds of notification emails:
  1. Individual applicant email: "New Applicant: <Name> applied for <Job Title>"
     - Contains data for exactly one applicant.
  2. Daily Applicant Digest: "Daily Applicant Digest for <Date>"
     - Contains data for one or more applicants, usually grouped by job title.

Extract EVERY applicant referenced in the email body and return them as a JSON array under key "applicants".

For each applicant, extract these fields when present. Use null if a field is not present. Do not invent values.

  - first_name        (string)
  - last_name         (string)
  - email             (string)
  - phone             (string, digits only preferred but keep the original if formatted)
  - position          (string, the job title they applied to — e.g. "Sales Team Member")
  - applied_at        (ISO 8601 timestamp if the email states when the application was submitted; otherwise null)
  - prescreen_score   (integer 0-100 if a prescreen score / applicant score is shown; otherwise null)
  - is_fast_track     (boolean — true only if CareerPlug flags this applicant as "Fast Track" / "Auto Fast Track" / matches priority prescreen; otherwise null)
  - source_platform   (string — the job board the application came from: "Indeed", "ZipRecruiter", "LinkedIn", "Direct" / "Direct Apply", or similar. Null if not stated.)
  - resume_url        (string URL — a link to view/download the applicant's resume, if present. NOT a link to the applicant's profile page.)
  - careerplug_applicant_id (string — CareerPlug's internal applicant ID if it appears in a URL like /applicants/12345 or similar)
  - raw_line          (string — a short verbatim snippet from the email that this record was extracted from; useful for debugging)

Return STRICTLY this JSON shape and NOTHING else:

  { "applicants": [ { ... }, { ... } ] }

If the email does not appear to be a CareerPlug applicant notification at all, return:

  { "applicants": [] }

Do not include markdown code fences. Do not include explanation.`;

// ---------- One-message processing ----------

interface OneMessageResult {
  status: "processed" | "skipped" | "error";
  applicants_upserted: number;
  applicants_seen: number;
  message_id: string;
  error?: string;
  actions?: Array<{ email?: string | null; name?: string | null; action: string; assessment_id?: string }>;
}

async function processCareerplugMessage(
  ctx: CareerplugCtx,
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
    return { status: "error", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: `fetch message: ${msgRes.error}` };
  }
  const msg: any = msgRes.data?.response_data ?? msgRes.data ?? {};

  // Pull headers + a workable body
  const headers = msg?.payload?.headers ?? [];
  const fromEmail: string =
    msg?.from ?? msg?.sender ??
    headers.find((h: any) => h?.name === "From")?.value ?? "";
  const subject: string =
    msg?.subject ??
    headers.find((h: any) => h?.name === "Subject")?.value ?? "";
  const internalDateMs = msg?.internalDate ? Number(msg.internalDate) : Date.now();
  const receivedAtISO: string = new Date(internalDateMs).toISOString();

  // Extract text/plain preferentially, fall back to text/html stripped of tags
  const bodyText = extractBestBody(msg);
  if (!bodyText || bodyText.trim().length < 20) {
    return { status: "skipped", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: "empty or too-short body" };
  }

  // 2. LLM parse (with subject + from for context)
  const cleanedBody = stripCareerplugTrackers(bodyText);
  const llmInput =
    `SUBJECT: ${subject}\nFROM: ${fromEmail}\nRECEIVED_AT (ISO): ${receivedAtISO}\n\n=== BODY ===\n${cleanedBody.slice(0, 8000)}\n=== END BODY ===\n`;

  const parseRes = await parseWithLLM({
    agencyId: ctx.agencyId,
    composioApiKey: ctx.composioApiKey,
    composioUserId: ctx.composioUserId,
    systemPrompt: CAREERPLUG_EXTRACT_PROMPT,
    userContent: llmInput,
    documentId: null,
    purpose: "careerplug_applicant_extract",
    maxTokens: 800,
  });

  if (!parseRes.ok) {
    if ("queued" in parseRes && parseRes.queued) {
      return { status: "error", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: `LLM queued: ${parseRes.queueId}` };
    }
    return { status: "error", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: `LLM parse: ${("error" in parseRes) ? parseRes.error : "unknown"}` };
  }

  const applicants: ExtractedApplicant[] = Array.isArray(parseRes.json?.applicants)
    ? parseRes.json.applicants
    : [];

  if (applicants.length === 0) {
    // Not a CareerPlug applicant email OR LLM extracted nothing. Still star
    // the message so we don't reprocess it every cron tick.
    await starMessage(ctx, messageId);
    return { status: "skipped", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: "LLM extracted zero applicants" };
  }

  // 3. Attachments — find any PDFs that could be resumes
  const pdfAttachments = extractPdfAttachments(msg);

  // 4. Upsert each applicant
  const actions: OneMessageResult["actions"] = [];
  let upserted = 0;
  for (let idx = 0; idx < applicants.length; idx++) {
    const a = applicants[idx];

    // Attach a resume PDF if available. When there are exactly N applicants
    // and N PDFs in the message, associate by index; otherwise attach the
    // first PDF only to the first applicant and let others be resume-less.
    let resumeDocumentId: string | null = null;
    if (pdfAttachments.length > 0) {
      const pdf = pdfAttachments.length === applicants.length
        ? pdfAttachments[idx]
        : (idx === 0 ? pdfAttachments[0] : null);
      if (pdf) {
        const stored = await storeResume(ctx, messageId, subject, receivedAtISO, pdf, a);
        if (stored.ok) resumeDocumentId = stored.documentId;
      }
    }

    // Compose upsert payload
    const payload: Record<string, unknown> = {
      first_name: a.first_name ?? null,
      last_name:  a.last_name ?? null,
      email:      a.email ?? null,
      phone:      a.phone ?? null,
      position:   a.position ?? null,
      applied_at: a.applied_at ?? receivedAtISO,
      resume_url: a.resume_url ?? null,
      resume_document_id: resumeDocumentId,
      // Distinct idempotency key per applicant when the email is a digest.
      // Individual-applicant emails have exactly 1 applicant → keeps clean gmail_msg_id.
      gmail_message_id: applicants.length === 1 ? messageId : `${messageId}:${idx}`,
      careerplug_metadata: {
        prescreen_score: a.prescreen_score,
        is_fast_track:   a.is_fast_track,
        source_platform: a.source_platform,
        careerplug_applicant_id: a.careerplug_applicant_id,
        raw_line: a.raw_line,
        gmail_source_message_id: messageId,
        gmail_from: fromEmail,
        gmail_subject: subject,
      },
    };

    const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
      p_agency_id: ctx.agencyId,
      p_payload:   payload,
    });
    if (rpcErr) {
      actions.push({ email: a.email, name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null, action: `rpc_error: ${rpcErr.message}` });
      continue;
    }
    const res = (rpcData ?? {}) as { assessment_id?: string; action?: string };
    actions.push({
      email: a.email,
      name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
      action: res.action ?? "unknown",
      assessment_id: res.assessment_id,
    });
    if (res.action === "inserted" || res.action === "updated_by_email") upserted++;
  }

  // 5. Star + 6. Archive
  await starMessage(ctx, messageId);
  const threadId: string | null = msg?.threadId ?? msg?.thread_id ?? null;
  if (threadId) {
    try {
      await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
        toolArguments: {
          thread_id: threadId,
          remove_label_ids: ["INBOX"],
          add_label_ids: [APPLICANTS_GMAIL_LABEL_ID],
          user_id: "me",
        },
      });
    } catch (e) {
      console.warn("careerplug archive threw (non-fatal):", e);
    }
  }

  return {
    status: "processed",
    applicants_seen: applicants.length,
    applicants_upserted: upserted,
    message_id: messageId,
    actions,
  };
}

// ---------- Helpers ----------

function extractBestBody(msg: any): string {
  // Composio's GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID returns body in a variety of
  // shapes. Try common paths in order:
  //   1. msg.messageText (plain, most common)
  //   2. msg.textBody / msg.plaintext_body / msg.body_text
  //   3. walk payload.parts[] for text/plain
  //   4. fallback: msg.htmlBody / msg.html_body → strip tags
  const direct: string | undefined =
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
  if (typeof direct === "string" && direct.trim().length > 20) return direct;

  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const stack: any[] = [...parts];
  let htmlFallback: string | null = null;
  while (stack.length > 0) {
    const p = stack.shift();
    if (!p) continue;
    const mime: string = p.mimeType ?? p.mime_type ?? "";
    const dataB64: string | undefined = p?.body?.data ?? p?.data;
    if (dataB64) {
      const decoded = tryDecodeB64Url(dataB64);
      if (decoded !== null) {
        if (mime.startsWith("text/plain")) return decoded;
        if (mime.startsWith("text/html") && htmlFallback === null) htmlFallback = decoded;
      }
    }
    if (Array.isArray(p.parts)) stack.push(...p.parts);
  }

  if (htmlFallback) return stripHtml(htmlFallback);

  const htmlDirect: string | undefined = msg?.htmlBody ?? msg?.html_body;
  if (typeof htmlDirect === "string") return stripHtml(htmlDirect);

  return "";
}

function tryDecodeB64Url(b64: string): string | null {
  try {
    // Gmail base64url → base64
    const std = b64.replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(std);
    // Interpret as UTF-8
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  } catch (_e) {
    return null;
  }
}

function stripCareerplugTrackers(text: string): string {
  // CareerPlug notification bodies are ~90% base64 tracking URLs. Every
  // clickable text is followed by a parenthesized URL blob. Strip them —
  // they carry zero applicant signal and blow past Groq's TPM budget.
  return text
    .replace(/\(\s*https?:\/\/email\.reply\.careerplug\.com\/[^\s)]+\s*\)/gi, "")
    .replace(/https?:\/\/email\.reply\.careerplug\.com\/[^\s)]+/gi, "")
    .replace(/[ \t]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n");
}

function stripHtml(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<\/tr>/gi, "\n")
    .replace(/<\/td>/gi, "\t")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

interface PdfAttachment {
  filename: string;
  attachmentId: string;
  mimeType: string;
}

function extractPdfAttachments(msg: any): PdfAttachment[] {
  const out: PdfAttachment[] = [];
  const list1 = msg?.attachmentList as any[] | undefined;
  if (Array.isArray(list1)) {
    for (const a of list1) {
      if (!a?.filename || !a?.attachmentId) continue;
      const mime = a?.mimeType ?? "application/octet-stream";
      if (mime === "application/pdf" || /\.pdf$/i.test(a.filename)) {
        out.push({ filename: a.filename, attachmentId: a.attachmentId, mimeType: mime });
      }
    }
    if (out.length > 0) return out;
  }
  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const stack: any[] = [...parts];
  while (stack.length > 0) {
    const p = stack.shift();
    if (!p) continue;
    const filename: string | undefined = p?.filename;
    const attId: string | undefined = p?.body?.attachmentId ?? p?.attachmentId;
    const mime: string = p?.mimeType ?? p?.mime_type ?? "";
    if (filename && attId && (mime === "application/pdf" || /\.pdf$/i.test(filename))) {
      out.push({ filename, attachmentId: attId, mimeType: mime });
    }
    if (Array.isArray(p.parts)) stack.push(...p.parts);
  }
  return out;
}

async function starMessage(ctx: CareerplugCtx, messageId: string): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: {
        message_id: messageId,
        label_ids: ["STARRED"],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn("careerplug star threw (non-fatal):", e);
  }
}

interface StoreResumeResult {
  ok: boolean;
  documentId?: string;
  error?: string;
}

async function storeResume(
  ctx: CareerplugCtx,
  messageId: string,
  subject: string,
  receivedAtISO: string,
  pdf: PdfAttachment,
  a: ExtractedApplicant,
): Promise<StoreResumeResult> {
  // 1. Download attachment bytes
  const getRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: messageId,
      attachment_id: pdf.attachmentId,
      file_name: pdf.filename,
      user_id: "me",
    },
  });
  if (!getRes.ok) return { ok: false, error: `GMAIL_GET_ATTACHMENT: ${getRes.error}` };
  const file = getRes.data?.file ?? getRes.data?.data?.file;
  const s3url = file?.s3url;
  let bytesB64 = "";
  if (s3url) {
    try {
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) {
        bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      }
      bytesB64 = btoa(bin);
    } catch (e) {
      return { ok: false, error: `s3url threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  } else {
    const fallback = getRes.data?.data ?? getRes.data?.bytes;
    if (typeof fallback === "string") bytesB64 = fallback;
    else return { ok: false, error: "no s3url and no inline bytes" };
  }

  // 2. Compose a stable filename: "Resume - <FirstLast> - <YYYYMMDD>.pdf"
  const nameSlug = [a.first_name, a.last_name].filter(Boolean).join(" ") || "unknown";
  const dateSlug = receivedAtISO.slice(0, 10).replace(/-/g, "");
  const targetName = `Resume - ${nameSlug} - ${dateSlug}.pdf`;

  // 3. Upload to Drive if we have a drive account, else skip Drive step
  let driveFileId: string | null = null;
  let driveUrl:    string | null = null;
  if (ctx.driveAccountId) {
    try {
      const uploadRes = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.driveAccountId,
        toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
        toolArguments: {
          file_name: targetName,
          mime_type: "application/pdf",
          file_content: bytesB64,           // base64 body
          is_base64: true,
          folder_to_upload_to: APPLICANTS_DRIVE_FOLDER_ID,
        },
      });
      if (uploadRes.ok) {
        driveFileId = uploadRes.data?.id ?? uploadRes.data?.fileId ?? uploadRes.data?.response_data?.id ?? null;
        driveUrl    = uploadRes.data?.webViewLink ?? uploadRes.data?.web_view_link ?? uploadRes.data?.response_data?.webViewLink ?? null;
      } else {
        console.warn(`resume Drive upload failed (non-fatal): ${uploadRes.error}`);
      }
    } catch (e) {
      console.warn("resume Drive upload threw (non-fatal):", e);
    }
  }

  // 4. Insert documents row
  const { data: docRow, error: docErr } = await sb
    .from("documents")
    .insert({
      agency_id: ctx.agencyId,
      file_name: targetName,
      groq_classification: "careerplug_resume",
      upload_source: "gmail",
      gmail_message_id: messageId,
      drive_file_id: driveFileId,
      drive_url: driveUrl,
      processing_status: "processed",
      uploaded_at: receivedAtISO,
    })
    .select("id")
    .single();
  if (docErr || !docRow) {
    return { ok: false, error: `documents insert: ${docErr?.message ?? "unknown"}` };
  }
  return { ok: true, documentId: docRow.id as string };
}

// ---------- Mode entry point ----------

export async function processCareerplugMode(
  ctx: CareerplugCtx,
  body: CareerplugBody,
): Promise<{
  ok: boolean;
  processed_messages: number;
  applicants_upserted: number;
  applicants_seen: number;
  skipped: number;
  errors: number;
  message_count: number;
  results: any[];
  error?: string;
}> {
  const query = body.gmail_query ??
    `(from:careerplug.com OR from:careerplug OR subject:"new applicant" OR subject:"applicant digest") -label:Applicants newer_than:14d`;
  const maxResults = body.max_results ?? 20;

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
    return { ok: false, processed_messages: 0, applicants_upserted: 0, applicants_seen: 0, skipped: 0, errors: 1, message_count: 0, results: [], error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: any[] = [];
  let applicantsUpserted = 0;
  let applicantsSeen = 0;
  let processed = 0;
  let skipped = 0;
  let errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processCareerplugMessage(ctx, msgId);
      results.push(r);
      if (r.status === "processed") {
        processed++;
        applicantsUpserted += r.applicants_upserted;
        applicantsSeen     += r.applicants_seen;
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
    applicants_upserted: applicantsUpserted,
    applicants_seen: applicantsSeen,
    skipped,
    errors,
    message_count: messages.length,
    results,
  };
}

// ==================== index.ts ====================
// =========================================================================
// document-processor / index.ts
// =========================================================================
// Edge Function entry point. Cron: every 30 minutes.
//
// PURPOSE: Single unified document intake pipeline. Replaces the 12-recipe
// approach with one orchestrator that handles every doc type uniformly,
// including ZIP archives (which are unpacked and processed recursively).
//
// FLOW:
//   1. fetchNewGmailAttachments()
//   2. for each attachment:
//        processOneAttachment(att, sourceLabel="gmail")
//          a. classifyDocument(filename, sender) -> docType
//          b. download (or use provided bytes when called recursively)
//          c. if docType === "archive_bundle":
//                unzip in memory; for each entry, call processOneAttachment(
//                  inner, sourceLabel="gmail_zip:<outer>")
//             else:
//                upload to Drive in dated folder, insert document row,
//                route to per-docType handler.
//   3. return rolled-up summary
//
// CURRENT BUILD STATE:
//   - Orchestrator: yes
//   - Bank statement path (full GL post + suspense loop): yes
//   - Comp recap / deduction / payroll / production parsers: yes
//   - Zip unpacker: yes (this build)
//
// AUTH:
//   POST body must include shared_secret matching the agency's
//   automation_runner_cron_secret. Body must include agency_id.
// =========================================================================

// deno-lint-ignore-file no-explicit-any
// v4 (2026-07-01): unpdf replaces removed Composio pdf-to-text tool

interface RunCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
}

interface ProcessedAttachment {
  documentId: string;
  fileName: string;
  fromEmail: string;
  docType: DocType;
  status:
    | "processed"
    | "skipped"
    | "queued"
    | "error"
    | "stub_pending"
    | "unpacked";
  jeCount: number;
  suspenseCount: number;
  error?: string;
  queueId?: string;
  sourceLabel?: string; // "gmail" or "gmail_zip:<outer>"
  innerCount?: number; // for archive_bundle: how many inner files processed
}

const MAX_ZIP_DEPTH = 2;

// ---- Gmail intake ----------------------------------------------------------

interface AttachmentInput {
  // Where this attachment came from. For Gmail intake: filled in below.
  // For zip inner files: filled in from the outer + the inner filename.
  messageId: string; // empty string for inner files
  threadId: string;  // gmail thread id (empty for inner zip files)
  fromEmail: string;
  subject: string;
  receivedAt: string; // ISO 8601
  fileName: string;
  mimeType: string;

  // Only one of attachmentId OR bytesB64 will be set.
  // - Gmail-fetched outer attachments: attachmentId is set; bytesB64 is null.
  // - Inner files from a zip: bytesB64 is set; attachmentId is null.
  attachmentId: string | null;
  bytesB64: string | null;

  // For inner files only — name of the containing zip, for source labeling.
  parentArchive?: string;
}

async function fetchNewGmailAttachments(ctx: RunCtx): Promise<AttachmentInput[]> {
  // Look back 7 days to catch anything we missed between cron ticks.
  // Idempotency is enforced per-file inside the loop.
  const lookback = "newer_than:7d has:attachment";

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query: lookback, max_results: 50 },
  });

  if (!listRes.ok) throw new Error(`Gmail fetch failed: ${listRes.error}`);

  const messages: any[] = listRes.data?.messages ?? listRes.data ?? [];
  const attachments: AttachmentInput[] = [];

  for (const m of messages) {
    const headers = m?.payload?.headers ?? [];
    const fromEmail =
      m?.from ?? m?.sender ??
      headers.find((h: any) => h.name === "From")?.value ?? "";
    const subject =
      m?.subject ??
      headers.find((h: any) => h.name === "Subject")?.value ?? "";
    const receivedAt = m?.messageTimestamp ??
      (m?.internalDate ? new Date(Number(m.internalDate)).toISOString()
                       : new Date().toISOString());

    // Composio's GMAIL_FETCH_EMAILS exposes attachments two ways depending on
    // mode — attachmentList[] (new) or payload.parts[] (raw). Support both.
    const list1 = m?.attachmentList as any[] | undefined;
    if (Array.isArray(list1)) {
      for (const a of list1) {
        const filename = a?.filename;
        const attId = a?.attachmentId;
        if (!filename || !attId) continue;

        // Idempotency: skip if already in documents (any upload_source that
        // starts with "gmail" — outer or inner-from-zip).
        const { data: existing } = await sb
          .from("documents")
          .select("id")
          .eq("agency_id", ctx.agencyId)
          .eq("file_name", filename)
          .like("upload_source", "gmail%")
          .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
          .maybeSingle();
        if (existing?.id) continue;

        attachments.push({
          messageId: m.messageId ?? m.id,
          threadId: m.threadId ?? m.thread_id ?? m.messageId ?? m.id,
          fromEmail, subject, receivedAt,
          fileName: filename,
          mimeType: a?.mimeType ?? "application/octet-stream",
          attachmentId: attId,
          bytesB64: null,
        });
      }
      continue;
    }

    // Fallback: walk payload.parts
    const parts: any[] = m?.payload?.parts ?? m?.parts ?? [];
    for (const p of parts) {
      const filename = p?.filename;
      if (!filename) continue;
      const attId = p?.body?.attachmentId;
      if (!attId) continue;

      const { data: existing } = await sb
        .from("documents")
        .select("id")
        .eq("agency_id", ctx.agencyId)
        .eq("file_name", filename)
        .like("upload_source", "gmail%")
        .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
        .maybeSingle();
      if (existing?.id) continue;

      attachments.push({
        messageId: m.id,
        threadId: m.threadId ?? m.thread_id ?? m.id,
        fromEmail, subject, receivedAt,
        fileName: filename,
        mimeType: p?.mimeType ?? "application/octet-stream",
        attachmentId: attId,
        bytesB64: null,
      });
    }
  }
  return attachments;
}

async function downloadAttachmentBytes(
  ctx: RunCtx, att: AttachmentInput,
): Promise<{ ok: true; bytesB64: string } | { ok: false; error: string }> {
  if (att.bytesB64) return { ok: true, bytesB64: att.bytesB64 }; // inner file already in hand
  if (!att.attachmentId) return { ok: false, error: "no attachmentId on outer attachment" };

  // Composio's GMAIL_GET_ATTACHMENT returns an s3url to fetch the raw bytes.
  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: att.messageId,
      attachment_id: att.attachmentId,
      file_name: att.fileName,
      user_id: "me",
    },
  });
  if (!res.ok) return { ok: false, error: `GMAIL_GET_ATTACHMENT failed: ${res.error}` };
  const file = res.data?.file ?? res.data?.data?.file;
  const s3url = file?.s3url;
  if (s3url) {
    try {
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch returned HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      // Base64-encode in chunks to avoid call-stack issues on large files.
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) {
        bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      }
      return { ok: true, bytesB64: btoa(bin) };
    } catch (e) {
      return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  }
  // Fallback for older Composio response shapes
  const fallback = res.data?.data ?? res.data?.bytes;
  if (typeof fallback === "string") return { ok: true, bytesB64: fallback };
  return { ok: false, error: "GMAIL_GET_ATTACHMENT returned no s3url and no inline bytes" };
}

// ---- ZIP unpack ------------------------------------------------------------

interface UnzippedEntry {
  fileName: string; // basename only (folder prefix stripped)
  bytesB64: string;
  mimeType: string;
}

function guessMime(name: string): string {
  const n = name.toLowerCase();
  if (n.endsWith(".pdf")) return "application/pdf";
  if (n.endsWith(".csv")) return "text/csv";
  if (n.endsWith(".txt")) return "text/plain";
  if (n.endsWith(".xlsx")) return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
  if (n.endsWith(".xls")) return "application/vnd.ms-excel";
  if (n.endsWith(".zip")) return "application/zip";
  return "application/octet-stream";
}

async function unzipBytes(bytesB64: string): Promise<UnzippedEntry[]> {
  const bin = atob(bytesB64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  const blob = new Blob([buf]);
  const reader = new ZipReader(new BlobReader(blob));
  const entries = await reader.getEntries();

  const out: UnzippedEntry[] = [];
  for (const entry of entries) {
    if (entry.directory) continue;
    if (!entry.getData) continue;
    const data = await entry.getData(new Uint8ArrayWriter());
    // Strip folder prefix from name
    const lastSlash = entry.filename.lastIndexOf("/");
    const baseName = lastSlash >= 0 ? entry.filename.slice(lastSlash + 1) : entry.filename;
    if (!baseName || baseName.startsWith(".")) continue; // skip hidden / __MACOSX

    // base64-encode entry bytes
    let bin2 = "";
    const CHUNK = 0x8000;
    for (let i = 0; i < data.length; i += CHUNK) {
      bin2 += String.fromCharCode(...data.subarray(i, i + CHUNK));
    }
    out.push({
      fileName: baseName,
      bytesB64: btoa(bin2),
      mimeType: guessMime(baseName),
    });
  }
  await reader.close();
  return out;
}

// ---- Drive upload ----------------------------------------------------------

const DRIVE_FOLDER_BY_DOCTYPE: Record<DocType, string> = {
  bank_statement_primary: "bank-statements",
  bank_statement_secondary: "bank-statements",
  bank_statement_pfa: "pfa-statements",
  comp_recap_1h: "sf-comp-recap",
  comp_recap_daily: "sf-comp-recap",
  deduction_statement: "sf-deductions",
  adp_payroll: "payroll",
  surepayroll_payroll: "payroll",
  commission_report: "commission-reports",
  team_production: "team-production",
  archive_bundle: "_archive-bundles",
  skip: "unsorted",
};

async function uploadToDrive(
  ctx: RunCtx, att: AttachmentInput, bytesB64: string,
  docType: DocType, txnDate: string,
): Promise<{ driveFileId: string; driveUrl: string } | null> {
  if (!ctx.driveAccountId) return null;
  const folder = DRIVE_FOLDER_BY_DOCTYPE[docType];
  const yearMonth = txnDate.slice(0, 7);
  const path = `Newtworks/Documents/${yearMonth}/${folder}/${att.fileName}`;

  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.driveAccountId,
    toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
    toolArguments: {
      file_name: att.fileName,
      file_path: path,
      content_base64: bytesB64,
      mime_type: att.mimeType,
    },
  });
  if (!res.ok) return null;
  return {
    driveFileId: res.data?.id ?? res.data?.file_id ?? "",
    driveUrl: res.data?.webViewLink ?? res.data?.url ?? "",
  };
}

// ---- documents row ---------------------------------------------------------

async function insertSourceDocument(
  ctx: RunCtx, att: AttachmentInput, docType: DocType,
  drive: { driveFileId: string; driveUrl: string } | null,
  sourceAccountCode: string | null,
  uploadSource: string,
): Promise<string> {
  const { data, error } = await sb
    .from("documents")
    .insert({
      agency_id: ctx.agencyId,
      file_name: att.fileName,
      file_type: att.mimeType,
      upload_source: uploadSource,
      drive_file_id: drive?.driveFileId ?? null,
      drive_url: drive?.driveUrl ?? null,
      processing_status: "received",
      processing_type: "document_processor",
      groq_classification: docType,
      source_account_code: sourceAccountCode,
      uploaded_by: att.fromEmail,
      uploaded_at: att.receivedAt,
      gmail_message_id: att.messageId || null,
      gmail_thread_id: att.threadId || null,
      notes: `subject: ${att.subject}${att.parentArchive ? ` | extracted_from: ${att.parentArchive}` : ""}`,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`document insert failed: ${error?.message ?? "unknown"}`);
  return data.id;
}

async function markDocument(
  documentId: string, status: string,
  recordsCreated?: number, tablesUpdated?: string[], notes?: string,
): Promise<void> {
  await sb.from("documents").update({
    processing_status: status,
    records_created: recordsCreated ?? 0,
    tables_updated: tablesUpdated ?? [],
    processed_at: new Date().toISOString(),
    notes: notes ?? undefined,
  }).eq("id", documentId);
}

// ---- Text extraction -------------------------------------------------------

async function extractText(
  _ctx: RunCtx, att: AttachmentInput, bytesB64: string, preserveFormat: boolean = false,
): Promise<{ ok: true; text: string } | { ok: false; error: string }> {
  if (att.mimeType.startsWith("text/") || att.fileName.endsWith(".txt") || att.fileName.endsWith(".csv")) {
    try { return { ok: true, text: atob(bytesB64) }; }
    catch (e) { return { ok: false, error: `text decode failed: ${String(e)}` }; }
  }
  // v4: unpdf (pure JS, edge-runtime-compatible). Image-based PDFs
  // return empty text -> route to Drive OCR folder for manual review.
  try {
    const bin = atob(bytesB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const pdf = await getDocumentProxy(bytes);
    const { text } = await unpdfExtractText(pdf, { mergePages: true });
    let merged = Array.isArray(text) ? text.join("\n") : String(text ?? "");
    if (!merged.trim()) {
      return { ok: false, error: "unpdf returned empty text (likely image-based PDF)" };
    }
    if (!preserveFormat) {
      // SF PDFs collapse each logical row into " 1<caps>" — reinject newlines
      merged = merged.replace(/ (?=1[A-Z ])/g, "\n");
    }
    return { ok: true, text: merged };
  } catch (e) {
    return { ok: false, error: `unpdf extraction failed: ${e instanceof Error ? e.message : String(e)}` };
  }
}

// ---- Bank handler ----------------------------------------------------------

async function handleBankStatement(
  ctx: RunCtx, att: AttachmentInput, documentId: string,
  bytesB64: string, sourceAccountCode: string,
): Promise<{ jeCount: number; suspenseCount: number; queueId?: string; error?: string }> {
  // Reset per-doc reference counter so identical-fingerprint txns across
  // different documents don't leak :N suffixes to each other.
  resetReferenceCounters();

  const extracted = await extractText(ctx, att, bytesB64);
  if (!extracted.ok) return { jeCount: 0, suspenseCount: 0, error: extracted.error };

  const parsed = await parseBankStatement({
    agencyId: ctx.agencyId,
    composioApiKey: ctx.composioApiKey,
    composioUserId: ctx.composioUserId,
    sourceAccountCode,
    statementText: extracted.text,
    documentId,
  });

  if (!parsed.ok) {
    if (parsed.queued) return { jeCount: 0, suspenseCount: 0, queueId: parsed.queueId };
    return { jeCount: 0, suspenseCount: 0, error: parsed.error };
  }

  let jeCount = 0;
  let suspenseCount = 0;
  for (const row of parsed.transactions) {
    const classification = await classifyBankTxn(ctx.agencyId, row.txn);
    const post = await postJournalEntry({
      agencyId: ctx.agencyId,
      txn: row.txn,
      txnDate: row.date,
      classification,
      sourceDocumentId: documentId,
    });
    if (post.skipped) continue;
    jeCount += 1;
    if (post.isSuspense && post.journalEntryId) {
      await createSuspenseTask({
        agencyId: ctx.agencyId,
        composioApiKey: ctx.composioApiKey,
        composioUserId: ctx.composioUserId,
        journalEntryId: post.journalEntryId,
        txn: row.txn,
        txnDate: row.date,
      });
      suspenseCount += 1;
    }
  }
  return { jeCount, suspenseCount };
}

function resolveSourceAccount(fromEmail: string, subject: string, fileName: string): string {
  const blob = (fromEmail + " " + subject + " " + fileName).toLowerCase();

  // ---- US Bank sub-account routing (order matters — most specific first).
  // File naming convention (Marie's spec): "US Bank {Label} {YY-MM}.pdf" where
  // Label is one of Income (3977, COA-007), Expenses (4335, COA-006), CC (3447,
  // COA-025 USBank GN Personal Card). Account numbers also match if statement
  // text is scanned in.
  if (/us\s*bank\s*income|\b3977\b/.test(blob)) return "COA-007";
  if (/us\s*bank\s*expenses|\b4335\b/.test(blob)) return "COA-006";
  if (/us\s*bank\s*cc|\b3447\b/.test(blob)) return "COA-025";
  // Generic US Bank fallback — Income (conservative default, matches historic behavior)
  if (/usbank|us[\s_-]?bank/.test(blob)) return "COA-007";

  // ---- Chase — Mktg 2 (COA-012) holds all post-cutover activity.
  // Mktg 1 (COA-011) is inactive post-cutover; require explicit "mktg 1" match.
  if (/chase[\s\-_]*(mktg|marketing)[\s\-_]*1/.test(blob)) return "COA-011";
  if (/chase/.test(blob)) return "COA-012";

  if (/truist|trb/.test(blob)) return "COA-004";
  if (/statefarm|sf[\s.-]?ach/.test(blob)) return "COA-024";
  if (/amex|american[\s_-]?express/.test(blob)) return "COA-009";
  if (/capital[\s_-]?one/.test(blob)) return "COA-010";
  if (/citi/.test(blob)) return "COA-028";
  if (/spark/.test(blob)) return "COA-026";
  return "COA-007";
}

// ---- Gmail thread archive --------------------------------------------------
// After a doc finishes successfully, check whether every document tied to the
// same gmail_thread_id is in a terminal state (processed/error/skipped). If so,
// archive the thread in Gmail by removing the INBOX label. Sets
// documents.gmail_archived_at for all rows in the thread so we know it happened.
// Gmail label routing per docType. Created 2026-07-14. Update this map when
// adding a new docType. Nulls skip label-add (still removes INBOX).
const ARCHIVE_LABEL_FOR_DOCTYPE: Record<string, string | null> = {
  bank_statement_primary:   "Label_22", // "Bank Statements"
  bank_statement_secondary: "Label_22",
  bank_statement_pfa:       "Label_28", // "PFA"
  comp_recap_1h:            "Label_24", // "SF Compensation"
  comp_recap_daily:         "Label_24",
  deduction_statement:      "Label_25", // "SF Deductions"
  surepayroll_payroll:      "Label_26", // "Payroll"
  adp_payroll:              "Label_26",
  commission_report:        "Label_27", // "Production"
  team_production:          "Label_27",
  careerplug_applicant:     "Label_20", // "Applicants" (attachment pipeline)
};

async function maybeArchiveThread(ctx: RunCtx, threadId: string | null | undefined, docType?: string): Promise<void> {
  if (!threadId) return;
  // Inner zip files inherit empty threadId — skip.
  try {
    const { data: pending } = await sb
      .from("documents")
      .select("id, processing_status")
      .eq("agency_id", ctx.agencyId)
      .eq("gmail_thread_id", threadId)
      .not("processing_status", "in", "(processed,error,skipped)");
    if ((pending?.length ?? 0) > 0) {
      console.log(`[archive] thread ${threadId}: ${pending?.length} docs still pending, not archiving yet`);
      return;
    }
    const res = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
      toolArguments: {
        thread_id: threadId,
        remove_label_ids: ["INBOX"],
        ...(docType && ARCHIVE_LABEL_FOR_DOCTYPE[docType]
          ? { add_label_ids: [ARCHIVE_LABEL_FOR_DOCTYPE[docType]!] }
          : {}),
        user_id: "me",
      },
    });
    if (!res.ok) {
      console.error(`[archive] thread ${threadId}: GMAIL_MODIFY_THREAD_LABELS failed: ${res.error}`);
      return;
    }
    await sb
      .from("documents")
      .update({ gmail_archived_at: new Date().toISOString() })
      .eq("agency_id", ctx.agencyId)
      .eq("gmail_thread_id", threadId)
      .is("gmail_archived_at", null);
    console.log(`[archive] thread ${threadId}: archived (INBOX label removed)`);
  } catch (e) {
    console.error(`[archive] thread ${threadId}: exception: ${e instanceof Error ? e.message : String(e)}`);
  }
}

// ---- Per-attachment processor (reusable for outer + zip-inner files) -------

async function processOneAttachment(
  ctx: RunCtx,
  att: AttachmentInput,
  depth: number,
  uploadSource: string,
): Promise<ProcessedAttachment[]> {
  const results: ProcessedAttachment[] = [];

  const docType = classifyDocument({
    fromEmail: att.fromEmail,
    subject: att.subject,
    fileName: att.fileName,
  });

  // Idempotency check: skip if this exact filename was already processed.
  // (The fetcher already checks this for outer attachments; this catches
  // inner-zip files where the fetcher hasn't seen them yet.)
  if (depth > 0) {
    const { data: existing } = await sb
      .from("documents")
      .select("id")
      .eq("agency_id", ctx.agencyId)
      .eq("file_name", att.fileName)
      .like("upload_source", "gmail%")
      .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
      .maybeSingle();
    if (existing?.id) {
      results.push({
        documentId: existing.id, fileName: att.fileName, fromEmail: att.fromEmail,
        docType, status: "skipped", jeCount: 0, suspenseCount: 0,
        sourceLabel: uploadSource,
        error: "already_processed (idempotent)",
      });
      return results;
    }
  }

  if (docType === "skip") {
    results.push({
      documentId: "", fileName: att.fileName, fromEmail: att.fromEmail,
      docType, status: "skipped", jeCount: 0, suspenseCount: 0,
      sourceLabel: uploadSource,
    });
    return results;
  }

  // Get bytes (downloads from Gmail for outer, uses in-hand bytes for inner)
  const dl = await downloadAttachmentBytes(ctx, att);
  if (!dl.ok) {
    console.error(`[document-processor] attachment_download_failed: ${att.fileName} threadId=${att.threadId} messageId=${att.messageId} reason="${dl.error}"`);
    results.push({
      documentId: "", fileName: att.fileName, fromEmail: att.fromEmail,
      docType, status: "error", jeCount: 0, suspenseCount: 0,
      sourceLabel: uploadSource,
      error: `attachment_download_failed: ${dl.error}`,
    });
    return results;
  }
  const bytesB64 = dl.bytesB64;

  // ---- ZIP fork --------------------------------------------------------
  if (docType === "archive_bundle") {
    if (depth >= MAX_ZIP_DEPTH) {
      results.push({
        documentId: "", fileName: att.fileName, fromEmail: att.fromEmail,
        docType, status: "skipped", jeCount: 0, suspenseCount: 0,
        sourceLabel: uploadSource,
        error: `nested_zip_too_deep (max ${MAX_ZIP_DEPTH})`,
      });
      return results;
    }

    // Archive the zip itself to Drive for completeness, then walk inner.
    const txnDate = att.receivedAt.slice(0, 10);
    const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate);
    const documentId = await insertSourceDocument(
      ctx, att, docType, drive, null, uploadSource,
    );

    let inner: UnzippedEntry[];
    try {
      inner = await unzipBytes(bytesB64);
    } catch (e) {
      await markDocument(documentId, "error", 0, [], `unzip failed: ${(e as Error).message}`);
      results.push({
        documentId, fileName: att.fileName, fromEmail: att.fromEmail,
        docType, status: "error", jeCount: 0, suspenseCount: 0,
        sourceLabel: uploadSource,
        error: `unzip_failed: ${(e as Error).message}`,
      });
      return results;
    }

    let processedCount = 0;
    let jeRollup = 0;
    let suspRollup = 0;

    for (const entry of inner) {
      // Pull a date from filename if possible — drives folder routing and
      // ensures pre-cutover documents land in their historical month folder.
      const inferred = inferDateFromFilename(entry.fileName);
      const receivedAt = inferred
        ? `${inferred}T12:00:00.000Z`
        : att.receivedAt;

      const innerAtt: AttachmentInput = {
        messageId: "",
        fromEmail: att.fromEmail,
        subject: att.subject, // preserve outer subject for diagnostic visibility
        receivedAt,
        fileName: entry.fileName,
        mimeType: entry.mimeType,
        attachmentId: null,
        bytesB64: entry.bytesB64,
        parentArchive: att.fileName,
      };

      const innerResults = await processOneAttachment(
        ctx, innerAtt, depth + 1, `gmail_zip:${att.fileName}`,
      );
      for (const r of innerResults) {
        results.push(r);
        if (r.status === "processed") processedCount += 1;
        jeRollup += r.jeCount;
        suspRollup += r.suspenseCount;
      }
    }

    await markDocument(
      documentId, "unpacked", inner.length, ["documents"],
      `unpacked ${inner.length} files; ${processedCount} processed downstream`,
    );

    // Push a summary row for the zip itself
    results.unshift({
      documentId, fileName: att.fileName, fromEmail: att.fromEmail,
      docType: "archive_bundle", status: "unpacked",
      jeCount: jeRollup, suspenseCount: suspRollup,
      sourceLabel: uploadSource,
      innerCount: inner.length,
    });
    return results;
  }

  // ---- Non-zip path: archive + parse -----------------------------------

  // Prefer date inferred from filename (eg "25_03_11 Compensation.pdf");
  // fall back to receivedAt. This is what puts pre-cutover docs in their
  // historical Drive folder rather than today's folder.
  const inferred = inferDateFromFilename(att.fileName);
  const txnDate = inferred ?? att.receivedAt.slice(0, 10);

  const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate);
  const isBankStmt =
    docType === "bank_statement_primary" ||
    docType === "bank_statement_secondary";
  const sourceAccountCode = isBankStmt
    ? resolveSourceAccount(att.fromEmail, att.subject, att.fileName)
    : null;
  const documentId = await insertSourceDocument(
    ctx, att, docType, drive, sourceAccountCode, uploadSource,
  );

  // Dispatch on docType
  try {
    switch (docType) {
      case "bank_statement_primary":
      case "bank_statement_secondary": {
        const src = sourceAccountCode as string;
        const r = await handleBankStatement(ctx, att, documentId, bytesB64, src);
        if (r.queueId) {
          await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "queued", jeCount: 0, suspenseCount: 0,
            queueId: r.queueId, sourceLabel: uploadSource,
          });
        } else if (r.error) {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "processed", r.jeCount,
            ["journal_entries", "journal_lines"],
            `${r.jeCount} JEs posted, ${r.suspenseCount} in suspense`);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed",
            jeCount: r.jeCount, suspenseCount: r.suspenseCount,
            sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "comp_recap_1h":
      case "comp_recap_daily": {
        const variant = docType === "comp_recap_1h" ? "1H" : "DAILY";
        const ex = await extractText(ctx, att, bytesB64);
        if (!ex.ok) {
          await markDocument(documentId, "error", 0, [], ex.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: ex.error, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await parseCompRecap({
          agencyId: ctx.agencyId, documentId, statementText: ex.text,
        });
        if (r.ok) {
          await markDocument(documentId, "processed", r.written, ["comp_recap"],
            `${r.written} comp_recap rows written`);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "deduction_statement": {
        const ex = await extractText(ctx, att, bytesB64);
        if (!ex.ok) {
          await markDocument(documentId, "error", 0, [], ex.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: ex.error, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await parseDeductionStatement({
          agencyId: ctx.agencyId, documentId, statementText: ex.text,
        });
        if (r.ok) {
          await markDocument(documentId, "processed", r.written, ["comp_recap"],
            `${r.written} deduction rows written`);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "bank_statement_pfa": {
        // Frost PFA statement. LLM parse (uses SYSTEM_PROMPT_PFA_STATEMENT in bundle),
        // insert pfa_bank_statements row, auto-match cleared items, insert unmatched
        // rows so reconciliation can balance, and alert on any unmatched.
        const ex = await extractText(ctx, att, bytesB64);
        if (!ex.ok) {
          await markDocument(documentId, "error", 0, [], ex.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: ex.error, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await processPfaStatement({
          agencyId: ctx.agencyId,
          documentId,
          pdfText: ex.text,
          composioApiKey: ctx.composioApiKey,
          composioUserId: ctx.composioUserId,
        });
        if (r.ok) {
          const res = r.result;
          const unm = res.unmatchedLines.length;
          const note = `PFA statement: ${res.totalLines} lines · ${res.matched} matched · ${res.inserted} inserted` + (unm > 0 ? ` · ${unm} unmatched` : "");
          await markDocument(documentId, "processed", res.totalLines,
            (unm > 0 ? ["pfa_bank_statements", "pfa_transactions", "alerts"] : ["pfa_bank_statements", "pfa_transactions"]), note);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else if (r.queued) {
          await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "queued", jeCount: 0, suspenseCount: 0,
            queueId: r.queueId, sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
            case "surepayroll_payroll": {
        // PDF path: unpdf with preserveFormat=true. CSV path: extractText decodes text bytes directly.
        const isCsv = /\.csv$/i.test(att.fileName);
        const ex = await extractText(ctx, att, bytesB64, true);
        if (!ex.ok) {
          await markDocument(documentId, "error", 0, [], ex.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: ex.error, sourceLabel: uploadSource,
          });
          break;
        }
        let parsed: ParsedSurePayroll;
        try {
          parsed = isCsv ? parseSurePayrollCsvText(ex.text) : parseSurePayrollText(ex.text);
        } catch (e) {
          const err = `parser: ${(e as Error).message}`;
          await markDocument(documentId, "error", 0, [], err);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: err, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await processSurePayrollParsed({
          agencyId: ctx.agencyId, documentId,
          gmailMessageId: att.messageId, gmailThreadId: att.threadId,
          parsed,
          sourceText: ex.text,
          sourceFormat: isCsv ? "csv" : "pdf",
          composioApiKey: ctx.composioApiKey,
          composioUserId: ctx.composioUserId,
          gmailAccountId: ctx.gmailAccountId,
        });
        if (r.ok) {
          const unmatchedNote = (r.unmatched_employees?.length ?? 0) > 0
            ? `, unmatched: ${r.unmatched_employees!.join(",")}` : "";
          const mergeNote = r.merged_existing ? " (merged existing row)" : "";
          const note = `SurePayroll: ${r.employees_written} employees, CPR week ${r.cpr_week_updated ?? "n/a"}, ${r.alerts_resolved} alerts resolved${mergeNote}${unmatchedNote}`;
          await markDocument(documentId, "processed", r.employees_written ?? 0,
            ["payroll_runs", "payroll_detail", "weekly_cpr_team_detail", "alerts"], note);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "error", 0, [], r.error ?? "unknown");
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "adp_payroll": {
        const ex = await extractText(ctx, att, bytesB64);
        if (!ex.ok) {
          await markDocument(documentId, "error", 0, [], ex.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: ex.error, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await parsePayrollRun({
          agencyId: ctx.agencyId, composioApiKey: ctx.composioApiKey,
          composioUserId: ctx.composioUserId, documentId, statementText: ex.text,
        });
        if (r.ok) {
          await markDocument(documentId, "processed", r.detailCount + 1,
            ["payroll_runs", "payroll_detail"],
            `payroll run ${r.run.pay_date}: ${r.detailCount} detail rows`);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else if (r.queued) {
          await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "queued", jeCount: 0, suspenseCount: 0,
            queueId: r.queueId, sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "commission_report":
      case "team_production": {
        const ex = await extractText(ctx, att, bytesB64);
        if (!ex.ok) {
          await markDocument(documentId, "error", 0, [], ex.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: ex.error, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await parseProductionReport({
          agencyId: ctx.agencyId, composioApiKey: ctx.composioApiKey,
          composioUserId: ctx.composioUserId, documentId,
          reportVariant: docType as "commission_report" | "team_production",
          statementText: ex.text,
        });
        if (r.ok) {
          const note = r.unmatchedStaff.length > 0
            ? `${r.written} rows; ${r.unmatchedStaff.length} unmatched: ${r.unmatchedStaff.slice(0,5).join(", ")}`
            : `${r.written} producer_production rows written`;
          await markDocument(documentId, "processed", r.written, ["producer_production"], note);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else if (r.queued) {
          await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "queued", jeCount: 0, suspenseCount: 0,
            queueId: r.queueId, sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "careerplug_applicant": {
        // CareerPlug resume PDF that arrived through the standard attachment
        // path (parent notification email is handled by processCareerplugMode).
        // Persist the document row as processed and archive the thread. Linking
        // the resume to a team_assessments row happens in the mode path when
        // the parent notification is parsed.
        await markDocument(documentId, "processed", 0, ["documents"],
          "CareerPlug resume stored via attachment pipeline; linkage handled by mode=careerplug");
        await maybeArchiveThread(ctx, att.threadId, docType);
        results.push({
          documentId, fileName: att.fileName, fromEmail: att.fromEmail,
          docType, status: "processed", jeCount: 0, suspenseCount: 0,
          sourceLabel: uploadSource,
        });
        break;
      }
      default: {
        await markDocument(documentId, "awaiting_parser_implementation",
          0, [], `Parser for ${docType} not yet implemented`);
        results.push({
          documentId, fileName: att.fileName, fromEmail: att.fromEmail,
          docType, status: "stub_pending", jeCount: 0, suspenseCount: 0,
          sourceLabel: uploadSource,
        });
      }
    }
  } catch (e) {
    await markDocument(documentId, "error", 0, [], (e as Error).message);
    results.push({
      documentId, fileName: att.fileName, fromEmail: att.fromEmail,
      docType, status: "error", jeCount: 0, suspenseCount: 0,
      error: (e as Error).message, sourceLabel: uploadSource,
    });
  }

  return results;
}

// ---- Main handler ----------------------------------------------------------

async function run(req: Request): Promise<Response> {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);

  const expected = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expected || expected !== sharedSecret) return jsonResponse({ ok: false, error: "auth failed" }, 401);

  const composioApiKey = await getSetting(agencyId, "composio_api_key");
  const composioUserId = await getSetting(agencyId, "composio_user_id");
  const gmailAccountId = await getSetting(agencyId, "composio_gmail_account_id");
  const driveAccountId = await getSetting(agencyId, "composio_googledrive_account_id");
  if (!composioApiKey || !composioUserId || !gmailAccountId) {
    return jsonResponse({
      ok: false,
      error: "missing composio_api_key / composio_user_id / composio_gmail_account_id",
    }, 400);
  }

  // ---- Mode dispatch ----
  // Absent or "attachments" (default): existing Gmail attachment intake.
  // "call_log": eGain daily call log HTML parser (folded in from the retired
  //   call-log-parser standalone edge fn, v39 2026-07-08).
  const mode = typeof body?.mode === "string" ? body.mode : "attachments";
  if (mode === "call_log") {
    const callLogCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId };
    const startedAt = new Date().toISOString();
    const result = await processCallLogMode(callLogCtx, body);
    return jsonResponse({ ok: true, mode: "call_log", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "careerplug") {
    const cpCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
    const startedAt = new Date().toISOString();
    const result = await processCareerplugMode(cpCtx, body);
    return jsonResponse({ ok: true, mode: "careerplug", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }

  const ctx: RunCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
  const startedAt = new Date().toISOString();
  const allResults: ProcessedAttachment[] = [];

  let attachments: AttachmentInput[];
  try {
    attachments = await fetchNewGmailAttachments(ctx);
  } catch (e) {
    return jsonResponse({
      ok: false,
      error: `gmail intake failed: ${(e as Error).message}`,
      started_at: startedAt,
    }, 500);
  }

  for (const att of attachments) {
    const results = await processOneAttachment(ctx, att, 0, "gmail");
    allResults.push(...results);
  }

  const summary = {
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    attachments_seen: attachments.length,
    items_total: allResults.length, // includes inner files from zips
    processed: allResults.filter((p) => p.status === "processed").length,
    skipped: allResults.filter((p) => p.status === "skipped").length,
    queued: allResults.filter((p) => p.status === "queued").length,
    errors: allResults.filter((p) => p.status === "error").length,
    stub_pending: allResults.filter((p) => p.status === "stub_pending").length,
    unpacked_zips: allResults.filter((p) => p.status === "unpacked").length,
    total_jes: allResults.reduce((n, p) => n + p.jeCount, 0),
    total_suspense: allResults.reduce((n, p) => n + p.suspenseCount, 0),
    items: allResults,
  };

  return jsonResponse({ ok: true, summary });
}

Deno.serve(run);
