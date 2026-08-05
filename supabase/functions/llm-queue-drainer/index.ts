// llm-queue-drainer edge function
//
// Purpose: Drains pending items in public.llm_parse_queue that document-processor
// couldn't complete synchronously (transient Groq failures, JSON parse issues,
// max_tokens truncations, daily TPD exhaustion).
//
// Supported purposes:
//   - parse_bank_statement         → drainBankStatementItem  (statement_balances + bank_transactions)
//   - careerplug_applicant_extract → drainCareerplugItem     (hiring_candidates via upsert RPC)
//
// Flow per item:
//   1. Call Groq direct with stored system_prompt + user_content
//   2. Parse JSON per purpose-specific shape
//   3. Purpose-specific write path
//   4. Mark queue item succeeded (or bump attempts on failure; 429 = don't burn)
//
// Invocation: POST { agency_id, shared_secret, [max_items=10, dry_run=false] }

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, jsonResponse, getSettingOrNull, stripFences } from "../_shared/supabase.ts";
import { callGroqChat } from "../_shared/llm.ts";
import { requireSharedSecret } from "../_shared/auth.ts";

// Bank statements run 11-13K tokens which exceeds gpt-oss-120b's 8000 TPM limit.
// Force a model with higher throughput for the drainer regardless of stored model.
const BANK_STATEMENT_MODEL = "llama-3.3-70b-versatile";
// Careerplug items are small (~1-2K tokens) but gpt-oss-120b is often the daily-cap
// victim (200K TPD). Draining on a different model spreads TPD load so we can drain
// backlog even when gpt-oss-120b is exhausted.
const CAREERPLUG_MODEL = "llama-3.3-70b-versatile";

// Purposes this drainer currently handles. Adding a new purpose = adding a
// handler function below AND appending its key here.
const SUPPORTED_PURPOSES = ["parse_bank_statement", "careerplug_applicant_extract"];

// Thin adapter over the shared Groq caller so the drain call sites keep their
// positional signature. temperature 0.1 preserved from the original inline copy.
async function callGroq(apiKey: string, model: string, systemPrompt: string, userContent: string, maxTokens = 8000): Promise<{ ok: boolean; raw: string; error?: string }> {
  const r = await callGroqChat({ apiKey, model, systemPrompt, userContent, maxTokens, temperature: 0.1 });
  return { ok: r.ok, raw: r.raw, error: r.error ?? undefined };
}

interface QueueItem {
  id: string;
  agency_id: string;
  document_id: string | null;
  purpose: string;
  system_prompt: string;
  user_content: string;
  model: string;
  attempts: number;
}

interface DrainResult {
  ok: boolean;
  error?: string;
  // Optional purpose-specific fields:
  statementBalance?: any;         // bank statements
  transactionsInserted?: number;  // bank statements
  skippedInformational?: number;  // bank statements
  docId?: string | null;          // bank statements
  applicantsUpserted?: number;    // careerplug
  applicantActions?: any[];       // careerplug
  note?: string;
}

