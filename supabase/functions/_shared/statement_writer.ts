// =========================================================================
// _shared/statement_writer.ts
// =========================================================================
// THE single statement ingestion writer. Both intake paths call this:
//   - document-processor handleBankStatement (synchronous parse)
//   - llm-queue-drainer drainBankStatementItem (queued parse)
// Collapsed 2026-08-11 from two hand-maintained copies (see open question
// "Collapse the twin statement ingestion writers into one shared function").
// What rides on the agreement between the two paths is money-sign
// correctness and cross-path duplicate detection — so there is now exactly
// one copy.
//
// Guarantees, in order of evaluation:
//   1. DUPLICATE-INGEST GUARD (document/period grain). The same statement
//      file historically arrived through two intake doors (email attachment
//      + Drive library sweep), producing two documents rows that were each
//      parsed. statement_balances has a unique index so balances collided;
//      statements has NO unique constraint so transactions doubled. Guard:
//      if another document already wrote transactions for this account +
//      statement period, stamp this document 'duplicate_ingest', emit a
//      low-severity alert, write NOTHING. Deliberately NOT a unique index
//      at the transaction grain — two genuinely distinct transactions can
//      share account, date, amount AND description (account 2110 has two
//      real 250.00 EVERQUOTE charges on 2026-05-10; the window ties with
//      both present).
//   2. RECONCILIATION GUARD. closing == opening + sum(signedAmount) within
//      STMT_RECON_EPSILON. Missing balances or a mismatch → stamp the
//      document 'held_reconciliation_mismatch', stash the parsed payload in
//      documents.notes, emit a high-severity alert, write NOTHING. This is
//      the deterministic backstop for silently dropped lines: the 2026-08-05
//      manual pass dropped repeated identical same-day charges (13 rows /
//      286.93 on AMEX 2141) and nothing checked the tie. Any dropped line —
//      whatever layer drops it — now breaks the tie loudly instead of
//      landing short.
//   3. BALANCE UPSERT keyed (agency_id, account_code, statement_period_end).
//      account_kind comes from the resolved accounts row — never inferred
//      from the account code string (the old '-CC-' inference can never
//      match numeric chart codes).
//   4. TRANSACTIONS with per-parse occurrence counting. Repeated identical
//      (account, date, amount, payee) lines within one parsed statement each
//      get their own occurrence number, carried on BOTH reference_number and
//      dedup_fingerprint (dp:<code>:<date>:<cents>:<payee20>[:N], N omitted
//      for the first occurrence). Any insert error → ok:false so callers do
//      NOT stamp the document processed (R2 silent-failure rule preserved
//      for both paths).
//
// Sign convention (D15): parser emits positive = money in, negative = money
// out, regardless of account kind. Bank rows keep the parser sign. Credit
// rows flip: a charge lands positive (balance owed goes up), a payment or
// refund lands negative. Derived only from account_kind, never from the
// amount's own sign.
// =========================================================================

import { sb } from "./supabase.ts";

const STMT_RECON_EPSILON = 0.01;

export interface ParsedStatementTxn {
  date: string;          // ISO transaction date (date charged, not posted)
  payee: string;
  memo: string;
  signedAmount: number;  // parser convention: + money in, - money out
}

export interface WriteParsedStatementOpts {
  agencyId: string;
  documentId: string;
  accountCode: string;               // chart code, e.g. "2141"
  account: {
    id: string;                      // accounts.id
    businessEntityId: string;
    accountKind: string;             // 'bank' | 'credit'
  };
  accountLast4: string | null;
  period: { start: string; end: string };
  openingBalance: number | null;
  closingBalance: number | null;
  transactions: ParsedStatementTxn[];
  source: "document_processor" | "llm_queue_drainer";
}

export type WriteParsedStatementResult =
  | { ok: true; inserted: number }
  | { ok: false; held: "duplicate_ingest"; reason: string; priorDocumentId: string }
  | { ok: false; held: "reconciliation_mismatch"; reason: string; delta: number | null }
  | { ok: false; held?: undefined; error: string; inserted: number };

