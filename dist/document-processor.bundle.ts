// =========================================================================
// document-processor bundle (auto-generated)
// Source of truth: supabase/functions/document-processor/*.ts (multi-file).
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python scripts/bundle_document_processor.py`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { BlobReader, ZipReader, Uint8ArrayWriter } from "jsr:@zip-js/zip-js@2";

// ==================== ../_shared/supabase.ts ====================
// =========================================================================
// _shared/supabase.ts
// =========================================================================
// Canonical Supabase client + settings + response helpers for ALL Newtworks
// edge functions. Source of truth for code that used to be copy-pasted into
// every function (client creation, getSetting, jsonResponse, stripFences).
//
// Edge functions deploy as single-file bundles: `scripts/bundle_edge_fn.py`
// inlines this file into each function's bundle. Never edit a bundle by hand;
// edit here and rebundle every consumer.
// =========================================================================


export const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
export const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
export const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
export const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
// Two variants on purpose — they preserve the two behaviors that existed in
// the wild before consolidation:
//   getSetting        — THROWS if the settings table read itself errors
//                       (infra failure ≠ missing row). Use on critical paths.
//   getSettingOrNull  — swallows read errors, returns null. Use where the
//                       caller treats "can't read" the same as "not set".
// Both return null when the row simply doesn't exist.
// -------------------------------------------------------------------------

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

export async function getSettingOrNull(
  agencyId: string,
  key: string,
): Promise<string | null> {
  try {
    const { data } = await sb
      .from("settings")
      .select("setting_value")
      .eq("agency_id", agencyId)
      .eq("setting_key", key)
      .maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) {
    return null;
  }
}

// Batch read — one query for N keys. Missing keys come back as null.
export async function getSettings(
  agencyId: string,
  keys: string[],
): Promise<Record<string, string | null>> {
  const out: Record<string, string | null> = {};
  for (const k of keys) out[k] = null;
  const { data, error } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", keys);
  if (error) {
    throw new Error(`settings batch read failed for agency ${agencyId}: ${error.message}`);
  }
  for (const row of data ?? []) {
    out[(row as any).setting_key] = (row as any).setting_value ?? null;
  }
  return out;
}

// -------------------------------------------------------------------------
// HTTP responses
// -------------------------------------------------------------------------

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
export function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== ../_shared/alerts.ts ====================
// =========================================================================
// _shared/alerts.ts
// =========================================================================
// Canonical alerts writer for ALL Newtworks edge functions.
//
// Why this exists: the alerts table takes (alert_type NOT NULL, severity,
// title, message, module_reference, related_id, is_resolved). Hand-written
// inserts have shipped with a `body:` column that does not exist and with
// alert_type missing — both fail silently when the insert result isn't
// checked. Going through this helper makes that class of bug impossible.
// =========================================================================


export async function insertAlert(opts: {
  agencyId: string;
  alertType: string;
  severity: "info" | "warning" | "high" | "critical" | string;
  title: string;
  message: string;
  moduleReference?: string;
  relatedId?: string | null;
}): Promise<{ ok: boolean; error: string | null }> {
  const row: Record<string, unknown> = {
    agency_id: opts.agencyId,
    alert_type: opts.alertType,
    severity: opts.severity,
    title: opts.title,
    message: opts.message,
    is_read: false,
    is_resolved: false,
  };
  if (opts.moduleReference != null) row.module_reference = opts.moduleReference;
  if (opts.relatedId != null) row.related_id = opts.relatedId;

  const { error } = await sb.from("alerts").insert(row);
  if (error) {
    // Never throw — alerting must not mask the underlying failure being
    // reported. But do surface the miss to whoever reads the function logs.
    console.error(`insertAlert failed (${opts.alertType}): ${error.message}`);
    return { ok: false, error: error.message };
  }
  return { ok: true, error: null };
}

// Resolve all open alerts carrying a given module_reference (the standard
// "this condition cleared" pattern used by surepayroll + pfa flows).
export async function resolveAlerts(opts: {
  agencyId: string;
  moduleReference: string;
}): Promise<{ ok: boolean; resolved: number; error: string | null }> {
  const { data, error } = await sb
    .from("alerts")
    .update({ is_resolved: true, resolved_at: new Date().toISOString() })
    .eq("agency_id", opts.agencyId)
    .eq("module_reference", opts.moduleReference)
    .eq("is_resolved", false)
    .select("id");
  if (error) {
    console.error(`resolveAlerts failed (${opts.moduleReference}): ${error.message}`);
    return { ok: false, resolved: 0, error: error.message };
  }
  return { ok: true, resolved: (data ?? []).length, error: null };
}

// ==================== ../_shared/composio.ts ====================
// =========================================================================
// _shared/composio.ts
// =========================================================================
// Canonical Composio HTTP wrapper for Newtworks edge functions.
//
// This file used to CLAIM to be "the one true copy" while three others
// existed: document-processor/lib/composio.ts (a fork that had timeout
// handling this one lacked), plus inline copies in automation-runner and
// generate-custom-probes. The 2026-08-06 fix for hung calls therefore landed
// in exactly one of the four, and automation-runner — which drives every
// scheduled Gmail parser — went five days still able to die as an uncaught
// exception. Consolidated 2026-08-11: the timeout handling lives HERE now, so
// a fix applied once is a fix applied everywhere.
//
// TIMEOUTS, and why they are not optional. An external call that hangs is not
// an error the calling code can catch. It runs until the Supabase platform's
// own wall-clock limit kills the whole invocation, surfacing as status 546
// with no stack and no log line. On a cron path that is close to invisible:
// the run simply never reports. Every call through this file is bounded, and a
// timeout comes back as an ordinary {ok:false} result the caller can handle.
//
// NO RETRIES here, on purpose. Retrying a hang doubles the wait and can push
// an otherwise-healthy invocation over the platform limit too. Retry is a
// separate decision belonging to the caller.
// =========================================================================


const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

/** Default ceiling for any single Composio call. Well under the platform
 *  wall-clock limit so a stuck call fails fast AND catchably. */
export const COMPOSIO_TIMEOUT_MS = 25000;

/** Same number, separate name: storage/S3 downloads are a distinct concern
 *  that happens to want the same ceiling. Kept apart so changing one does not
 *  silently change the other. */
export const S3_FETCH_TIMEOUT_MS = 25000;

/** Where a timeout should be reported, if anywhere. Omit entirely and a
 *  timeout returns a clean failed result without writing an alert — correct
 *  for callers that already record their own failures (automation-runner logs
 *  every recipe failure to automation_run_log and Telegram). */
export interface TimeoutAlertTarget {
  agencyId?: string;
  moduleReference: string;
  context: string;
}

export async function writeTimeoutAlert(
  service: string,
  elapsedMs: number,
  target: TimeoutAlertTarget,
): Promise<void> {
  try {
    await insertAlert({
      agencyId: target.agencyId ?? AGENCY_ID_DEFAULT,
      alertType: "external_call_timeout",
      severity: "warning",
      title: `${service} call timed out`,
      message: `${service} call did not respond within ${elapsedMs}ms and was aborted. Context: ${target.context}`,
      moduleReference: target.moduleReference,
    });
  } catch (_e) {
    // Best-effort. Must never mask the original timeout or throw a second
    // uncaught exception on the way out.
  }
}

/**
 * fetch() with a hard time limit. Returns res:null on timeout or throw, never
 * rejects. Use this for ANY outbound call in an edge function, not just
 * Composio ones — a bare fetch() to Google, Groq or storage carries exactly
 * the same hang risk.
 */
export async function _sharedFetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  service: string,
  context: string,
  alertTarget?: TimeoutAlertTarget,
): Promise<{ res: Response | null; timedOut: boolean; elapsedMs: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = Date.now();
  try {
    const res = await fetch(url, { ...init, signal: controller.signal });
    return { res, timedOut: false, elapsedMs: Date.now() - startedAt };
  } catch (e) {
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut && alertTarget) {
      await writeTimeoutAlert(service, elapsedMs, alertTarget);
    } else if (!timedOut) {
      console.error(`[${service}] fetch threw after ${elapsedMs}ms (${context}): ${e instanceof Error ? e.message : String(e)}`);
    }
    return { res: null, timedOut, elapsedMs };
  } finally {
    clearTimeout(timer);
  }
}

function unwrapComposio(text: string, httpOk: boolean, status: number): ComposioCallResult {
  let parsed: any = {};
  try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
  const ok = httpOk && !!parsed?.successful;
  const data = parsed?.data?.response_data ?? parsed?.data ?? null;
  const error = ok
    ? null
    : parsed?.error?.message || parsed?.error || text.slice(0, 400);
  return { ok, data, error, httpStatus: status };
}

function composioTimeoutResult(slug: string, timedOut: boolean, elapsedMs: number): ComposioCallResult {
  return {
    ok: false,
    data: null,
    httpStatus: 0,
    error: timedOut
      ? `Composio ${slug} did not respond within ${elapsedMs}ms and was aborted`
      : `Composio ${slug} fetch failed after ${elapsedMs}ms`,
  };
}

export interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

export async function _sharedCallComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  /**
   * Which published set of tools to use. LEAVE THIS UNSET unless you have a
   * reason not to.
   *
   * Composio publishes its tools in dated sets. A request that does not name a
   * set gets the oldest one, which holds far fewer tools than the account
   * actually has — 51 Google Drive tools instead of 90. Anything missing from
   * that oldest set answers "Tool ... not found", which reads exactly like a
   * permission problem and is not one. Two months of Drive filing and every
   * scanned resume were lost to this, and four rounds of fixing went at the
   * wrong layer, because a tool tested by hand goes through a connection that
   * DOES name a set and therefore always worked.
   *
   * It is set per request on purpose. Naming a newer set changes the shape of
   * what comes back, and the payroll, bank statement and comp parsers all read
   * those shapes. So each caller opts in where it has been checked, rather than
   * one flip changing everything at once.
   */
  toolkitVersion?: string;
  timeoutMs?: number;
  alertTarget?: TimeoutAlertTarget;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await _sharedFetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        connected_account_id: opts.connectedAccountId,
        arguments: opts.toolArguments,
        ...(opts.toolkitVersion ? { version: opts.toolkitVersion } : {}),
      }),
    },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS,
    `composio:${opts.toolSlug}`,
    `tool=${opts.toolSlug}`,
    opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

export async function _sharedCallComposioNoAuth(opts: {
  apiKey: string;
  userId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
  timeoutMs?: number;
  alertTarget?: TimeoutAlertTarget;
}): Promise<ComposioCallResult> {
  const { res, timedOut, elapsedMs } = await _sharedFetchWithTimeout(
    `${COMPOSIO_BASE}/${opts.toolSlug}`,
    {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        user_id: opts.userId,
        arguments: opts.toolArguments,
      }),
    },
    opts.timeoutMs ?? COMPOSIO_TIMEOUT_MS,
    `composio:${opts.toolSlug}`,
    `tool=${opts.toolSlug} (no connected account)`,
    opts.alertTarget,
  );
  if (!res) return composioTimeoutResult(opts.toolSlug, timedOut, elapsedMs);
  return unwrapComposio(await res.text(), res.ok, res.status);
}

// ==================== ../_shared/statement_writer.ts ====================
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

// ==================== lib/composio.ts ====================
// =========================================================================
// lib/composio.ts — document-processor-local shim over _shared/composio.ts
// =========================================================================
// Consolidated 2026-08-11. The HTTP request, timeout, and response-unwrapping
// logic used to be fully duplicated here (this file used to be ~150 lines
// mirroring _shared/composio.ts almost exactly, plus a hand-rolled
// writeTimeoutAlert). That duplication is why the 2026-08-06 timeout fix
// landed here first and took five more days to reach automation-runner. The
// mechanism now lives in exactly one place: _shared/composio.ts.
//
// WHY THIS FILE STILL EXISTS AT ALL: document-processor has always written an
// alerts-table row on EVERY timeout, unconditionally — that was the original
// fork's behavior since 2026-08-06. _shared/composio.ts makes alerting
// opt-in per call (alertTarget?), because other consumers (automation-runner)
// deliberately do NOT want a duplicate alerts-table row on top of their own
// automation_run_log + Telegram failure recording. Rather than touch this
// function's 30+ call sites to pass an alertTarget by hand, this shim
// supplies the same default the old duplicated implementation hardcoded, so
// deleting the duplication changed NOTHING about runtime alerting behavior.
// Every existing `callComposio(...)`, `callComposioNoAuth(...)` and
// `fetchWithTimeout(...)` call in this function keeps working with its
// existing arguments, unchanged.
// =========================================================================


// S3_FETCH_TIMEOUT_MS, COMPOSIO_TIMEOUT_MS and the ComposioCallResult type
// carry no document-processor-specific behavior — they are plain constants
// and a type, nothing to shim. Import them straight from _shared/composio.ts
// at the call sites that need them, not through here. (An earlier version of
// this file re-exported them, which is correct for the real multi-file
// source but breaks the bundle: the bundler strips the import line above and
// leaves a bare `export { S3_FETCH_TIMEOUT_MS };` standing next to the
// identical `export const S3_FETCH_TIMEOUT_MS` already declared by the
// _shared/composio.ts entry earlier in the bundle — two top-level exports of
// the same name, a boot failure esbuild caught and the project's own
// validator does not, since it only checks `const`, not `export {}`.)

function dpAlertTarget(service: string, context: string): TimeoutAlertTarget {
  return { moduleReference: `document-processor:${service}_timeout`, context };
}

export async function callComposio(
  opts: Parameters<typeof _sharedCallComposio>[0],
): ReturnType<typeof _sharedCallComposio> {
  return _sharedCallComposio({
    ...opts,
    alertTarget: opts.alertTarget ?? dpAlertTarget("composio", `tool=${opts.toolSlug}`),
  });
}

export async function callComposioNoAuth(
  opts: Parameters<typeof _sharedCallComposioNoAuth>[0],
): ReturnType<typeof _sharedCallComposioNoAuth> {
  return _sharedCallComposioNoAuth({
    ...opts,
    alertTarget: opts.alertTarget ?? dpAlertTarget("composio", `tool=${opts.toolSlug}`),
  });
}

export async function fetchWithTimeout(
  url: string,
  init: RequestInit,
  timeoutMs: number,
  service: string,
  context: string,
): ReturnType<typeof _sharedFetchWithTimeout> {
  return _sharedFetchWithTimeout(url, init, timeoutMs, service, context, dpAlertTarget(service, context));
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
const GROQ_TIMEOUT_MS = 25000;

// TIMEOUT HANDLING added 2026-08-06 (Task 4, build-instructions 2026-08-06).
// See lib/composio.ts's header comment for the full "why" -- same rationale
// applies here: a stuck Groq call should fail fast and catchably instead of
// riding the invocation to the platform's own wall-clock kill (observed as
// an uncaught-exception 546 after ~105-113s). No retry added on purpose.
async function writeGroqTimeoutAlert(elapsedMs: number, context: string): Promise<void> {
  try {
    await sb.from("alerts").insert({
      alert_type: "external_call_timeout",
      severity: "warning",
      title: "Groq call timed out",
      message: `Groq call did not respond within ${elapsedMs}ms and was aborted. Context: ${context}`,
      module_reference: "document-processor:groq_timeout",
      is_read: false,
      is_resolved: false,
    });
  } catch (_e) {
    // Best-effort; never let a failed alert insert mask the original timeout.
  }
}

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
  // When true, a failed Groq call returns { ok:false, queued:false } instead of
  // parking a row in llm_parse_queue. For callers that already have their own
  // fallback and would otherwise leave rows nobody drains — see the note on
  // Step 3 below.
  skipQueueOnFailure?: boolean;
  // Pointer to the row this job must write its result back to, stored on the
  // queue row as target_ref and read by llm-queue-drainer. Required for any
  // purpose whose write target is NOT implied by documentId or by the parsed
  // payload itself. Shape is purpose-specific — the drainer's handler for the
  // purpose defines it. Added 2026-08-07 after a queued wrapup_organize job
  // proved undrainable: nothing recorded which weekly_cpr_team_detail row it
  // belonged to, and the source email had already been archived.
  targetRef?: Record<string, unknown>;
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
  context: string; // e.g. "purpose=resume_identity_extract document=<id>" -- for the timeout alert
}): Promise<{ ok: boolean; raw: string; error: string | null; httpStatus: number }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GROQ_TIMEOUT_MS);
  const startedAt = Date.now();
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
      signal: controller.signal,
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
    const elapsedMs = Date.now() - startedAt;
    const timedOut = e instanceof Error && e.name === "AbortError";
    if (timedOut) await writeGroqTimeoutAlert(elapsedMs, opts.context);
    const error = timedOut
      ? `Groq call timed out after ${elapsedMs}ms`
      : `Groq fetch failed: ${(e as Error).message}`;
    return { ok: false, raw: "", error, httpStatus: 0 };
  } finally {
    clearTimeout(timer);
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
      context: `purpose=${opts.purpose} document=${opts.documentId ?? "none"}`,
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
  //
  // Opt-out: llm-queue-drainer only handles the purposes it has handlers for.
  // A caller whose purpose the drainer does not know would leave rows pending
  // forever, inflating the queue with work nobody will ever pick up. Callers
  // that carry their own fallback set skipQueueOnFailure and take the plain
  // failure instead. (Found 2026-08-04: 69 stranded resume_identity_extract
  // rows from the first full resume backlog run.)
  if (opts.skipQueueOnFailure) {
    return {
      ok: false,
      queued: false,
      error: "Groq direct call failed; queue skipped at caller's request",
    };
  }

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
      target_ref: opts.targetRef ?? null,
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

// ==================== lib/text_recovery.ts ====================
// =========================================================================
// lib/text_recovery.ts
// =========================================================================
// Recovers readable text from a scanned or photographed file that carries no
// extractable text of its own.
//
// WHY THIS EXISTS (2026-08-04):
//   Roughly one in five hand-forwarded resumes is a scan or a phone photo
//   saved as a PDF. Those files have page images and no text layer, so the
//   normal extraction step returns nothing and the resume fails with no
//   candidate row — a real applicant who never enters the system. At one in
//   five, hand entry is a permanent tax.
//
// WHY THIS SHAPE:
//   Google Drive reads the page images of a file when the file is brought in
//   AS a Google Doc. That costs nothing beyond the Drive account already
//   connected, needs no new vendor and no charge per file, and the recovered
//   text feeds the existing identity step unchanged.
//
//   An earlier plan assumed these files were already sitting in Drive and
//   could simply be converted in place. They are not: checked live on
//   2026-08-04, none of the 143 forwarded resumes ever got a Drive copy,
//   because the upload step had been failing quietly for weeks. So this brings
//   the file in from Gmail rather than converting something already there.
//
// THE CHAIN:
//   1. Ask Gmail for the attachment. It answers with a temporary signed link,
//      good for an hour, not with the bytes.
//   2. Get that link into Drive as a Google Doc. Two doors are tried, in order
//      of how well they work — see the note on the conversion step below.
//   3. Read the new document back as plain text. Two doors here as well.
//
// The converted document is deliberately KEPT, not deleted. It becomes the
// Drive copy these resumes have always been missing, and the caller writes its
// id onto the documents row.
//
// EVERY FAILURE NAMES ITS STAGE AND ITS DOOR. The three stages have three
// completely different fixes, and the log cannot be read after the fact, so
// the detail has to travel back in the returned value.
// =========================================================================

// deno-lint-ignore-file no-explicit-any


/** Everything this module needs to reach Gmail and Drive. */
export interface TextRecoveryDeps {
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
  /** Optional Drive folder to file the converted document in. Null = My Drive root. */
  driveParentFolderId?: string | null;
}

export type TextRecoveryResult =
  | {
      ok: true;
      text: string;
      driveFileId: string;
      driveUrl: string;
      charCount: number;
      /** Which conversion door worked, and which read door. For the record. */
      via: string;
    }
  | { ok: false; error: string; stage: "gmail" | "convert" | "read" };

/** The Drive type that makes Drive read the page images of a scan. */
const DRIVE_DOC_MIME = "application/vnd.google-apps.document";

/**
 * Which published set of Google Drive tools to ask for.
 *
 * THIS LINE IS THE FIX. Without it, Composio hands back its oldest set of Drive
 * tools, which has 51 of the account's 90 and none of the three that can turn a
 * scanned page into readable text. Those three then answer "Tool ... not found",
 * which looks exactly like the account lacking permission. It is not. Checked
 * live 2026-08-04: name a set and the same account, same key, reaches all three.
 *
 * A dated set rather than "latest" on purpose. "Latest" moves when Composio
 * publishes, and a change in the shape of a reply would break this quietly.
 * Raise this deliberately after checking, the same way any other pinned
 * dependency gets raised.
 */
const DRIVE_TOOLKIT_VERSION = "20260721_00";

/** Shortest recovered text we will treat as a real result. */
const MIN_USEFUL_CHARS = 40;

function stripExtension(fileName: string): string {
  return fileName.replace(/\.[A-Za-z0-9]{1,6}$/, "").trim() || fileName;
}

/**
 * Pull the storage key out of a Composio download link. The link is a signed
 * URL whose path IS the key, e.g. ".../486473/gmail/GMAIL_GET_ATTACHMENT/
 * response/abc123?X-Amz-...". The plain upload tool wants exactly that path,
 * not the whole link and not the bytes.
 */
function storageKeyFromUrl(url: string): string | null {
  try {
    const path = new URL(url).pathname.replace(/^\/+/, "");
    return path.length > 0 ? decodeURIComponent(path) : null;
  } catch {
    return null;
  }
}

/** Best guess at the original file's type, from its extension. */
function guessSourceMime(fileName: string): string {
  const ext = fileName.toLowerCase().match(/\.([a-z0-9]{1,6})$/)?.[1] ?? "";
  if (ext === "jpg" || ext === "jpeg") return "image/jpeg";
  if (ext === "png") return "image/png";
  if (ext === "gif") return "image/gif";
  if (ext === "tif" || ext === "tiff") return "image/tiff";
  if (ext === "webp") return "image/webp";
  return "application/pdf";
}

/**
 * Pull the temporary signed link out of a Composio response, tolerating the
 * two nesting shapes the wrapper can hand back.
 */
function signedLink(data: any, key: "file" | "downloaded_file_content"): string | null {
  const holder = data?.[key] ?? data?.data?.[key];
  const url = holder?.s3url;
  return typeof url === "string" && url.length > 0 ? url : null;
}

function firstId(data: any): string {
  return data?.id ?? data?.data?.id ?? data?.file_id ?? data?.data?.file_id ?? "";
}

/**
 * Recover text from one scanned file.
 */
export async function recoverTextFromScannedFile(opts: {
  deps: TextRecoveryDeps;
  messageId: string;
  attachmentId: string;
  fileName: string;
}): Promise<TextRecoveryResult> {
  const { deps, messageId, attachmentId, fileName } = opts;
  const tried: string[] = [];

  if (!deps.driveAccountId) {
    return { ok: false, stage: "convert", error: "no Drive account connected, cannot read the page images" };
  }
  if (!messageId || !attachmentId) {
    return {
      ok: false,
      stage: "gmail",
      error: "no Gmail message id or attachment id on this file, so the original cannot be fetched again",
    };
  }

  const drive = async (slug: string, toolArguments: Record<string, any>) => {
    tried.push(slug);
    return await callComposio({
      apiKey: deps.composioApiKey,
      userId: deps.composioUserId,
      connectedAccountId: deps.driveAccountId as string,
      toolSlug: slug,
      toolArguments,
      toolkitVersion: DRIVE_TOOLKIT_VERSION,
    });
  };

  // ---- 1. Fresh signed link from Gmail ---------------------------------
  // It must be fresh: Drive fetches this link itself, and the link expires
  // after an hour. Reusing one captured earlier in a long run will fail.
  const gm = await callComposio({
    apiKey: deps.composioApiKey,
    userId: deps.composioUserId,
    connectedAccountId: deps.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: messageId,
      attachment_id: attachmentId,
      file_name: fileName,
      user_id: "me",
    },
  });
  if (!gm.ok) {
    return { ok: false, stage: "gmail", error: `GMAIL_GET_ATTACHMENT failed: ${gm.error}` };
  }
  const sourceUrl = signedLink(gm.data, "file");
  if (!sourceUrl) {
    return { ok: false, stage: "gmail", error: "Gmail returned no download link for the attachment" };
  }

  // ---- 2. Get it into Drive as a Google Doc ----------------------------
  // TWO DOORS, tried in this order. Both were checked live on 2026-08-04.
  //
  // Door 1 hands Drive the link and asks for a Google Doc in a single call.
  // This is the mechanism the tool itself documents for page-image files, and
  // it is the one that works when the same chain is run by hand. It is tried
  // first because it is one call instead of two and needs no storage key.
  //
  // Door 2 is the two-call route: upload a faithful copy of the original, then
  // copy that copy as a Google Doc. Kept as the fallback because the plain
  // upload is the one Drive tool this function is definitely able to reach.
  //
  // A door that answers "Tool ... not found" is not broken and not misused —
  // it means this function's Composio key cannot see that tool at all, even
  // though an interactive session can. Do not spend a deploy cycle re-testing
  // it. Whichever door works is reported back in `via`.
  let docId = "";
  let docUrl = "";
  let via = "";

  const fromUrl = await drive("GOOGLEDRIVE_UPLOAD_FROM_URL", {
    source_url: sourceUrl,
    name: stripExtension(fileName),
    mime_type: DRIVE_DOC_MIME,
    ...(deps.driveParentFolderId ? { parent_folder_id: deps.driveParentFolderId } : {}),
  });
  if (fromUrl.ok && firstId(fromUrl.data)) {
    docId = firstId(fromUrl.data);
    docUrl = fromUrl.data?.webViewLink ?? fromUrl.data?.display_url ?? "";
    via = "upload_from_url";
  }

  let convertError = fromUrl.ok ? "returned no document id" : String(fromUrl.error);

  if (!docId) {
    const s3Key = storageKeyFromUrl(sourceUrl);
    if (!s3Key) {
      return {
        ok: false,
        stage: "convert",
        error: `${convertError}; and no storage key could be read out of the Gmail link for the fallback route`,
      };
    }

    const up = await drive("GOOGLEDRIVE_UPLOAD_FILE", {
      file_to_upload: {
        name: fileName,
        mimetype: guessSourceMime(fileName),
        s3key: s3Key,
      },
      ...(deps.driveParentFolderId ? { folder_to_upload_to: deps.driveParentFolderId } : {}),
    });
    if (!up.ok || !firstId(up.data)) {
      return {
        ok: false,
        stage: "convert",
        error: `both conversion routes failed. upload-from-link: ${convertError}. plain upload: ${up.ok ? "returned no file id" : up.error}`,
      };
    }
    const originalId = firstId(up.data);

    // Copy it AS a Google Doc. Naming the Doc type as the target is what makes
    // Drive read the page images; the language hint improves that reading. The
    // Doc type cannot be set on the upload itself — Drive rejects it outright
    // as an upload type, checked live 2026-08-04.
    const conv = await drive("GOOGLEDRIVE_COPY_FILE_ADVANCED", {
      fileId: originalId,
      name: `${stripExtension(fileName)} (text)`,
      mimeType: DRIVE_DOC_MIME,
      ocrLanguage: "en",
      ...(deps.driveParentFolderId ? { parents: [deps.driveParentFolderId] } : {}),
    });
    if (!conv.ok || !firstId(conv.data)) {
      return {
        ok: false,
        stage: "convert",
        error: `both conversion routes failed. upload-from-link: ${convertError}. copy-as-document: ${conv.ok ? "returned no document id" : conv.error}. The original file did upload to Drive as ${originalId}, so the Drive copy is not lost. Tried: ${tried.join(", ")}`,
      };
    }
    docId = firstId(conv.data);
    docUrl = conv.data?.webViewLink ?? conv.data?.display_url ?? "";
    via = "upload_then_copy";
  }

  if (!docUrl) docUrl = `https://docs.google.com/document/d/${docId}/edit`;

  // ---- 3. Read the recovered text back --------------------------------
  // Two doors again. The first exports a Google Doc to plain text directly.
  // The second is the dedicated export tool, same idea, different slug — kept
  // because which of the two a given key can see is not predictable.
  let textUrl: string | null = null;
  let readError = "";

  const dl = await drive("GOOGLEDRIVE_DOWNLOAD_FILE", { fileId: docId, mime_type: "text/plain" });
  if (dl.ok) {
    textUrl = signedLink(dl.data, "downloaded_file_content");
    if (!textUrl) readError = "GOOGLEDRIVE_DOWNLOAD_FILE returned no plain-text link";
  } else {
    readError = `GOOGLEDRIVE_DOWNLOAD_FILE failed: ${dl.error}`;
  }

  if (!textUrl) {
    const ex = await drive("GOOGLEDRIVE_EXPORT_GOOGLE_WORKSPACE_FILE", {
      fileId: docId,
      mimeType: "text/plain",
    });
    if (ex.ok) {
      textUrl = signedLink(ex.data, "downloaded_file_content") ?? signedLink(ex.data, "file");
      if (textUrl) via = `${via}+export`;
    }
    if (!textUrl) {
      return {
        ok: false,
        stage: "read",
        error: `${readError}; export fallback also failed: ${ex.ok ? "no link returned" : ex.error}. The converted document exists as ${docId}, so the text is recoverable by hand. Tried: ${tried.join(", ")}`,
      };
    }
  }

  // Was a bare fetch() with no time limit until 2026-08-11. Google holding this
  // link open would hang the whole invocation until the platform's own
  // wall-clock limit killed it as an uncaught exception (status 546) instead of
  // returning a catchable error — the exact failure mode fetchWithTimeout was
  // written for on 2026-08-06, and the last fetch() in this function that had
  // not been moved onto it.
  let text = "";
  try {
    const { res: r, timedOut, elapsedMs } = await fetchWithTimeout(
      textUrl, {}, S3_FETCH_TIMEOUT_MS, "drive_plaintext_export",
      `document=${docId}`,
    );
    if (timedOut) {
      return { ok: false, stage: "read", error: `plain-text link did not respond within ${elapsedMs}ms and was aborted; document is ${docId}, text is recoverable by hand` };
    }
    if (!r) {
      return { ok: false, stage: "read", error: `plain-text fetch failed after ${elapsedMs}ms; document is ${docId}` };
    }
    if (!r.ok) {
      return { ok: false, stage: "read", error: `plain-text link returned HTTP ${r.status}; document is ${docId}` };
    }
    text = await r.text();
  } catch (e) {
    return {
      ok: false,
      stage: "read",
      error: `plain-text fetch threw: ${e instanceof Error ? e.message : String(e)}; document is ${docId}`,
    };
  }

  // Drive puts a byte-order mark at the front of an exported text file. Left in
  // place it becomes the first character of the candidate's first name.
  const trimmed = text.replace(/^\uFEFF/, "").trim();
  if (trimmed.length < MIN_USEFUL_CHARS) {
    // The conversion ran but produced nothing usable — a blank page, a photo
    // of something that is not a document, or handwriting. Say so plainly
    // instead of handing a few stray characters to the identity step.
    return {
      ok: false,
      stage: "read",
      error: `reading the page images recovered only ${trimmed.length} characters, too little to identify anyone; document is ${docId}`,
    };
  }

  return {
    ok: true,
    text: trimmed,
    driveFileId: docId,
    driveUrl: docUrl,
    charCount: trimmed.length,
    via,
  };
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
  openingBalance: number | null;
  closingBalance: number | null;
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
  "opening_balance": <number; the beginning balance for the period, null if not stated>,
  "closing_balance": <number; the ending balance for the period, null if not stated>,
  "transactions": [
    {
      "date": "YYYY-MM-DD",
      "payee": "<vendor / merchant / counterparty>",
      "memo": "<any additional description; empty string if none>",
      "amount": <number; NEGATIVE for money out, POSITIVE for money in>,
      "section": "<one of: purchase, payment, credit_refund, other>",
      "raw_line": "<the verbatim text of this transaction line from the statement, before any parsing>"
    }
  ]
}

