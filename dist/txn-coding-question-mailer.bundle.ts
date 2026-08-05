// =========================================================================
// txn-coding-question-mailer bundle (auto-generated)
// Source of truth: supabase/functions/txn-coding-question-mailer/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py txn-coding-question-mailer`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// ==================== _shared/supabase.ts ====================
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


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

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

async function getSetting(
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

async function getSettingOrNull(
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
async function getSettings(
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

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== _shared/auth.ts ====================
// =========================================================================
// _shared/auth.ts
// =========================================================================
// Canonical shared-secret gate for cron/internally-dispatched edge functions.
// The dispatch side (_dispatch_edge_fn, run_automation_recipe, automation-
// runner INTERNAL handlers) POSTs { agency_id, shared_secret } in the body;
// the secret must match settings.automation_runner_cron_secret.
//
// Usage in a handler:
//   const denied = await requireSharedSecret(agencyId, body.shared_secret);
//   if (denied) return denied;
// =========================================================================


async function requireSharedSecret(
  agencyId: string,
  provided: string | undefined | null,
): Promise<Response | null> {
  if (!provided) {
    return jsonResponse({ ok: false, error: "missing shared_secret" }, 401);
  }
  const expected = await getSettingOrNull(agencyId, "automation_runner_cron_secret");
  if (!expected || provided !== expected) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }
  return null;
}

// ==================== _shared/composio.ts ====================
// =========================================================================
// _shared/composio.ts
// =========================================================================
// Canonical Composio HTTP wrapper for ALL Newtworks edge functions. This is
// the one true copy of callComposio — every function that used to carry its
// own inline copy now bundles this file via scripts/bundle_edge_fn.py.
// =========================================================================

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

interface ComposioCallResult {
  ok: boolean;
  data: any;
  error: string | null;
  httpStatus: number;
}

async function callComposio(opts: {
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
      ...(opts.toolkitVersion ? { version: opts.toolkitVersion } : {}),
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

async function callComposioNoAuth(opts: {
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

// ==================== _shared/gmail.ts ====================
// =========================================================================
// _shared/gmail.ts
// =========================================================================
// Canonical "send an email through Composio Gmail" path for ALL Newtworks
// edge functions. Replaces the settings-triplet fetch + GMAIL_SEND_EMAIL
// call that used to be copy-pasted into txn-coding-question-mailer,
// license-reminder-runner, pfa-reconciliation-send, terminate-team-member
// and the document-processor wrap-up parsers.
//
// The sender account is Composio-managed paper.newt.management@gmail.com.
// =========================================================================


interface GmailCreds {
  apiKey: string;
  userId: string;
  accountId: string;
}

// One batch settings query for the three Composio Gmail credentials.
async function getComposioGmailCreds(
  agencyId: string,
): Promise<{ ok: true; creds: GmailCreds } | { ok: false; error: string }> {
  let map: Record<string, string | null>;
  try {
    map = await getSettings(agencyId, [
      "composio_api_key",
      "composio_user_id",
      "composio_gmail_account_id",
    ]);
  } catch (e) {
    return { ok: false, error: `settings read failed: ${(e as Error).message}` };
  }
  const apiKey = map["composio_api_key"];
  const userId = map["composio_user_id"];
  const accountId = map["composio_gmail_account_id"];
  if (!apiKey || !userId || !accountId) {
    return { ok: false, error: "missing Composio Gmail credentials in settings" };
  }
  return { ok: true, creds: { apiKey, userId, accountId } };
}

// Send one email. Exactly one of html / text should be provided.
// attachment (if any) must already be staged with Composio — GMAIL_SEND_EMAIL
// only accepts { name, mimetype, s3key } pointers, never raw bytes.
async function sendGmail(opts: {
  creds: GmailCreds;
  to: string;
  subject: string;
  html?: string;
  text?: string;
  cc?: string[];
  attachment?: { name: string; mimetype: string; s3key: string };
}): Promise<ComposioCallResult> {
  const args: Record<string, any> = {
    recipient_email: opts.to,
    subject: opts.subject,
    body: opts.html ?? opts.text ?? "",
    is_html: opts.html != null,
    user_id: "me",
  };
  if (opts.cc && opts.cc.length > 0) args.cc = opts.cc;
  if (opts.attachment) args.attachment = opts.attachment;

  return await callComposio({
    apiKey: opts.creds.apiKey,
    userId: opts.creds.userId,
    connectedAccountId: opts.creds.accountId,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolArguments: args,
  });
}

// ==================== _shared/html.ts ====================
// =========================================================================
// _shared/html.ts
// =========================================================================
// Tiny HTML helpers shared across the email-composing edge functions.
// Formatting helpers (money, dates) stay LOCAL to each function on purpose —
// their formats genuinely differ per surface and unifying them would change
// live email output.
// =========================================================================

function escHtml(s: string | null | undefined): string {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ==================== txn-coding-question-mailer/index.ts ====================
// =========================================================================
// txn-coding-question-mailer (Newtworks)
// =========================================================================
// Reads v_bank_register_coding_questions filtered by agency, composes a
// grouped HTML email of pending coding questions, sends via Composio Gmail.
//
// Invoked by automation-runner as an INTERNAL dispatch handler.
//
// Recipe wiring:
//   composio_action  = 'INTERNAL'
//   internal_handler = 'dispatch_txn_coding_question_mailer'
//   input_config:
//     {
//       "recipient_email": "paper.newt.management@gmail.com",
//       "only_if_rows_exist": true,
//       "subject_template": "❓ {count} Transaction(s) Need Your Input — {date}"
//     }
// =========================================================================

// deno-lint-ignore-file no-explicit-any

function fmtMoney(n: number): string {
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function fmtDate(iso: string): string {
  const [y, m, d] = iso.split("-").map((x) => parseInt(x, 10));
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return `${months[m - 1]} ${d}, ${y}`;
}

function buildBody(rows: any[]): string {
  const needsReview = rows.filter((r) => r.coding_status === "needs_peter");
  const unclassified = rows.filter((r) => r.coding_status === "unclassified" || r.coding_status == null);

  const section = (title: string, subset: any[], hint: string) => {
    if (subset.length === 0) return "";
    const items = subset
      .map((r) => {
        const arrow = r.direction === "credit" ? "↓" : "↑";
        const merchant = r.merchant ? ` — <em>${escHtml(r.merchant)}</em>` : "";
        const suggestion = r.suggested_debit_account
          ? `<div style="margin-top:4px;font-size:13px;color:#475569;">Suggested: <b>${escHtml(r.suggested_debit_account)}</b> / <b>${escHtml(r.suggested_credit_account)}</b> <span style="color:#94a3b8;">(${escHtml(r.suggested_confidence || "")})</span></div>`
          : `<div style="margin-top:4px;font-size:13px;color:#94a3b8;">No rule matched — manual coding needed</div>`;
        return `
          <tr>
            <td style="padding:10px 8px;border-bottom:1px solid #e2e8f0;vertical-align:top;">
              <div style="font-size:13px;color:#0f172a;font-weight:600;">
                ${fmtDate(r.txn_date)} · ${arrow} ${fmtMoney(parseFloat(r.amount))} · ${escHtml(r.account_label || "")}${merchant}
              </div>
              ${suggestion}
              ${r.coding_question ? `<div style="margin-top:4px;font-size:12px;color:#64748b;font-style:italic;">${escHtml(r.coding_question)}</div>` : ""}
            </td>
          </tr>`;
      })
      .join("");
    return `
      <h3 style="margin:20px 0 6px 0;font-size:14px;color:#0f172a;">${title} (${subset.length})</h3>
      <div style="font-size:12px;color:#64748b;margin-bottom:6px;">${hint}</div>
      <table style="width:100%;border-collapse:collapse;">${items}</table>`;
  };

  return `<!DOCTYPE html>
<html><body style="margin:0;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f8fafc;">
<div style="max-width:640px;margin:0 auto;background:#fff;padding:24px;border-radius:8px;">
  <h2 style="margin:0 0 6px 0;font-size:18px;color:#0f172a;">Cash Register — pending your input</h2>
  <div style="font-size:13px;color:#64748b;margin-bottom:8px;">${rows.length} transaction(s) in the register haven't hit the GL yet.</div>
  ${section("Suggested — please confirm", needsReview, "A rule matched but confidence is medium/low. Confirm or override.")}
  ${section("Unclassified — no rule matched", unclassified, "Manual coding needed. Adding a rule for these prevents future ones from stacking up.")}
  <div style="margin-top:24px;padding-top:16px;border-top:1px solid #e2e8f0;font-size:12px;color:#94a3b8;">
    Code these in Newtworks → Financials → Cash Register.
  </div>
</div>
</body></html>`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "POST only" }, 405);
  }
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }

  const agencyId: string | undefined = body.agency_id;
  const sharedSecret: string | undefined = body.shared_secret;
  const recipient: string = body.recipient_email || "paper.newt.management@gmail.com";
  const onlyIfRowsExist: boolean = body.only_if_rows_exist !== false; // default true
  const subjectTemplate: string = body.subject_template || "❓ {count} Transaction(s) Need Your Input — {date}";

  if (!agencyId) {
    return jsonResponse({ ok: false, error: "missing agency_id" }, 400);
  }
  const denied = await requireSharedSecret(agencyId, sharedSecret);
  if (denied) return denied;

  // Read pending coding questions
  const { data: rows, error: viewErr } = await sb
    .from("v_bank_register_coding_questions")
    .select("id, txn_date, account_label, direction, amount, merchant, suggested_debit_account, suggested_credit_account, suggested_confidence, coding_status, coding_question, status")
    .eq("agency_id", agencyId)
    .order("txn_date", { ascending: false })
    .order("amount", { ascending: false });
  if (viewErr) {
    return jsonResponse({ ok: false, error: `view read failed: ${viewErr.message}` }, 500);
  }
  const count = rows?.length ?? 0;

  if (count === 0 && onlyIfRowsExist) {
    return jsonResponse({
      ok: true,
      records_processed: 0,
      output_summary: "0 pending coding questions — no email sent",
    });
  }

  // Compose email
  const todayIso = new Date().toISOString().split("T")[0];
  const subject = subjectTemplate.replace("{count}", String(count)).replace("{date}", fmtDate(todayIso));
  const html = buildBody(rows || []);

  // Send via Composio Gmail
  const credsRes = await getComposioGmailCreds(agencyId);
  if (!credsRes.ok) {
    return jsonResponse({ ok: false, error: credsRes.error }, 500);
  }

  const sendResult = await sendGmail({
    creds: credsRes.creds,
    to: recipient,
    subject,
    html,
  });

  if (!sendResult.ok) {
    return jsonResponse({
      ok: false,
      error: `Composio GMAIL_SEND_EMAIL failed: ${sendResult.error}`,
      records_processed: 0,
      output_summary: `Failed to send: ${sendResult.error}`,
    }, 500);
  }

  return jsonResponse({
    ok: true,
    records_processed: count,
    output_summary: `Sent coding-question email to ${recipient} — ${count} rows`,
  });
});
