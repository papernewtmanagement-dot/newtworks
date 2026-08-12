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

import { sb } from "../../_shared/supabase.ts";
import { callComposio } from "../lib/composio.ts";

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
