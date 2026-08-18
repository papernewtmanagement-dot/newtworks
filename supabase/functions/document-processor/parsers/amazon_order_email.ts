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
// count. Peter does not want periodic manual CSV re-uploads, so this is
// treated as the permanent data ceiling for live orders, not a temporary
// gap: entity/card attribution comes from
// match_amazon_orders_to_cash_register() (matches grand_total + date
// against cash_register_preliminary, resolves the card via the accounts
// table), and GL categorization comes from amazon_categorize_email_orders()
// (matches the subject-line category text against
// amazon_order_category_rules, entity-aware, then writes the account onto
// the ledger row via the exact matched_cash_register_id -> ledger.
// cash_register_id link). Both added 2026-08-18, both called at the end of
// every batch below — safe to call every run, each only touches rows it
// hasn't resolved yet. This is a coarser categorization than the
// item-level system (amazon_apply_charge_categories) that runs against the
// CSV-imported historical orders, which has actual product names to work
// from — that's an accepted, permanent tradeoff, not a bug.
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

import { sb } from "../../_shared/supabase.ts";
import { callComposio } from "../lib/composio.ts";

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

  // Now that entity attribution may have just resolved some orders, apply
  // order-level GL categorization (from the subject-line category, since
  // live orders have no item-level detail) to any newly-matched orders.
  // Safe to call every run — only touches orders with a resolved entity,
  // a resolved ledger row, and no existing item-level categorization.
  let categorized = 0;
  try {
    const { data: catRows, error: catErr } = await sb.rpc("amazon_categorize_email_orders", {
      p_agency_id: ctx.agencyId,
      p_dry_run: false,
    });
    if (!catErr && Array.isArray(catRows)) {
      categorized = catRows.filter((r: any) => typeof r.note === "string" && r.note.startsWith("moved to")).length;
    }
  } catch (e) {
    console.warn("amazon_categorize_email_orders call threw (non-fatal):", e);
  }

  return { ok: true, processed, skipped, errors, message_count: messages.length, matched, categorized, results };
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

  // Subject: "Ordered: N <Category> item(s)" — the current live template.
  // An OLDER template also exists in the mailbox backlog: 'Ordered: "Product
  // title..."' or 'Ordered: N "Product title..." and M more items' (no
  // category at all, just a truncated product name — sometimes itself
  // starting with a digit, e.g. '7" Heirloom...', which makes a leading
  // digit unreliable as an item count in this template). Category/item
  // count are a nice-to-have, not a requirement: every message whose BODY
  // yields an order_id and grand_total gets inserted and starred regardless
  // of which subject template it used. Only a body-extraction failure is a
  // hard error (see below).
  const subjMatch = subject.match(/Ordered:\s*(\d+)\s+(.+?)\s+items?\s*$/i);
  const itemCount = subjMatch ? parseInt(subjMatch[1], 10) : null;
  const category = subjMatch ? subjMatch[2].trim() : null;

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