Rules:
- Extract the beginning/opening balance and ending/closing balance from the
  account summary section. Credit card statements may call these "Previous
  Balance" and "New Balance". Report both as positive numbers for asset
  accounts; for credit-card statements, report the outstanding balance as
  a positive number (the amount owed).
- Skip beginning balance, ending balance, and "Total" summary lines in the
  transactions array — they belong in opening_balance/closing_balance, not
  as transactions.
- Skip non-transactional informational lines.
- Combine multi-line transaction descriptions into the single payee/memo pair.
- "date" MUST be the TRANSACTION date (the date the purchase/payment actually
  occurred). If the statement prints both a transaction date and a separate
  posting date for a line, use the transaction date — never the posting date.
- "section" classifies which part of the statement this line came from:
  - "purchase" — a charge / purchase / new debit on the account (credit card
    purchases, fees, interest charged).
  - "payment" — a payment made toward the account balance (includes autopay,
    "Payment - Thank You" style lines).
  - "credit_refund" — a merchant refund, rebate, or statement credit issued
    back to the account.
  - "other" — use ONLY when the line genuinely does not fit any of the above;
    do not guess — if uncertain between two categories, prefer "other".
- Combine multi-line transaction descriptions into the single payee/memo pair;
  "raw_line" is a best-effort verbatim capture of the source line(s) for that
  transaction and may include the original date/amount text as printed.
- If the statement prints its own notation for what kind of line this is
  (e.g. "CR MERCHANDISE/SERVICE RETURN", "CASH BACK REWARD", "AUTOPAY",
  "RETURNED PAYMENT"), APPEND that exact notation to "memo" -- do not drop it.
  This is the bank's own explanation of the transaction; losing it forces
  someone to go re-open the PDF later to find out why a line is a credit.
- If the statement prints multiple transaction lines with the SAME date,
  payee, and amount, output one JSON object for EACH printed line. NEVER
  merge, collapse, or deduplicate repeated identical lines — repeated small
  identical charges (game stores, app stores, subscriptions) are real
  separate transactions and every printed line must appear in the output.
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
    maxTokens: 8000,
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

  const openingBalance = typeof json?.opening_balance === "number" ? json.opening_balance : null;
  const closingBalance = typeof json?.closing_balance === "number" ? json.closing_balance : null;

  return {
    ok: true,
    statementPeriod: { start: period.start, end: period.end },
    accountLast4: json?.account_last4 ?? null,
    openingBalance,
    closingBalance,
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
// with positive amounts.
//
// REPLACES the prior LLM-based parser (v1, 2026-05). Key bug it fixes:
// the LLM consistently extracted the YEAR-TO-DATE column instead of CURRENT,
// producing 22x overstatement of period deductions.
//
// VERIFIED RECONCILIATIONS:
//   - June 1-15 2026: 3 rows, total $457.17 (matches comp PDF
//     "LESS DEDUCTIONS 457.17-").
//   - May 16-31 2026: 5 rows, total $1,286.56 (matches comp PDF
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
  amount: number;  // always positive -- comp_gl_writer debits deductions on positive amount
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
    const amount = Math.abs(current);  // always positive -- see sign-convention note above
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
      business_entity_id: "b1111111-1111-1111-1111-111111111111",
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
      business_entity_id: "b1111111-1111-1111-1111-111111111111",
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

// role_level + is_admin_backoffice are selected so the CPR write below can skip
// people who are paid but do not belong in CPR team roll-ups (Owner, admin /
// back-office). They still get full payroll_detail rows -- the exclusion is
// CPR-only. Fix 2026-08-07: without these fields the payroll import CREATED
// weekly_cpr_team_detail rows for the Owner and for the back-office teammate
// (the upsert below inserts when no row exists), which then rendered in every
// team section of the CPR page -- the Owner under his own name and the
// back-office teammate as "(unknown)", because the page deliberately filters
// back-office people out of its name lookup. Standing rule: is_admin_backoffice
// = false and role_level != 'Owner' in every CPR / comp / production roll-up.
async function spMatchTeamMember(last: string, first: string): Promise<{ id: string; agency_id: string | null; role_level: string | null; is_admin_backoffice: boolean | null } | null> {
  const { data, error } = await sb.from("team").select("id, agency_id, role_level, is_admin_backoffice").ilike("last_name", last).ilike("first_name", first).maybeSingle();
  if (error || !data) return null;
  return { id: data.id, agency_id: data.agency_id, role_level: data.role_level ?? null, is_admin_backoffice: data.is_admin_backoffice ?? null };
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
  sourceText: string;          // stored in raw_pdf_text for audit (legacy column name)
  sourceFormat: "pdf" | "csv"; // shapes the notes field + YTD-backfill branch
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}): Promise<SPProcessResult> {
  const parsed = opts.parsed;

  // Payroll records live under PaperNewt LLC (W-2 employer of record).
  // Cash movement JEs stay on Peter Story State Farm. (2026-07-15 decision)
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
    const { error: updErr } = await sb.from("payroll_runs").update(runFields).eq("id", existingByPeriod.id);
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

    // YTD backfill: PDF path carries per-item YTD from the source. CSV path
    // does not — we compute cumulative YTD gross from prior payroll_detail rows
    // in the same calendar year (excluding this run itself). Downstream columns
    // driven by ytd_total (weekly_cpr_team_detail.payroll_ytd_paid) require this.
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
      effectiveEarningsYtd = effectiveYtdGross; // matches item-sum semantics
    }

    detailRows.push({
      payroll_run_id: runRowId, agency_id: opts.agencyId, business_entity_id: businessEntityId, team_member_id: match.id,
      gross_pay: e.period_gross, federal_tax: e.deduction_items["FED WTH"]?.period ?? 0, state_tax: stateTax,
      social_security: e.deduction_items["FICA"]?.period ?? 0, medicare: e.deduction_items["MEDFICA"]?.period ?? 0,
      other_deductions: otherDed, net_pay: e.net_pay, employment_type: "W2",
      ytd_gross: effectiveYtdGross, employer_taxes: employerSum,
      raw_earnings: { state: e.income_state, period_hours: e.period_hours, items: e.earnings_items, period_total: earningsPeriodTotal, ytd_total: effectiveEarningsYtd },
      raw_deductions: { items: e.deduction_items, period_total: dedPeriodTotal, ytd_total: dedYtdTotal },
      raw_employer_taxes: { items: e.employer_items, period_total: empPeriodTotal, ytd_total: empYtdTotal },
    });

    // CPR roll-up gate: agency entity AND not Owner AND not admin/back-office.
    // payroll_detail above already has this person; this only decides whether a
    // weekly_cpr_team_detail row gets created/updated for them.
    const spCprEligible =
      match.agency_id === opts.agencyId &&
      (match.role_level ?? "") !== "Owner" &&
      match.is_admin_backoffice !== true;
    if (spCprEligible) {
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
  let { data: cprReport } = await sb.from("weekly_cpr_reports").select("id").eq("agency_id", opts.agencyId).eq("week_ending_date", cprWeekEnd).maybeSingle();
  if (!cprReport?.id && Object.keys(cprBreakdownByTeamId).length > 0) {
    // Fix 2026-08-14: payroll runs are frequently ingested BEFORE the week's CPR
    // report row exists (report row is otherwise only created on-demand by a
    // teammate's first Telegram check-in or CPR form touch that week). Without
    // this, the whole CPR-write block below was silently skipped for every
    // eligible employee in the run -- not just teammates without another path
    // onto the report (e.g. unlicensed staff who never check in via Telegram).
    // Root-caused 2026-08-14: Cassandra Alves missing from the week-ending
    // 2026-08-15 CPR report because the 08-10 payroll run landed 75 minutes
    // before the report row was created by another teammate's check-in --
    // every eligible employee in that run, not just her, silently lost their
    // payroll YTD write. Create the report row here so the payroll import
    // never depends on being ingested after someone else's check-in.
    const { data: newReport, error: reportErr } = await sb
      .from("weekly_cpr_reports")
      .insert({ agency_id: opts.agencyId, week_ending_date: cprWeekEnd })
      .select("id")
      .maybeSingle();
    if (reportErr && (reportErr as any).code !== "23505") {
      // Non-conflict error: leave cprReport unset, CPR write below is skipped
      // for this run same as before -- payroll_detail rows above are unaffected.
    } else if (newReport?.id) {
      cprReport = newReport;
    } else {
      // 23505 = created concurrently between our select and insert; re-select.
      const { data: refetched } = await sb.from("weekly_cpr_reports").select("id").eq("agency_id", opts.agencyId).eq("week_ending_date", cprWeekEnd).maybeSingle();
      cprReport = refetched ?? null;
    }
  }
  if (cprReport?.id) {
    // upsert, not update: if a team member's weekly_cpr_team_detail row for this
    // report hasn't been created yet (it's created on-demand as each teammate's
    // CPR form gets touched during the week, sometimes after payroll lands),
    // a plain .update() matches zero rows and silently drops the payroll YTD
    // data for that member with no error. onConflict targets the existing
    // (weekly_cpr_report_id, team_member_id) unique constraint; the
    // trg_snapshot_team_on_weekly_cpr_team_detail_insert BEFORE INSERT trigger
    // backfills the rest of the row's team-snapshot fields on the insert path.
    for (const [teamMemberId, breakdown] of Object.entries(cprBreakdownByTeamId)) {
      const ytdGross = (breakdown as any).ytd_total;
      await sb.from("weekly_cpr_team_detail").upsert({
        agency_id: opts.agencyId,
        weekly_cpr_report_id: cprReport.id,
        team_member_id: teamMemberId,
        payroll_ytd_paid: ytdGross,
        payroll_ytd_breakdown: breakdown,
      }, { onConflict: "weekly_cpr_report_id,team_member_id" });
    }
  }

  // Fix 2026-07-20: module_reference is stored as "payroll_run:<pay_period_end>"
  // (per payroll_weekly_nag), not the bare literal "payroll_run" this code
  // previously matched — the .eq comparison never hit anything, so alerts
  // stayed open silently after every successful import. Match on the exact
  // pay_period_end this ingest closes.
  const { data: alertsResolved } = await sb.from("alerts").update({ is_resolved: true, resolved_at: new Date().toISOString() }).eq("agency_id", opts.agencyId).eq("module_reference", `payroll_run:${parsed.pay_period_end}`).eq("is_resolved", false).select("id");

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

  const { res: htmlFetch, timedOut } = await fetchWithTimeout(s3url, {}, S3_FETCH_TIMEOUT_MS, "s3_download", `call log HTML, message=${messageId}`);
  if (!htmlFetch) return { status: "error", error: timedOut ? "s3 fetch timed out" : "s3 fetch failed" };
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

// ==================== parsers/pdf_columnar.ts ====================
// =========================================================================
// parsers/pdf_columnar.ts
// =========================================================================
// Column-aware PDF text extraction using pdfjs-dist positions (via unpdf's
// getDocumentProxy). Handles the two-column resume problem: pdfjs's default
// content-stream order interleaves left/right column text line-by-line, so
// a resume with a narrow left sidebar (contact/skills) and a wide right
// column (experience) comes out as jumbled text (see Cassandra Alves,
// Stephanie Rogers, Randy Castle in the 2026-07-17 audit).
//
// Approach per page:
//   1. Pull every TextItem with its (x, y, width, height) from pdfjs.
//   2. Detect a vertical whitespace band in the middle of the page — count
//      items crossing each of 200 x-slices; find the widest contiguous
//      empty stretch in the middle 60% of the page. If it's > ~3% of page
//      width, treat as a column boundary.
//   3. Bucket items into columns by their horizontal midpoint.
//   4. Within each column, group items into lines by y (bottom-origin, so
//      higher y = higher on the page), then join left-to-right.
//   5. Concatenate columns left-to-right with a blank line between.
//
// Falls back to single-column extraction (equivalent to unpdf.extractText)
// when no significant middle gap is detected on a page. Single-column pages
// come out identical to the plain unpdf path.
//
// Called by:  parsers/careerplug_applicant.ts (resume PDF extraction).
//             Not used for bank/comp/deduction/payroll — those are
//             single-column by construction and go through the existing
//             extractText() path in index.ts.
// =========================================================================


interface PdfTextItem {
  str: string;
  x: number;       // left edge (user space, bottom-origin)
  y: number;       // baseline y (bottom-origin)
  width: number;
  height: number;
}

export async function extractPdfTextColumnAware(bytes: Uint8Array): Promise<string> {
  const pdf = await getDocumentProxy(bytes);
  const numPages: number = (pdf as any).numPages;
  const pageTexts: string[] = [];

  for (let p = 1; p <= numPages; p++) {
    const page = await (pdf as any).getPage(p);
    const viewport = page.getViewport({ scale: 1 });
    const pageWidth: number = viewport.width;
    const content = await page.getTextContent();

    const items: PdfTextItem[] = [];
    for (const raw of content.items as any[]) {
      if (!raw || typeof raw.str !== "string") continue;
      if (raw.str === "") continue;
      const transform = raw.transform;
      if (!Array.isArray(transform) || transform.length < 6) continue;
      items.push({
        str: raw.str,
        x: Number(transform[4]) || 0,
        y: Number(transform[5]) || 0,
        width: Number(raw.width) || 0,
        height: Number(raw.height) || 0,
      });
    }

    if (items.length === 0) {
      pageTexts.push("");
      continue;
    }

    const boundaries = detectColumnBoundaries(items, pageWidth);

    if (boundaries.length === 0) {
      pageTexts.push(itemsToText(items));
    } else {
      const cuts = [0, ...boundaries, pageWidth + 1e6];
      const columnItems: PdfTextItem[][] = cuts.slice(0, -1).map(() => []);
      for (const item of items) {
        const mx = item.x + item.width / 2;
        for (let c = 0; c < cuts.length - 1; c++) {
          if (mx >= cuts[c] && mx < cuts[c + 1]) {
            columnItems[c].push(item);
            break;
          }
        }
      }
      const columnTexts = columnItems
        .filter((col) => col.length > 0)
        .map((col) => itemsToText(col));
      pageTexts.push(columnTexts.join("\n\n"));
    }
  }

  return pageTexts.join("\n\n").trim();
}

/**
 * Fallback single-column extraction using unpdf's built-in extractText.
 * Exported so callers can degrade gracefully if column-aware throws.
 */
export async function extractPdfTextPlain(bytes: Uint8Array): Promise<string> {
  const pdf = await getDocumentProxy(bytes);
  const { text } = await unpdfExtractText(pdf, { mergePages: true });
  return Array.isArray(text) ? text.join("\n") : String(text ?? "");
}

// -----------------------------------------------------------------------------

function detectColumnBoundaries(items: PdfTextItem[], pageWidth: number): number[] {
  if (items.length < 20 || pageWidth <= 0) return [];

  const NUM_BANDS = 200;
  const bandWidth = pageWidth / NUM_BANDS;
  const bandCounts = new Array(NUM_BANDS).fill(0);
  for (const item of items) {
    const bStart = Math.max(0, Math.floor(item.x / bandWidth));
    const bEnd = Math.min(NUM_BANDS - 1, Math.floor((item.x + Math.max(0, item.width)) / bandWidth));
    for (let b = bStart; b <= bEnd; b++) bandCounts[b]++;
  }

  // Only consider gaps whose CENTER lands in the middle 60% of the page
  // (between 20% and 80%). Anything closer to the edges is a page margin,
  // not a column boundary.
  const minCenterBand = Math.floor(NUM_BANDS * 0.2);
  const maxCenterBand = Math.floor(NUM_BANDS * 0.8);

  let bestStart = -1;
  let bestWidth = 0;
  let curStart = -1;
  for (let b = 0; b < NUM_BANDS; b++) {
    if (bandCounts[b] === 0) {
      if (curStart < 0) curStart = b;
    } else {
      if (curStart >= 0) {
        const w = b - curStart;
        const centerBand = curStart + Math.floor(w / 2);
        if (w > bestWidth && centerBand >= minCenterBand && centerBand <= maxCenterBand) {
          bestWidth = w;
          bestStart = curStart;
        }
        curStart = -1;
      }
    }
  }
  if (curStart >= 0) {
    const w = NUM_BANDS - curStart;
    const centerBand = curStart + Math.floor(w / 2);
    if (w > bestWidth && centerBand >= minCenterBand && centerBand <= maxCenterBand) {
      bestWidth = w;
      bestStart = curStart;
    }
  }

  // Require the gap to be wider than 3% of page width. On US letter (612pt)
  // that's ~18pt — about the width of a comfortable column gutter.
  const MIN_GAP_BANDS = Math.max(3, Math.floor(NUM_BANDS * 0.03));
  if (bestWidth < MIN_GAP_BANDS || bestStart < 0) return [];

  const boundaryX = (bestStart + bestWidth / 2) * bandWidth;
  return [boundaryX];
}

/**
 * Group items into lines by y (with a small tolerance for baseline drift),
 * sort lines top-to-bottom, then within each line sort left-to-right and
 * insert spaces where the horizontal gap between items exceeds ~30% of the
 * previous glyph width.
 */
function itemsToText(items: PdfTextItem[]): string {
  const LINE_TOL = 3; // points

  // Sort by y descending (top-of-page first, since pdfjs uses bottom-origin),
  // then x ascending as a stable secondary key.
  const sorted = [...items].sort((a, b) => {
    if (Math.abs(b.y - a.y) > LINE_TOL) return b.y - a.y;
    return a.x - b.x;
  });

  const lines: PdfTextItem[][] = [];
  let curLine: PdfTextItem[] = [];
  let curLineY: number | null = null;

  for (const item of sorted) {
    if (curLineY === null || Math.abs(item.y - curLineY) <= LINE_TOL) {
      curLine.push(item);
      // Use the first-seen y as the line's anchor — keeps tolerance stable.
      if (curLineY === null) curLineY = item.y;
    } else {
      lines.push(curLine);
      curLine = [item];
      curLineY = item.y;
    }
  }
  if (curLine.length > 0) lines.push(curLine);

  const out: string[] = [];
  for (const line of lines) {
    const s = lineToString(line);
    if (s.trim().length > 0) out.push(s);
  }
  return out.join("\n");
}

function lineToString(items: PdfTextItem[]): string {
  if (items.length === 0) return "";
  items.sort((a, b) => a.x - b.x);
  let out = items[0].str;
  for (let i = 1; i < items.length; i++) {
    const prev = items[i - 1];
    const cur = items[i];
    const prevRight = prev.x + prev.width;
    const gap = cur.x - prevRight;
    const avgCharW = prev.width / Math.max(prev.str.length, 1);
    const prevEndsSpace = /\s$/.test(prev.str);
    const curStartsSpace = /^\s/.test(cur.str);
    if (gap > avgCharW * 0.3 && !prevEndsSpace && !curStartsSpace) out += " ";
    out += cur.str;
  }
  return out;
}

// ==================== parsers/resume_reformat.ts ====================
// =========================================================================
// parsers/resume_reformat.ts
// =========================================================================
// Adds visual section separators to raw resume text for readability in the
// Newtworks HRPeople UI (whitespace: pre-wrap). Mirrors the DB function
// public._resume_reformat_add_separators() exactly — keep in sync.
//
// Two things happen:
//   1. Extraction artifacts fixed: literal '\n' string (backslash-n) → real
//      newline, and (cid:127) → '•' (Type1 font glyph mapping failure that
//      unpdf leaves in when the font's bullet char isn't unicode-mapped).
//   2. Divider inserted before every recognized section header ("Objective",
//      "Skills", "Experience", "Education", etc — 50+ variants).
//
// Idempotent: input that already contains the divider is returned unchanged,
// so re-running the doc-processor on a re-extracted resume won't stack
// dividers.
// =========================================================================

export const KNOWN_HEADERS: ReadonlySet<string> = new Set([
  // summary / objective
  "objective", "career objective",
  "summary", "professional summary", "profile", "profile summary", "about me",
  // experience
  "experience", "work experience", "professional experience",
  "employment history", "relevant experience", "work history",
  // skills
  "skills", "skills & abilities", "skills & competencies", "skills and competencies",
  "skills and abilities", "technical skills", "technical proficiencies",
  "core competencies", "expertise", "key skills",
  "key skills and characteristics", "areas of strength", "courses & skills",
  // education
  "education", "educational background", "education/professional development",
  "education & credentials",
  // certifications / licenses
  "certifications", "licenses", "certifications & licenses",
  "certifications and licenses", "licenses & certifications",
  // other
  "languages", "language",
  "references", "awards", "honors", "awards & recognition",
  "projects", "volunteer experience", "activities",
  "assessments", "contact", "contacts", "contact information",
  "interests", "hobbies", "publications", "affiliations",
  "key achievements", "achievements", "additional information",
  "professional development",
]);

const DIVIDER = "────────────────────────────────────────";

function isSectionHeader(line: string): boolean {
  const s = line.trim();
  if (!s || s.length > 60) return false;
  const clean = s.replace(/:+$/, "").trim();
  return KNOWN_HEADERS.has(clean.toLowerCase());
}

export function reformatResumeSeparators(raw: string): string {
  if (!raw || raw.trim() === "") return raw;
  // Idempotency guard — don't re-process text that already has our divider.
  if (raw.includes(DIVIDER)) return raw;

  let cleaned = raw.replace(/\\n/g, "\n");
  cleaned = cleaned.replace(/\(cid:127\)/g, "•");
  cleaned = cleaned.replace(/\(cid:129\)/g, "•");
  cleaned = cleaned.replace(/\(cid:9679\)/g, "●");

  const lines = cleaned.split("\n");
  const firstNonEmptyIdx = lines.findIndex((l) => l.trim() !== "");

  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === firstNonEmptyIdx) {
      out.push(line);
      continue;
    }
    if (isSectionHeader(line)) {
      while (out.length > 0 && out[out.length - 1].trim() === "") out.pop();
      out.push("");
      out.push(DIVIDER);
      out.push("");
      out.push(line.replace(/:+$/, "").trim());
    } else {
      out.push(line);
    }
  }

  // Collapse runs of 3+ blank lines to 2
  const collapsed: string[] = [];
  let blankRun = 0;
  for (const l of out) {
    if (l.trim() === "") {
      blankRun++;
      if (blankRun <= 2) collapsed.push(l);
    } else {
      blankRun = 0;
      collapsed.push(l);
    }
  }

  return collapsed.join("\n").replace(/^\n+|\n+$/g, "") + "\n";
}

