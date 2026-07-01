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

import { sb } from "./lib/supabase.ts";
import type { BankTxn, ClassificationResult } from "./classifier.ts";

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
