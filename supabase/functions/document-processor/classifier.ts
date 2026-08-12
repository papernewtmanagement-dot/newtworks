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

import { sb } from "../_shared/supabase.ts";

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
  | "resume_manual_batch"
  | "archive_bundle"
  | "skip";

export interface DocClassifyInput {
  fromEmail: string;
  subject: string;
  fileName: string;
}

const docRules: Array<{ docType: DocType; test: (i: DocClassifyInput) => boolean }> = [
  // ----- SUREPAYROLL (v37 PDF 2026-07-07, v52 +CSV 2026-07-14,
  //       filename-fallback broadened 2026-07-18) —
  //       SF-forwarded SurePayroll summary. Deterministic parsers for both
  //       formats: unpdf regex for PDF, header-mapped column parser for CSV.
  //       Requires .pdf or .csv extension to avoid matching inline images
  //       (image001.gif etc.) that come with the email.
  //
  //       Peter does not use ADP; every payroll doc at this agency is
  //       SurePayroll. The filename fallbacks below catch SurePayroll files
  //       that arrive without a statefarm sender (Drive uploads, zip
  //       contents, Alvi's Gmail forwards). The equivalent adp_payroll
  //       filename fallback was DELETED 2026-07-18 — the "Payroll Summary.pdf"
  //       from 2026-07-06 hit that landmine and misclassified. -----
  { docType: "surepayroll_payroll",
    test: (i) => /statefarm/i.test(i.fromEmail)
              && /payroll/i.test(i.subject + " " + i.fileName)
              && /\.(pdf|csv)$/i.test(i.fileName) },

  // ----- SUREPAYROLL filename fallbacks (any sender, incl. Drive/zip) -----
  //       "Payroll Summary.pdf" and "Payroll Summary (N).pdf" — SurePayroll
  //       portal download naming.
  { docType: "surepayroll_payroll",
    test: (i) => /^Payroll Summary(?:\s*\(\d+\))?\.pdf$/i.test(filenameBase(i.fileName)) },
  //       "YY-MM-DD.csv" — SurePayroll weekly CSV naming (check date).
  { docType: "surepayroll_payroll",
    test: (i) => /^\d{2}-\d{2}-\d{2}\.csv$/i.test(filenameBase(i.fileName)) },
  //       Generic safety net: any *.pdf or *.csv with payroll-keyword in name.
  { docType: "surepayroll_payroll",
    test: (i) => /\.(pdf|csv)$/i.test(i.fileName)
              && /\b(payroll|paystub|pay[\s_-]?run|paycheck)\b/i.test(filenameBase(i.fileName)) },

  // ----- SUREPAYROLL non-parseable attachments (inline images) — SKIP silently.
  //       Same sender + subject match but neither pdf nor csv: don't try. -----
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

  // ----- HAND-FORWARDED RESUME BATCH (2026-08-03) — a bare resume PDF
  //       attached to an email a PERSON forwarded, with no job-board sender
  //       and usually an empty body. Marie forwards these from her own Gmail
  //       in batches ("Applicants - Career Plug 3", "Applicants - Indeed
  //       08/01"); Stephanie forwards them from her State Farm mailbox under
  //       the subject "Resumes".
  //
  //       Deliberately sender-agnostic. Every prior resume route was gated on
  //       the sender, so a forward from anyone else fell through to "skip" —
  //       no documents row, no candidate row, no error. About 80 resumes piled
  //       up that way before it was noticed 2026-08-03.
  //
  //       Ordering is load-bearing: this sits AFTER the CareerPlug rule above
  //       so genuine CareerPlug mail keeps its own route.
  //
  //       State-Farm-forward carve-out REMOVED 2026-08-06: the old CTS
  //       instrument (and its mode=sf_forwarded_applicant parser) is fully
  //       decommissioned -- Peter confirmed he is no longer forwarding CTS
  //       profile PDFs. Resumes from Peter's SF mailbox now flow through
  //       this same route like every other hand-forwarded resume. -----
  { docType: "resume_manual_batch",
    test: (i) => /\.pdf$/i.test(i.fileName) &&
                 /resume|curriculum[\s_-]?vitae|\bcv\b/i.test(filenameBase(i.fileName)) },

  // ----- FROST PFA STATEMENT (2026-07-09) — must come BEFORE the generic
  //       bank statement rules. Sender = Frost Bank; subject/filename mentions
  //       "PFA", "premium fund", or the PFA account number 020715816. -----
  { docType: "bank_statement_pfa",
    test: (i) => /frost/i.test(i.fromEmail + " " + i.subject) &&
                 /(pfa|premium\s?fund|020715816)/i.test(i.subject + " " + i.fileName) },
  { docType: "bank_statement_pfa",
    test: (i) => /020715816/.test(i.subject + " " + i.fileName) },
  // ----- FROST PFA STATEMENT — subject-only fallback (2026-08-03).
  //       Peter forwards his own "PFA Statement MM-YY" emails from his
  //       State Farm mailbox rather than receiving them straight from
  //       Frost, so the sender rule above never matches (fromEmail is
  //       peter.story.yrru@statefarm.com, not Frost) and the filename
  //       ("MM_YY Statement.pdf") carries no PFA/account-number marker
  //       either. That combination fell through to "skip" and the July
  //       2026 statement silently never got parsed — found 2026-08-03,
  //       ingested by hand. "PFA" in the subject alone is specific
  //       enough at this agency to route correctly regardless of sender.
  //       Guards, each load-bearing: require "statement" wording so our OWN
  //       outgoing "PFA Reconciliation — <Month>" emails never match (the
  //       Gmail fetch query has no -in:sent, so sent mail IS scanned, and
  //       processPfaStatement's idempotency step would un-clear transactions
  //       and delete the real statement row for that period); exclude
  //       "reconciliation" explicitly as a second belt; and require .pdf so
  //       the 7 inline signature images on every forward don't each get
  //       classified as a statement and error out.
  { docType: "bank_statement_pfa",
    test: (i) => /\bpfa\b/i.test(i.subject) &&
                 /statement/i.test(i.subject + " " + i.fileName) &&
                 !/reconciliation/i.test(i.subject) &&
                 /\.pdf$/i.test(i.fileName) },

  // ----- BANK / CC STATEMENTS — sender drives classification -----
  { docType: "bank_statement_primary",
    test: (i) => /usbank|us[\s_-]?bank|usbank\.com/i.test(i.fromEmail + " " + i.subject) &&
                 /statement|estatement/i.test(i.fileName + " " + i.subject) },
  { docType: "bank_statement_secondary",
    test: (i) => /(chase|bankofamerica|trb|truist|wells\s?fargo|amex|american[\s_-]?express|capital[\s_-]?one|citi|spark|discover|rbfcu|randolph|fidelity)/i.test(i.fromEmail + " " + i.subject) &&
                 /statement|estatement/i.test(i.fileName + " " + i.subject) },

  // ----- BANK / CC STATEMENTS — filename-only fallback (Alvi's zip-content
  //       naming convention). Pattern: "{Institution} {Label} YY-MM.pdf" —
  //       e.g. "US Bank KidsProfitDisc 26-01.pdf", "RBFCU Saving 26-03.pdf",
  //       "Discover Tithe CC 26-02.pdf". No "statement" in the filename, no
  //       usbank sender on the outer email (Alvi forwards from her Gmail).
  //       Institution match distinguishes primary (US Bank) from secondary
  //       (everything else). Added 2026-07-27 after the KidsProfitDisc.zip
  //       intake left 7 inner files unclassified. -----
  { docType: "bank_statement_primary",
    test: (i) => /^us[\s_-]?bank\b.*\d{2}-\d{2}\.pdf$/i.test(filenameBase(i.fileName)) },
  // Date shape allows "26-04.pdf", "26_04.pdf" and a multi-month range like
  // "26_01-03.pdf" — Fidelity sends one PDF covering several months, and Alvi
  // labels those with underscores. Superset of the old \d{2}-\d{2} pattern.
  { docType: "bank_statement_secondary",
    test: (i) => /^(rbfcu|randolph|chase|bankofamerica|bank[\s_-]?of[\s_-]?america|trb|truist|wells\s?fargo|amex|american[\s_-]?express|capital[\s_-]?one|citi|spark|discover|fidelity)\b.*\d{2}[-_]\d{2}(?:[-_]\d{2})?\.pdf$/i.test(filenameBase(i.fileName)) },

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

  // ----- ADP / GUSTO PAYROLL — sender path ONLY (2026-07-18).
  //       Filename-only fallback DELETED: previously routed any file with
  //       "payroll"/"paystub"/etc in the name to adp_payroll when the
  //       SurePayroll sender rule didn't match. That caused the 7/06
  //       "Payroll Summary.pdf" misclassification (statefarm sender rule
  //       hadn't shipped yet → fell to filename fallback → adp_payroll →
  //       generic LLM parser instead of SurePayroll deterministic parser).
  //       Peter does not use ADP; every payroll doc at this agency is
  //       SurePayroll, caught by the sender + filename fallbacks above.
  //       If ADP/Gusto is ever added, this sender rule catches it. -----
  { docType: "adp_payroll",
    test: (i) => /adp\.com|workforcenow|gusto/i.test(i.fromEmail + " " + i.subject) },

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