// ==================== parsers/resume_tenure_extract.ts ====================
// =========================================================================
// parsers/resume_tenure_extract.ts
// =========================================================================
// Deterministic (regex-only, no LLM) extraction of work-experience date
// ranges from resume_extracted_text, computing total months worked per job.
//
// WHY THIS EXISTS: role_fit_v5_6 (2026-08-14) softens the SJT construct's
// weight for candidates with limited documented work history, reading
// months from resume_analysis.qualifications.prior_similar_role.roles[].
// tenure_months. That field was previously populated only by a manual/
// in-chat resume-scoring workflow with incomplete coverage (see
// persistent_memory spec "SPEC — Resume scoring: deterministic
// work-experience-months extraction"). This module makes tenure_months
// populate automatically, every time, as part of resume ingest.
//
// SINGLE SOURCE OF TRUTH (Peter directive 2026-08-14): this module is the
// ONLY thing that ever writes employer/title/tenure_months into
// prior_similar_role.roles[]. There is no separate "manual" writer of that
// data — when Peter asks for a candidate's work history to be filled in or
// corrected by hand, that request should call extractAndWriteTenure() too,
// not re-derive the numbers a different way. Qualitative fields on each
// role entry (category, notes) and the top-level qualitative fields
// (highest_relevance, insurance_tenure_months, success_signals, notes) are
// NOT touched by this module — those stay owned by whatever in-chat
// scoring pass sets them, matched onto the same roles[] entries by
// employer name.
//
// DESIGN CHOICE (Peter directive 2026-08-14, confirmed after reviewing real
// resume-format diversity): pattern-matching only, no per-resume LLM call
// to associate dates with jobs. This is faster and free, and accurate
// tenure_months in every one of 23 test job entries across 6 real sampled
// resumes. Known accepted tradeoff: employer/title labeling can be wrong on
// unusual layouts (ambiguous separator conventions, stray blank lines from
// PDF extraction) — this NEVER affects tenure_months, which is derived
// independently of the label-splitting heuristic. Never guesses a date
// range that isn't in the text; a job with no parseable dates simply gets
// no tenure_months entry (matches the "never guess" principle already
// established for autonomy scoring and other resume signals).
// =========================================================================

// deno-lint-ignore-file no-explicit-any


// -------------------------------------------------------------------------
// Date parsing
// -------------------------------------------------------------------------

const RESUME_MONTH_NAMES: Record<string, number> = {
  jan: 1, january: 1, feb: 2, february: 2, mar: 3, march: 3, apr: 4, april: 4,
  may: 5, jun: 6, june: 6, jul: 7, july: 7, aug: 8, august: 8, sep: 9, sept: 9,
  september: 9, oct: 10, october: 10, nov: 11, november: 11, dec: 12, december: 12,
};

const MONTH_NAME_RE =
  "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t|tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)";
const DATE_TOKEN_RE = `(?:${MONTH_NAME_RE}\\.?\\s+\\d{4}|\\d{1,2}\\/\\d{4}|(?<!\\d)\\d{4}(?!\\d))`;
const PRESENT_RE = "(?:present|current|now|ongoing)";
const RANGE_RE = new RegExp(
  `(${DATE_TOKEN_RE})\\s*(?:to|thru|through|[\u2013\u2014-])\\s*(${DATE_TOKEN_RE}|${PRESENT_RE})`,
  "i",
);

type MonthYear = { year: number; month: number };
type DateTokenResult = MonthYear | "present" | null;

function parseDateToken(tok: string): DateTokenResult {
  const t = tok.trim().toLowerCase();
  if (/^(present|current|now|ongoing)$/.test(t)) return "present";
  let m = t.match(/^([a-z]+)\.?\s+(\d{4})$/);
  if (m && RESUME_MONTH_NAMES[m[1]]) return { year: parseInt(m[2], 10), month: RESUME_MONTH_NAMES[m[1]] };
  m = t.match(/^(\d{1,2})\/(\d{4})$/);
  if (m) {
    const mo = parseInt(m[1], 10);
    if (mo >= 1 && mo <= 12) return { year: parseInt(m[2], 10), month: mo };
  }
  m = t.match(/^(\d{4})$/);
  if (m) {
    const y = parseInt(m[1], 10);
    // Plausible working-life year range only -- a bare 4-digit token is the
    // weakest signal this parser accepts (no month name, no slash), and
    // without this guard it can match digits embedded in a phone number,
    // zip code, or ID (e.g. "(210274-1570" reads as years 274 and 1570 --
    // real incident, Autumn Verkaik-Bushby resume, caught 2026-08-14).
    if (y >= 1950 && y <= new Date().getUTCFullYear() + 1) return { year: y, month: 1 };
    return null;
  }
  return null;
}

function monthsBetween(start: MonthYear | null, end: DateTokenResult, asOf: MonthYear): number | null {
  if (!start || !end) return null;
  const e = end === "present" ? asOf : end;
  const months = (e.year - start.year) * 12 + (e.month - start.month);
  // Hard backstop regardless of upstream parsing: 50 years is far beyond
  // any real single-job tenure. Discard rather than trust a corrupted value.
  if (months > 600) return null;
  return Math.max(0, months);
}

// -------------------------------------------------------------------------
// Section isolation — reuses KNOWN_HEADERS from resume_reformat.ts (single
// source of truth for the header list) so the boundary detected here
// matches the divider that module already inserted.
// -------------------------------------------------------------------------

const EXPERIENCE_HEADERS: ReadonlySet<string> = new Set([
  "experience", "work experience", "professional experience",
  "employment history", "relevant experience", "work history",
]);

function isBullet(line: string): boolean {
  return /^\s*[•\-*●]/.test(line);
}
function isHeaderLine(line: string): boolean {
  const clean = line.trim().replace(/:+$/, "").toLowerCase();
  return KNOWN_HEADERS.has(clean);
}

function extractExperienceSection(text: string): string[] | null {
  const lines = text.split("\n");
  let start = -1;
  let end = lines.length;
  for (let i = 0; i < lines.length; i++) {
    const clean = lines[i].trim().replace(/:+$/, "").toLowerCase();
    if (EXPERIENCE_HEADERS.has(clean)) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return null;
  for (let i = start; i < lines.length; i++) {
    if (isHeaderLine(lines[i])) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end);
}

// -------------------------------------------------------------------------
// Title/employer best-effort split — see module header for accepted
// limitations. Never affects tenure_months.
// -------------------------------------------------------------------------

function splitHeaderIntoTitleEmployer(headerLines: string[]): { title: string | null; employer: string | null } {
  if (headerLines.length === 0) return { title: null, employer: null };

  if (headerLines.length === 1) {
    const line = headerLines[0].replace(/[,:]\s*$/, "").trim();

    // Leftmost separator wins — a header can carry multiple separators for
    // different purposes (e.g. "Title — Employer - SubDept | Location"),
    // and the FIRST one is reliably the title/employer boundary. Dash
    // requires surrounding whitespace so hyphenated names ("Tru-Fit") do
    // not false-trigger; pipe and comma never appear inside a word so no
    // such guard is needed for them.
    const pipeMatch = line.match(/\s*\|\s*/);
    const dashMatch = line.match(/\s+[\u2013\u2014-]\s+/);
    const commaIdx = line.indexOf(",");

    const seps = [
      pipeMatch ? { idx: pipeMatch.index!, len: pipeMatch[0].length, kind: "pipe" as const } : null,
      dashMatch ? { idx: dashMatch.index!, len: dashMatch[0].length, kind: "dash" as const } : null,
      commaIdx >= 0 ? { idx: commaIdx, len: 1, kind: "comma" as const } : null,
    ].filter((s): s is { idx: number; len: number; kind: "pipe" | "dash" | "comma" } => s !== null)
      .sort((a, b) => a.idx - b.idx);

    if (seps.length > 0) {
      const s = seps[0];
      const left = line.slice(0, s.idx).trim();
      const right = line.slice(s.idx + s.len).trim();
      if (left && right) {
        // Dash convention: left=title. Pipe/comma convention: left=employer.
        return s.kind === "dash" ? { title: left, employer: right } : { title: right, employer: left };
      }
    }
    return { title: line || null, employer: null };
  }

  // 2 lines: top = title, bottom (nearest the date line) = employer (+location, stripped)
  const title = headerLines[0].trim() || null;
  let employerLine = headerLines[1].trim();
  employerLine = employerLine.replace(/\s*[\u2013\u2014-]\s*[A-Za-z .]+,?\s*[A-Z]{2}\s*$/, "");
  employerLine = employerLine.split(",")[0].trim();
  return { title, employer: employerLine || null };
}

// -------------------------------------------------------------------------
// Core parse
// -------------------------------------------------------------------------

export interface ParsedRole {
  title: string | null;
  employer: string | null;
  tenure_months: number;
  start_raw: string;
  end_raw: string;
}

/**
 * Pure function — no I/O. Parses every job entry with a recognizable date
 * range out of the Work Experience section of resumeText. asOf defaults to
 * the current date and governs how "Present"/"Current" resolves; pass a
 * fixed value only for testing.
 */
export function parseWorkExperienceRoles(resumeText: string, asOf?: MonthYear): ParsedRole[] {
  if (!resumeText) return [];
  const now = asOf ?? (() => {
    const d = new Date();
    return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1 };
  })();

  const section = extractExperienceSection(resumeText);
  if (!section) return [];

  const roles: ParsedRole[] = [];
  let cursor = 0;
  while (cursor < section.length) {
    const line = section[cursor];
    const m = line.match(RANGE_RE);
    if (!m) {
      cursor++;
      continue;
    }
    const start = parseDateToken(m[1]);
    const startMY = start === "present" ? null : start;
    const end: DateTokenResult = /present|current|now|ongoing/i.test(m[2]) ? "present" : parseDateToken(m[2]);
    const before = line.slice(0, m.index).replace(/[|,\u2013\u2014-]\s*$/, "").trim();

    let headerLines: string[];
    if (before.length > 3) {
      headerLines = [before];
    } else {
      headerLines = [];
      let back = cursor - 1;
      while (back >= 0 && headerLines.length < 2) {
        const bl = section[back];
        if (bl.trim() === "" || isBullet(bl)) break;
        if (RANGE_RE.test(bl)) break;
        // Wrapped bullet continuation lines carry no leading marker but are
        // mid-sentence prose, not a header — recognizable by ending in a
        // lowercase letter + period/comma, which job titles/employers do not.
        if (/[a-z][.,]\s*$/.test(bl.trim())) { back--; continue; }
        headerLines.unshift(bl.trim());
        back--;
      }
    }

    let { title, employer } = splitHeaderIntoTitleEmployer(headerLines);
    // Sanity filter: a real job title/employer is never a lowercase-started
    // sentence fragment or a run-on phrase. Better to leave the label blank
    // than write garbled prose into a candidate factual record — this never
    // affects tenure_months, which is computed independently of this filter.
    const looksLikeBadProse = (s: string | null) =>
      !s || /^[a-z]/.test(s.trim()) || s.length > 80 || (s.match(/,/g) ?? []).length >= 2;
    if (looksLikeBadProse(title)) title = null;
    if (looksLikeBadProse(employer)) employer = null;
    const tenure_months = monthsBetween(startMY, end, now);
    if (tenure_months !== null) {
      roles.push({ title, employer, tenure_months, start_raw: m[1], end_raw: m[2] });
    }
    cursor++;
  }
  return roles;
}

// -------------------------------------------------------------------------
// Merge into resume_analysis.qualifications.prior_similar_role.roles[]
// -------------------------------------------------------------------------

