// =========================================================================
// document-processor / index.ts
// =========================================================================
// Edge Function entry point. Intended cron: */30 minutes.
//
// PURPOSE: Single unified document intake pipeline. Replaces the 12-recipe
// approach with one orchestrator that handles every doc type uniformly.
//
// FLOW (per spec):
//   1. fetchNewGmailAttachments()
//   2. for each attachment:
//        a. classifyDocument(filename, sender) → docType
//        b. download
//        c. uploadToDrive(folder for that docType)
//        d. insertSourceDocument(...)
//        e. switch(docType):
//             bank_statement_*    → parseBank → write txns → postGL → suspense
//             everything else     → stub: mark awaiting_parser_implementation
//   3. return summary
//
// CURRENT BUILD STATE:
//   - Orchestrator: ✅
//   - Bank statement path (full GL post + suspense loop): ✅
//   - All other doc types: stub (parsers land in Phase 2)
//
// AUTH:
//   POST body must include shared_secret matching the agency's
//   automation_runner_cron_secret. Body must include agency_id.
// =========================================================================

// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, getSetting, jsonResponse } from "./lib/supabase.ts";
import { callComposio } from "./lib/composio.ts";
import { classifyDocument, classifyBankTxn, DocType } from "./classifier.ts";
import { parseBankStatement } from "./parsers/bank.ts";
import { parseCompRecap } from "./parsers/comp_recap.ts";
import { parseDeductionStatement } from "./parsers/deduction.ts";
import { parsePayrollRun } from "./parsers/payroll.ts";
import { parseProductionReport } from "./parsers/production.ts";
import { postJournalEntry } from "./gl-poster.ts";
import { createSuspenseTask } from "./suspense.ts";

interface RunCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
}

interface ProcessedAttachment {
  documentId: string;
  fileName: string;
  fromEmail: string;
  docType: DocType;
  status: "processed" | "skipped" | "queued" | "error" | "stub_pending";
  jeCount: number;
  suspenseCount: number;
  error?: string;
  queueId?: string;
}

// ---- Gmail intake ----------------------------------------------------------

interface GmailAttachment {
  messageId: string;
  fromEmail: string;
  subject: string;
  receivedAt: string;
  fileName: string;
  mimeType: string;
  attachmentId: string;
}

async function fetchNewGmailAttachments(ctx: RunCtx): Promise<GmailAttachment[]> {
  const lookback = "newer_than:1d has:attachment";

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query: lookback, max_results: 50 },
  });

  if (!listRes.ok) throw new Error(`Gmail fetch failed: ${listRes.error}`);

  const messages: any[] = listRes.data?.messages ?? listRes.data ?? [];
  const attachments: GmailAttachment[] = [];

  for (const m of messages) {
    const headers = m?.payload?.headers ?? [];
    const fromEmail = m?.from ?? headers.find((h: any) => h.name === "From")?.value ?? "";
    const subject = m?.subject ?? headers.find((h: any) => h.name === "Subject")?.value ?? "";
    const receivedAt = m?.internalDate
      ? new Date(Number(m.internalDate)).toISOString()
      : new Date().toISOString();
    const parts: any[] = m?.payload?.parts ?? m?.parts ?? [];
    for (const p of parts) {
      const filename = p?.filename;
      if (!filename) continue;
      const attId = p?.body?.attachmentId;
      if (!attId) continue;

      // Idempotency: skip if already in documents
      const { data: existing } = await sb
        .from("documents")
        .select("id")
        .eq("agency_id", ctx.agencyId)
        .eq("file_name", filename)
        .eq("upload_source", "gmail")
        .gte("uploaded_at", new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString())
        .maybeSingle();
      if (existing?.id) continue;

      attachments.push({
        messageId: m.id,
        fromEmail,
        subject,
        receivedAt,
        fileName: filename,
        mimeType: p?.mimeType ?? "application/octet-stream",
        attachmentId: attId,
      });
    }
  }
  return attachments;
}

async function downloadAttachment(ctx: RunCtx, att: GmailAttachment): Promise<string | null> {
  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: { message_id: att.messageId, attachment_id: att.attachmentId },
  });
  if (!res.ok) return null;
  return res.data?.data ?? res.data?.bytes ?? null;
}

// ---- Drive upload ----------------------------------------------------------

const DRIVE_FOLDER_BY_DOCTYPE: Record<DocType, string> = {
  bank_statement_primary: "bank-statements",
  bank_statement_secondary: "bank-statements",
  comp_recap_1h: "sf-comp-recap",
  comp_recap_daily: "sf-comp-recap",
  deduction_statement: "sf-deductions",
  adp_payroll: "payroll",
  commission_report: "commission-reports",
  team_production: "team-production",
  skip: "unsorted",
};