async function drainBankStatementItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  // 1. Call Groq (force higher-TPM model for bank statements — see rate limit note above).
  //
  // Output cap raised 4000 -> 8000 on 2026-08-04. A busy card statement is 50-65
  // transactions, and at 4000 the JSON came back cut off mid-string: AMEX
  // Discretionary 26-04 failed three times with "Unterminated string in JSON at
  // position 10658" and was then dead, because a parse failure burns the attempt
  // counter. Rate limiting does NOT burn it (429 is treated as transient and
  // retried on the next tick), so trading a little more TPM pressure for no
  // truncation is strictly the better failure mode: a throttled item drains
  // later, a truncated item never drains at all.
  const llm = await callGroq(groqKey, BANK_STATEMENT_MODEL, item.system_prompt, item.user_content, 8000);
  if (!llm.ok) return { ok: false, error: llm.error };

  // 2. Parse JSON
  let json: any;
  try { json = JSON.parse(stripFences(llm.raw)); }
  catch (e) { return { ok: false, error: `JSON parse failed: ${e}. Head: ${llm.raw.slice(0, 200)}` }; }

  const period = json?.statement_period;
  if (!period?.start || !period?.end) {
    return { ok: false, error: "missing statement_period.start/.end in LLM response" };
  }
  const openingBalance = typeof json?.opening_balance === "number" ? json.opening_balance : null;
  const closingBalance = typeof json?.closing_balance === "number" ? json.closing_balance : null;
  const accountLast4 = json?.account_last4 ?? null;
  const rawTxns: any[] = Array.isArray(json?.transactions) ? json.transactions : [];

  // 3. Look up document → source_account_code
  if (!item.document_id) return { ok: false, error: "queue item has no document_id" };
  const { data: doc } = await sb
    .from("documents")
    .select("id, source_account_code, agency_id")
    .eq("id", item.document_id)
    .maybeSingle();
  if (!doc) return { ok: false, error: "document not found" };
  if (!doc.source_account_code) return { ok: false, error: "document.source_account_code missing" };

  // Look up chart_of_accounts row for this account_code + agency
  const { data: coa } = await sb
    .from("chart_of_accounts")
    .select("id, account_type, business_entity_id, account_name")
    .eq("agency_id", doc.agency_id)
    .eq("account_code", doc.source_account_code)
    .maybeSingle();
  if (!coa) return { ok: false, error: `chart_of_accounts row not found for account_code=${doc.source_account_code}` };

  const isBankAccount = coa.account_type === "asset" || coa.account_type === "bank";
  const isCreditAccount = coa.account_type === "liability" || coa.account_type === "credit";

  if (dryRun) {
    return {
      ok: true,
      statementBalance: { period, openingBalance, closingBalance, accountLast4 },
      transactionsInserted: rawTxns.length,
      docId: doc.id,
    };
  }

  // 4. Upsert statement_balances (unique on agency + account + period_end conceptually)
  // Use manual delete+insert since we don't know the exact unique constraint name.
  await sb
    .from("statement_balances")
    .delete()
    .eq("agency_id", doc.agency_id)
    .eq("account_code", doc.source_account_code)
    .eq("statement_period_end", period.end);

  const { error: sbErr } = await sb.from("statement_balances").insert({
    agency_id: doc.agency_id,
    business_entity_id: coa.business_entity_id,
    account_code: doc.source_account_code,
    account_last4: accountLast4,
    account_kind: isBankAccount ? "bank" : (isCreditAccount ? "credit" : "unknown"),
    statement_period_start: period.start,
    statement_period_end: period.end,
    opening_balance: openingBalance,
    closing_balance: closingBalance,
    source_document_id: doc.id,
    source: "llm_queue_drainer",
  });
  if (sbErr) return { ok: false, error: `statement_balances insert failed: ${sbErr.message}` };

  // 5. Insert transactions. bank_transactions.bank_account_id FKs chart_of_accounts.id
  // (misnamed column, per operational_rule). Dedup on (agency_id, bank_account_id, transaction_date, amount, description).
  let inserted = 0;
  let skippedInformational = 0;
  let skippedDuplicate = 0;
  const errors: string[] = [];
  for (const t of rawTxns) {
    if (!t || typeof t.amount !== "number" || !t.date) continue;
    const payee = String(t.payee ?? "").trim();
    if (!payee) continue;
    const memo = String(t.memo ?? "").trim();

    if (isBankAccount) {
      const row = {
        agency_id: doc.agency_id,
        business_entity_id: coa.business_entity_id,
        bank_account_id: coa.id,  // NB: FKs chart_of_accounts.id (misnamed column)
        transaction_date: t.date,
        description: memo ? `${payee} — ${memo}` : payee,
        amount: t.amount,
        transaction_type: t.amount >= 0 ? "deposit" : "withdrawal",
        source_document_id: doc.id,
      };
      const { error: btErr } = await sb
        .from("bank_transactions")
        .upsert(row, { onConflict: "agency_id,bank_account_id,transaction_date,amount,description", ignoreDuplicates: true });
      if (btErr) { errors.push(`tx ${t.date}: ${btErr.message}`); continue; }
      inserted += 1;
    } else if (isCreditAccount) {
      // Skip payment/thank-you lines on CC statements — these are informational
      // (the credit-side echo of a bank withdrawal that already gets posted from the paying
      // bank's statement). Posting them creates shadow duplicate JEs against the card liability.
      // Backfill migration 20260729235855 cleared 12 shadow JEs + 13 credit_transactions.
      // See open_question ca5f4a79.
      const descForCheck = `${payee} ${memo}`;
      if (/(?:online\s+payment|autopay|automatic\s+payment)[\s\-]*(?:thank\s*you|received)?|payment\s+thank\s*you/i.test(descForCheck)) {
        skippedInformational += 1;
        continue;
      }

      // credit_transactions has its own credit_account_id (FKs credit_accounts).
      // Look up credit_accounts row that maps to this chart account.
      const { data: ca } = await sb
        .from("credit_accounts")
        .select("id, business_entity_id")
        .eq("agency_id", doc.agency_id)
        .eq("chart_account_id", coa.id)
        .maybeSingle();
      if (!ca) { errors.push(`no credit_accounts row for chart_account_id=${coa.id}`); continue; }
      const row = {
        agency_id: doc.agency_id,
        business_entity_id: ca.business_entity_id ?? coa.business_entity_id,
        credit_account_id: ca.id,
        transaction_date: t.date,
        description: memo ? `${payee} — ${memo}` : payee,
        amount: t.amount,
        source_document_id: doc.id,
      };
      // DEDUP. The bank branch above upserts with an onConflict key; this
      // branch used a plain insert, so re-ingesting a card statement duplicated
      // every single line. That is exactly what happened on 2026-08-04 when the
      // stranded Discover Tithe zip was finally reprocessed: 5 lines from the
      // January statement landed a second time on top of pre-existing rows and
      // the period double-counted to -2244.88 against a real -1122.44 move.
      //
      // Match on account + date + amount only, NOT description. The duplicates
      // had different description text for the same charge ("REASONABLE FAITH —
      // TX Services" vs "REASONABLE FAITH 4349442618 TX"), so a description-based
      // key would not have caught them.
      const { data: dupe } = await sb
        .from("credit_transactions")
        .select("id")
        .eq("credit_account_id", ca.id)
        .eq("transaction_date", t.date)
        .eq("amount", t.amount)
        .limit(1)
        .maybeSingle();
      if (dupe) { skippedDuplicate += 1; continue; }

      const { error: ctErr } = await sb
        .from("credit_transactions")
        .insert(row);
      if (ctErr) { errors.push(`tx ${t.date}: ${ctErr.message}`); continue; }
      inserted += 1;
    }
  }

  // 6. Mark doc processed
  await sb.from("documents").update({
    processing_status: "processed",
    processed_at: new Date().toISOString(),
    notes: `${inserted} txns via llm_queue_drainer; balance ${openingBalance}→${closingBalance}${skippedInformational ? ` (${skippedInformational} payment/thank-you lines skipped)` : ""}${skippedDuplicate ? ` (${skippedDuplicate} already-present lines skipped)` : ""}${errors.length ? ` (${errors.length} tx errors)` : ""}`,
    tables_updated: ["statement_balances", isBankAccount ? "bank_transactions" : "credit_transactions"],
    records_created: inserted + 1,
  }).eq("id", doc.id);

  return {
    ok: true,
    statementBalance: { period, openingBalance, closingBalance, accountLast4 },
    transactionsInserted: inserted,
    skippedInformational,
    docId: doc.id,
    error: errors.length ? errors.slice(0, 5).join(" | ") : undefined,
  };
}