function normalizeEmployer(s: string | null | undefined): string {
  return (s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Merges parsed roles into the existing qualifications.prior_similar_role
 * shape, OVERWRITING employer/title/tenure_months on any existing role
 * entry it can match by employer name (this module owns those three
 * fields), and preserving category/notes on matched entries untouched
 * (those are owned by qualitative scoring). Unmatched parsed roles are
 * appended as new entries with category/notes left null. Existing entries
 * with no matching parsed role (undated jobs, or jobs this parser missed)
 * are left exactly as they are.
 */
export function mergeParsedRolesIntoResumeAnalysis(
  existing: any,
  parsedRoles: ParsedRole[],
): { updated: any; changed: boolean } {
  const base = existing && typeof existing === "object" ? { ...existing } : {};
  const qualifications = { ...(base.qualifications ?? {}) };
  const priorSimilarRole = { ...(qualifications.prior_similar_role ?? {}) };
  const existingRoles: any[] = Array.isArray(priorSimilarRole.roles) ? [...priorSimilarRole.roles] : [];

  const usedExistingIdx = new Set<number>();
  const mergedRoles: any[] = [];

  for (const parsed of parsedRoles) {
    const normParsed = normalizeEmployer(parsed.employer);
    let matchIdx = -1;
    if (normParsed) {
      matchIdx = existingRoles.findIndex((r, idx) => {
        if (usedExistingIdx.has(idx)) return false;
        const normExisting = normalizeEmployer(r?.employer);
        if (!normExisting) return false;
        return normExisting === normParsed || normExisting.includes(normParsed) || normParsed.includes(normExisting);
      });
    }
    if (matchIdx >= 0) {
      usedExistingIdx.add(matchIdx);
      const existingRole = existingRoles[matchIdx];
      mergedRoles.push({
        ...existingRole,
        employer: parsed.employer ?? existingRole.employer,
        title: parsed.title ?? existingRole.title,
        tenure_months: parsed.tenure_months,
      });
    } else {
      mergedRoles.push({
        employer: parsed.employer,
        title: parsed.title,
        tenure_months: parsed.tenure_months,
        category: null,
        notes: null,
      });
    }
  }
  // Carry over any existing entries this parse run didn't touch (undated
  // jobs, or jobs on a layout this parser couldn't read) unchanged.
  existingRoles.forEach((r, idx) => {
    if (!usedExistingIdx.has(idx)) mergedRoles.push(r);
  });

  priorSimilarRole.roles = mergedRoles;
  qualifications.prior_similar_role = priorSimilarRole;
  base.qualifications = qualifications;

  const changed = JSON.stringify(existingRoles) !== JSON.stringify(mergedRoles);
  return { updated: base, changed };
}

// -------------------------------------------------------------------------
// Orchestration — call this from resume ingest.
// -------------------------------------------------------------------------

/**
 * Parses resumeText for work-experience tenure and writes the result into
 * hiring_candidates.resume_analysis for candidateId, merging (never
 * clobbering qualitative fields) into whatever is already there. Also
 * invalidates that ONE candidate's scoring cache (sets
 * cached_scoring_version to NULL) so the next page load recomputes their
 * fit score with the fresh tenure data — deliberately does NOT bump the
 * agency-wide hiregauge_scoring_version, since that would force every
 * OTHER candidate to recompute for a change that only affects this one.
 *
 * Non-fatal on any failure — logs a warning and returns ok:false. Never
 * throws; callers in the ingest pipeline should not have resume text
 * writes blocked by a tenure-parsing problem.
 */
export async function extractAndWriteWorkExperienceTenure(
  candidateId: string | null | undefined,
  resumeText: string | null | undefined,
): Promise<{ ok: boolean; rolesFound: number; changed: boolean; error?: string }> {
  if (!candidateId || !resumeText) return { ok: false, rolesFound: 0, changed: false, error: "missing candidateId or resumeText" };
  try {
    const parsedRoles = parseWorkExperienceRoles(resumeText);
    if (parsedRoles.length === 0) return { ok: true, rolesFound: 0, changed: false };

    const { data, error: fetchErr } = await sb
      .from("hiring_candidates")
      .select("resume_analysis")
      .eq("id", candidateId)
      .single();
    if (fetchErr) {
      console.warn(`extractAndWriteWorkExperienceTenure: fetch failed for ${candidateId}: ${fetchErr.message}`);
      return { ok: false, rolesFound: parsedRoles.length, changed: false, error: fetchErr.message };
    }

    const { updated, changed } = mergeParsedRolesIntoResumeAnalysis(data?.resume_analysis, parsedRoles);
    if (!changed) return { ok: true, rolesFound: parsedRoles.length, changed: false };

    const { error: writeErr } = await sb
      .from("hiring_candidates")
      .update({ resume_analysis: updated, cached_scoring_version: null })
      .eq("id", candidateId);
    if (writeErr) {
      console.warn(`extractAndWriteWorkExperienceTenure: write failed for ${candidateId}: ${writeErr.message}`);
      return { ok: false, rolesFound: parsedRoles.length, changed: false, error: writeErr.message };
    }
    return { ok: true, rolesFound: parsedRoles.length, changed: true };
  } catch (e) {
    console.warn(`extractAndWriteWorkExperienceTenure threw for ${candidateId}:`, e);
    return { ok: false, rolesFound: 0, changed: false, error: e instanceof Error ? e.message : String(e) };
  }
}

// ==================== parsers/resume_ingest.ts ====================
// =========================================================================
// parsers/resume_ingest.ts
// =========================================================================
// Shared resume-ingest primitives used by BOTH applicant intake modes
// (careerplug and sf_forwarded_applicant). The two modes parse different
// input formats — CareerPlug is an email body, SF forward is a subject +
// CTS attachment — but the resume-processing tail is identical:
//   1. Download the PDF bytes from the Composio s3url
//   2. Extract text column-aware (fallback to plain unpdf if that throws)
//   3. Reformat with section-divider separators
//   4. Write to hiring_candidates.resume_extracted_text ONLY when empty
//      (never clobbers hand-corrected text on a re-run)
//   5. Deterministically parse work-experience date ranges and merge
//      tenure_months into resume_analysis.qualifications.prior_similar_role
//      .roles[] (added 2026-08-14 — see resume_tenure_extract.ts for why).
//      Runs every call, independent of whether step 4 actually wrote
//      anything, so tenure data stays current even on a re-run of an
//      already-stored resume.
//
// Both mode parsers call these functions instead of inlining the block.
// Any future extraction/formatting improvements happen here once.
// =========================================================================


/**
 * Fetch a resume PDF from the given Composio s3url, extract text
 * column-aware (with plain-unpdf fallback), and run through the reformatter.
 *
 * Returns the ready-to-store resume text, or null if any step failed — a
 * null return should be treated as non-fatal: the caller can still land the
 * candidate row with resume_url populated and resume_extracted_text NULL,
 * and Peter can re-run extraction later.
 */
export async function extractResumeTextFromS3url(s3url: string): Promise<string | null> {
  try {
    const { res: r, timedOut } = await fetchWithTimeout(s3url, {}, S3_FETCH_TIMEOUT_MS, "s3_download", `resume text extraction, url=${s3url.slice(0, 80)}`);
    if (!r) {
      console.warn(timedOut ? "resume s3url fetch for text extraction timed out" : "resume s3url fetch for text extraction failed");
      return null;
    }
    if (!r.ok) {
      console.warn(`resume s3url fetch for text extraction returned HTTP ${r.status}`);
      return null;
    }
    const buf = new Uint8Array(await r.arrayBuffer());

    let raw = "";
    try {
      raw = await extractPdfTextColumnAware(buf);
    } catch (colErr) {
      console.warn(`resume column-aware extract failed; falling back to plain unpdf: ${colErr instanceof Error ? colErr.message : String(colErr)}`);
      try {
        raw = await extractPdfTextPlain(buf);
      } catch (plainErr) {
        console.warn(`resume plain unpdf also failed: ${plainErr instanceof Error ? plainErr.message : String(plainErr)}`);
        return null;
      }
    }

    if (!raw || raw.trim().length === 0) return null;
    return reformatResumeSeparators(raw);
  } catch (e) {
    console.warn("extractResumeTextFromS3url threw (non-fatal):", e);
    return null;
  }
}

/**
 * Write resume_extracted_text to a hiring_candidates row, BUT ONLY when
 * the column is currently NULL or empty. Never clobbers hand-corrected
 * text on a re-run of the same message.
 *
 * Non-fatal on any failure — logs a warning and moves on. The candidate
 * row itself was already inserted upstream, so a failed backfill just
 * means the row keeps resume_extracted_text NULL until the next run.
 */
export async function writeResumeTextIfEmpty(
  candidateId: string | null | undefined,
  resumeText: string | null | undefined,
): Promise<void> {
  if (!candidateId || !resumeText) return;
  try {
    const { error } = await sb
      .from("hiring_candidates")
      .update({ resume_extracted_text: resumeText })
      .eq("id", candidateId)
      .or("resume_extracted_text.is.null,resume_extracted_text.eq.");
    if (error) {
      console.warn(`resume_extracted_text update for ${candidateId} failed: ${error.message}`);
    }
  } catch (e) {
    console.warn(`resume_extracted_text update threw for ${candidateId}:`, e);
  }

  // Deterministic tenure extraction — non-fatal, runs regardless of whether
  // the text write above actually changed anything. See resume_tenure_extract.ts.
  await extractAndWriteWorkExperienceTenure(candidateId, resumeText);
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
    // Star + apply Applicants label so the message exits the fetch pool.
    // Without this, a Groq failure (rate-limit, transient, JSON parse, etc.)
    // leaves the email unfiled — and the next 15-min cron fires the fetch
    // query again and re-hammers Groq with the same body. That amplification
    // (37 real applicants × 96 fetches/day × 5K tokens) previously exhausted
    // the daily 200K TPD budget by ~8am. Queue item + drainer coverage is
    // the durable path; the raw email doesn't need to sit in INBOX.
    await starMessage(ctx, messageId);
    const failThreadId: string | null = msg?.threadId ?? msg?.thread_id ?? null;
    if (failThreadId) {
      try {
        await callComposio({
          apiKey: ctx.composioApiKey,
          userId: ctx.composioUserId,
          connectedAccountId: ctx.gmailAccountId,
          toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
          toolArguments: {
            thread_id: failThreadId,
            remove_label_ids: ["INBOX"],
            add_label_ids: [APPLICANTS_GMAIL_LABEL_ID],
            user_id: "me",
          },
        });
      } catch (e) {
        console.warn("careerplug archive-on-queue threw (non-fatal):", e);
      }
    }
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
    // storeResume() ALSO extracts the resume text (column-aware + reformatted)
    // for downstream write into hiring_candidates.resume_extracted_text after
    // the upsert RPC returns the candidate id.
    let resumeDocumentId: string | null = null;
    let stored: StoreResumeResult | null = null;
    if (pdfAttachments.length > 0) {
      const pdf = pdfAttachments.length === applicants.length
        ? pdfAttachments[idx]
        : (idx === 0 ? pdfAttachments[0] : null);
      if (pdf) {
        stored = await storeResume(ctx, messageId, subject, receivedAtISO, pdf, a);
        if (stored.ok) resumeDocumentId = stored.documentId ?? null;
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

    // Write extracted resume text back to hiring_candidates.resume_extracted_text.
    // ONLY when the column is currently NULL or empty — never clobbers a
    // hand-corrected text on a re-run of the same message.
    if (stored?.ok && stored.resumeText && res.assessment_id) {
      await writeResumeTextIfEmpty(res.assessment_id, stored.resumeText);
    }
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
  /** Column-aware extracted + reformatted resume text. Present only when
   *  PDF text extraction succeeded and produced non-empty output. */
  resumeText?: string;
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
  // 1. Fetch attachment metadata (Composio returns an s3url pointing at the
  //    file already stored in its temp bucket — we extract the s3key for the
  //    Drive UPLOAD call instead of round-tripping through base64 ourselves).
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
  if (!s3url) return { ok: false, error: "no s3url on attachment response" };
  const s3keyMatch = s3url.match(/https?:\/\/[^/]+\/(.+?)\?/);
  const s3key = s3keyMatch ? s3keyMatch[1] : null;
  if (!s3key) return { ok: false, error: "could not extract s3key from s3url" };

  // 2. Compose a stable filename: "Resume - <FirstLast> - <YYYYMMDD>.pdf"
  const nameSlug = [a.first_name, a.last_name].filter(Boolean).join(" ") || "unknown";
  const dateSlug = receivedAtISO.slice(0, 10).replace(/-/g, "");
  const targetName = `Resume - ${nameSlug} - ${dateSlug}.pdf`;

  // 2b. Extract resume text (column-aware, reformatted). Best-effort — a
  // failure here does not block the Drive upload or the documents insert;
  // the row can still land with resume_url pointing at the Drive file and
  // resume_extracted_text NULL, and Peter can re-run extraction later.
  const resumeText = await extractResumeTextFromS3url(s3url);

  // 3. Upload to Drive using the current GOOGLEDRIVE_UPLOAD_FILE schema:
  //    file_to_upload: { name, mimetype, s3key }. Composio's backend copies
  //    directly from its S3 bucket to Drive. The old (file_content + is_base64)
  //    shape silently uploads 0-byte placeholders — Priscilla Brito's original
  //    upload 2026-07-15 hit that bug.
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
          file_to_upload: {
            name: targetName,
            mimetype: "application/pdf",
            s3key,
          },
          folder_to_upload_to: APPLICANTS_DRIVE_FOLDER_ID,
        },
      });
      if (uploadRes.ok) {
        driveFileId = uploadRes.data?.id ?? uploadRes.data?.fileId ?? uploadRes.data?.response_data?.id ?? null;
        // New Composio Drive response doesn't return webViewLink; construct it.
        driveUrl    = driveFileId ? `https://drive.google.com/file/d/${driveFileId}/view` : null;
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
  return {
    ok: true,
    documentId: docRow.id as string,
    resumeText: resumeText ?? undefined,
  };
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
    `(from:careerplug.com OR from:careerplug OR subject:"new applicant" OR subject:"applicant digest") -label:Team-Hiring-Applicants newer_than:14d`;
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

// ==================== parsers/resume_manual_batch.ts ====================
// =========================================================================
// parsers/resume_manual_batch.ts
// =========================================================================
// Hand-forwarded resume batches — bare resume PDFs attached to an email with
// an empty body, forwarded by a person rather than sent by a job board.
//
// Called from index.ts when classifyDocument() returns "resume_manual_batch".
//
// WHY THIS EXISTS (found 2026-08-03):
//   Resume PDFs only reached hiring_candidates by two routes, and both were
//   gated on the SENDER:
//     - careerplug_applicant       → sender must be careerplug.com
//     - mode=sf_forwarded_applicant → sender must be Peter's State Farm
//                                     mailbox AND subject must say "Applicant"
//   Marie forwards raw resume PDFs from her own Gmail with an empty body and
//   subjects like "Applicants - Career Plug 3" / "Applicants - Indeed 08/01".
//   Those matched neither route, so classifyDocument() returned "skip" — no
//   documents row, no candidate row, no error, nothing to notice. Roughly 80
//   resumes accumulated that way across five threads before anyone looked.
//
// WHAT THIS DOES, per PDF:
//   1. Extract the resume text column-aware (same primitives the CareerPlug
//      and State-Farm-forward paths use), fall back to plain extraction.
//   2. Identify the candidate from the TEXT, not the filename. Filenames in
//      these batches are inconsistent enough to be useless as an identity
//      source: "First_Last_Resume.pdf", "ResumeFIRSTLAST.pdf",
//      "ALL_CAPS_Resume.pdf", and bare "Resume.pdf" all appear.
//   3. Upsert through upsert_candidate_from_careerplug — the same routine the
//      CareerPlug path uses, so the four layers of duplicate protection are
//      shared rather than reinvented. The idempotency key is
//      "<messageId>:<fileName>" because one message carries many resumes.
//   4. Store the resume text on the candidate row, never clobbering text that
//      is already there.
//
// FAILURE POSTURE — deliberate:
//   Identity extraction degrades instead of failing. The language model is
//   tried twice; if it does not answer, a deterministic pass pulls the email
//   address and phone number by pattern and takes the name from the first
//   plausible line of the resume. A candidate row with a shaky name that
//   Peter can correct in the app is strictly better than a resume that
//   vanishes, because the fetcher's duplicate check (message id + file name)
//   means a file abandoned once is never offered again. Only when BOTH the
//   language model and the deterministic pass come up with no email and no
//   name does this give up — and then it raises an alert and reports the
//   error upward so index.ts leaves the thread in the inbox.
//
// KNOWN WART: upsert_candidate_from_careerplug hardcodes
// ingestion_metadata.source = "careerplug" for every caller. Rows created
// here therefore read as CareerPlug-sourced. Real provenance is recoverable
// from ingestion_metadata.source_message (sender, subject, message id), which
// this parser fills in. Changing the routine's hardcoded label is a separate
// job affecting the live CareerPlug path, so it is not done here.
// =========================================================================

// deno-lint-ignore-file no-explicit-any


interface RmbIdentity {
  first_name: string | null;
  last_name: string | null;
  email: string | null;
  phone: string | null;
}

export interface RmbArgs {
  agencyId: string;
  documentId: string;
  messageId: string;
  fromEmail: string;
  subject: string;
  receivedAt: string;   // ISO 8601
  fileName: string;
  bytesB64: string;
  resumeUrl: string | null;  // Drive link, when the Drive upload succeeded

  // Gmail's own id for this attachment. Needed only to fetch the original
  // again when the file turns out to be a scan with no text in it. Null for
  // files that came out of a zip, which have no attachment of their own.
  gmailAttachmentId?: string | null;

  // Credentials for the scanned-file text recovery step. Omit to switch that
  // step off entirely — the parser then behaves exactly as it did before.
  recovery?: TextRecoveryDeps;

  // Text already read out of this scan somewhere else and handed in with the
  // request. When present the parser skips its own recovery step and uses this
  // instead. See the note on the resume_text_recovery mode in index.ts for why
  // that door exists.
  preRecoveredText?: string | null;
  preRecoveredDriveFileId?: string | null;
  preRecoveredDriveUrl?: string | null;
}

export interface RmbResult {
  ok: boolean;
  candidateId: string | null;
  action: string;              // inserted | updated_by_email | noop_by_gmail_message_id | ...
  candidateName: string | null;
  identitySource: "llm" | "deterministic" | "none";
  // Where the resume text came from: the file's own text layer, or Drive text
  // recognition after the file proved to be a scan.
  textSource?: "pdf" | "text_recognition";
  // Set when text recognition ran. This converted document is the Drive copy
  // these resumes have otherwise never had, so the caller stores it.
  recoveredDriveFileId?: string | null;
  recoveredDriveUrl?: string | null;
  error?: string;
}

const RMB_ID_SYSTEM = `You read the text of one resume and return the candidate's identity. Return ONLY a JSON object, no prose, no markdown fences. Use null for anything the resume does not state. Never invent a name, an email address, or a phone number.`;

const RMB_ID_USER_TMPL = (resumeText: string) => `Return JSON with exactly this shape:
{"first_name":"","last_name":"","email":"","phone":""}

Rules:
- first_name / last_name: the candidate's own name, usually at the very top. Drop middle names, initials, suffixes, and credentials such as MBA or RN. If only one name is present, put it in first_name and set last_name to null.
- email: the candidate's own address. Ignore addresses belonging to former employers, schools, or references.
- phone: digits only, no punctuation, no country code.
- Nothing found for a field → null.

Resume text:
${resumeText.slice(0, 12000)}`;

// Deterministic patterns — the fallback when the language model does not answer.
const RMB_EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const RMB_PHONE_RE = /(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/;

// Words that mark a line as a heading or contact block rather than a name.
const RMB_NOT_A_NAME_RE =
  /(resume|curriculum|vitae|objective|summary|profile|experience|education|skills|references|address|phone|email|linkedin|http|www\.|@|\d{3})/i;

function rmbTitleCase(s: string): string {
  return s
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

/**
 * Pull a name out of the resume text without help from the language model.
 * Looks at the first handful of non-empty lines and takes the first one that
 * looks like a person's name: two to four words, letters only, no heading
 * keywords, no contact-block markers. ALL-CAPS names are title-cased.
 */
function rmbNameFromText(text: string): { first_name: string | null; last_name: string | null } {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).slice(0, 12);
  for (const line of lines) {
    const cleaned = line.replace(/[|•·,]+/g, " ").replace(/\s+/g, " ").trim();
    if (!cleaned || cleaned.length > 60) continue;
    if (RMB_NOT_A_NAME_RE.test(cleaned)) continue;
    const words = cleaned.split(" ").filter((w) => /^[A-Za-z][A-Za-z'’.-]*$/.test(w));
    if (words.length !== cleaned.split(" ").length) continue;
    if (words.length < 2 || words.length > 4) continue;
    const named = rmbTitleCase(words.join(" ")).split(" ");
    return { first_name: named[0], last_name: named.slice(1).join(" ") };
  }
  return { first_name: null, last_name: null };
}

function rmbDeterministicIdentity(text: string): RmbIdentity {
  const email = text.match(RMB_EMAIL_RE)?.[0] ?? null;
  const phoneRaw = text.match(RMB_PHONE_RE)?.[0] ?? null;
  const phone = phoneRaw ? phoneRaw.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "") : null;
  const { first_name, last_name } = rmbNameFromText(text);
  return { first_name, last_name, email, phone };
}

function rmbCleanIdentity(raw: any): RmbIdentity {
  const str = (v: any): string | null => {
    if (typeof v !== "string") return null;
    const t = v.trim();
    if (!t || t.toLowerCase() === "null" || t.toLowerCase() === "n/a") return null;
    return t;
  };
  const phoneRaw = str(raw?.phone);
  return {
    first_name: str(raw?.first_name),
    last_name: str(raw?.last_name),
    email: str(raw?.email)?.toLowerCase() ?? null,
    phone: phoneRaw ? phoneRaw.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "") : null,
  };
}

async function rmbExtractResumeText(bytesB64: string): Promise<string | null> {
  try {
    const bin = atob(bytesB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);

    let raw = "";
    try {
      raw = await extractPdfTextColumnAware(bytes);
    } catch (colErr) {
      console.warn(`[resume_manual_batch] column-aware extract failed, trying plain: ${colErr instanceof Error ? colErr.message : String(colErr)}`);
      try {
        raw = await extractPdfTextPlain(bytes);
      } catch (plainErr) {
        console.warn(`[resume_manual_batch] plain extract also failed: ${plainErr instanceof Error ? plainErr.message : String(plainErr)}`);
        return null;
      }
    }
    if (!raw || !raw.trim()) return null;
    return reformatResumeSeparators(raw);
  } catch (e) {
    console.warn("[resume_manual_batch] text extraction threw:", e);
    return null;
  }
}

export async function processResumeManualBatch(args: RmbArgs): Promise<RmbResult> {
  const fail = (error: string): RmbResult => ({
    ok: false, candidateId: null, action: "error",
    candidateName: null, identitySource: "none", error,
  });

  // ---- 1. Resume text --------------------------------------------------
  let resumeText = await rmbExtractResumeText(args.bytesB64);
  let textSource: "pdf" | "text_recognition" = "pdf";
  let recoveredDriveFileId: string | null = null;
  let recoveredDriveUrl: string | null = null;
  let recoveryFailure: string | null = null;

  // Text handed in with the request, used in place of the file's own text layer
  // — which, these files being scans, they do not have. This is the same text
  // the recovery step below would have produced, so everything after this point
  // behaves identically whichever way the text arrived.
  const handedInText = (args.preRecoveredText ?? "").trim();
  if (!resumeText && handedInText.length >= 40) {
    resumeText = reformatResumeSeparators(handedInText);
    textSource = "text_recognition";
    recoveredDriveFileId = args.preRecoveredDriveFileId ?? null;
    recoveredDriveUrl = args.preRecoveredDriveUrl ?? null;
  }

  // Nothing extractable means the file is a scan or a phone photo — page
  // images with no text layer. About one in five of these resumes is. Rather
  // than losing a real applicant, send the original through Drive, which
  // performs text recognition when a page-image file is brought in as a
  // Google Doc, and carry on with the recovered text. Everything below this
  // point is unchanged, which is the whole point of doing it here.
  if (!resumeText && args.recovery && args.gmailAttachmentId) {
    const rec = await recoverTextFromScannedFile({
      deps: args.recovery,
      messageId: args.messageId,
      attachmentId: args.gmailAttachmentId,
      fileName: args.fileName,
    });
    if (rec.ok) {
      resumeText = reformatResumeSeparators(rec.text);
      textSource = "text_recognition";
      recoveredDriveFileId = rec.driveFileId;
      recoveredDriveUrl = rec.driveUrl;
      console.log(`[resume_manual_batch] ${args.fileName}: no text in the file; recovered ${rec.charCount} characters by Drive text recognition`);
    } else {
      recoveryFailure = `${rec.stage} stage: ${rec.error}`;
      console.warn(`[resume_manual_batch] ${args.fileName}: text recognition failed at the ${recoveryFailure}`);
    }
  }

  if (!resumeText) {
    // Say WHICH step broke. Without this the only record is a console line
    // nobody can read after the fact, and the three possible causes — Gmail,
    // the conversion, the read — have three different fixes.
    const why = recoveryFailure
      ? `text recognition failed at the ${recoveryFailure}`
      : args.recovery
        ? "text recognition was not attempted (no Gmail attachment id on this file)"
        : "text recognition is switched off for this caller";
    await rmbAlert(args, `No readable text in this file, and ${why}. Needs manual entry.`);
    return fail(`no text in file; ${why}`);
  }

  // ---- 2. Identity: language model first, twice ------------------------
  let identity: RmbIdentity | null = null;
  let identitySource: RmbResult["identitySource"] = "none";

  for (let attempt = 1; attempt <= 2; attempt++) {
    const res = await parseWithLLM({
      agencyId: args.agencyId,
      composioApiKey: "",   // unused by lib/llm.ts; kept for signature compatibility
      composioUserId: "",
      systemPrompt: RMB_ID_SYSTEM,
      userContent: RMB_ID_USER_TMPL(resumeText),
      documentId: args.documentId,
      purpose: "resume_identity_extract",
      maxTokens: 400,
      // llm-queue-drainer has no handler for this purpose, and the pattern
      // matching below already covers a model failure — a queued row would sit
      // pending forever. Take the plain failure instead.
      skipQueueOnFailure: true,
    });
    if (res.ok) {
      const cand = rmbCleanIdentity(res.json);
      if (cand.first_name || cand.email) {
        identity = cand;
        identitySource = "llm";
        break;
      }
    }
    // Rate limits are the common failure here (many resumes land in one run),
    // so pause before the retry rather than hammering.
    if (attempt === 1) await new Promise((r) => setTimeout(r, 4000));
  }

  // ---- 3. Deterministic fallback ---------------------------------------
  if (!identity) {
    const det = rmbDeterministicIdentity(resumeText);
    if (det.email || det.first_name) {
      identity = det;
      identitySource = "deterministic";
      console.warn(`[resume_manual_batch] ${args.fileName}: language model gave no identity; used pattern matching (email=${det.email ?? "none"}, name=${[det.first_name, det.last_name].filter(Boolean).join(" ") || "none"})`);
    }
  }

  if (!identity) {
    await rmbAlert(args, "Could not determine who this resume belongs to — no name and no email address found by either method. Needs manual entry.");
    return fail("identity extraction failed (language model and pattern matching both empty)");
  }

  // Pattern-fill anything the language model left blank. Additive only —
  // never overwrites a value the model did return.
  if (identitySource === "llm") {
    const det = rmbDeterministicIdentity(resumeText);
    identity.email = identity.email ?? det.email;
    identity.phone = identity.phone ?? det.phone;
  }

  let candidateName = [identity.first_name, identity.last_name].filter(Boolean).join(" ") || null;

  // hiring_candidates carries team_assessments_identity_check, which demands
  // either a team member id or a non-empty candidate_name. A resume that gives
  // up an email address but no name violates it and throws, and because the
  // fetcher's duplicate check means an abandoned file is never offered again,
  // that applicant is lost for good. Fall back to the part of the email address
  // before the @ sign so the row lands soft and the name can be corrected in
  // the app. (Found 2026-08-04: one resume in the first backlog run did this.)
  let nameFromEmail = false;
  if (!candidateName && identity.email) {
    const localPart = identity.email.split("@")[0]?.trim();
    if (localPart) {
      candidateName = localPart;
      nameFromEmail = true;
      console.warn(`[resume_manual_batch] ${args.fileName}: no name found by either method; using email local part "${localPart}" as candidate_name`);
    }
  }

  // ---- 4. Upsert -------------------------------------------------------
  // Idempotency key is message id + file name: one forwarded email carries
  // many resumes, so the message id alone would collapse the whole batch
  // into a single candidate.
  const payload: Record<string, unknown> = {
    first_name: identity.first_name,
    last_name: identity.last_name,
    candidate_name: candidateName,
    email: identity.email,
    phone: identity.phone,
    position: null,
    applied_at: args.receivedAt,
    resume_url: args.resumeUrl ?? recoveredDriveUrl,
    resume_document_id: args.documentId,
    gmail_message_id: `${args.messageId}:${args.fileName}`,
    careerplug_metadata: {
      gmail_source_message_id: args.messageId,
      gmail_from: args.fromEmail,
      gmail_subject: args.subject,
      source_platform: null,
    },
  };

  const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
    p_agency_id: args.agencyId,
    p_payload: payload,
  });
  if (rpcErr) {
    await rmbAlert(args, `Candidate upsert failed: ${rpcErr.message}`);
    return fail(`upsert_candidate_from_careerplug: ${rpcErr.message}`);
  }

  const res = (rpcData ?? {}) as { assessment_id?: string; action?: string };
  const candidateId = res.assessment_id ?? null;

  // ---- 5. Resume text onto the candidate row ---------------------------
  await writeResumeTextIfEmpty(candidateId, resumeText);

  // The row landed, but under a stand-in name. Say so, so it gets corrected.
  if (nameFromEmail) {
    await rmbAlert(
      args,
      `Saved, but no name could be read from this resume. The name currently shows as "${candidateName}" (taken from the email address). Please correct it on the candidate record.`,
    );
  }

  return {
    ok: true,
    candidateId,
    action: res.action ?? "unknown",
    candidateName,
    identitySource,
    textSource,
    recoveredDriveFileId,
    recoveredDriveUrl,
  };
}

async function rmbAlert(args: RmbArgs, message: string): Promise<void> {
  try {
    await sb.from("alerts").insert({
      agency_id: args.agencyId,
      alert_type: "resume_ingest_failed",
      severity: "warning",
      title: `Resume could not be ingested — ${args.fileName}`,
      message: `${message}\n\nFrom: ${args.fromEmail}\nSubject: "${args.subject}"\nFile: ${args.fileName}`,
      module_reference: "document-processor",
      related_id: args.documentId,
      is_read: false,
      is_resolved: false,
      created_at: new Date().toISOString(),
    });
  } catch (e) {
    console.warn("[resume_manual_batch] alert insert failed (non-fatal):", e);
  }
}

// ==================== parsers/wrapup_ingest.ts ====================
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
//   2. Classify as one of:
//        - "nag_reply"  (subject "Re: [EXTERNAL] Wrap-up follow-up — X")
//        - "wrapup"     (subject contains wrap-up / wrapup / wrap up)
//        - "cpr_reply"  (subject "CPR RECAP — WEEK OF …")
//        - "unclassified" (skip + label)
//      Nag reply is checked FIRST because its subject would otherwise match
//      the generic wrap-up regex and get mis-routed to the reply's-week
//      Saturday instead of the ORIGINAL nagged week.
//   3. Resolve sender team_member (handles Fw: forwarding by parsing the
//      first inner "From:" line when the outer sender is us).
//   4. Resolve week_ending_date (Saturday):
//        - nag_reply → look up parent nag via In-Reply-To → RFC Message-ID
//          in wrapup_nag_log.nag_message_id_rfc; skip if not found.
//        - cpr_reply → look up parent CPR via In-Reply-To → RFC id in
//          weekly_cpr_reports.cpr_recap_message_id_rfc, fall back to the
//          legacy gmail_message_id column, skip if not found.
//        - wrapup   → nearest past Saturday from received timestamp CT,
//          BUT if that Saturday's CPR has already been sent to the team,
//          shift forward one week (email is for the current in-progress
//          week, not the just-closed one).
//   5. Pull existing wrapup_text + the six-item rubric from
//      get_wrapup_checklist_text().
//   6. LLM merges new email into current text, organized under the six
//      required sections; returns coverage[6] + missing_item_labels[].
//   7. Write organized text back; flip wrapup_done if all six covered.
//   8. If missing items and same missing-set hasn't been nagged this week,
//      send public nag email (whole team including Peter) + log. On send,
//      also capture the sent nag's RFC-2822 Message-ID so a future reply
//      can be routed back to this week via In-Reply-To.
//   9. Apply Wrapups Gmail label + remove INBOX.
// =========================================================================

// deno-lint-ignore-file no-explicit-any


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
  kind: "wrapup" | "cpr_reply" | "nag_reply" | "unclassified";
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
3. If a category has NO content across <CURRENT_WRAPUP_TEXT> + <NEW_EMAIL_BODY>, write EXACTLY the string "(none reported)" under the header. NEVER invent placeholder content. Plausible-sounding phrasings like "No X this week", "Nothing to report", "Did not take any cancellation calls", "No significant updates", "N/A" — if those exact words do not appear in the source, they are FABRICATION and must NOT be written. When in doubt, write "(none reported)".
4. If the new email adds material to a category that already had content, integrate (append if new, do not duplicate if a paraphrase of what's already there). Do NOT lose prior content.
5. Do NOT add signatures, disclaimers, closing lines, or content outside the six categories.
6. Do NOT include email metadata (dates, subjects, greetings) unless the content is materially useful.
7. Strip email signatures ("Thanks for trusting Peter Story State Farm…", block contact info, forwarded header stubs, etc.) from the source before folding in.
8. Preserve customer first names + last initials as written (e.g. "Delia C.") — cancellation stories often reference customers by name.
9. Zero-fabrication test: before writing ANY sentence under a section header, verify that the words either appear in the source OR are the exact literal string "(none reported)". Nothing else. Inventing content that sounds plausible is the most damaging failure mode of this parser — it makes teammates appear to have covered sections they never addressed. Prior real failure: a teammate's email had no section-2 content; the LLM wrote "Did not take any cancellation calls." under section 2. That line was fabricated — the words never appeared in the source. Correct output would have been "(none reported)".

RULES for coverage:
A section is covered if the teammate addressed it in their email in ANY way — including "N/A", "nothing to report", "no cancels this week", "no obstacles", or any deliberate acknowledgment that they read the section and answered it. Content quality is NOT the bar; presence of a genuine answer is. Do not penalize brief, sparse, or "nothing to report" answers — they count.

A section is NOT covered ONLY when the teammate did not address it at all in the source — i.e. the LLM output "(none reported)" for that section because there was no content to fold in from either <CURRENT_WRAPUP_TEXT> or <NEW_EMAIL_BODY>.

- item_1 covered if teammate addressed personal life and/or annuity status (any content, including "no updates").
- item_2 covered if teammate addressed cancellations/lapses/trends or highlights (any content, including "no cancels this week").
- item_3 covered if teammate addressed obstacles (any content, including "no obstacles").
- item_4 covered if teammate stated a plan (any content, however brief).
- item_5 covered if teammate stated an efficiency recommendation (any content, including "no suggestions").
- item_6 covered if teammate addressed teammate brags (any content, including "none this week").

The only false signal is "(none reported)" written by you because the source had nothing on that section.

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
  const defaultQuery = `(${fromClause}) ${subjectMatch} -label:Team-Wrapups -in:sent newer_than:21d`;

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
    // Small breath between messages so Groq's per-minute quota doesn't
    // trip during backfill. Steady-state cron only sees 1-2 msgs per tick
    // so this is negligible in production.
    await new Promise((r) => setTimeout(r, 1500));
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
  // Composio's GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID returns messageTimestamp
  // (ISO 8601 string) at the top level, and NOT internalDate. Fall back to
  // Date header parsing, then Date.now() as last resort (which corrupts week
  // routing — hence the multi-source fallback).
  const receivedAtISO: string =
    (typeof msg?.messageTimestamp === "string" && msg.messageTimestamp)
      || (msg?.internalDate ? new Date(Number(msg.internalDate)).toISOString() : "")
      || parseDateHeader(headers)
      || new Date().toISOString();
  const threadId: string | undefined = msg?.threadId ?? msg?.thread_id;

  const bodyText = wupExtractBestBody(msg);
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
  const kind: "wrapup" | "cpr_reply" | "nag_reply" | "unclassified" = await classifyKind(subject, inReplyTo);
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
    // Write-back pointer for llm-queue-drainer. Without this the queue-fallback
    // path below is a silent loss: the email gets labeled + archived (so no
    // future cron tick re-fetches it) while the queued job has no way to know
    // which weekly_cpr_team_detail row it was organizing. That is exactly how
    // John Kostov's 2026-08-06 wrap-up went missing until it was recovered by
    // hand on 2026-08-07.
    targetRef: {
      table: "weekly_cpr_team_detail",
      detail_id: detailRow.id,
      team_member_id: teamMember.id,
      week_ending_date: weekEnding,
      gmail_message_id: messageId,
      sender_first_name: teamMember.first_name,
    },
  });
  if (!parseRes.ok) {
    // Archive so the wrapup email exits the fetch pool. Without this, the
    // 30-min Weekly Wrapup cron re-fetches the same emails (John, Cassie,
    // Stephanie) all afternoon on Fridays and re-hammers Groq, which
    // amplifies quota drain and multiplies queue rows for the same message.
    // Queue item is the durable record; drainer picks it up when quota
    // recovers.
    await labelAndArchive(ctx, messageId, threadId);
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
): Promise<"wrapup" | "cpr_reply" | "nag_reply" | "unclassified"> {
  const subjectLower = (subject || "").toLowerCase();
  // Nag reply MUST be checked FIRST — the subject "Re: [EXTERNAL] Wrap-up
  // follow-up — Name" matches the generic wrap-up regex, but it is a REPLY
  // TO A NAG about a PRIOR week, not a fresh wrap-up for the current week.
  // Routing it as "wrapup" causes timestamp-fallback to land on the wrong
  // Saturday and re-nag for pieces the teammate already covered elsewhere.
  if (/^\s*re:\s*(?:\[external\]\s*)?wrap[\s\-_]?up\s+follow[\s\-_]?up/i.test(subject)) {
    return "nag_reply";
  }
  // Explicit wrap-up subject
  if (/(wrap[\s\-_]?up|wrapup)/i.test(subject)) return "wrapup";
  // CPR reply — by subject
  if (/cpr recap/i.test(subject)) {
    // If it's the original send (not a reply/forward), it originated from us.
    // Classifier here only sees reply/forward (defaultQuery excludes -in:sent).
    return "cpr_reply";
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

// Given an ISO timestamp, returns the Saturday date (YYYY-MM-DD in
// America/Chicago) that the wrap-up email is targeting. Assumes:
//   Fri (idx=5) or Sat (idx=6) → THIS week's Saturday (Sat=today, Fri=+1)
//     Rationale: team writes their wrap-up on Fri afternoon / Sat morning
//     for the week that ends that same Saturday.
//   Sun (idx=0) → last Saturday (yesterday). Wrap-up landing after CPR
//     for the week that just closed.
//   Mon-Thu (idx=1..4) → last Saturday. Late wrap-up covering the
//     just-closed week.
// Parse RFC 2822 date header (e.g. "Fri, 10 Jul 2026 22:19:31 +0000") into
// ISO 8601. Returns "" if unparseable.
function parseDateHeader(headers: any[]): string {
  const dateHeader = headers?.find((h: any) => h?.name === "Date")?.value;
  if (!dateHeader || typeof dateHeader !== "string") return "";
  try {
    const d = new Date(dateHeader);
    if (isNaN(d.getTime())) return "";
    return d.toISOString();
  } catch { return ""; }
}

function wrapupTargetSaturdayCT(receivedAtISO: string): string {
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
  let daysOffset: number;
  if (idx === 6) daysOffset = 0;                // Sat: today
  else if (idx === 5) daysOffset = 1;           // Fri: +1 (tomorrow's Sat)
  else if (idx === 0) daysOffset = -1;          // Sun: yesterday
  else daysOffset = -(idx + 1);                 // Mon..Thu: back to last Sat
  const base = new Date(`${y}-${m}-${d}T12:00:00Z`);
  base.setUTCDate(base.getUTCDate() + daysOffset);
  return base.toISOString().slice(0, 10);
}

async function resolveWeekEnding(
  agencyId: string,
  kind: "wrapup" | "cpr_reply" | "nag_reply",
  inReplyTo: string,
  receivedAtISO: string,
): Promise<string | null> {
  const cleaned = (inReplyTo || "").replace(/[<>]/g, "").trim();

  // Nag reply: look up the parent nag by its stored RFC Message-ID. That
  // row's week_ending_date IS the week the nag was about. If we cannot
  // resolve it, DO NOT fall through to timestamp math — a nag reply about
  // week 7/11 that lands on 7/22 must not be routed to 7/18 just because
  // it arrived on a Wednesday. Return null → parser skips the message.
  if (kind === "nag_reply") {
    if (!cleaned) return null;
    const { data } = await sb
      .from("wrapup_nag_log")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("nag_message_id_rfc", cleaned)
      .maybeSingle();
    return data?.week_ending_date ?? null;
  }

  // CPR reply: try the new RFC Message-ID column first (canonical going
  // forward), then fall back to the historical gmail_message_id column for
  // pre-fix rows. If BOTH fail, return null rather than mis-routing via
  // timestamp math — same safety principle as nag_reply above.
  if (kind === "cpr_reply") {
    if (!cleaned) return null;
    const { data: rfcRow } = await sb
      .from("weekly_cpr_reports")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("cpr_recap_message_id_rfc", cleaned)
      .maybeSingle();
    if (rfcRow?.week_ending_date) return rfcRow.week_ending_date;
    const { data: gidRow } = await sb
      .from("weekly_cpr_reports")
      .select("week_ending_date")
      .eq("agency_id", agencyId)
      .eq("gmail_message_id", cleaned)
      .maybeSingle();
    return gidRow?.week_ending_date ?? null;
  }

  // Fresh wrap-up email: timestamp-based Saturday derivation is the default.
  // BUT — if the CPR RECAP for that Saturday has already been sent to the
  // team, the just-closed week is published; a wrap-up landing after that
  // is FOR THE CURRENT IN-PROGRESS WEEK, not a late submission for the
  // closed one. Shift forward one Saturday in that case.
  //
  // Why: teammates who send wrap-ups Mon-Thu (default rule routes back to
  // last Sat) can't be writing for a week whose CPR already went out — the
  // "late wrap-up" interpretation only makes sense while the prior CPR is
  // still in-draft. Once it's sent, the same email must be for this week.
  const baseSat = wrapupTargetSaturdayCT(receivedAtISO);
  const { data: baseCpr } = await sb
    .from("weekly_cpr_reports")
    .select("sent_to_team_at")
    .eq("agency_id", agencyId)
    .eq("week_ending_date", baseSat)
    .maybeSingle();
  if (baseCpr?.sent_to_team_at) {
    const nextSat = new Date(`${baseSat}T12:00:00Z`);
    nextSat.setUTCDate(nextSat.getUTCDate() + 7);
    return nextSat.toISOString().slice(0, 10);
  }
  return baseSat;
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

  // 5. Capture Gmail internal id AND RFC-2822 Message-ID (headers) from the
  //    send. The RFC id is what teammates' reply clients put in In-Reply-To,
  //    so storing it enables reliable reply-to-week routing on the next
  //    ingest run. Gmail's send-response body typically does NOT include
  //    the RFC id, so we do a follow-up metadata fetch on the sent message.
  const sentGmailId: string | null =
    sendRes.data?.id ?? sendRes.data?.messageId ?? sendRes.data?.response_data?.id ?? null;
  let rfcMsgId: string | null = null;
  if (sentGmailId) {
    try {
      const metaRes = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
        toolArguments: {
          message_id: sentGmailId,
          format: "metadata",
          user_id: "me",
        },
      });
      if (metaRes.ok) {
        const meta: any = metaRes.data?.response_data ?? metaRes.data ?? {};
        const headers: any[] = meta?.payload?.headers ?? [];
        const raw = headers.find((h: any) =>
          h?.name === "Message-ID" || h?.name === "Message-Id" || h?.name === "message-id"
        )?.value;
        if (raw && typeof raw === "string") {
          rfcMsgId = raw.replace(/[<>]/g, "").trim() || null;
        }
      }
    } catch (e) {
      console.warn("wrapup nag RFC Message-ID capture failed (non-fatal):", e);
    }
  }
  await sb.from("wrapup_nag_log").insert({
    agency_id: ctx.agencyId,
    team_member_id: teamMember.id,
    week_ending_date: weekEnding,
    missing_items_hash: hash,
    missing_items: missingLabels,
    gmail_message_id: sentGmailId,
    nag_message_id_rfc: rfcMsgId,
    trigger_email_id: triggerMessageId,
  });
  return true;
}

// ---------- Label + archive ----------

// Apply the Wrapups label + remove INBOX at the MESSAGE level (not thread
// level). CPR reply threads contain multiple replies from different
// teammates; thread-level labeling would archive/hide siblings that still
// Label the incoming Gmail message with our "Wrapups" label + remove from
// INBOX. Both signals so future wrapup ingest runs know these messages don't
// need to be processed. This uses GMAIL_ADD_LABEL_TO_EMAIL which only
// touches the one message.
async function labelAndArchive(
  ctx: WrapupCtx,
  messageId: string,
  _threadId: string | undefined,
): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: {
        message_id: messageId,
        remove_label_ids: ["INBOX"],
        add_label_ids: [WRAPUPS_LABEL_ID],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn("wrapup label+archive threw (non-fatal):", e);
  }
}