async function uploadToDrive(
  ctx: RunCtx, att: GmailAttachment, bytesB64: string, docType: DocType, txnDate: string,
): Promise<{ driveFileId: string; driveUrl: string } | null> {
  if (!ctx.driveAccountId) return null;
  const folder = DRIVE_FOLDER_BY_DOCTYPE[docType];
  const yearMonth = txnDate.slice(0, 7);
  const path = `BCC/Documents/${yearMonth}/${folder}/${att.fileName}`;

  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.driveAccountId,
    toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
    toolArguments: {
      file_name: att.fileName,
      file_path: path,
      content_base64: bytesB64,
      mime_type: att.mimeType,
    },
  });
  if (!res.ok) return null;
  return {
    driveFileId: res.data?.id ?? res.data?.file_id ?? "",
    driveUrl: res.data?.webViewLink ?? res.data?.url ?? "",
  };
}

// ---- documents row ---------------------------------------------------------

async function insertSourceDocument(
  ctx: RunCtx, att: GmailAttachment, docType: DocType,
  drive: { driveFileId: string; driveUrl: string } | null,
  sourceAccountCode: string | null,
): Promise<string> {
  const { data, error } = await sb
    .from("documents")
    .insert({
      agency_id: ctx.agencyId,
      file_name: att.fileName,
      file_type: att.mimeType,
      upload_source: "gmail",
      drive_file_id: drive?.driveFileId ?? null,
      drive_url: drive?.driveUrl ?? null,
      processing_status: "received",
      processing_type: "document_processor",
      groq_classification: docType,
      source_account_code: sourceAccountCode,
      uploaded_by: att.fromEmail,
      uploaded_at: att.receivedAt,
      notes: `subject: ${att.subject}`,
    })
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
  ctx: RunCtx, att: GmailAttachment, bytesB64: string,
): Promise<{ ok: true; text: string } | { ok: false; error: string }> {
  if (att.mimeType.startsWith("text/") || att.fileName.endsWith(".txt") || att.fileName.endsWith(".csv")) {
    try {
      const decoded = atob(bytesB64);
      return { ok: true, text: decoded };
    } catch (e) {
      return { ok: false, error: `text decode failed: ${String(e)}` };
    }
  }

  // PDF path — try Composio's hosted PDF→text. If unavailable, caller queues.
  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.composioUserId,
    toolSlug: "COMPOSIO_SEARCH_PDF_TO_TEXT",
    toolArguments: { file_base64: bytesB64 },
  });
  if (!res.ok) return { ok: false, error: `pdf→text tool failed: ${res.error}` };
  const text = res.data?.text ?? res.data?.content ?? "";
  if (!text) return { ok: false, error: "pdf→text returned empty content" };
  return { ok: true, text };
}

// ---- Per-docType handlers --------------------------------------------------

async function handleBankStatement(
  ctx: RunCtx, att: GmailAttachment, documentId: string,
  bytesB64: string, sourceAccountCode: string,
): Promise<{ jeCount: number; suspenseCount: number; queueId?: string; error?: string }> {
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

  let jeCount = 0;
  let suspenseCount = 0;
  for (const row of parsed.transactions) {
    const classification = await classifyBankTxn(ctx.agencyId, row.txn);
    const post = await postJournalEntry({
      agencyId: ctx.agencyId,
      txn: row.txn,
      txnDate: row.date,
      classification,
      sourceDocumentId: documentId,
    });
    if (post.skipped) continue;
    jeCount += 1;
    if (post.isSuspense && post.journalEntryId) {
      await createSuspenseTask({
        agencyId: ctx.agencyId,
        composioApiKey: ctx.composioApiKey,
        composioUserId: ctx.composioUserId,
        journalEntryId: post.journalEntryId,
        txn: row.txn,
        txnDate: row.date,
      });
      suspenseCount += 1;
    }
  }
  return { jeCount, suspenseCount };
}

async function handleStub(docType: DocType, documentId: string): Promise<void> {
  await markDocument(
    documentId, "awaiting_parser_implementation",
    0, [], `Parser for ${docType} not yet implemented in this build`,
  );
}