// -------------------------------------------------------------------------
// CareerPlug applicant drainer
// -------------------------------------------------------------------------
// Mirrors what processCareerplugMessage() does after a successful Groq call:
// parse applicants[] out of the JSON and call upsert_candidate_from_careerplug
// per applicant. Skips the resume-PDF path (queue items don't carry attachments);
// the RPC's email-based dedup layer will merge in resume data if the same
// applicant arrives cleanly later.
//
// Uses CAREERPLUG_MODEL (llama-3.3-70b-versatile) instead of the queued
// model (usually gpt-oss-120b) to spread TPD load — gpt-oss-120b is the model
// that hits 200K TPD daily and drops these to the queue in the first place,
// so retrying on the same model recreates the problem.
async function drainCareerplugItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<DrainResult> {
  // 1. Call Groq. Careerplug messages are small; 1500 max_tokens covers the
  // biggest daily digest we've observed.
  const llm = await callGroq(groqKey, CAREERPLUG_MODEL, item.system_prompt, item.user_content, 1500);
  if (!llm.ok) return { ok: false, error: llm.error };

  // 2. Parse JSON. Expect { "applicants": [ {...}, ... ] }
  let json: any;
  try { json = JSON.parse(stripFences(llm.raw)); }
  catch (e) { return { ok: false, error: `JSON parse failed: ${e}. Head: ${llm.raw.slice(0, 200)}` }; }

  const applicants: any[] = Array.isArray(json?.applicants) ? json.applicants : [];
  if (applicants.length === 0) {
    // LLM decided this isn't an applicant notification. Treat as success — no
    // work to do, don't need to retry.
    return { ok: true, applicantsUpserted: 0, applicantActions: [], note: "LLM returned zero applicants" };
  }

  // 3. Reconstruct source-message metadata from the user_content header lines
  // (parseWithLLM stores exactly what processCareerplugMessage passed in).
  const subject = item.user_content.match(/^SUBJECT:\s*(.+)$/m)?.[1]?.trim() ?? "";
  const fromEmail = item.user_content.match(/^FROM:\s*(.+)$/m)?.[1]?.trim() ?? "";
  const receivedAtISO = item.user_content.match(/^RECEIVED_AT \(ISO\):\s*(.+)$/m)?.[1]?.trim() ?? "";

  if (dryRun) {
    return { ok: true, applicantsUpserted: applicants.length, applicantActions: [], note: "dry_run" };
  }

  // 4. Upsert each applicant via the same RPC processCareerplugMessage uses.
  // Idempotency: RPC dedups by ingestion_metadata.source_message.gmail_message_id
  // first (we don't have that; queue doesn't preserve it), then falls back to
  // lower(email). So a same-email applicant already ingested via any path gets
  // matched and updated instead of duplicated.
  const actions: any[] = [];
  let upserted = 0;
  for (let idx = 0; idx < applicants.length; idx++) {
    const a = applicants[idx];
    const payload: Record<string, unknown> = {
      first_name: a.first_name ?? null,
      last_name:  a.last_name ?? null,
      email:      a.email ?? null,
      phone:      a.phone ?? null,
      position:   a.position ?? null,
      applied_at: a.applied_at ?? (receivedAtISO || new Date().toISOString()),
      resume_url: a.resume_url ?? null,
      resume_document_id: null,  // drainer path has no Gmail attachment access
      gmail_message_id: null,    // not preserved in llm_parse_queue schema
      careerplug_metadata: {
        prescreen_score: a.prescreen_score,
        is_fast_track:   a.is_fast_track,
        source_platform: a.source_platform,
        careerplug_applicant_id: a.careerplug_applicant_id,
        raw_line: a.raw_line,
        gmail_source_message_id: null,
        gmail_from: fromEmail,
        gmail_subject: subject,
        drained_from_queue: true,
        drainer_queue_id: item.id,
        drainer_drained_at: new Date().toISOString(),
      },
    };

    const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
      p_agency_id: item.agency_id,
      p_payload:   payload,
    });
    if (rpcErr) {
      actions.push({
        email: a.email,
        name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
        action: `rpc_error: ${rpcErr.message}`,
      });
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

  return { ok: true, applicantsUpserted: upserted, applicantActions: actions };
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);

  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  const groqKey = await getSettingOrNull(agencyId, "groq_api_key");
  if (!groqKey) return jsonResponse({ ok: false, error: "groq_api_key not set" }, 400);

  const maxItems = Math.min(Math.max(parseInt(body?.max_items ?? "10", 10) || 10, 1), 50);
  const dryRun = body?.dry_run === true;

  // Pull pending items for any supported purpose. Order by created_at so
  // oldest backlog drains first (fair-queue behavior across purposes).
  const { data: items, error: qErr } = await sb
    .from("llm_parse_queue")
    .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts")
    .eq("agency_id", agencyId)
    .eq("status", "pending")
    .in("purpose", SUPPORTED_PURPOSES)
    .lt("attempts", 3)
    .order("created_at", { ascending: true })
    .limit(maxItems);

  if (qErr) return jsonResponse({ ok: false, error: `queue read failed: ${qErr.message}` }, 500);
  if (!items || items.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "no pending items" });
  }

  const results: any[] = [];
  let totalTxns = 0;
  let totalApplicants = 0;
  let successes = 0;
  let failures = 0;
  let byPurpose: Record<string, { drained: number; ok: number; err: number }> = {};

  for (const item of items as QueueItem[]) {
    const purposeStats = byPurpose[item.purpose] ??= { drained: 0, ok: 0, err: 0 };
    purposeStats.drained += 1;

    let r: DrainResult;
    if (item.purpose === "parse_bank_statement") {
      r = await drainBankStatementItem(item, groqKey, dryRun);
    } else if (item.purpose === "careerplug_applicant_extract") {
      r = await drainCareerplugItem(item, groqKey, dryRun);
    } else {
      // Shouldn't happen — SUPPORTED_PURPOSES filter guards this. Skip defensively.
      r = { ok: false, error: `unsupported purpose: ${item.purpose}` };
    }

    if (!dryRun) {
      // Bump attempts + record result. Rate limit (429) = transient, don't count as an attempt.
      const isRateLimit = !r.ok && /Groq HTTP 429/.test(r.error ?? "");
      if (r.ok) {
        await sb.from("llm_parse_queue").update({
          status: "succeeded",
          attempts: (item.attempts ?? 0) + 1,
          last_attempt_at: new Date().toISOString(),
          completed_at: new Date().toISOString(),
          result_raw: null,
          last_error: r.error ?? null,
        }).eq("id", item.id);
      } else if (isRateLimit) {
        // Transient rate limit — don't burn the attempts counter; cron will retry.
        await sb.from("llm_parse_queue").update({
          status: "pending",
          last_attempt_at: new Date().toISOString(),
          last_error: r.error ?? "rate limited",
        }).eq("id", item.id);
      } else {
        const newAttempts = (item.attempts ?? 0) + 1;
        await sb.from("llm_parse_queue").update({
          status: newAttempts >= 3 ? "failed" : "pending",
          attempts: newAttempts,
          last_attempt_at: new Date().toISOString(),
          last_error: r.error ?? "unknown",
        }).eq("id", item.id);
      }
    }

    if (r.ok) {
      successes += 1;
      purposeStats.ok += 1;
      totalTxns += r.transactionsInserted ?? 0;
      totalApplicants += r.applicantsUpserted ?? 0;
    } else {
      failures += 1;
      purposeStats.err += 1;
    }

    results.push({
      queue_id: item.id,
      purpose: item.purpose,
      document_id: item.document_id,
      ok: r.ok,
      // Bank statement fields (undefined for careerplug):
      transactions_inserted: r.transactionsInserted,
      statement_balance: r.statementBalance,
      // Careerplug fields (undefined for bank statements):
      applicants_upserted: r.applicantsUpserted,
      applicant_actions: r.applicantActions,
      note: r.note,
      error: r.error,
    });
  }

  return jsonResponse({
    ok: true,
    drained: items.length,
    successes,
    failures,
    total_transactions_inserted: totalTxns,
    total_applicants_upserted: totalApplicants,
    by_purpose: byPurpose,
    dry_run: dryRun,
    items: results,
  });
});