// ---------- Body extraction ----------

function wupExtractBestBody(msg: any): string {
  const direct: string | undefined =
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
  if (typeof direct === "string" && direct.trim().length > 20) return direct;

  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const plain = wupFindPart(parts, "text/plain");
  if (plain) {
    const decoded = wupDecodeBase64Url(plain?.body?.data ?? "");
    if (decoded && decoded.trim().length > 20) return decoded;
  }
  const html = wupFindPart(parts, "text/html");
  if (html) {
    const decoded = wupDecodeBase64Url(html?.body?.data ?? "");
    if (decoded) return wupStripHtml(decoded);
  }
  const bodyDirect = wupDecodeBase64Url(msg?.payload?.body?.data ?? "");
  if (bodyDirect && bodyDirect.trim().length > 20) return bodyDirect;
  return "";
}

function wupFindPart(parts: any[], mimeType: string): any {
  for (const p of parts) {
    if (p?.mimeType === mimeType) return p;
    if (p?.parts) {
      const nested = wupFindPart(p.parts, mimeType);
      if (nested) return nested;
    }
  }
  return null;
}

function wupDecodeBase64Url(s: string): string {
  if (!s) return "";
  try {
    const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - b64.length % 4) % 4);
    return atob(padded);
  } catch {
    return "";
  }
}

function wupStripHtml(html: string): string {
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

// ==================== parsers/wrapup_no_send.ts ====================
// Wrap-up no-send check parser (2026-07-22).
//
// Purpose: fires once at Fri 7 PM CT (via cron `0 0 * * 6` UTC). Checks
// which teammates have submitted NO wrap-up yet for the current week and:
//   1. Emails each missing teammate (to: teammate SF email, cc: Peter)
//   2. Sends ONE group Telegram message via pjsagencybot to PJS Agency
//      chat naming every missing teammate
//
// Design choices (Peter directive 2026-07-22):
// - Recipient of email = teammate + Peter cc'd (not whole team)
// - Telegram = single GROUP message via pjsagencybot (not personal DM)
// - Single fire per week (no repeat throttle needed structurally, but
//   wrapup_nag_log hash guard added for defense against duplicate cron ticks)
// - dry_run: true in body → compose but do not send; return would-send list
//
// Related: parsers/wrapup_ingest.ts (per-partial-submission nag path)


export interface WrapupNoSendCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}

export interface WrapupNoSendBody {
  mode: "no_send_check";
  dry_run?: boolean;         // If true: no sends, just return plan
  target_week?: string;      // Optional YYYY-MM-DD override; else computed
}

interface MissingTeammate {
  id: string;
  first_name: string;
  email_sf: string;
}

// Compute the current week-ending Saturday in CT. Fri 7 PM CT (= Sat 00:00 UTC)
// tick lands on Fri CT wall-clock → target Sat is tomorrow.
function currentSaturdayCT(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    year: "numeric", month: "2-digit", day: "2-digit", weekday: "short",
  }).formatToParts(now);
  const y = parts.find(p => p.type === "year")!.value;
  const m = parts.find(p => p.type === "month")!.value;
  const d = parts.find(p => p.type === "day")!.value;
  const wd = parts.find(p => p.type === "weekday")!.value;
  const dayIdx: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  const idx = dayIdx[wd] ?? 0;
  // Days forward to next Sat (Sat itself → 0)
  const daysOffset = idx === 6 ? 0 : 6 - idx;
  const base = new Date(`${y}-${m}-${d}T12:00:00Z`);
  base.setUTCDate(base.getUTCDate() + daysOffset);
  return base.toISOString().slice(0, 10);
}

const PETER_SF_EMAIL = "peter.story.yrru@statefarm.com";
const NO_SEND_MARKER = "__NO_SEND__";

export async function processWrapupNoSendMode(
  ctx: WrapupNoSendCtx,
  body: WrapupNoSendBody,
): Promise<Record<string, unknown>> {
  const startedAt = new Date().toISOString();
  const dryRun = body.dry_run === true;
  const targetWeek = body.target_week || currentSaturdayCT(new Date());

  console.log(`[no_send_check] target_week=${targetWeek} dry_run=${dryRun}`);

  // 1. Look up weekly_cpr_reports row for the target week
  const { data: reportRow, error: reportErr } = await sb
    .from("weekly_cpr_reports")
    .select("id")
    .eq("agency_id", ctx.agencyId)
    .eq("week_ending_date", targetWeek)
    .maybeSingle();
  if (reportErr) {
    console.error(`[no_send_check] weekly_cpr_reports lookup failed: ${reportErr.message}`);
    return { ok: false, error: `weekly_cpr_reports lookup: ${reportErr.message}`, target_week: targetWeek, started_at: startedAt };
  }
  if (!reportRow?.id) {
    console.log(`[no_send_check] no weekly_cpr_reports row for ${targetWeek} — cannot check`);
    return { ok: true, target_week: targetWeek, missing: [], skipped: "no_report_row", dry_run: dryRun, started_at: startedAt };
  }

  // 2. Pull rostered teammates who have NO wrapup_text yet
  //    Filter matches wrapup_ingest.ts (agency, active, not archived,
  //    not admin_backoffice, not Owner).
  const { data: teamRows, error: teamErr } = await sb
    .from("team")
    .select("id, first_name, email_sf, role_level, weekly_cpr_team_detail!inner(wrapup_text,weekly_cpr_report_id)")
    .eq("agency_id", ctx.agencyId)
    .eq("category", "agency")
    .eq("is_active", true)
    .is("archived_at", null)
    .eq("is_admin_backoffice", false)
    .eq("weekly_cpr_team_detail.weekly_cpr_report_id", reportRow.id);
  if (teamErr) {
    console.error(`[no_send_check] roster query failed: ${teamErr.message}`);
    return { ok: false, error: `roster query: ${teamErr.message}`, target_week: targetWeek, started_at: startedAt };
  }

  const missing: MissingTeammate[] = [];
  for (const row of teamRows || []) {
    // Skip Owner (Peter)
    if ((row.role_level || "") === "Owner") continue;
    const details = (row as any).weekly_cpr_team_detail as Array<{ wrapup_text: string | null }>;
    const anyText = (details || []).some(d => (d.wrapup_text || "").trim().length > 0);
    if (anyText) continue;
    const email = (row.email_sf || "").trim();
    if (!email) continue;  // Can't email them, skip
    missing.push({ id: row.id, first_name: row.first_name, email_sf: email });
  }

  console.log(`[no_send_check] ${missing.length} missing teammate(s): ${missing.map(m => m.first_name).join(", ")}`);

  if (missing.length === 0) {
    return { ok: true, target_week: targetWeek, missing: [], dry_run: dryRun, started_at: startedAt, finished_at: new Date().toISOString() };
  }

  // 3. Compose email per missing teammate; hash-throttle via wrapup_nag_log
  const hashRes = await sb.rpc("wrapup_missing_items_hash", { p_missing: [NO_SEND_MARKER] });
  const hash: string = (hashRes.data as string) || "";
  if (!hash) {
    return { ok: false, error: "hash computation failed", target_week: targetWeek, started_at: startedAt };
  }

  const emailResults: Array<Record<string, unknown>> = [];
  for (const tm of missing) {
    // Throttle check
    const { data: prior } = await sb
      .from("wrapup_nag_log")
      .select("id")
      .eq("agency_id", ctx.agencyId)
      .eq("team_member_id", tm.id)
      .eq("week_ending_date", targetWeek)
      .eq("missing_items_hash", hash)
      .maybeSingle();
    if (prior?.id) {
      console.log(`[no_send_check] ${tm.first_name}: already logged for week ${targetWeek}, skipping`);
      emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, skipped: "already_logged" });
      continue;
    }

    // Belt-and-suspenders: even if wrapup_text is empty on the current-week
    // detail row, scan Gmail directly for any wrap-up-shaped email from this
    // teammate in the last 4 days. If found, the parser may have silently
    // failed to process/route/label it — nagging would be a false positive.
    // Skip and log an alert so Peter knows the parser needs attention.
    const gmailScan = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_FETCH_EMAILS",
      toolArguments: {
        query: `from:${tm.email_sf} (subject:wrap-up OR subject:wrapup OR subject:"wrap up" OR subject:"CPR RECAP") -in:sent newer_than:4d`,
        max_results: 3,
        user_id: "me",
        include_payload: false,
        verbose: false,
      },
    });
    if (gmailScan.ok) {
      const scanMsgs: any[] = (gmailScan.data as any)?.messages ?? (gmailScan.data as any)?.response_data?.messages ?? [];
      if (scanMsgs.length > 0) {
        console.warn(`[no_send_check] ${tm.first_name}: wrapup_text empty on ${targetWeek} row BUT ${scanMsgs.length} wrap-up-shaped email(s) found in Gmail — parser may have silently failed. Skipping nag.`);
        // Fire an alert so Peter knows to investigate
        try {
          // FIXED 2026-08-04: alerts has `message` (not `body`) and alert_type
          // is NOT NULL — this insert had been failing silently since ship.
          const { error: alertErr } = await sb.from("alerts").insert({
            agency_id: ctx.agencyId,
            alert_type: "wrapup_parser_stuck",
            module_reference: "wrapup_ingest",
            severity: "warning",
            title: `Wrap-up parser possibly stuck — ${tm.first_name}`,
            message: `No-send checker found ${scanMsgs.length} wrap-up-shaped email(s) from ${tm.first_name} in the last 4 days but wrapup_text is empty on the ${targetWeek} team_detail row. Nag suppressed. Investigate wrapup_ingest recipe logs.`,
            is_resolved: false,
          });
          if (alertErr) console.warn(`[no_send_check] alert insert error for ${tm.first_name}: ${alertErr.message}`);
        } catch (e) {
          console.warn(`[no_send_check] alert insert failed for ${tm.first_name}:`, e);
        }
        emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, skipped: "gmail_shows_wrapup_present", gmail_count: scanMsgs.length });
        continue;
      }
    }

    const subject = `Wrap-up — haven't seen yours yet this week`;
    const body =
`Hey ${tm.first_name},

Haven't seen your wrap-up email land yet. Send it before Saturday so it lands in this week's CPR.

The six items:

  1. Personal life and annuity status updates — your book, pending apps, upcoming reviews
  2. Lapse/cancel trends + individual highlights — trends you're seeing and specific wins
  3. Personal obstacles you're running into + solutions you propose
  4. Your plan for a 1% increase in sales points next week
  5. A recommendation to make the office more efficient / remove pain points for the whole team
  6. Brags on teammates — something you saw them do that matched our mission statement or job description

Reply here or fire a fresh email — whichever's easier.

— Peter
`;

    if (dryRun) {
      emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, would_send_to: tm.email_sf, cc: PETER_SF_EMAIL, subject, dry_run: true });
      continue;
    }

    // Live send
    const sendRes = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_SEND_EMAIL",
      toolArguments: {
        recipient_email: tm.email_sf,
        cc: [PETER_SF_EMAIL],
        subject,
        body,
        is_html: false,
        user_id: "me",
      },
    });
    if (!sendRes.ok) {
      console.warn(`[no_send_check] send failed for ${tm.first_name}: ${sendRes.error}`);
      emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, error: sendRes.error });
      continue;
    }

    const sentGmailId: string | null =
      sendRes.data?.id ?? sendRes.data?.messageId ?? sendRes.data?.response_data?.id ?? null;

    await sb.from("wrapup_nag_log").insert({
      agency_id: ctx.agencyId,
      team_member_id: tm.id,
      week_ending_date: targetWeek,
      missing_items_hash: hash,
      missing_items: [NO_SEND_MARKER],
      gmail_message_id: sentGmailId,
      trigger_email_id: null,
    });

    emailResults.push({ team_member_id: tm.id, first_name: tm.first_name, sent: true, gmail_message_id: sentGmailId });
  }

  // 4. Send ONE group Telegram message via pjsagencybot to PJS Agency chat
  const missingNames = missing.map(m => m.first_name).join(", ");
  const telegramText =
`📝 Wrap-up not in yet from: ${missingNames}

Send it before Saturday so it lands in this week's CPR — reply to any wrap-up thread or fire a fresh email.`;

  let telegramResult: Record<string, unknown>;
  if (dryRun) {
    telegramResult = { would_send: true, chat_id: -5377408548, text_preview: telegramText, dry_run: true };
  } else {
    // Pull chat_id from settings for defense in depth (default matches op-rule)
    const { data: chatIdSetting } = await sb
      .from("settings")
      .select("setting_value")
      .eq("setting_key", "telegram_team_group_chat_id")
      .maybeSingle();
    const chatId = chatIdSetting?.setting_value ? parseInt(chatIdSetting.setting_value, 10) : -5377408548;

    const tgRes = await sb.rpc("telegram_send_message_v2", {
      p_chat_id: chatId,
      p_text: telegramText,
      p_bot: "pjsagency",
    });
    if (tgRes.error) {
      console.warn(`[no_send_check] telegram group send failed: ${tgRes.error.message}`);
      telegramResult = { error: tgRes.error.message };
    } else {
      telegramResult = { sent: true, chat_id: chatId, response: tgRes.data };
    }
  }

  return {
    ok: true,
    mode: "no_send_check",
    target_week: targetWeek,
    dry_run: dryRun,
    missing_count: missing.length,
    email_results: emailResults,
    telegram_result: telegramResult,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
  };
}

// ==================== parsers/paypal_print_sales.ts ====================
// =========================================================================
// parsers/paypal_print_sales.ts
// =========================================================================
// Processes PayPal "you received a payment" notifications for PaperNewt
// print sales, forwarded by Marie from marie.t.story@gmail.com (or, if
// PayPal is ever pointed directly at paper.newt.management@gmail.com in the
// future, straight from service@paypal.com).
//
// Called via document-processor mode="paypal_print_sales".
//
// These emails carry NO attachment — the invoice/payment details are the
// email body itself. That is why this is a "mode" (like wrapup_ingest,
// careerplug_applicant) rather than a classifyDocument() docType: the normal
// attachment pipeline (fetchNewGmailAttachments → processOneAttachment) only
// ever sees messages that have at least one attachment, so a body-only
// PayPal forward would never reach it.
//
// Flow per matched Gmail message:
//   1. Fetch full message.
//   2. Confirm subject/body actually says "paid for your invoice" (belt,
//      since the Gmail query already filters on this).
//   3. Extract invoice #, USD amount, and payer name via regex on the
//      subject + plaintext body (PayPal's notification format is fixed —
//      see the two 2026-08 samples this was written against: invoices
//      0059 and 0061).
//   4. Idempotency: skip if reference_number PAYPAL-INV-<n> already exists
//      in ledger.
//   5. Resolve the PaperNewt Print Sales income account (code 4300 on
//      entity b1111111) and insert ONE ledger row crediting it — this
//      agency's ledger is single-entry per transaction (see
//      statement_gl_writer output), not double-entry; there is no
//      offsetting "cash" leg to write here.
//   6. Best-effort, non-fatal: save the notification's HTML body to the
//      Print Sales Drive folder.
//   7. Label Operations/Print Sales + archive (strip INBOX/UNREAD) — ONLY
//      after the ledger insert in step 5 is confirmed. A message that
//      fails extraction or account resolution is left alone in the inbox
//      so it surfaces on the next run instead of silently vanishing.
//
// Deliberately NOT done here, per explicit instruction: no __SKIP__ or
// classification rule for the eventual PayPal-to-real-bank transfer. The
// balance-sheet guard already prevents double-counting income when that
// transfer lands in a tracked account — the deposit stays unclassified
// until manually pointed at the PayPal cash account (code 1060,
// "PaperNewt Printing") once that account's statement pipeline exists.
// =========================================================================

// deno-lint-ignore-file no-explicit-any


const PAYPAL_LABEL_ID = "Label_33"; // Gmail label "Operations/Print Sales" (paper.newt.management@gmail.com)
const PRINTSALES_DRIVE_FOLDER_ID = "1YUlKCgCVgKy0jEWH0sRnCbdjp6Zo-oyl"; // Drive: Operations/Print Sales
const PAPERNEWT_ENTITY_ID = "b1111111-1111-1111-1111-111111111111";
const PRINT_SALES_ACCOUNT_CODE = "4300"; // "Print Sales" (shared_concept code), display-named "PaperNewt Print Sales" for this entity

export interface PaypalCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId?: string;
}

export interface PaypalBody {
  gmail_query?: string;
  max_results?: number;
}

interface OnePaypalResult {
  status: "processed" | "skipped" | "error";
  message_id: string;
  invoice_number: string | null;
  amount: number | null;
  reference_number: string | null;
  error?: string;
}

