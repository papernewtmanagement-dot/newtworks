// llm-queue-drainer edge function
//
// Purpose: Drains pending items in public.llm_parse_queue that document-processor
// couldn't complete synchronously (transient Groq failures, JSON parse issues,
// max_tokens truncations). Focused on purpose='parse_bank_statement' — the biggest
// backlog and the one that matters most for the P&L.
//
// Flow per item:
//   1. Call Groq direct with stored system_prompt + user_content
//   2. Parse JSON
//   3. Look up chart_of_accounts by source_account_code
//   4. Upsert statement_balances row
//   5. Insert bank_transactions rows (dedup index handles idempotency)
//   6. Update documents.processing_status = 'processed'
//   7. Mark queue item completed
//
// The daily bank_gl_writer cron picks up bank_transactions and creates JEs — this
// drainer intentionally stops at bank_transactions to keep responsibilities narrow.
//
// Invocation: POST { agency_id, shared_secret, [max_items=10, dry_run=false] }

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const LLM_MODEL_FALLBACK = "openai/gpt-oss-120b";
// Bank statements run 11-13K tokens which exceeds gpt-oss-120b's 8000 TPM limit.
// Force a model with higher throughput for the drainer regardless of stored model.
const BANK_STATEMENT_MODEL = "llama-3.3-70b-versatile";

const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  return (data?.setting_value as string) ?? null;
}

function stripFences(s: string): string {
  return s.replace(/^```(?:json)?\s*/i, "").replace(/\s*```\s*$/i, "").trim();
}

async function callGroq(apiKey: string, model: string, systemPrompt: string, userContent: string, maxTokens = 8000): Promise<{ ok: boolean; raw: string; error?: string }> {
  try {
    const res = await fetch(GROQ_ENDPOINT, {
      method: "POST",
      headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: userContent },
        ],
        temperature: 0.1,
        max_tokens: maxTokens,
      }),
    });
    const text = await res.text();
    if (!res.ok) return { ok: false, raw: "", error: `Groq HTTP ${res.status}: ${text.slice(0, 400)}` };
    let parsed: any;
    try { parsed = JSON.parse(text); }
    catch (e) { return { ok: false, raw: text, error: `non-JSON envelope: ${e}` }; }
    const content = parsed?.choices?.[0]?.message?.content ?? "";
    if (!content) return { ok: false, raw: "", error: "empty content" };
    return { ok: true, raw: content };
  } catch (e) {
    return { ok: false, raw: "", error: `fetch failed: ${(e as Error).message}` };
  }
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

async function drainBankStatementItem(item: QueueItem, groqKey: string, dryRun: boolean): Promise<{
  ok: boolean;
  error?: string;
  statementBalance?: any;
  transactionsInserted?: number;
  docId?: string | null;
}> {
  // 1. Call Groq (force higher-TPM model for bank statements — see rate limit note above).
  // Cap max_tokens at 4000 to stay under 12K TPM even for the biggest statements.
  const llm = await callGroq(groqKey, BANK_STATEMENT_MODEL, item.system_prompt, item.user_content, 4000);
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
    notes: `${inserted} txns via llm_queue_drainer; balance ${openingBalance}→${closingBalance}${errors.length ? ` (${errors.length} tx errors)` : ""}`,
    tables_updated: ["statement_balances", isBankAccount ? "bank_transactions" : "credit_transactions"],
    records_created: inserted + 1,
  }).eq("id", doc.id);

  return {
    ok: true,
    statementBalance: { period, openingBalance, closingBalance, accountLast4 },
    transactionsInserted: inserted,
    docId: doc.id,
    error: errors.length ? errors.slice(0, 5).join(" | ") : undefined,
  };
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); }
  catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);

  const expectedSecret = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expectedSecret || expectedSecret !== sharedSecret) {
    return jsonResponse({ ok: false, error: "auth failed" }, 401);
  }

  const groqKey = await getSetting(agencyId, "groq_api_key");
  if (!groqKey) return jsonResponse({ ok: false, error: "groq_api_key not set" }, 400);

  const maxItems = Math.min(Math.max(parseInt(body?.max_items ?? "10", 10) || 10, 1), 50);
  const dryRun = body?.dry_run === true;

  // Pull pending bank statement items for this agency
  const { data: items, error: qErr } = await sb
    .from("llm_parse_queue")
    .select("id, agency_id, document_id, purpose, system_prompt, user_content, model, attempts")
    .eq("agency_id", agencyId)
    .eq("status", "pending")
    .eq("purpose", "parse_bank_statement")
    .lt("attempts", 3)
    .order("created_at", { ascending: true })
    .limit(maxItems);

  if (qErr) return jsonResponse({ ok: false, error: `queue read failed: ${qErr.message}` }, 500);
  if (!items || items.length === 0) {
    return jsonResponse({ ok: true, drained: 0, message: "no pending items" });
  }

  const results: any[] = [];
  let totalTxns = 0;
  let successes = 0;
  let failures = 0;

  for (const item of items as QueueItem[]) {
    const r = await drainBankStatementItem(item, groqKey, dryRun);

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

    if (r.ok) { successes += 1; totalTxns += r.transactionsInserted ?? 0; }
    else failures += 1;

    results.push({
      queue_id: item.id,
      document_id: item.document_id,
      ok: r.ok,
      transactions_inserted: r.transactionsInserted ?? 0,
      statement_balance: r.statementBalance,
      error: r.error,
    });
  }

  return jsonResponse({
    ok: true,
    drained: items.length,
    successes,
    failures,
    total_transactions_inserted: totalTxns,
    dry_run: dryRun,
    items: results,
  });
});