function resolveSourceAccount(fromEmail: string, subject: string): string {
  const blob = (fromEmail + " " + subject).toLowerCase();
  if (/usbank|us[\s_-]?bank/.test(blob)) return "QBO-007";
  if (/truist|trb/.test(blob)) return "QBO-004";
  if (/chase/.test(blob)) return "QBO-011";
  if (/statefarm|sf[\s.-]?ach/.test(blob)) return "QBO-024";
  if (/amex|american[\s_-]?express/.test(blob)) return "QBO-009";
  if (/capital[\s_-]?one/.test(blob)) return "QBO-010";
  if (/citi/.test(blob)) return "QBO-028";
  if (/spark/.test(blob)) return "QBO-026";
  return "QBO-007";
}

// ---- Main handler ----------------------------------------------------------

async function run(req: Request): Promise<Response> {
  let body: any = {};
  try { body = await req.json(); } catch { return jsonResponse({ ok: false, error: "invalid JSON body" }, 400); }

  const agencyId = body?.agency_id as string;
  const sharedSecret = body?.shared_secret as string;
  if (!agencyId) return jsonResponse({ ok: false, error: "agency_id required" }, 400);

  const expected = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expected || expected !== sharedSecret) return jsonResponse({ ok: false, error: "auth failed" }, 401);

  const composioApiKey = await getSetting(agencyId, "composio_api_key");
  const composioUserId = await getSetting(agencyId, "composio_user_id");
  const gmailAccountId = await getSetting(agencyId, "composio_gmail_account_id");
  const driveAccountId = await getSetting(agencyId, "composio_googledrive_account_id");
  if (!composioApiKey || !composioUserId || !gmailAccountId) {
    return jsonResponse({
      ok: false,
      error: "missing composio_api_key / composio_user_id / composio_gmail_account_id",
    }, 400);
  }

  const ctx: RunCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
  const startedAt = new Date().toISOString();
  const processed: ProcessedAttachment[] = [];

  let attachments: GmailAttachment[];
  try {
    attachments = await fetchNewGmailAttachments(ctx);
  } catch (e) {
    return jsonResponse({
      ok: false,
      error: `gmail intake failed: ${(e as Error).message}`,
      started_at: startedAt,
    }, 500);
  }

  for (const att of attachments) {
    try {
      const docType = classifyDocument({
        fromEmail: att.fromEmail, subject: att.subject, fileName: att.fileName,
      });
      if (docType === "skip") {
        processed.push({
          documentId: "", fileName: att.fileName, fromEmail: att.fromEmail,
          docType, status: "skipped", jeCount: 0, suspenseCount: 0,
        });
        continue;
      }

      const bytesB64 = await downloadAttachment(ctx, att);
      if (!bytesB64) {
        processed.push({
          documentId: "", fileName: att.fileName, fromEmail: att.fromEmail,
          docType, status: "error", jeCount: 0, suspenseCount: 0,
          error: "attachment download failed",
        });
        continue;
      }

      const txnDate = att.receivedAt.slice(0, 10);
      const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate);
      const isBankStmt = docType === "bank_statement_primary" || docType === "bank_statement_secondary";
      const sourceAccountCode = isBankStmt ? resolveSourceAccount(att.fromEmail, att.subject) : null;
      const documentId = await insertSourceDocument(ctx, att, docType, drive, sourceAccountCode);

      switch (docType) {
        case "bank_statement_primary":
        case "bank_statement_secondary": {
          const src = sourceAccountCode as string;
          const result = await handleBankStatement(ctx, att, documentId, bytesB64, src);
          if (result.queueId) {
            await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${result.queueId}`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "queued", jeCount: 0, suspenseCount: 0, queueId: result.queueId,
            });
          } else if (result.error) {
            await markDocument(documentId, "error", 0, [], result.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: result.error,
            });
          } else {
            await markDocument(
              documentId, "processed", result.jeCount,
              ["journal_entries", "journal_lines"],
              `${result.jeCount} JEs posted, ${result.suspenseCount} in suspense`,
            );
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "processed",
              jeCount: result.jeCount, suspenseCount: result.suspenseCount,
            });
          }
          break;
        }
        case "comp_recap_1h":
        case "comp_recap_daily": {
          const variant = docType === "comp_recap_1h" ? "1H" : "DAILY";
          const extracted = await extractText(ctx, att, bytesB64);
          if (!extracted.ok) {
            await markDocument(documentId, "error", 0, [], extracted.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: extracted.error,
            });
            break;
          }
          const r = await parseCompRecap({
            agencyId: ctx.agencyId, composioApiKey: ctx.composioApiKey,
            composioUserId: ctx.composioUserId, documentId,
            recapVariant: variant as "1H" | "DAILY", statementText: extracted.text,
          });
          if (r.ok) {
            await markDocument(documentId, "processed", r.written, ["comp_recap"],
              `${r.written} comp_recap rows written`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "processed", jeCount: 0, suspenseCount: 0,
            });
          } else if (r.queued) {
            await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "queued", jeCount: 0, suspenseCount: 0, queueId: r.queueId,
            });
          } else {
            await markDocument(documentId, "error", 0, [], r.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: r.error,
            });
          }
          break;
        }
        case "deduction_statement": {
          const extracted = await extractText(ctx, att, bytesB64);
          if (!extracted.ok) {
            await markDocument(documentId, "error", 0, [], extracted.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: extracted.error,
            });
            break;
          }
          const r = await parseDeductionStatement({
            agencyId: ctx.agencyId, composioApiKey: ctx.composioApiKey,
            composioUserId: ctx.composioUserId, documentId, statementText: extracted.text,
          });
          if (r.ok) {
            await markDocument(documentId, "processed", r.written, ["comp_recap"],
              `${r.written} deduction rows written`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "processed", jeCount: 0, suspenseCount: 0,
            });
          } else if (r.queued) {
            await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "queued", jeCount: 0, suspenseCount: 0, queueId: r.queueId,
            });
          } else {
            await markDocument(documentId, "error", 0, [], r.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: r.error,
            });
          }
          break;
        }
        case "adp_payroll": {
          const extracted = await extractText(ctx, att, bytesB64);
          if (!extracted.ok) {
            await markDocument(documentId, "error", 0, [], extracted.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: extracted.error,
            });
            break;
          }
          const r = await parsePayrollRun({
            agencyId: ctx.agencyId, composioApiKey: ctx.composioApiKey,
            composioUserId: ctx.composioUserId, documentId, statementText: extracted.text,
          });
          if (r.ok) {
            await markDocument(documentId, "processed", r.detailCount + 1,
              ["payroll_runs", "payroll_detail"],
              `payroll run ${r.run.pay_date}: ${r.detailCount} detail rows`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "processed", jeCount: 0, suspenseCount: 0,
            });
          } else if (r.queued) {
            await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "queued", jeCount: 0, suspenseCount: 0, queueId: r.queueId,
            });
          } else {
            await markDocument(documentId, "error", 0, [], r.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: r.error,
            });
          }
          break;
        }
        case "commission_report":
        case "team_production": {
          const extracted = await extractText(ctx, att, bytesB64);
          if (!extracted.ok) {
            await markDocument(documentId, "error", 0, [], extracted.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: extracted.error,
            });
            break;
          }
          const r = await parseProductionReport({
            agencyId: ctx.agencyId, composioApiKey: ctx.composioApiKey,
            composioUserId: ctx.composioUserId, documentId,
            reportVariant: docType as "commission_report" | "team_production",
            statementText: extracted.text,
          });
          if (r.ok) {
            const note = r.unmatchedStaff.length > 0
              ? `${r.written} rows written; ${r.unmatchedStaff.length} unmatched: ${r.unmatchedStaff.slice(0,5).join(", ")}`
              : `${r.written} producer_production rows written`;
            await markDocument(documentId, "processed", r.written, ["producer_production"], note);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "processed", jeCount: 0, suspenseCount: 0,
            });
          } else if (r.queued) {
            await markDocument(documentId, "queued_for_llm", 0, [], `LLM parse queued: ${r.queueId}`);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "queued", jeCount: 0, suspenseCount: 0, queueId: r.queueId,
            });
          } else {
            await markDocument(documentId, "error", 0, [], r.error);
            processed.push({
              documentId, fileName: att.fileName, fromEmail: att.fromEmail,
              docType, status: "error", jeCount: 0, suspenseCount: 0, error: r.error,
            });
          }
          break;
        }
        default: {
          await handleStub(docType, documentId);
          processed.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "stub_pending", jeCount: 0, suspenseCount: 0,
          });
        }
      }
    } catch (e) {
      processed.push({
        documentId: "", fileName: att.fileName, fromEmail: att.fromEmail,
        docType: "skip", status: "error",
        jeCount: 0, suspenseCount: 0, error: (e as Error).message,
      });
    }
  }

  const summary = {
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    attachments_seen: attachments.length,
    processed: processed.filter((p) => p.status === "processed").length,
    skipped: processed.filter((p) => p.status === "skipped").length,
    queued: processed.filter((p) => p.status === "queued").length,
    errors: processed.filter((p) => p.status === "error").length,
    stub_pending: processed.filter((p) => p.status === "stub_pending").length,
    total_jes: processed.reduce((n, p) => n + p.jeCount, 0),
    total_suspense: processed.reduce((n, p) => n + p.suspenseCount, 0),
    items: processed,
  };

  return jsonResponse({ ok: true, summary });
}

Deno.serve(run);