export async function processPaypalPrintSalesMode(ctx: PaypalCtx, body: PaypalBody) {
  // -label excludes messages we've already processed (they carry the label
  // after archiving). Sender clause covers both Marie's forwards (current
  // reality) and a possible future direct PayPal send.
  const defaultQuery =
    `(from:marie.t.story@gmail.com OR from:service@paypal.com) subject:"paid for your invoice" -label:${PAYPAL_LABEL_ID}`;
  const query = body.gmail_query ?? defaultQuery;
  const maxResults = body.max_results ?? 20;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query, max_results: maxResults, user_id: "me", include_payload: false, verbose: false },
  });
  if (!listRes.ok) {
    return { ok: false, processed: 0, skipped: 0, errors: 1, message_count: 0, results: [], error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: OnePaypalResult[] = [];
  let processed = 0;
  let skipped = 0;
  let errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processOnePaypalMessage(ctx, msgId);
      results.push(r);
      if (r.status === "processed") processed++;
      else if (r.status === "skipped") skipped++;
      else errors++;
    } catch (e) {
      errors++;
      results.push({
        status: "error", message_id: msgId, invoice_number: null, amount: null, reference_number: null,
        error: e instanceof Error ? e.message : String(e),
      });
    }
    // Small breath between messages, matching the pattern used elsewhere in
    // this function for Gmail/Groq rate-limit headroom during backfill.
    await new Promise((r) => setTimeout(r, 500));
  }

  return { ok: true, processed, skipped, errors, message_count: messages.length, results };
}

async function processOnePaypalMessage(ctx: PaypalCtx, messageId: string): Promise<OnePaypalResult> {
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: { message_id: messageId, format: "full", user_id: "me" },
  });
  if (!msgRes.ok) {
    return { status: "error", message_id: messageId, invoice_number: null, amount: null, reference_number: null, error: `fetch: ${msgRes.error}` };
  }
  const msg: any = msgRes.data?.response_data ?? msgRes.data ?? {};
  const headers = msg?.payload?.headers ?? [];
  const hget = (name: string): string => headers.find((h: any) => h?.name === name)?.value ?? "";
  const subject: string = msg?.subject ?? hget("Subject");
  const receivedAtISO: string =
    (typeof msg?.messageTimestamp === "string" && msg.messageTimestamp)
      || (msg?.internalDate ? new Date(Number(msg.internalDate)).toISOString() : "")
      || new Date().toISOString();

  const bodyText = ppExtractBestBody(msg, "text/plain");
  const bodyHtml = ppExtractBestBody(msg, "text/html");
  const combined = `${subject}\n${bodyText}`;

  if (!/paid for your invoice/i.test(combined)) {
    await ppLabelAndArchive(ctx, messageId);
    return { status: "skipped", message_id: messageId, invoice_number: null, amount: null, reference_number: null, error: "did not match 'paid for your invoice'" };
  }

  // "... paid for your invoice # 0059" (subject) / "Invoice #\n0059" (body)
  const invMatch = combined.match(/invoice\s*#\s*(\d+)/i);
  const invoiceNumber = invMatch ? invMatch[1] : null;

  // "You received a $143.33 USD payment" / "Amount paid ... $143.33 USD"
  const amtMatch =
    combined.match(/\$([\d,]+\.\d{2})\s*USD\s*payment/i) ||
    combined.match(/Amount paid\D*\$([\d,]+\.\d{2})/i);
  const amount = amtMatch ? parseFloat(amtMatch[1].replace(/,/g, "")) : null;

  // "Matt Friess paid for your invoice" (subject)
  const payerMatch = subject.match(/^(?:Fwd:\s*)?(.+?)\s+paid for your invoice/i);
  const payerFull = payerMatch ? payerMatch[1].trim() : null;
  const payerParts = payerFull ? payerFull.split(/\s+/) : [];
  const payerFirst = payerParts[0] ?? "";
  const payerLastInitial = payerParts[1]?.[0] ?? "";

  if (!invoiceNumber || amount === null) {
    return {
      status: "error", message_id: messageId, invoice_number: invoiceNumber, amount, reference_number: null,
      error: "could not extract invoice number or amount from subject/body",
    };
  }

  const referenceNumber = `PAYPAL-INV-${invoiceNumber}`;

  const { data: existing } = await sb.from("ledger").select("id").eq("reference_number", referenceNumber).maybeSingle();
  if (existing) {
    await ppLabelAndArchive(ctx, messageId);
    return { status: "skipped", message_id: messageId, invoice_number: invoiceNumber, amount, reference_number: referenceNumber, error: "already booked" };
  }

  const { data: acct, error: acctErr } = await sb
    .from("chart_of_accounts")
    .select("id")
    .eq("agency_id", ctx.agencyId)
    .eq("account_code", PRINT_SALES_ACCOUNT_CODE)
    .eq("business_entity_id", PAPERNEWT_ENTITY_ID)
    .maybeSingle();
  if (acctErr || !acct) {
    return {
      status: "error", message_id: messageId, invoice_number: invoiceNumber, amount, reference_number: referenceNumber,
      error: `Print Sales account (code ${PRINT_SALES_ACCOUNT_CODE}) not found on PaperNewt entity`,
    };
  }

  const entryDate = receivedAtISO.slice(0, 10);
  const description = `PayPal print sale — invoice #${invoiceNumber} — ${payerFirst}${payerLastInitial ? " " + payerLastInitial + "." : ""}`.trim();

  const { error: insErr } = await sb.from("ledger").insert({
    agency_id: ctx.agencyId,
    account_id: acct.id,
    debit: 0,
    credit: amount,
    entry_date: entryDate,
    entry_type: "manual",
    source: "paypal_print_sales",
    reference_number: referenceNumber,
    description,
    classification_status: "classified",
    classified_by: "document-processor:paypal_print_sales",
    classified_at: new Date().toISOString(),
  });
  if (insErr) {
    return {
      status: "error", message_id: messageId, invoice_number: invoiceNumber, amount, reference_number: referenceNumber,
      error: `ledger insert: ${insErr.message}`,
    };
  }

  // Best-effort archival of the raw notification. A failure here must never
  // undo the ledger insert above — the money is already correctly booked.
  if (ctx.driveAccountId && bodyHtml) {
    try {
      await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.driveAccountId,
        toolSlug: "GOOGLEDRIVE_CREATE_FILE_FROM_TEXT",
        toolArguments: {
          file_name: `PayPal Invoice ${invoiceNumber} — ${entryDate}.html`,
          text_content: bodyHtml,
          mime_type: "text/html",
          parent_id: PRINTSALES_DRIVE_FOLDER_ID,
        },
      });
    } catch (e) {
      console.warn("paypal_print_sales drive upload threw (non-fatal):", e);
    }
  }

  // Archive fires only after the ledger insert above is confirmed.
  await ppLabelAndArchive(ctx, messageId);

  return { status: "processed", message_id: messageId, invoice_number: invoiceNumber, amount, reference_number: referenceNumber };
}

async function ppLabelAndArchive(ctx: PaypalCtx, messageId: string): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: {
        message_id: messageId,
        remove_label_ids: ["INBOX", "UNREAD"],
        add_label_ids: [PAYPAL_LABEL_ID],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn("paypal_print_sales label+archive threw (non-fatal):", e);
  }
}

// ---------- Body extraction (local copies — see wrapup_ingest.ts's wup*
// equivalents; kept separate on purpose so this file has no cross-parser
// symbol dependency and the bundler needs no rename entry for it) ----------

function ppExtractBestBody(msg: any, mimeType: "text/plain" | "text/html"): string {
  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const part = ppFindPart(parts, mimeType);
  if (part) {
    const decoded = ppDecodeBase64Url(part?.body?.data ?? "");
    if (decoded) return decoded;
  }
  if (mimeType === "text/plain") {
    const direct: string | undefined = msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
    if (typeof direct === "string" && direct.trim().length > 0) return direct;
  }
  const bodyDirect = ppDecodeBase64Url(msg?.payload?.body?.data ?? "");
  return bodyDirect || "";
}

function ppFindPart(parts: any[], mimeType: string): any {
  for (const p of parts) {
    if (p?.mimeType === mimeType) return p;
    if (p?.parts) {
      const nested = ppFindPart(p.parts, mimeType);
      if (nested) return nested;
    }
  }
  return null;
}

function ppDecodeBase64Url(s: string): string {
  if (!s) return "";
  try {
    const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - b64.length % 4) % 4);
    return atob(padded);
  } catch {
    return "";
  }
}

// ==================== parsers/amazon_order_email.ts ====================
// =========================================================================
// parsers/amazon_order_email.ts
// =========================================================================
// Live capture of Amazon "Ordered:" confirmation emails from
// auto-confirm@amazon.com. These land in paper.newt.management@gmail.com
// (Delivered-To confirmed 2026-08-18) and are auto-filtered by an existing
// Gmail filter into Label_12 ("Operations/Amazon Transactions") — that
// filter is untouched by this parser; it only reads the label, never
// creates or modifies it.
//
// Called via document-processor mode="amazon_order_email".
//
// WHY LIVE EMAIL, NOT THE CSV ORDER-HISTORY REPORT (2026-08-18 decision):
// The live emails carry no payment card and no per-item price — only
// order #, ship-to name/city/state, a single grand total, a coarse
// category from the subject line ("Ordered: 1 Bedding item"), and item
// count. That is deliberately treated as ENOUGH: Peter does not want
// periodic manual CSV re-uploads, and per-item categorization was judged
// not worth that cost. Entity/card attribution instead comes from
// match_amazon_orders_to_cash_register() (Postgres function, agency
// migration 2026-08-18), which matches each order's grand_total + date
// against cash_register_preliminary (exact amount, date window) and
// resolves the matched row's card to a business_entity_id via the
// accounts table (checking account_number_last4 and alternate_last4s).
// This parser calls that function once per batch after upserting orders.
//
// Idempotency: STARRED is the processed marker (same convention as
// call_log, careerplug, paypal_print_sales in this file set). A message
// already starred is excluded by the query and never re-parsed. Separately,
// amazon_orders.order_id is the primary key, so even a re-parsed message
// cannot double-insert — ON CONFLICT DO NOTHING protects the historical
// CSV-imported rows (source=csv_import) from ever being overwritten by a
// same-order live email.
// =========================================================================

// deno-lint-ignore-file no-explicit-any


const AMAZON_LABEL_ID = "Label_12"; // "Operations/Amazon Transactions" — pre-existing filter target, read-only here

export interface AmazonOrderEmailCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
}

export interface AmazonOrderEmailBody {
  gmail_query?: string;
  max_results?: number;
}

interface OneAmazonResult {
  status: "processed" | "skipped" | "error";
  message_id: string;
  order_id: string | null;
  grand_total: number | null;
  category: string | null;
  error?: string;
}

// Left-to-right isolate marks (U+2066 / U+2069) Amazon wraps the item count
// in — e.g. "Ordered: \u20661\u2069 Bedding item". Strip before matching.
function stripIsolates(s: string): string {
  return s.replace(/[\u2066\u2067\u2068\u2069]/g, "");
}

export async function processAmazonOrderEmailMode(ctx: AmazonOrderEmailCtx, body: AmazonOrderEmailBody) {
  const defaultQuery = `from:auto-confirm@amazon.com subject:"Ordered:" -label:starred`;
  const query = body.gmail_query ?? defaultQuery;
  const maxResults = body.max_results ?? 50;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query, max_results: maxResults, user_id: "me", include_payload: false, verbose: false },
  });
  if (!listRes.ok) {
    return { ok: false, processed: 0, skipped: 0, errors: 1, message_count: 0, matched: 0, results: [], error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: OneAmazonResult[] = [];
  let processed = 0;
  let skipped = 0;
  let errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processOneAmazonMessage(ctx, msgId);
      results.push(r);
      if (r.status === "processed") processed++;
      else if (r.status === "skipped") skipped++;
      else errors++;
    } catch (e) {
      errors++;
      results.push({
        status: "error", message_id: msgId, order_id: null, grand_total: null, category: null,
        error: e instanceof Error ? e.message : String(e),
      });
    }
    // Small breath between messages — same rate-limit headroom pattern used
    // elsewhere in this pipeline.
    await new Promise((r) => setTimeout(r, 300));
  }

  // Attempt entity attribution for any orders (this run or prior runs) that
  // are still unmatched — safe to call every run, touches only rows with
  // target_business_entity_id IS NULL.
  let matched = 0;
  try {
    const { data: matchRows, error: matchErr } = await sb.rpc("match_amazon_orders_to_cash_register", {
      p_agency_id: ctx.agencyId,
    });
    if (!matchErr && Array.isArray(matchRows)) {
      matched = matchRows.filter((r: any) => r.matched === true).length;
    }
  } catch (e) {
    console.warn("match_amazon_orders_to_cash_register call threw (non-fatal):", e);
  }

  return { ok: true, processed, skipped, errors, message_count: messages.length, matched, results };
}