function moduleRef(source: WriteParsedStatementOpts["source"]): string {
  return source === "llm_queue_drainer" ? "llm-queue-drainer" : "document-processor";
}

export async function writeParsedStatement(
  opts: WriteParsedStatementOpts,
): Promise<WriteParsedStatementResult> {
  const nowIso = () => new Date().toISOString();

  // ---- 1. Duplicate-ingest guard (document/period grain) ------------------
  const { data: priorBal } = await sb
    .from("statement_balances")
    .select("id, source_document_id")
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .eq("statement_period_end", opts.period.end)
    .maybeSingle();

  if (priorBal?.source_document_id && priorBal.source_document_id !== opts.documentId) {
    const { count } = await sb
      .from("statements")
      .select("id", { count: "exact", head: true })
      .eq("agency_id", opts.agencyId)
      .eq("source_document_id", priorBal.source_document_id);
    if ((count ?? 0) > 0) {
      const reason =
        `duplicate_ingest: document ${priorBal.source_document_id} already wrote ` +
        `${count} transactions for account ${opts.accountCode} period ending ${opts.period.end}. ` +
        `Nothing written from this document.`;
      await sb.from("documents").update({
        processing_status: "duplicate_ingest",
        notes: reason,
        processed_at: nowIso(),
      }).eq("id", opts.documentId);
      await sb.from("alerts").insert({
        agency_id: opts.agencyId,
        alert_type: "duplicate_statement_ingest",
        severity: "low",
        title: `Duplicate statement skipped — ${opts.accountCode} period ending ${opts.period.end}`,
        message: reason,
        module_reference: moduleRef(opts.source),
        related_id: opts.documentId,
        is_read: false,
        is_resolved: false,
        created_at: nowIso(),
      });
      return { ok: false, held: "duplicate_ingest", reason, priorDocumentId: priorBal.source_document_id };
    }
  }

  // ---- 2. Reconciliation guard --------------------------------------------
  const openBal = opts.openingBalance;
  const closeBal = opts.closingBalance;
  let reconDelta: number | null = null;
  let reconHeldReason: string | null = null;

  if (openBal === null || closeBal === null) {
    reconHeldReason =
      `missing balance from parser: opening=${openBal === null ? "null" : openBal}, ` +
      `closing=${closeBal === null ? "null" : closeBal}`;
  } else {
    const txnSum = opts.transactions.reduce((acc, t) => acc + t.signedAmount, 0);
    const expected = openBal + txnSum;
    reconDelta = Math.round((closeBal - expected) * 100) / 100;
    if (Math.abs(reconDelta) > STMT_RECON_EPSILON) {
      reconHeldReason =
        `delta=$${reconDelta.toFixed(2)} exceeds epsilon $${STMT_RECON_EPSILON.toFixed(2)} ` +
        `(opening=$${openBal.toFixed(2)}, sum_txns=$${txnSum.toFixed(2)}, ` +
        `expected_close=$${expected.toFixed(2)}, actual_close=$${closeBal.toFixed(2)}, ` +
        `${opts.transactions.length} txns)`;
    }
  }

  if (reconHeldReason !== null) {
    const heldNotes = JSON.stringify({
      held: "reconciliation_mismatch",
      reason: reconHeldReason,
      reconciliation_delta: reconDelta,
      source_account_code: opts.accountCode,
      account_last4: opts.accountLast4,
      statement_period: opts.period,
      opening_balance: openBal,
      closing_balance: closeBal,
      txn_count: opts.transactions.length,
      parsed_transactions: opts.transactions.map((t) => ({
        date: t.date, payee: t.payee, memo: t.memo, amount: t.signedAmount,
      })),
    });
    await sb.from("documents").update({
      processing_status: "held_reconciliation_mismatch",
      reconciliation_delta: reconDelta,
      notes: heldNotes,
      processed_at: nowIso(),
    }).eq("id", opts.documentId);
    await sb.from("alerts").insert({
      agency_id: opts.agencyId,
      alert_type: "reconciliation_mismatch",
      severity: "high",
      title: `Statement reconciliation mismatch — ${opts.accountCode} period ending ${opts.period.end}`,
      message:
        `Parsed statement for account ${opts.accountCode} does not tie to the printed ` +
        `statement summary. ${reconHeldReason}. Held for review — nothing written.`,
      module_reference: moduleRef(opts.source),
      related_id: opts.documentId,
      is_read: false,
      is_resolved: false,
      created_at: nowIso(),
    });
    console.warn(`[statement_writer] reconciliation_mismatch doc=${opts.documentId} account=${opts.accountCode}: ${reconHeldReason}`);
    return { ok: false, held: "reconciliation_mismatch", reason: reconHeldReason, delta: reconDelta };
  }

  // Success path: record near-zero delta for the audit trail.
  await sb.from("documents").update({ reconciliation_delta: reconDelta }).eq("id", opts.documentId);

  // ---- 3. Balance upsert (agency_id, account_code, statement_period_end) --
  const balPayload = {
    business_entity_id: opts.account.businessEntityId,
    account_last4: opts.accountLast4,
    account_kind: opts.account.accountKind,
    statement_period_start: opts.period.start,
    opening_balance: openBal,
    closing_balance: closeBal,
    source_document_id: opts.documentId,
    source: opts.source,
    updated_at: nowIso(),
  };
  const upd = await sb
    .from("statement_balances")
    .update(balPayload)
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .eq("statement_period_end", opts.period.end)
    .select("id");
  if (upd.error) {
    return { ok: false, error: `statement_balances update failed: ${upd.error.message}`, inserted: 0 };
  }
  if (!upd.data || upd.data.length === 0) {
    const ins = await sb.from("statement_balances").insert({
      agency_id: opts.agencyId,
      account_code: opts.accountCode,
      statement_period_end: opts.period.end,
      ...balPayload,
    });
    if (ins.error) {
      return { ok: false, error: `statement_balances insert failed: ${ins.error.message}`, inserted: 0 };
    }
  }

  // ---- 4. Transactions with per-parse occurrence counting -----------------
  // legacy_source_table intentionally omitted — NULL is the correct value for
  // live intake (finrebuild_e1_statements_legacy_source_table_nullable).
  const refCounters = new Map<string, number>();
  let inserted = 0;
  const errors: string[] = [];

  for (const t of opts.transactions) {
    const amount = opts.account.accountKind === "credit" ? -t.signedAmount : t.signedAmount;
    const transactionType = opts.account.accountKind === "credit"
      ? (amount >= 0 ? "charge" : "payment_or_credit")
      : (amount >= 0 ? "deposit" : "withdrawal");
    const description = t.memo ? `${t.payee} — ${t.memo}` : t.payee;

    const payeeShort = t.payee.toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 20);
    const amtCents = Math.round(Math.abs(amount) * 100);
    const fpBase = `dp:${opts.accountCode}:${t.date}:${amtCents}:${payeeShort}`;
    const occ = (refCounters.get(fpBase) ?? 0) + 1;
    refCounters.set(fpBase, occ);
    const withOcc = occ === 1 ? fpBase : `${fpBase}:${occ}`;

    const { error: stErr } = await sb.from("statements").insert({
      id: crypto.randomUUID(),
      agency_id: opts.agencyId,
      business_entity_id: opts.account.businessEntityId,
      account_id: opts.account.id,
      account_kind: opts.account.accountKind,
      transaction_date: t.date,
      description,
      amount,
      transaction_type: transactionType,
      reference_number: withOcc,
      dedup_fingerprint: withOcc,
      source_document_id: opts.documentId,
    });
    if (stErr) { errors.push(`tx ${t.date}: ${stErr.message}`); continue; }
    inserted += 1;
  }

  if (errors.length > 0) {
    return {
      ok: false,
      error: `${errors.length}/${opts.transactions.length} transaction inserts failed: ${errors.slice(0, 5).join(" | ")}`,
      inserted,
    };
  }

  return { ok: true, inserted };
}
