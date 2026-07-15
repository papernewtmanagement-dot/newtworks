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
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const COMPOSIO_BASE = "https://backend.composio.dev/api/v3/tools/execute";

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) throw new Error(`settings read failed: ${key}: ${error.message}`);
  return data?.setting_value ?? null;
}

function fmtMoney(n: number): string {
  return `$${n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function fmtDate(iso: string): string {
  const [y, m, d] = iso.split("-").map((x) => parseInt(x, 10));
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return `${months[m - 1]} ${d}, ${y}`;
}

function esc(s: string | null | undefined): string {
  if (s == null) return "";
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function callComposio(opts: {
  apiKey: string;
  userId: string;
  connectedAccountId: string;
  toolSlug: string;
  toolArguments: Record<string, any>;
}): Promise<{ ok: boolean; data: any; error: string | null; httpStatus: number }> {
  const res = await fetch(`${COMPOSIO_BASE}/${opts.toolSlug}`, {
    method: "POST",
    headers: { "x-api-key": opts.apiKey, "Content-Type": "application/json" },
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
  const error = ok ? null : (parsed?.error?.message || parsed?.error || text.slice(0, 400));
  return { ok, data, error, httpStatus: res.status };
}

function buildBody(rows: any[]): string {
  const needsReview = rows.filter((r) => r.coding_status === "needs_peter");
  const unclassified = rows.filter((r) => r.coding_status === "unclassified" || r.coding_status == null);

  const section = (title: string, subset: any[], hint: string) => {
    if (subset.length === 0) return "";
    const items = subset
      .map((r) => {
        const arrow = r.direction === "credit" ? "↓" : "↑";
        const merchant = r.merchant ? ` — <em>${esc(r.merchant)}</em>` : "";
        const suggestion = r.suggested_debit_account
          ? `<div style="margin-top:4px;font-size:13px;color:#475569;">Suggested: <b>${esc(r.suggested_debit_account)}</b> / <b>${esc(r.suggested_credit_account)}</b> <span style="color:#94a3b8;">(${esc(r.suggested_confidence || "")})</span></div>`
          : `<div style="margin-top:4px;font-size:13px;color:#94a3b8;">No rule matched — manual coding needed</div>`;
        return `
          <tr>
            <td style="padding:10px 8px;border-bottom:1px solid #e2e8f0;vertical-align:top;">
              <div style="font-size:13px;color:#0f172a;font-weight:600;">
                ${fmtDate(r.txn_date)} · ${arrow} ${fmtMoney(parseFloat(r.amount))} · ${esc(r.account_label || "")}${merchant}
              </div>
              ${suggestion}
              ${r.coding_question ? `<div style="margin-top:4px;font-size:12px;color:#64748b;font-style:italic;">${esc(r.coding_question)}</div>` : ""}
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
    return new Response(JSON.stringify({ ok: false, error: "POST only" }), { status: 405 });
  }
  let body: any = {};
  try { body = await req.json(); } catch { /* empty */ }

  const agencyId: string | undefined = body.agency_id;
  const sharedSecret: string | undefined = body.shared_secret;
  const recipient: string = body.recipient_email || "paper.newt.management@gmail.com";
  const onlyIfRowsExist: boolean = body.only_if_rows_exist !== false; // default true
  const subjectTemplate: string = body.subject_template || "❓ {count} Transaction(s) Need Your Input — {date}";

  if (!agencyId) {
    return new Response(JSON.stringify({ ok: false, error: "missing agency_id" }), { status: 400 });
  }
  if (!sharedSecret) {
    return new Response(JSON.stringify({ ok: false, error: "missing shared_secret" }), { status: 401 });
  }
  const expectedSecret = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expectedSecret || sharedSecret !== expectedSecret) {
    return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), { status: 401 });
  }

  // Read pending coding questions
  const { data: rows, error: viewErr } = await sb
    .from("v_bank_register_coding_questions")
    .select("id, txn_date, account_label, direction, amount, merchant, suggested_debit_account, suggested_credit_account, suggested_confidence, coding_status, coding_question, status")
    .eq("agency_id", agencyId)
    .order("txn_date", { ascending: false })
    .order("amount", { ascending: false });
  if (viewErr) {
    return new Response(JSON.stringify({ ok: false, error: `view read failed: ${viewErr.message}` }), { status: 500 });
  }
  const count = rows?.length ?? 0;

  if (count === 0 && onlyIfRowsExist) {
    return new Response(JSON.stringify({
      ok: true,
      records_processed: 0,
      output_summary: "0 pending coding questions — no email sent",
    }), { status: 200, headers: { "Content-Type": "application/json" } });
  }

  // Compose email
  const todayIso = new Date().toISOString().split("T")[0];
  const subject = subjectTemplate.replace("{count}", String(count)).replace("{date}", fmtDate(todayIso));
  const html = buildBody(rows || []);

  // Send via Composio Gmail
  const composioApiKey = await getSetting(agencyId, "composio_api_key");
  const composioUserId = await getSetting(agencyId, "composio_user_id");
  const gmailAccountId = await getSetting(agencyId, "composio_gmail_account_id");
  if (!composioApiKey || !composioUserId || !gmailAccountId) {
    return new Response(JSON.stringify({
      ok: false,
      error: "missing Composio Gmail credentials in settings",
    }), { status: 500 });
  }

  const sendResult = await callComposio({
    apiKey: composioApiKey,
    userId: composioUserId,
    connectedAccountId: gmailAccountId,
    toolSlug: "GMAIL_SEND_EMAIL",
    toolArguments: {
      recipient_email: recipient,
      subject: subject,
      body: html,
      is_html: true,
    },
  });

  if (!sendResult.ok) {
    return new Response(JSON.stringify({
      ok: false,
      error: `Composio GMAIL_SEND_EMAIL failed: ${sendResult.error}`,
      records_processed: 0,
      output_summary: `Failed to send: ${sendResult.error}`,
    }), { status: 500, headers: { "Content-Type": "application/json" } });
  }

  return new Response(JSON.stringify({
    ok: true,
    records_processed: count,
    output_summary: `Sent coding-question email to ${recipient} — ${count} rows`,
  }), { status: 200, headers: { "Content-Type": "application/json" } });
});