async function processOneAmazonMessage(ctx: AmazonOrderEmailCtx, messageId: string): Promise<OneAmazonResult> {
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: { message_id: messageId, format: "full", user_id: "me" },
  });
  if (!msgRes.ok) {
    return { status: "error", message_id: messageId, order_id: null, grand_total: null, category: null, error: `fetch: ${msgRes.error}` };
  }
  const msg: any = msgRes.data?.response_data ?? msgRes.data ?? {};
  const subjectRaw: string = msg?.subject ?? "";
  const subject = stripIsolates(subjectRaw);
  const receivedAtISO: string =
    (typeof msg?.messageTimestamp === "string" && msg.messageTimestamp)
      || (msg?.internalDate ? new Date(Number(msg.internalDate)).toISOString() : "")
      || new Date().toISOString();

  const bodyText = aoeExtractBestBody(msg, "text/plain");

  // Subject: "Ordered: N <Category> item" or "... items"
  const subjMatch = subject.match(/Ordered:\s*(\d+)\s+(.+?)\s+items?\s*$/i);
  const itemCount = subjMatch ? parseInt(subjMatch[1], 10) : null;
  const category = subjMatch ? subjMatch[2].trim() : null;

  if (!subjMatch) {
    // Doesn't match the expected subject shape at all — leave un-starred so
    // it surfaces for manual review rather than silently vanishing.
    return { status: "error", message_id: messageId, order_id: null, grand_total: null, category: null, error: `subject did not match expected pattern: "${subject}"` };
  }

  // Body: "Order #\n114-XXXXXXX-XXXXXXX"
  const orderIdMatch = bodyText.match(/Order #\r?\n(\S+)/);
  const orderId = orderIdMatch ? orderIdMatch[1].trim() : null;

  // Body: "Grand Total:\n27.24 USD"
  const totalMatch = bodyText.match(/Grand Total:\r?\n([\d,]+\.\d+)\s*USD/i);
  const grandTotal = totalMatch ? parseFloat(totalMatch[1].replace(/,/g, "")) : null;

  // Body: "Thomas - MACHIPONGO, VA" on its own line, followed (after blank
  // lines) by "Order #". Name may contain spaces; city is letters/spaces;
  // state is a 2-letter code.
  const shipToMatch = bodyText.match(/\n([A-Za-z][A-Za-z .'-]*) - ([A-Za-z .]+), ([A-Z]{2})\r?\n/);
  const shipToName = shipToMatch ? shipToMatch[1].trim() : null;
  const shipToAddress = shipToMatch ? `${shipToMatch[2].trim()}, ${shipToMatch[3]}` : null;

  if (!orderId || grandTotal === null) {
    return {
      status: "error", message_id: messageId, order_id: orderId, grand_total: grandTotal, category,
      error: `could not extract order_id or grand_total from body`,
    };
  }

  const { error: insErr } = await sb.from("amazon_orders").insert({
    order_id: orderId,
    agency_id: ctx.agencyId,
    order_date: receivedAtISO,
    order_status: "ordered",
    website: "amazon.com",
    currency: "USD",
    ship_to_name: shipToName,
    ship_to_address: shipToAddress,
    grand_total: grandTotal,
    item_count: itemCount,
    category,
    source: "email_live",
  }, { count: undefined }).select("order_id");
  // Duplicate order_id (e.g. re-processed thread, or overlap with a
  // CSV-imported historical row) is expected and not an error — the row
  // already exists, so just mark this message processed and move on.
  if (insErr && (insErr as any).code !== "23505") {
    return {
      status: "error", message_id: messageId, order_id: orderId, grand_total: grandTotal, category,
      error: `amazon_orders insert: ${insErr.message}`,
    };
  }

  await aoeStarMessage(ctx, messageId);

  return { status: "processed", message_id: messageId, order_id: orderId, grand_total: grandTotal, category };
}

async function aoeStarMessage(ctx: AmazonOrderEmailCtx, messageId: string): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: {
        message_id: messageId,
        add_label_ids: ["STARRED"],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn("amazon_order_email star threw (non-fatal):", e);
  }
}

// ---------- Body extraction (local copy — see paypal_print_sales.ts's pp*
// equivalents; kept separate on purpose so this file has no cross-parser
// symbol dependency and the bundler needs no rename entry for it) ----------

function aoeExtractBestBody(msg: any, mimeType: "text/plain" | "text/html"): string {
  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const part = aoeFindPart(parts, mimeType);
  if (part) {
    const decoded = aoeDecodeBase64Url(part?.body?.data ?? "");
    if (decoded) return decoded;
  }
  if (mimeType === "text/plain") {
    const direct: string | undefined = msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
    if (typeof direct === "string" && direct.trim().length > 0) return direct;
  }
  const bodyDirect = aoeDecodeBase64Url(msg?.payload?.body?.data ?? "");
  return bodyDirect || "";
}

function aoeFindPart(parts: any[], mimeType: string): any {
  for (const p of parts) {
    if (p?.mimeType === mimeType) return p;
    if (p?.parts) {
      const nested = aoeFindPart(p.parts, mimeType);
      if (nested) return nested;
    }
  }
  return null;
}

function aoeDecodeBase64Url(s: string): string {
  if (!s) return "";
  try {
    const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
    const padded = b64 + "=".repeat((4 - b64.length % 4) % 4);
    return atob(padded);
  } catch {
    return "";
  }
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
  // Drive folder that recovered scanned files get filed into. Null puts them
  // in the Drive root.
  driveParentFolderId?: string | null;
  // Fixed folders for doc types that file by type, not by account (2026-08-09
  // Drive/Gmail reorg: Comp + Deductions merged into one "Comp - Deduct"
  // folder; Payroll lives under Team/Payroll). Falls through to the generic
  // Documents/<month>/<type> tree under driveParentFolderId if unset.
  driveCompDeductFolderId?: string | null;
  drivePayrollFolderId?: string | null;
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

  // Set when a documents row already exists for this attachment but was left
  // mid-flight, and the file is being offered again. The handler updates that
  // row instead of inserting a second one. See retryableDocumentId().
  retryDocumentId?: string | null;
  retryCount?: number;
}

// Statuses that mean a documents row is finished, deliberately parked, or owned
// by another process. A row in any of these is never offered again:
//   processed / filed / archived / skipped / duplicate  finished
//   error                        finished; an alert was already raised
//   unpacked                     zip container, already expanded
//   archive_failed               document handled; only the Gmail archive failed
//   queued_for_llm               llm-queue-drainer owns it
//   stored_pending_walkthrough   deliberately held for review
//   held_reconciliation_mismatch deliberately held for review
const DOC_STATUS_NO_RETRY = new Set([
  "processed", "filed", "archived", "skipped", "duplicate", "error",
  "unpacked", "archive_failed", "queued_for_llm",
  "stored_pending_walkthrough", "held_reconciliation_mismatch",
]);

const DOC_MAX_RETRIES = 3;

/**
 * A documents row already exists for this attachment. Decide whether it
 * represents finished work (skip the file) or a run that died partway through
 * (offer the file again).
 *
 * Found 2026-08-04: in a 143-file resume backlog run, four files had their
 * documents row inserted and then the run ended — wall clock, most likely —
 * before the handler reached a terminal status. They sat at "received"
 * indefinitely, because the duplicate check above skipped any existing row
 * regardless of its status, so the file was never offered again. That is silent,
 * permanent loss of a real applicant. Three older rows were stranded the same
 * way, two of them credit-card statement bundles.
 *
 * Returns the document id to reuse when the row should be retried, else null.
 * The attempt counter keeps a document that dies every single time from being
 * picked up on every tick forever.
 */
function retryableDocumentId(
  existing: { id?: string; processing_status?: string; retry_count?: number } | null | undefined,
  fileName: string,
): string | null {
  if (!existing?.id) return null;
  const status = existing.processing_status ?? "";
  if (DOC_STATUS_NO_RETRY.has(status)) return null;
  const tries = existing.retry_count ?? 0;
  if (tries >= DOC_MAX_RETRIES) {
    console.warn(`[fetch] ${fileName}: document ${existing.id} still at "${status}" after ${tries} attempts — giving up, not offering again`);
    return null;
  }
  console.log(`[fetch] ${fileName}: offering document ${existing.id} again, stuck at "${status}" (attempt ${tries + 1} of ${DOC_MAX_RETRIES})`);
  return existing.id;
}

async function fetchNewGmailAttachments(
  ctx: RunCtx,
  opts?: { query?: string; maxResults?: number },
): Promise<AttachmentInput[]> {
  // Look back 7 days to catch anything we missed between cron ticks.
  // Idempotency is enforced per-file inside the loop.
  //
  // OVERRIDE (body.gmail_query / body.max_results): this fetcher is the only
  // door into ingestion, so a 7-day-only window means an email missed for any
  // reason becomes permanently unreachable and has to be hand-entered. Passing
  // a Gmail search string pushes a specific stuck message through the REAL
  // pipeline — same classify, same parsers, same reconcile — instead of
  // someone typing statement figures in by hand. Default behaviour unchanged.
  const lookback = opts?.query ?? "newer_than:7d has:attachment";
  const maxResults = opts?.maxResults ?? 50;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query: lookback, max_results: maxResults },
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

        // Idempotency: (gmail_message_id, file_name). Message ID is a stable
        // Gmail identifier; filenames within a single message are unique in
        // practice. Prior key was file_name alone across all-of-gmail, which
        // silently skipped generic-named repeats (SF sending "Payroll Summary.pdf"
        // collided with a legacy row from a prior week). Attachment IDs are
        // NOT stable across Gmail API calls, so cannot be part of the key.
        const msgId = m.messageId ?? m.id;
        const { data: existing } = await sb
          .from("documents")
          .select("id, processing_status, retry_count")
          .eq("agency_id", ctx.agencyId)
          .eq("gmail_message_id", msgId)
          .eq("file_name", filename)
          .maybeSingle();
        const retryId = retryableDocumentId(existing, filename);
        if (existing?.id && !retryId) continue;

        attachments.push({
          retryDocumentId: retryId,
          retryCount: existing?.retry_count ?? 0,
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

      // Idempotency: same as above — (gmail_message_id, file_name).
      const msgId = m.id;
      const { data: existing } = await sb
        .from("documents")
        .select("id, processing_status, retry_count")
        .eq("agency_id", ctx.agencyId)
        .eq("gmail_message_id", msgId)
        .eq("file_name", filename)
        .maybeSingle();
      const retryId = retryableDocumentId(existing, filename);
      if (existing?.id && !retryId) continue;

      attachments.push({
        retryDocumentId: retryId,
        retryCount: existing?.retry_count ?? 0,
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

/**
 * Pull the storage key out of a Composio download link — the link's path IS
 * the key. GOOGLEDRIVE_UPLOAD_FILE wants that key, not a URL and not bytes.
 */
function storageKeyFromDownloadUrl(url: string): string | null {
  try {
    const path = new URL(url).pathname.replace(/^\/+/, "");
    return path.length > 0 ? decodeURIComponent(path) : null;
  } catch {
    return null;
  }
}

async function downloadAttachmentBytes(
  ctx: RunCtx, att: AttachmentInput,
): Promise<{ ok: true; bytesB64: string; s3Key: string | null } | { ok: false; error: string }> {
  // Inner zip files have no storage key of their own — they were never
  // downloaded separately, so there is nothing for Drive to pick up.
  if (att.bytesB64) return { ok: true, bytesB64: att.bytesB64, s3Key: null };
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
      const { res: r, timedOut } = await fetchWithTimeout(s3url, {}, S3_FETCH_TIMEOUT_MS, "s3_download", "generic attachment download");
      if (!r) return { ok: false, error: timedOut ? `s3url fetch timed out` : `s3url fetch failed` };
      if (!r.ok) return { ok: false, error: `s3url fetch returned HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      // Base64-encode in chunks to avoid call-stack issues on large files.
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) {
        bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      }
      return { ok: true, bytesB64: btoa(bin), s3Key: storageKeyFromDownloadUrl(s3url) };
    } catch (e) {
      return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  }
  // Fallback for older Composio response shapes
  const fallback = res.data?.data ?? res.data?.bytes;
  if (typeof fallback === "string") return { ok: true, bytesB64: fallback, s3Key: null };
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
  // careerplug_applicant had no entry, so its resumes were filed under a
  // folder literally named "undefined". Fixed 2026-08-03 alongside adding
  // resume_manual_batch, which would have hit the same hole.
  careerplug_applicant: "applicant-resumes",
  resume_manual_batch: "applicant-resumes",
  archive_bundle: "_archive-bundles",
  skip: "unsorted",
};

/**
 * Which published set of Google Drive tools the folder helpers ask for.
 *
 * Composio publishes its tools in dated sets, and a request that does not name
 * one gets the oldest set — which is missing tools the account genuinely has,
 * and answers "Tool ... not found" when you reach for them. That reads exactly
 * like a permission problem and is not one. See the long note in lib/composio.ts.
 *
 * Named here rather than globally because a newer set can change the shape of
 * what comes back, and the payroll, statement and comp parsers read those
 * shapes. The plain upload below deliberately does NOT name a set: it works on
 * the oldest one, and there is nothing to gain by moving it.
 */
const DRIVE_FOLDER_TOOLKIT_VERSION = "20260721_00";

/** Folder ids worked out during this run. Keyed "<parent id>/<folder name>". */
const driveFolderCache = new Map<string, string>();

/**
 * Find a folder by name inside a parent, creating it if it is not there.
 * Returns null if neither works, and the caller then files one level up rather
 * than not at all.
 */
async function resolveDriveFolder(
  ctx: RunCtx, name: string, parentId: string,
): Promise<string | null> {
  const key = `${parentId}/${name}`;
  const cached = driveFolderCache.get(key);
  if (cached) return cached;
  if (!ctx.driveAccountId) return null;

  const find = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.driveAccountId,
    toolSlug: "GOOGLEDRIVE_FIND_FOLDER",
    toolArguments: { name_exact: name, parent_folder_id: parentId },
    toolkitVersion: DRIVE_FOLDER_TOOLKIT_VERSION,
  });
  const files = find.ok ? (find.data?.files ?? find.data?.data?.files ?? []) : [];
  let id: string = Array.isArray(files) && files.length > 0 ? (files[0]?.id ?? "") : "";

  if (!id) {
    const made = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.driveAccountId,
      toolSlug: "GOOGLEDRIVE_CREATE_FOLDER",
      toolArguments: { name, parent_id: parentId },
      toolkitVersion: DRIVE_FOLDER_TOOLKIT_VERSION,
    });
    id = made.ok ? (made.data?.id ?? made.data?.data?.id ?? "") : "";
    if (!id) {
      console.warn(`[document-processor] could not find or create Drive folder "${name}" under ${parentId}: ${find.error ?? ""} ${made.error ?? ""}`);
      return null;
    }
  }

  driveFolderCache.set(key, id);
  return id;
}

/** account_code -> Drive folder id, cached per run. Populated from
 * accounts.drive_folder_id (2026-08-09 Drive/Gmail reorg: statements now file
 * straight into the matching Accounts/Bank/<code> or Accounts/Credit Cards/<code>
 * folder instead of a generic bucket). Null/absent means no mapping yet — the
 * account was probably added after the last folder-ID backfill; falls through
 * to the generic tree rather than guessing.
 */
const accountDriveFolderCache = new Map<string, string | null>();
async function getAccountDriveFolderId(
  agencyId: string, accountCode: string | null,
): Promise<string | null> {
  if (!accountCode) return null;
  const key = `${agencyId}/${accountCode}`;
  if (accountDriveFolderCache.has(key)) return accountDriveFolderCache.get(key) ?? null;

  const { data, error } = await sb
    .from("accounts")
    .select("drive_folder_id, chart_of_accounts!inner(account_code)")
    .eq("agency_id", agencyId)
    .eq("chart_of_accounts.account_code", accountCode)
    .maybeSingle();

  const id = !error && (data as any)?.drive_folder_id ? String((data as any).drive_folder_id) : null;
  accountDriveFolderCache.set(key, id);
  return id;
}

/**
 * Where a document belongs.
 *
 * 2026-08-09: Peter reorganized both Drive and Gmail around three fixed
 * targets instead of the old generic tree — per-account folders under
 * Accounts/Bank/<code> and Accounts/Credit Cards/<code>, one merged
 * "Comp - Deduct" folder, and Team/Payroll. Those are checked first, in that
 * order. Anything that doesn't match (commission reports, team production,
 * archive bundles, and any bank/CC account not yet in accounts.drive_folder_id)
 * falls through to the legacy <Newtworks root>/Documents/<year-month>/<type>
 * tree, which still exists as the catch-all.
 *
 * Every step falls back one level up. A file in the right year but the wrong
 * type folder can be moved later; a file that never got filed cannot.
 */
async function documentFolderId(
  ctx: RunCtx, docType: DocType, txnDate: string, accountCode?: string | null,
): Promise<string | null> {
  const acctFolder = await getAccountDriveFolderId(ctx.agencyId, accountCode ?? null);
  if (acctFolder) return acctFolder;

  if (
    (docType === "comp_recap_1h" || docType === "comp_recap_daily" || docType === "deduction_statement")
    && ctx.driveCompDeductFolderId
  ) {
    return ctx.driveCompDeductFolderId;
  }
  if (
    (docType === "adp_payroll" || docType === "surepayroll_payroll")
    && ctx.drivePayrollFolderId
  ) {
    return ctx.drivePayrollFolderId;
  }

  const root = ctx.driveParentFolderId ?? null;
  if (!root) return null;

  const yearMonth = /^\d{4}-\d{2}/.test(txnDate ?? "")
    ? txnDate.slice(0, 7)
    : new Date().toISOString().slice(0, 7);
  const leaf = DRIVE_FOLDER_BY_DOCTYPE[docType] ?? "unsorted";

  const documents = await resolveDriveFolder(ctx, "Documents", root);
  if (!documents) return root;
  const month = await resolveDriveFolder(ctx, yearMonth, documents);
  if (!month) return documents;
  const typeFolder = await resolveDriveFolder(ctx, leaf, month);
  return typeFolder ?? month;
}

// FIXED 2026-08-04. This had been failing on EVERY document for weeks and
// saying nothing. GOOGLEDRIVE_UPLOAD_FILE requires a single `file_to_upload`
// object holding the file's name, type and storage key; the old call passed
// `file_name`, `file_path` and `content_base64`, which are not fields the tool
// accepts, so every upload was rejected as invalid input. Because the failure
// returned null quietly, nothing was filed to Drive and nothing was raised —
// 148 resumes, the August bank statements, payroll and card statements all have
// no Drive copy as a result.
//
// KNOWN LIMIT, follow-on work: the tool places files by folder ID, not by path,
// and only the Newtworks root folder ID is known. So everything lands in that
// one folder rather than the year-month and document-type folders the old path
// string described. That structure needs the folder IDs resolved (or created)
// before it can be restored. One flat folder beats nothing being filed at all,
// which is the state this replaces.
async function uploadToDrive(
  ctx: RunCtx, att: AttachmentInput, bytesB64: string,
  docType: DocType, txnDate: string, s3Key?: string | null,
  accountCode?: string | null,
): Promise<{ driveFileId: string; driveUrl: string } | null> {
  if (!ctx.driveAccountId) return null;

  // No storage key means the file was never staged where Drive can fetch it
  // (inner zip members). Skip rather than fail loudly — the zip itself is filed.
  if (!s3Key) return null;

  // Account folder, fixed type folder, or year-month/document-type folder,
  // in that priority order. Created on first use.
  const folderId = await documentFolderId(ctx, docType, txnDate, accountCode);

  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.driveAccountId,
    toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
    toolArguments: {
      file_to_upload: {
        name: att.fileName,
        mimetype: att.mimeType || "application/pdf",
        s3key: s3Key,
      },
      ...(folderId ? { folder_to_upload_to: folderId } : {}),
    },
  });

  if (!res.ok) {
    // Say so. A silent null here is exactly what hid this for weeks.
    console.error(`[document-processor] drive_upload_failed: ${att.fileName} docType=${docType} reason="${res.error}"`);
    try {
      await sb.from("alerts").insert({
        agency_id: ctx.agencyId,
        alert_type: "drive_upload_failed",
        severity: "warning",
        title: `Could not file ${att.fileName} to Drive`,
        message: `The Drive upload was rejected: ${res.error}\n\nThe document was still processed; only its Drive copy is missing.`,
        module_reference: "document-processor",
        is_read: false,
        is_resolved: false,
        created_at: new Date().toISOString(),
      });
    } catch (_e) { /* alerting must never break processing */ }
    return null;
  }

  return {
    driveFileId: res.data?.id ?? res.data?.data?.id ?? res.data?.file_id ?? "",
    driveUrl: res.data?.webViewLink ?? res.data?.display_url ?? res.data?.url ?? "",
  };
}

// ---- documents row ---------------------------------------------------------

async function insertSourceDocument(
  ctx: RunCtx, att: AttachmentInput, docType: DocType,
  drive: { driveFileId: string; driveUrl: string } | null,
  sourceAccountCode: string | null,
  uploadSource: string,
): Promise<string> {
  const row = {
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
    gmail_attachment_id: att.attachmentId || null,
    notes: `subject: ${att.subject}${att.parentArchive ? ` | extracted_from: ${att.parentArchive}` : ""}`,
  };

  // This attachment is being offered again because its previous row was left
  // mid-flight. Update that row in place rather than inserting a second one, so
  // a retry never turns into a duplicate document. The attempt counter is what
  // eventually stops a file that fails every time. See retryableDocumentId().
  if (att.retryDocumentId) {
    const { data: retried, error: retryErr } = await sb
      .from("documents")
      .update({
        ...row,
        retry_count: (att.retryCount ?? 0) + 1,
        processed_at: null,
        records_created: 0,
        tables_updated: [],
      })
      .eq("id", att.retryDocumentId)
      .select("id")
      .single();
    if (retryErr || !retried) {
      throw new Error(`document retry update failed: ${retryErr?.message ?? "unknown"}`);
    }
    return retried.id;
  }

  const { data, error } = await sb
    .from("documents")
    .insert(row)
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

// Statement-native sign per D15 (finance rebuild spec, 2026-08-07):
// bank: deposit positive / withdrawal negative. credit: charge positive /
// credit-refund negative. The LLM parser (bank.ts) always returns
// "positive = money in, negative = money out" regardless of account kind —
// toStatementNativeAmount, makeStatementReference, and the ref-counter
// bookkeeping that used to live here were deleted 2026-08-11: their only
// caller, handleBankStatement, now delegates to _shared/statement_writer.ts,
// which carries the same sign-flip rule and fingerprint scheme (see that
// file's "Sign convention (D15)" comment — identical logic, one copy).

async function handleBankStatement(
  ctx: RunCtx, att: AttachmentInput, documentId: string,
  bytesB64: string, sourceAccountCode: string,
): Promise<{ jeCount: number; suspenseCount: number; queueId?: string; error?: string; held?: boolean }> {
  // Resolve the full accounts row (id, business_entity_id, account_kind) —
  // not just the chart code sourceAccountCode already carries. See
  // resolveSourceAccountEntry: same match logic as resolveSourceAccount, so
  // this can never disagree with the code already resolved for this
  // document, it just also returns the row identity statements.account_id
  // needs.
  const acctResult = await resolveSourceAccountEntry(ctx.agencyId, att.fromEmail, att.subject, att.fileName);
  if (!("entry" in acctResult)) {
    return { jeCount: 0, suspenseCount: 0, error: `account_unmapped: ${acctResult.unmapped}` };
  }
  const account = acctResult.entry;

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

  // ---- Reconciliation guard, duplicate-ingest guard, balance write, and
  // per-transaction insert all live in _shared/statement_writer.ts as of
  // 2026-08-11 (see that file's header). This is the second of the two
  // hand-maintained twins to move onto it — llm-queue-drainer's
  // drainBankStatementItem moved first, in the same piece of work. The
  // duplicate-ingest guard below is NEW for this function: the old inline
  // code here only ever checked reconciliation, never duplicate ingestion,
  // so a statement that arrived twice (email attachment + Drive sweep, the
  // two intake doors this guard exists for) could double-post transactions
  // through THIS path even though llm-queue-drainer was already protected.
  // Moving onto the shared writer closes that gap as a side effect of
  // removing the duplication, not as a separate fix.
  const w = await writeParsedStatement({
    agencyId: ctx.agencyId,
    documentId,
    accountCode: sourceAccountCode,
    account: {
      id: account.id,
      businessEntityId: account.businessEntityId,
      accountKind: account.accountKind,
    },
    accountLast4: parsed.accountLast4,
    period: { start: parsed.statementPeriod.start, end: parsed.statementPeriod.end },
    openingBalance: parsed.openingBalance,
    closingBalance: parsed.closingBalance,
    transactions: parsed.transactions.map((r) => ({
      date: r.date,
      payee: r.txn.payee,
      memo: r.txn.memo,
      signedAmount: r.txn.signedAmount,
    })),
    source: "document_processor",
  });

  if (!w.ok) {
    if (w.held === "reconciliation_mismatch") {
      return { jeCount: 0, suspenseCount: 0, held: true, error: `held_reconciliation_mismatch: ${w.reason}` };
    }
    if (w.held === "duplicate_ingest") {
      return { jeCount: 0, suspenseCount: 0, held: true, error: `duplicate_ingest: ${w.reason}` };
    }
    throw new Error(`statements insert failed: ${w.error}`);
  }
  return { jeCount: w.inserted, suspenseCount: 0 };
}

// Prefix for statements whose account cannot be determined. The chart of
// accounts is numeric, so any value carrying this prefix fails the account
// lookup loudly instead of filing money to the wrong account.
const UNMAPPED = "UNMAPPED-";

// ---- Statement account routing --------------------------------------------
//
// The ACCOUNT TABLES are the source of truth. credit_accounts and bank_accounts
// each carry the account's last-4 (plus credit_accounts.alternate_last4s for
// reissued cards) and a chart_account_id. Adding or re-numbering an account is a
// row edit in those tables — it must never require touching this file again.
//
// Deliberately NOT matching digits against chart_of_accounts names: last-4 3977
// appears in the names of both 1012 and 1050, and 1247 in both 2114 and 2140.
// Name matching picks the wrong one. The tables carry exactly one row per real
// account, which is why they are the thing to read.
//
// is_active is respected. Retired accounts (TRB, State Farm Bank 2353, Capital
// One Spark) resolve to UNMAPPED so a surprise statement stops instead of
// posting somewhere plausible.

type AccountEntry = {
  id: string;
  businessEntityId: string;
  accountKind: string;
  last4s: string[];
  code: string | null;
  name: string;
  // Lower-cased "institution accountname", used when a statement carries no
  // account number we know yet (Fidelity HSA). Still resolved from the tables,
  // so the account-to-chart mapping stays in one place.
  haystack: string;
  active: boolean;
};

let accountIndexCache: { agencyId: string; entries: AccountEntry[] } | null = null;

// Single source table (accounts) replaces the old bank_accounts/credit_accounts
// pair. account_kind ('bank' | 'credit') is a column on the row now, not
// implied by which table it came from.
async function loadAccountIndex(agencyId: string): Promise<AccountEntry[]> {
  if (accountIndexCache && accountIndexCache.agencyId === agencyId) {
    return accountIndexCache.entries;
  }
  const entries: AccountEntry[] = [];

  const { data: rows, error: accErr } = await sb
    .from("accounts")
    .select("id, business_entity_id, account_kind, account_name, institution, account_number_last4, alternate_last4s, is_active, chart_of_accounts(account_code)")
    .eq("agency_id", agencyId);
  if (accErr) throw new Error(`accounts read failed: ${accErr.message}`);
  for (const a of rows ?? []) {
    const last4s = [a.account_number_last4, ...(a.alternate_last4s ?? [])]
      .filter((v: string | null): v is string => !!v);
    entries.push({
      id: a.id,
      businessEntityId: a.business_entity_id,
      accountKind: a.account_kind,
      last4s,
      code: (a as any).chart_of_accounts?.account_code ?? null,
      name: a.account_name ?? `${a.account_kind} account`,
      haystack: `${a.institution ?? ""} ${a.account_name ?? ""}`.toLowerCase(),
      active: a.is_active !== false,
    });
  }

  accountIndexCache = { agencyId, entries };
  return entries;
}

// Words Marie and Alvi put in filenames, translated to an ACCOUNT NUMBER only.
// The number is then resolved through the tables like any other, so the
// account-to-chart mapping lives in exactly one place. Order matters — most
// specific first, or a personal statement lands on an agency account.
const LABEL_TO_LAST4: Array<[RegExp, string]> = [
  [/kids[\s_-]?profit[\s_-]?disc/, "6730"],
  [/us[\s_-]?bank[\s_-]?personal[\s_-]?checking|personal[\s_-]?checking/, "0353"],
  [/tithe[\s_-]?tax/, "6755"],
  [/us[\s_-]?bank[\s_-]?other[\s_-]?income|other[\s_-]?income/, "2545"],
  [/sf[\s_-]?personal[\s_-]?cc/, "8847"],
  [/us\s*bank\s*income/, "3977"],
  [/us\s*bank\s*expenses/, "4335"],
  [/us\s*bank\s*cc/, "3447"],
  [/rbfcu[\s_-]?checking|randolph[\s_-]?brooks[\s_-]?checking/, "6608"],
  [/rbfcu|randolph[\s_-]?brooks/, "6596"],
  [/discover[\s_-]?tithe|discover[\s_-]?cc|discover/, "3208"],
  [/amex[\s_-]?personal/, "1006"],
  [/chase/, "7762"],
  [/citi/, "1247"],
  [/capital[\s_-]?one/, "7435"],
  [/amex|american[\s_-]?express/, "1003"],
  // Generic US Bank fallback — Income. Must stay LAST of the US Bank rules.
  [/usbank|us[\s_-]?bank/, "3977"],
];

// Labels resolved by INSTITUTION NAME rather than by account number, for
// accounts whose number we do not hold yet. Matched against the institution
// and account name on the bank_accounts / credit_accounts row, so the mapping
// still comes from the tables. Fidelity sends HSA statements that never show a
// number we have on file.
const LABEL_TO_NAME: Array<[RegExp, string]> = [
  [/fidelity/, "fidelity"],
];

// Accounts that are gone. Named explicitly so the failure message says why.
const RETIRED_HINTS: Array<[RegExp, string]> = [
  [/truist|trb/, "TRB-RETIRED"],
  [/statefarm|sf[\s.-]?ach/, "SF-BANK-RETIRED"],
  [/spark/, "SPARK-RETIRED"],
];

// Returns the full matched accounts row (id, business_entity_id, account_kind,
// chart code) — not just the chart code string. statements.account_id needs
// the row id; the old bank_gl_writer/cc_gl_writer era only ever needed the
// chart code, which is why this used to return a bare string. Kept as one
// function (not two independent lookups) so the code and the id can never
// diverge for the same resolution.
async function resolveSourceAccountEntry(
  agencyId: string,
  fromEmail: string,
  subject: string,
  fileName: string,
): Promise<{ entry: AccountEntry } | { unmapped: string }> {
  const blob = (fromEmail + " " + subject + " " + fileName).toLowerCase();

  let entries: AccountEntry[];
  try {
    entries = await loadAccountIndex(agencyId);
  } catch (e) {
    // Never guess an account because a lookup failed.
    return { unmapped: UNMAPPED + "ACCOUNT-TABLE-UNREADABLE" };
  }

  const matchLast4 = (last4: string): { entry: AccountEntry } | { unmapped: string } | null => {
    const hits = entries.filter((e) => e.last4s.includes(last4));
    const live = hits.filter((e) => e.active);
    if (live.length === 1) {
      if (!live[0].code) return { unmapped: UNMAPPED + `NO-CHART-LINK-${last4}` };
      return { entry: live[0] };
    }
    if (live.length > 1) {
      const codes = [...new Set(live.map((e) => e.code ?? "null"))];
      // Same account listed twice against one chart account is not a conflict.
      if (codes.length === 1 && codes[0] !== "null") return { entry: live[0] };
      return { unmapped: UNMAPPED + `AMBIGUOUS-${last4}` };
    }
    if (hits.length) return { unmapped: UNMAPPED + `RETIRED-${last4}` };
    return null;
  };

  // 1. An account number in the sender, subject or filename wins outright.
  //    Longest-first so a 4-digit run inside a longer number is not mistaken
  //    for the account. Only digits the tables actually know are considered.
  const known = new Set<string>();
  for (const e of entries) for (const l of e.last4s) known.add(l);
  for (const digits of blob.match(/\d{4,}/g) ?? []) {
    // Try the whole run, then its trailing 4 (statements often print the full
    // number, e.g. "1-047-8744-3977" flattens to a long run ending in 3977).
    for (const cand of [digits, digits.slice(-4)]) {
      if (known.has(cand)) {
        const r = matchLast4(cand);
        if (r) return r;
      }
    }
  }

  // 2. No usable number — fall back to the filename label, resolved through
  //    the same tables.
  for (const [re, last4] of LABEL_TO_LAST4) {
    if (re.test(blob)) {
      const r = matchLast4(last4);
      if (r) return r;
      return { unmapped: UNMAPPED + `LABEL-${last4}-NOT-IN-TABLES` };
    }
  }

  // 3. Accounts identified by institution name rather than a number.
  for (const [re, needle] of LABEL_TO_NAME) {
    if (!re.test(blob)) continue;
    const live = entries.filter((e) => e.active && e.haystack.includes(needle));
    const withCode = live.filter((e) => !!e.code);
    const codes = [...new Set(withCode.map((e) => e.code))];
    if (codes.length === 1) return { entry: withCode[0] };
    if (codes.length > 1) return { unmapped: UNMAPPED + `AMBIGUOUS-NAME-${needle}` };
    return { unmapped: UNMAPPED + `NAME-${needle}-NOT-IN-TABLES` };
  }

  // 4. Known-dead institutions get a named failure rather than a generic one.
  for (const [re, hint] of RETIRED_HINTS) {
    if (re.test(blob)) return { unmapped: UNMAPPED + hint };
  }

  // No silent default. Returning an account here guesses whose money this is;
  // an unrecognised statement must stop and be looked at instead.
  return { unmapped: UNMAPPED + "UNRECOGNISED" };
}

// Thin wrapper preserving the old string-returning signature for call sites
// that only ever needed the chart code (documents.source_account_code,
// statement_balances.account_code, error/log messages).
async function resolveSourceAccount(
  agencyId: string,
  fromEmail: string,
  subject: string,
  fileName: string,
): Promise<string> {
  const r = await resolveSourceAccountEntry(agencyId, fromEmail, subject, fileName);
  return "entry" in r ? (r.entry.code as string) : r.unmapped;
}

// ---- statement_balances writer --------------------------------------------
// Called after a bank statement parses successfully. Upserts one row per
// (agency_id, account_code, statement_period_end) so re-processing the same
// statement PDF overwrites in place rather than duplicating. Business entity
// comes from chart_of_accounts; account kind is inferred from the COA code
// prefix (CC → credit, else bank). Added 2026-07-27 alongside the Alvi zip
// classifier fallback — this is what makes statement_balances actually populate
// from ingested statements rather than needing a manual backfill.
async function writeStatementBalance(opts: {
  agencyId: string;
  documentId: string;
  accountCode: string;
  accountLast4: string | null;
  statementPeriodStart: string;
  statementPeriodEnd: string;
  openingBalance: number | null;
  closingBalance: number | null;
}): Promise<{ ok: boolean; error?: string }> {
  // Look up the business entity from chart_of_accounts.
  const { data: coa, error: coaErr } = await sb
    .from("chart_of_accounts")
    .select("business_entity_id, account_subtype")
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .maybeSingle();
  if (coaErr) {
    return { ok: false, error: `chart_of_accounts lookup failed: ${coaErr.message}` };
  }
  const businessEntityId = coa?.business_entity_id ?? null;
  if (!businessEntityId) {
    return { ok: false, error: `no chart_of_accounts row for ${opts.accountCode}` };
  }
  // Infer kind: any code with "-CC-" in it is a credit card; everything else
  // is a bank account. Matches the existing statement_balances.account_kind
  // convention (values already in the table: "bank", "credit").
  const accountKind = /-CC-/i.test(opts.accountCode) ? "credit" : "bank";

  // Upsert-by-natural-key: (agency_id, account_code, statement_period_end).
  // No explicit unique constraint exists, so do it in two steps: try UPDATE
  // by that key, INSERT if nothing was touched. Both branches use the same
  // source label so we can tell downstream that this row came from the
  // document-processor pipeline (vs. manual backfill or gl-cutover).
  const upd = await sb
    .from("statement_balances")
    .update({
      business_entity_id: businessEntityId,
      account_last4: opts.accountLast4,
      account_kind: accountKind,
      statement_period_start: opts.statementPeriodStart,
      opening_balance: opts.openingBalance,
      closing_balance: opts.closingBalance,
      source_document_id: opts.documentId,
      source: "document_processor",
      notes: `auto-ingested via document-processor from statement PDF`,
      updated_at: new Date().toISOString(),
    })
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .eq("statement_period_end", opts.statementPeriodEnd)
    .select("id");
  if (upd.error) return { ok: false, error: `statement_balances update failed: ${upd.error.message}` };
  if (upd.data && upd.data.length > 0) return { ok: true };

  const ins = await sb.from("statement_balances").insert({
    agency_id: opts.agencyId,
    business_entity_id: businessEntityId,
    account_code: opts.accountCode,
    account_last4: opts.accountLast4,
    account_kind: accountKind,
    statement_period_start: opts.statementPeriodStart,
    statement_period_end: opts.statementPeriodEnd,
    opening_balance: opts.openingBalance,
    closing_balance: opts.closingBalance,
    source_document_id: opts.documentId,
    source: "document_processor",
    notes: `auto-ingested via document-processor from statement PDF`,
  });
  if (ins.error) return { ok: false, error: `statement_balances insert failed: ${ins.error.message}` };
  return { ok: true };
}

// ---- Gmail thread archive --------------------------------------------------
// After a doc finishes successfully, check whether every document tied to the
// same gmail_thread_id is in a terminal state (processed/error/skipped). If so,
// archive the thread in Gmail by removing the INBOX label. Sets
// documents.gmail_archived_at for all rows in the thread so we know it happened.
// Gmail label routing per docType — this is the fallback used only when the
// account has no accounts.gmail_label_id (see getAccountGmailLabelId above,
// checked first in maybeArchiveThread). Created 2026-07-14. Update this map
// when adding a new docType. Nulls skip label-add (still removes INBOX).
//
// bank_statement_* were null from 2026-07-29 (old generic bank-statement
// labels deleted in that reorg) until 2026-08-09, when per-account labels
// (accounts.gmail_label_id) took over routing for every mapped account. They
// stay null here on purpose — an account not yet in the table should get NO
// label rather than a wrong generic one, same reasoning as Drive's UNMAPPED.
const ARCHIVE_LABEL_FOR_DOCTYPE: Record<string, string | null> = {
  bank_statement_primary:   null,
  bank_statement_secondary: null,
  bank_statement_pfa:       null,
  comp_recap_1h:            "Label_24", // "Comp-Deduct"
  comp_recap_daily:         "Label_24",
  deduction_statement:      "Label_24", // "Comp-Deduct" (merged with comp recap 2026-08-09; old "SF Deductions" Label_25 was retired)
  surepayroll_payroll:      "Label_26", // "Team/Payroll"
  adp_payroll:              "Label_26",
  commission_report:        null, // deleted 2026-07-29
  team_production:          null,
  careerplug_applicant:     "Label_20", // "Team/Hiring/Applicants" (attachment pipeline)
  resume_manual_batch:      "Label_20", // "Team/Hiring/Applicants" (hand-forwarded batches)
};

/** account_code -> Gmail label id, cached per run. Populated from
 * accounts.gmail_label_id (2026-08-09 Drive/Gmail reorg follow-up: bank/CC
 * statements route to their own account's label instead of no label at all —
 * the old generic bank-statement labels were deleted in the 2026-07-29 reorg
 * and nothing replaced them until now). Null/absent falls through to
 * ARCHIVE_LABEL_FOR_DOCTYPE exactly as before.
 */
const accountGmailLabelCache = new Map<string, string | null>();
async function getAccountGmailLabelId(
  agencyId: string, accountCode: string | null,
): Promise<string | null> {
  if (!accountCode) return null;
  const key = `${agencyId}/${accountCode}`;
  if (accountGmailLabelCache.has(key)) return accountGmailLabelCache.get(key) ?? null;

  const { data, error } = await sb
    .from("accounts")
    .select("gmail_label_id, chart_of_accounts!inner(account_code)")
    .eq("agency_id", agencyId)
    .eq("chart_of_accounts.account_code", accountCode)
    .maybeSingle();

  const id = !error && (data as any)?.gmail_label_id ? String((data as any).gmail_label_id) : null;
  accountGmailLabelCache.set(key, id);
  return id;
}

async function maybeArchiveThread(
  ctx: RunCtx, threadId: string | null | undefined, docType?: string, accountCode?: string | null,
): Promise<void> {
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
    // Per-account label wins when the account has one; otherwise fall back to
    // the doc-type map exactly as before.
    const acctLabel = await getAccountGmailLabelId(ctx.agencyId, accountCode ?? null);
    const labelId = acctLabel ?? (docType ? ARCHIVE_LABEL_FOR_DOCTYPE[docType] : null);

    const res = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
      toolArguments: {
        thread_id: threadId,
        remove_label_ids: ["INBOX"],
        ...(labelId ? { add_label_ids: [labelId] } : {}),
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
      .select("id, processing_status, retry_count")
      .eq("agency_id", ctx.agencyId)
      .eq("file_name", att.fileName)
      .like("upload_source", "gmail%")
      .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
      .maybeSingle();
    if (existing?.id) {
      // This check used to skip ANY existing row regardless of status, which is
      // the exact stranding bug retryableDocumentId() was written to fix — but
      // the fix was only wired into the outer fetcher, not here. An inner zip
      // file whose run died before reaching a terminal status therefore sat at
      // "received" through every single re-run, unreachable. Discover Tithe
      // 26-02 and 26-05 were stuck that way (found 2026-08-04).
      const retryId = retryableDocumentId(existing, att.fileName);
      if (retryId) {
        att.retryDocumentId = retryId;
        att.retryCount = existing.retry_count ?? 0;
      } else {
        results.push({
          documentId: existing.id, fileName: att.fileName, fromEmail: att.fromEmail,
          docType, status: "skipped", jeCount: 0, suspenseCount: 0,
          sourceLabel: uploadSource,
          error: "already_processed (idempotent)",
        });
        return results;
      }
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
  const attachmentS3Key = dl.s3Key;

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
    const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate, attachmentS3Key);
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

  // Resolved before the Drive upload (not after, as before 2026-08-09) so
  // bank/CC statements can file straight into their matching account folder.
  const isBankStmt =
    docType === "bank_statement_primary" ||
    docType === "bank_statement_secondary";
  const sourceAccountCode = isBankStmt
    ? await resolveSourceAccount(ctx.agencyId, att.fromEmail, att.subject, att.fileName)
    : null;
  const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate, attachmentS3Key, sourceAccountCode);
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
        } else if (r.held) {
          // Reconciliation guard held the parse. Handler already wrote
          // documents.processing_status='held_reconciliation_mismatch',
          // reconciliation_delta, notes payload, and emitted the alert.
          // Do NOT call markDocument here — it would overwrite those writes.
          // Do NOT archive the Gmail thread — the document needs human review.
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
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
            ["statements"],
            `${r.jeCount} statement rows written`);
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
        // PDF path: extractText uses unpdf with preserveFormat=true (parser needs
        // original whitespace). CSV path: extractText auto-decodes text bytes.
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
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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
      case "resume_manual_batch": {
        // Hand-forwarded resume PDF (see parsers/resume_manual_batch.ts).
        // Identity comes out of the resume text, then the candidate is
        // upserted through the shared CareerPlug routine.
        const r = await processResumeManualBatch({
          agencyId: ctx.agencyId,
          documentId,
          messageId: att.messageId,
          fromEmail: att.fromEmail,
          subject: att.subject,
          receivedAt: att.receivedAt,
          fileName: att.fileName,
          bytesB64,
          resumeUrl: drive?.driveUrl ?? null,
          gmailAttachmentId: att.attachmentId,
          recovery: {
            composioApiKey: ctx.composioApiKey,
            composioUserId: ctx.composioUserId,
            gmailAccountId: ctx.gmailAccountId,
            driveAccountId: ctx.driveAccountId,
            driveParentFolderId: ctx.driveParentFolderId ?? null,
          },
        });
        if (r.ok) {
          // Text recognition produced a Drive copy. Keep it on the row — these
          // resumes have otherwise never had one, because the normal Drive
          // upload returns quietly when it fails.
          if (r.recoveredDriveFileId && !drive?.driveFileId) {
            await sb.from("documents")
              .update({ drive_file_id: r.recoveredDriveFileId, drive_url: r.recoveredDriveUrl ?? null })
              .eq("id", documentId);
          }
          await markDocument(documentId, "processed", 1, ["hiring_candidates"],
            `Resume ingested for ${r.candidateName ?? "unnamed candidate"} (${r.action}, identity via ${r.identitySource}, text via ${r.textSource ?? "pdf"}); candidate ${r.candidateId ?? "unknown"}`);
          await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else {
          // Leave the thread in the inbox on failure — an alert was already
          // raised inside the parser, and the thread staying visible is the
          // backstop against a resume disappearing quietly.
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
        // the resume to a hiring_candidates row happens in the mode path when
        // the parent notification is parsed.
        await markDocument(documentId, "processed", 0, ["documents"],
          "CareerPlug resume stored via attachment pipeline; linkage handled by mode=careerplug");
        await maybeArchiveThread(ctx, att.threadId, docType, sourceAccountCode);
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

// ---- mode: resume_text_recovery --------------------------------------------
// Deliberate re-run for forwarded resumes that failed because the file was a
// scan or a photo with no text in it.
//
// WHY A SEPARATE DOOR: those rows sit at processing_status "error", and "error"
// is in the do-not-retry set, so the mid-flight retry guard treats them as
// finished and the mail fetcher will never offer them again. Nothing reopens
// them on its own. This is the door.
//
// It does NOT re-download the original bytes. By definition these files have no
// text to extract, so handing the parser an empty body lets its own recovery
// step fetch the original from Gmail and run Drive text recognition — one fewer
// round trip per file, and one code path instead of two.
//
// Body: { agency_id, shared_secret, mode: "resume_text_recovery",
//         document_ids?: string[], limit?: number, dry_run?: boolean }
// With no document_ids it picks up every forwarded resume still failing for
// this reason, oldest first.
interface TextRecoveryOutcome {
  documentId: string;
  fileName: string;
  status: "recovered" | "still_failing" | "unrecoverable" | "would_run";
  candidateId?: string | null;
  candidateName?: string | null;
  error?: string;
}

async function processResumeTextRecoveryMode(
  ctx: RunCtx, body: any,
): Promise<{
  considered: number; recovered: number; stillFailing: number;
  unrecoverable: number; dryRun: boolean; outcomes: TextRecoveryOutcome[];
}> {
  const documentIds: string[] = Array.isArray(body?.document_ids)
    ? body.document_ids.filter((x: unknown) => typeof x === "string")
    : [];
  const limit = Math.min(Math.max(Number(body?.limit) || 40, 1), 100);
  const dryRun = body?.dry_run === true;

  // Text already read out of the scans by the caller, keyed by document id.
  // This door exists because reading a scan needs a Google Drive tool that this
  // function's Composio key cannot see, while the same tool works fine from an
  // interactive session. Rather than leave real applicants stranded waiting on
  // that permission, the reading can happen outside and the text be handed in
  // here. Everything downstream — identity, candidate row, Drive link — runs
  // exactly as it does on the automatic path.
  const handedIn = new Map<
    string,
    { text: string; driveFileId: string | null; driveUrl: string | null }
  >();
  if (Array.isArray(body?.recovered)) {
    for (const r of body.recovered) {
      const id = typeof r?.document_id === "string" ? r.document_id : null;
      const text = typeof r?.text === "string" ? r.text : "";
      if (id && text.trim().length >= 40) {
        handedIn.set(id, {
          text,
          driveFileId: typeof r?.drive_file_id === "string" ? r.drive_file_id : null,
          driveUrl: typeof r?.drive_url === "string" ? r.drive_url : null,
        });
      }
    }
  }

  let q = sb
    .from("documents")
    .select("id, file_name, gmail_message_id, gmail_attachment_id, uploaded_by, uploaded_at")
    .eq("agency_id", ctx.agencyId)
    .eq("groq_classification", "resume_manual_batch")
    .eq("processing_status", "error");

  if (documentIds.length > 0) {
    q = q.in("id", documentIds);
  } else {
    // Only the rows that failed for lack of readable text. Leaves alone the
    // ones that failed for any other reason, which need a different fix.
    q = q.ilike("notes", "%image-only PDF%");
  }

  const { data: rows, error: selErr } = await q
    .order("created_at", { ascending: true })
    .limit(limit);

  if (selErr) {
    return { considered: 0, recovered: 0, stillFailing: 0, unrecoverable: 0, dryRun, outcomes: [] };
  }

  const outcomes: TextRecoveryOutcome[] = [];
  let recovered = 0, stillFailing = 0, unrecoverable = 0;

  for (const row of rows ?? []) {
    const fileName = (row as any).file_name ?? "(unnamed)";
    const messageId = (row as any).gmail_message_id as string | null;
    const attachmentId = (row as any).gmail_attachment_id as string | null;

    const supplied = handedIn.get((row as any).id) ?? null;

    // No way back to the original file. Say so rather than failing vaguely.
    // Text handed in with the request makes this moot: nothing needs fetching.
    if (!supplied && (!messageId || !attachmentId)) {
      unrecoverable++;
      outcomes.push({
        documentId: (row as any).id, fileName, status: "unrecoverable",
        error: "no Gmail message id or attachment id on this row, so the original file cannot be fetched again",
      });
      continue;
    }

    if (dryRun) {
      outcomes.push({ documentId: (row as any).id, fileName, status: "would_run" });
      continue;
    }

    const r = await processResumeManualBatch({
      agencyId: ctx.agencyId,
      documentId: (row as any).id,
      messageId: messageId ?? "",
      fromEmail: (row as any).uploaded_by ?? "",
      // The original subject line was overwritten by the failure message when
      // the row first errored, so it is genuinely gone. Left blank rather than
      // invented.
      subject: "",
      receivedAt: (row as any).uploaded_at ?? new Date().toISOString(),
      fileName,
      bytesB64: "",   // deliberate — see the note above
      resumeUrl: null,
      gmailAttachmentId: attachmentId,
      preRecoveredText: supplied?.text ?? null,
      preRecoveredDriveFileId: supplied?.driveFileId ?? null,
      preRecoveredDriveUrl: supplied?.driveUrl ?? null,
      recovery: {
        composioApiKey: ctx.composioApiKey,
        composioUserId: ctx.composioUserId,
        gmailAccountId: ctx.gmailAccountId,
        driveAccountId: ctx.driveAccountId,
        driveParentFolderId: ctx.driveParentFolderId ?? null,
      },
    });

    if (r.ok) {
      if (r.recoveredDriveFileId) {
        await sb.from("documents")
          .update({ drive_file_id: r.recoveredDriveFileId, drive_url: r.recoveredDriveUrl ?? null })
          .eq("id", (row as any).id);
      }
      await markDocument((row as any).id, "processed", 1, ["hiring_candidates"],
        `Resume recovered by text recognition for ${r.candidateName ?? "unnamed candidate"} (${r.action}, identity via ${r.identitySource}); candidate ${r.candidateId ?? "unknown"}`);
      recovered++;
      outcomes.push({
        documentId: (row as any).id, fileName, status: "recovered",
        candidateId: r.candidateId, candidateName: r.candidateName,
      });
    } else {
      await markDocument((row as any).id, "error", 0, [], r.error);
      stillFailing++;
      outcomes.push({
        documentId: (row as any).id, fileName, status: "still_failing", error: r.error,
      });
    }
  }

  return {
    considered: (rows ?? []).length,
    recovered, stillFailing, unrecoverable, dryRun, outcomes,
  };
}

// ---- mode: drive_backfill --------------------------------------------------
// Files a Drive copy for documents that never got one.
//
// WHY THIS IS NEEDED: the Drive upload was rejecting every single file for
// weeks and returning quietly, so nothing was filed and nothing was raised. It
// was repaired on 2026-08-04, but by then 148 resumes, the August bank
// statements, payroll and the card statements all had no Drive copy. Those
// documents were processed correctly — their figures are in the books. It is
// only the filed copy that is missing.
//
// LIMIT: this refiles from Gmail using the message and attachment ids already
// on the row, so it only works while the original email is still in the
// mailbox. Anything older than that cannot be recovered from here and needs the
// file from another source.
//
// Body: { agency_id, shared_secret, mode: "drive_backfill",
//         limit?: number, document_ids?: string[], dry_run?: boolean,
//         classification?: string }
interface DriveBackfillOutcome {
  documentId: string;
  fileName: string;
  status: "filed" | "gone_from_gmail" | "upload_failed" | "would_run";
  driveFileId?: string;
  error?: string;
}

async function processDriveBackfillMode(
  ctx: RunCtx, body: any,
): Promise<{
  considered: number; filed: number; goneFromGmail: number;
  uploadFailed: number; dryRun: boolean; outcomes: DriveBackfillOutcome[];
}> {
  const documentIds: string[] = Array.isArray(body?.document_ids)
    ? body.document_ids.filter((x: unknown) => typeof x === "string")
    : [];
  const limit = Math.min(Math.max(Number(body?.limit) || 25, 1), 100);
  const dryRun = body?.dry_run === true;
  const classification = typeof body?.classification === "string" ? body.classification : null;

  let q = sb
    .from("documents")
    .select("id, file_name, groq_classification, gmail_message_id, gmail_attachment_id, uploaded_at, source_account_code")
    .eq("agency_id", ctx.agencyId)
    .is("drive_file_id", null)
    .not("gmail_message_id", "is", null)
    .not("gmail_attachment_id", "is", null);

  if (documentIds.length > 0) q = q.in("id", documentIds);
  if (classification) q = q.eq("groq_classification", classification);

  // Newest first on purpose: the newest are the ones still inside the mailbox,
  // so the runs that can actually succeed happen before the ones that cannot.
  const { data: rows, error: selErr } = await q
    .order("uploaded_at", { ascending: false })
    .limit(limit);

  if (selErr) {
    return { considered: 0, filed: 0, goneFromGmail: 0, uploadFailed: 0, dryRun, outcomes: [] };
  }

  const outcomes: DriveBackfillOutcome[] = [];
  let filed = 0, goneFromGmail = 0, uploadFailed = 0;

  for (const row of rows ?? []) {
    const id = (row as any).id as string;
    const fileName = (row as any).file_name ?? "(unnamed)";
    const docType = ((row as any).groq_classification ?? "skip") as DocType;
    const uploadedAt = (row as any).uploaded_at ?? new Date().toISOString();

    if (dryRun) {
      outcomes.push({ documentId: id, fileName, status: "would_run" });
      continue;
    }

    // Ask Gmail for the attachment. The reply carries a temporary signed link
    // whose path is the storage key the upload tool wants. The bytes themselves
    // are not needed — Drive collects the file itself.
    const gm = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_GET_ATTACHMENT",
      toolArguments: {
        message_id: (row as any).gmail_message_id,
        attachment_id: (row as any).gmail_attachment_id,
        file_name: fileName,
        user_id: "me",
      },
    });
    const s3url = gm.ok
      ? (gm.data?.file?.s3url ?? gm.data?.data?.file?.s3url ?? null)
      : null;
    if (!s3url) {
      goneFromGmail++;
      outcomes.push({
        documentId: id, fileName, status: "gone_from_gmail",
        error: gm.ok ? "Gmail returned no download link" : String(gm.error).slice(0, 300),
      });
      continue;
    }

    let s3Key: string | null = null;
    try {
      const path = new URL(s3url).pathname.replace(/^\/+/, "");
      s3Key = path.length > 0 ? decodeURIComponent(path) : null;
    } catch { s3Key = null; }
    if (!s3Key) {
      uploadFailed++;
      outcomes.push({ documentId: id, fileName, status: "upload_failed", error: "could not read a storage key out of the Gmail link" });
      continue;
    }

    const att: AttachmentInput = {
      messageId: (row as any).gmail_message_id,
      threadId: "",
      fromEmail: "",
      subject: "",
      receivedAt: uploadedAt,
      fileName,
      mimeType: fileName.toLowerCase().endsWith(".zip") ? "application/zip" : "application/pdf",
      attachmentId: (row as any).gmail_attachment_id,
    } as AttachmentInput;

    // Filed by the date the document arrived. The original path used the
    // document's own transaction date, which is not on this row — close enough
    // for a copy whose only job is to be findable.
    const drive = await uploadToDrive(
      ctx, att, "", docType, String(uploadedAt).slice(0, 10), s3Key,
      (row as any).source_account_code ?? null,
    );
    if (!drive || !drive.driveFileId) {
      uploadFailed++;
      outcomes.push({ documentId: id, fileName, status: "upload_failed", error: "Drive rejected the upload; an alert was raised with the reason" });
      continue;
    }

    await sb.from("documents")
      .update({ drive_file_id: drive.driveFileId, drive_url: drive.driveUrl || null })
      .eq("id", id);

    filed++;
    outcomes.push({ documentId: id, fileName, status: "filed", driveFileId: drive.driveFileId });
  }

  return {
    considered: (rows ?? []).length,
    filed, goneFromGmail, uploadFailed, dryRun, outcomes,
  };
}

// ---- mode: composio_probe --------------------------------------------------
// Asks Composio, using THIS function's own key, what it can actually see and
// do. It exists because a tool working from an interactive session proves
// nothing about whether this function can reach it — the two authenticate
// differently. Learning that the hard way cost four deploy cycles on
// 2026-08-04, at roughly eight minutes each. Probe first, design second.
//
// Body: { agency_id, shared_secret, mode: "composio_probe",
//         toolkit?: "googledrive",          // list every tool the key can see
//         calls?: [ { slug, account?: "gmail" | "drive", arguments? } ] }
//
// Reads only. Writes nothing, changes nothing, and every result comes back in
// the reply rather than the log, because the log cannot be read after the fact.
async function processComposioProbeMode(ctx: RunCtx, body: any): Promise<any> {
  const out: any = {
    composio_user_id: ctx.composioUserId,
    gmail_account_id: ctx.gmailAccountId,
    drive_account_id: ctx.driveAccountId,
  };

  const toolkit = typeof body?.toolkit === "string" ? body.toolkit : null;
  if (toolkit) {
    try {
      const { res, timedOut } = await fetchWithTimeout(
        `https://backend.composio.dev/api/v3/tools?toolkit_slugs=${encodeURIComponent(toolkit)}&limit=500`,
        { headers: { "x-api-key": ctx.composioApiKey } },
        S3_FETCH_TIMEOUT_MS,
        "composio",
        `toolkit probe: ${toolkit}`,
      );
      if (!res) {
        out.toolkit = toolkit;
        out.toolkit_error = timedOut ? "toolkit probe timed out" : "toolkit probe fetch failed";
      } else {
        const text = await res.text();
        let parsed: any = {};
        try { parsed = JSON.parse(text); } catch { parsed = { raw: text.slice(0, 1500) }; }
        const items = parsed?.items ?? parsed?.data ?? null;
        out.toolkit = toolkit;
        out.toolkit_http_status = res.status;
        if (Array.isArray(items)) {
          out.toolkit_tool_count = items.length;
          out.toolkit_tools = items
            .map((t: any) => t?.slug ?? t?.name)
            .filter((x: unknown) => typeof x === "string")
            .sort();
        } else {
          out.toolkit_raw = JSON.stringify(parsed).slice(0, 1500);
        }
      }
    } catch (e) {
      out.toolkit_error = e instanceof Error ? e.message : String(e);
    }
  }

  const calls = Array.isArray(body?.calls) ? body.calls.slice(0, 12) : [];
  if (calls.length > 0) {
    out.calls = [];
    for (const c of calls) {
      const slug = typeof c?.slug === "string" ? c.slug : null;
      if (!slug) continue;
      const account = c?.account === "drive" ? ctx.driveAccountId : ctx.gmailAccountId;
      if (!account) {
        out.calls.push({ slug, ok: false, error: "no connected account of that kind is stored" });
        continue;
      }
      const args = c?.arguments && typeof c.arguments === "object" ? c.arguments : {};
      const r = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: account,
        toolSlug: slug,
        toolArguments: args,
      });
      out.calls.push({
        slug,
        ok: r.ok,
        http_status: r.httpStatus,
        error: r.error ? String(r.error).slice(0, 400) : null,
        data_preview: r.data ? JSON.stringify(r.data).slice(0, 1000) : null,
      });
    }
  }

  return out;
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
  const driveFolderId = await getSetting(agencyId, "drive_newtworks_root_folder_id");
  const driveCompDeductFolderId = await getSetting(agencyId, "drive_comp_deduct_folder_id");
  const drivePayrollFolderId = await getSetting(agencyId, "drive_payroll_folder_id");
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
  if (mode === "wrapup") {
    const wupCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId };
    const startedAt = new Date().toISOString();
    const result = await processWrapupMode(wupCtx, body);
    return jsonResponse({ ok: true, mode: "wrapup", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "paypal_print_sales") {
    const ppCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
    const startedAt = new Date().toISOString();
    const result = await processPaypalPrintSalesMode(ppCtx, body);
    return jsonResponse({ ok: true, mode: "paypal_print_sales", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "amazon_order_email") {
    const aoeCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId };
    const startedAt = new Date().toISOString();
    const result = await processAmazonOrderEmailMode(aoeCtx, body);
    return jsonResponse({ ok: true, mode: "amazon_order_email", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "resume_text_recovery") {
    // Re-run forwarded resumes that failed for lack of readable text, pushing
    // each one through Drive text recognition. See the note on the function.
    const trCtx: RunCtx = {
      agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
      driveParentFolderId: driveFolderId,
      driveCompDeductFolderId, drivePayrollFolderId,
    };
    const startedAt = new Date().toISOString();
    const result = await processResumeTextRecoveryMode(trCtx, body);
    return jsonResponse({ ok: true, mode: "resume_text_recovery", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "drive_backfill") {
    // File the Drive copies lost while the upload was silently failing.
    const bfCtx: RunCtx = {
      agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
      driveParentFolderId: driveFolderId,
      driveCompDeductFolderId, drivePayrollFolderId,
    };
    const startedAt = new Date().toISOString();
    const result = await processDriveBackfillMode(bfCtx, body);
    return jsonResponse({ ok: true, mode: "drive_backfill", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "composio_probe") {
    // Read-only capability check. See the note on the function above.
    const prCtx: RunCtx = {
      agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
      driveParentFolderId: driveFolderId,
      driveCompDeductFolderId, drivePayrollFolderId,
    };
    const startedAt = new Date().toISOString();
    const result = await processComposioProbeMode(prCtx, body);
    return jsonResponse({ ok: true, mode: "composio_probe", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "no_send_check") {
    // Wrap-up no-send check (2026-07-22). Fires once per week at Fri 7 PM CT.
    // Emails each teammate who submitted nothing + one group Telegram to PJS
    // Agency chat. Pass body.dry_run=true to preview without sending.
    const nsCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId };
    const startedAt = new Date().toISOString();
    const result = await processWrapupNoSendMode(nsCtx, body);
    return jsonResponse({ ok: true, mode: "no_send_check", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }

  const ctx: RunCtx = {
    agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
    driveParentFolderId: driveFolderId,
      driveCompDeductFolderId, drivePayrollFolderId,
  };
  const startedAt = new Date().toISOString();
  const allResults: ProcessedAttachment[] = [];

  let attachments: AttachmentInput[];
  try {
    attachments = await fetchNewGmailAttachments(ctx, {
      query: typeof body?.gmail_query === "string" ? body.gmail_query : undefined,
      maxResults: typeof body?.max_results === "number" ? body.max_results : undefined,
    });
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
