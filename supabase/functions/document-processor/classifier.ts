// =========================================================================
// classifier.ts
// =========================================================================
// 1. classifyBankTxn(): matches a bank transaction against
//    gl_classification_rules (priority-ordered). The catch-all SUSPENSE rule
//    guarantees a result.
// 2. classifyDocument(): determines the docType from filename + sender
//    BEFORE bank transactions are even parsed.
// =========================================================================

import { sb } from "./lib/supabase.ts";

export interface BankTxn {
  payee: string;
  memo: string;
  signedAmount: number; // positive = in, negative = out
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
  return {
    ruleId: "00000000-0000-0000-0000-000000000000",
    ruleName: "SUSPENSE (synthetic — no catch-all rule found)",
    debitAccountCode: "QBO-SUSP",
    creditAccountCode: "QBO-SUSP",
    subCategoryLabel: "Pending agent classification",
    confidence: "suspense",
    isSuspense: true,
  };
}

export function invalidateRulesCache(): void { rulesCache = null; }

export type DocType =
  | "bank_statement_primary"
  | "bank_statement_secondary"
  | "comp_recap_1h"
  | "comp_recap_daily"
  | "deduction_statement"
  | "adp_payroll"
  | "commission_report"
  | "team_production"
  | "skip";

export interface DocClassifyInput {
  fromEmail: string;
  subject: string;
  fileName: string;
}

const docRules: Array<{ docType: DocType; test: (i: DocClassifyInput) => boolean }> = [
  { docType: "bank_statement_primary",
    test: (i) => /usbank|us[\s_-]?bank|usbank\.com/i.test(i.fromEmail + " " + i.subject) &&
                 /statement|estatement/i.test(i.fileName + " " + i.subject) },
  { docType: "bank_statement_secondary",
    test: (i) => /(chase|bankofamerica|trb|truist|wells\s?fargo)/i.test(i.fromEmail + " " + i.subject) &&
                 /statement|estatement/i.test(i.fileName + " " + i.subject) },
  { docType: "comp_recap_1h",
    test: (i) => /statefarm|sf\s?agent|sf[\s.-]?ach/i.test(i.fromEmail + " " + i.subject) &&
                 /1h|hour|hourly/i.test(i.subject + " " + i.fileName) },
  { docType: "comp_recap_daily",
    test: (i) => /statefarm/i.test(i.fromEmail) &&
                 /comp\s?recap|daily\s?comp/i.test(i.subject + " " + i.fileName) },
  { docType: "deduction_statement",
    test: (i) => /statefarm/i.test(i.fromEmail) && /deduction/i.test(i.subject + " " + i.fileName) },
  { docType: "adp_payroll",
    test: (i) => /adp\.com|workforcenow|gusto/i.test(i.fromEmail + " " + i.subject) },
  { docType: "commission_report",
    test: (i) => /commission/i.test(i.subject + " " + i.fileName) &&
                 !/comp\s?recap/i.test(i.subject) },
  { docType: "team_production",
    test: (i) => /production\s?report|team\s?production/i.test(i.subject + " " + i.fileName) },
];

export function classifyDocument(input: DocClassifyInput): DocType {
  for (const r of docRules) {
    if (r.test(input)) return r.docType;
  }
  return "skip";
}
