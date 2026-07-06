// =========================================================================
// suspense.ts
// =========================================================================
// For each JE that landed in COA-SUSP, create a task in the tasks table so
// the agent can classify it. Task includes up to 3 LLM-ranked best guesses.
//
// Priority by amount:  >$500=high, $100-500=medium, <$100=low
// =========================================================================

import { sb } from "./lib/supabase.ts";
import type { BankTxn } from "./classifier.ts";
import { parseWithLLM } from "./lib/llm.ts";

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
