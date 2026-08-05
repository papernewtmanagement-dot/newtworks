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
import { sb, jsonResponse } from "../_shared/supabase.ts";
import { requireSharedSecret } from "../_shared/auth.ts";
import { getComposioGmailCreds, sendGmail } from "../_shared/gmail.ts";
import { escHtml } from "../_shared/html.ts";

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
