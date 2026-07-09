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
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { BlobReader, ZipReader, Uint8ArrayWriter } from "jsr:@zip-js/zip-js@2";
// v4 (2026-07-01): unpdf replaces removed Composio pdf-to-text tool
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";
import { sb, getSetting, jsonResponse } from "./lib/supabase.ts";
import { callComposio } from "./lib/composio.ts";
import {
  classifyDocument,
  classifyBankTxn,
  inferDateFromFilename,
  DocType,
} from "./classifier.ts";
import { parseBankStatement } from "./parsers/bank.ts";
import { parseCompRecap } from "./parsers/comp_recap.ts";
import { parseDeductionStatement } from "./parsers/deduction.ts";
import { parsePayrollRun } from "./parsers/payroll.ts";
import { parseProductionReport } from "./parsers/production.ts";
import { processSurePayrollPdf } from "./parsers/surepayroll.ts";
import { processPfaStatement } from "./parsers/pfa_statement.ts";
import { processCallLogMode } from "./parsers/sf_daily_call_log.ts";
import { postJournalEntry, resetReferenceCounters } from "./gl-poster.ts";
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
}

async function fetchNewGmailAttachments(ctx: RunCtx): Promise<AttachmentInput[]> {
  // Look back 7 days to catch anything we missed between cron ticks.
  // Idempotency is enforced per-file inside the loop.
  const lookback = "newer_than:7d has:attachment";

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: { query: lookback, max_results: 50 },
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

        // Idempotency: skip if already in documents (any upload_source that
        // starts with "gmail" — outer or inner-from-zip).
        const { data: existing } = await sb
          .from("documents")
          .select("id")
          .eq("agency_id", ctx.agencyId)
          .eq("file_name", filename)
          .like("upload_source", "gmail%")
          .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
          .maybeSingle();
        if (existing?.id) continue;

        attachments.push({
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

      const { data: existing } = await sb
        .from("documents")
        .select("id")
        .eq("agency_id", ctx.agencyId)
        .eq("file_name", filename)
        .like("upload_source", "gmail%")
        .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
        .maybeSingle();
      if (existing?.id) continue;

      attachments.push({
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

async function downloadAttachmentBytes(
  ctx: RunCtx, att: AttachmentInput,
): Promise<{ ok: true; bytesB64: string } | { ok: false; error: string }> {
  if (att.bytesB64) return { ok: true, bytesB64: att.bytesB64 }; // inner file already in hand
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
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch returned HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      // Base64-encode in chunks to avoid call-stack issues on large files.
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) {
        bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      }
      return { ok: true, bytesB64: btoa(bin) };
    } catch (e) {
      return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  }
  // Fallback for older Composio response shapes
  const fallback = res.data?.data ?? res.data?.bytes;
  if (typeof fallback === "string") return { ok: true, bytesB64: fallback };
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
  archive_bundle: "_archive-bundles",
  skip: "unsorted",
};

async function uploadToDrive(
  ctx: RunCtx, att: AttachmentInput, bytesB64: string,
  docType: DocType, txnDate: string,
): Promise<{ driveFileId: string; driveUrl: string } | null> {
  if (!ctx.driveAccountId) return null;
  const folder = DRIVE_FOLDER_BY_DOCTYPE[docType];
  const yearMonth = txnDate.slice(0, 7);
  const path = `Newtworks/Documents/${yearMonth}/${folder}/${att.fileName}`;

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
  ctx: RunCtx, att: AttachmentInput, docType: DocType,
  drive: { driveFileId: string; driveUrl: string } | null,
  sourceAccountCode: string | null,
  uploadSource: string,
): Promise<string> {
  const { data, error } = await sb
    .from("documents")
    .insert({
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
      notes: `subject: ${att.subject}${att.parentArchive ? ` | extracted_from: ${att.parentArchive}` : ""}`,
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

async function handleBankStatement(
  ctx: RunCtx, att: AttachmentInput, documentId: string,
  bytesB64: string, sourceAccountCode: string,
): Promise<{ jeCount: number; suspenseCount: number; queueId?: string; error?: string }> {
  // Reset per-doc reference counter so identical-fingerprint txns across
  // different documents don't leak :N suffixes to each other.
  resetReferenceCounters();

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

function resolveSourceAccount(fromEmail: string, subject: string, fileName: string): string {
  const blob = (fromEmail + " " + subject + " " + fileName).toLowerCase();

  // ---- US Bank sub-account routing (order matters — most specific first).
  // File naming convention (Marie's spec): "US Bank {Label} {YY-MM}.pdf" where
  // Label is one of Income (3977, COA-007), Expenses (4335, COA-006), CC (3447,
  // COA-025 USBank GN Personal Card). Account numbers also match if statement
  // text is scanned in.
  if (/us\s*bank\s*income|\b3977\b/.test(blob)) return "COA-007";
  if (/us\s*bank\s*expenses|\b4335\b/.test(blob)) return "COA-006";
  if (/us\s*bank\s*cc|\b3447\b/.test(blob)) return "COA-025";
  // Generic US Bank fallback — Income (conservative default, matches historic behavior)
  if (/usbank|us[\s_-]?bank/.test(blob)) return "COA-007";

  // ---- Chase — Mktg 2 (COA-012) holds all post-cutover activity.
  // Mktg 1 (COA-011) is inactive post-cutover; require explicit "mktg 1" match.
  if (/chase[\s\-_]*(mktg|marketing)[\s\-_]*1/.test(blob)) return "COA-011";
  if (/chase/.test(blob)) return "COA-012";

  if (/truist|trb/.test(blob)) return "COA-004";
  if (/statefarm|sf[\s.-]?ach/.test(blob)) return "COA-024";
  if (/amex|american[\s_-]?express/.test(blob)) return "COA-009";
  if (/capital[\s_-]?one/.test(blob)) return "COA-010";
  if (/citi/.test(blob)) return "COA-028";
  if (/spark/.test(blob)) return "COA-026";
  return "COA-007";
}

// ---- Gmail thread archive --------------------------------------------------
// After a doc finishes successfully, check whether every document tied to the
// same gmail_thread_id is in a terminal state (processed/error/skipped). If so,
// archive the thread in Gmail by removing the INBOX label. Sets
// documents.gmail_archived_at for all rows in the thread so we know it happened.
async function maybeArchiveThread(ctx: RunCtx, threadId: string | null | undefined): Promise<void> {
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
    const res = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
      toolArguments: {
        thread_id: threadId,
        remove_label_ids: ["INBOX"],
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
      .select("id")
      .eq("agency_id", ctx.agencyId)
      .eq("file_name", att.fileName)
      .like("upload_source", "gmail%")
      .gte("uploaded_at", new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString())
      .maybeSingle();
    if (existing?.id) {
      results.push({
        documentId: existing.id, fileName: att.fileName, fromEmail: att.fromEmail,
        docType, status: "skipped", jeCount: 0, suspenseCount: 0,
        sourceLabel: uploadSource,
        error: "already_processed (idempotent)",
      });
      return results;
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
    const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate);
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

  const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate);
  const isBankStmt =
    docType === "bank_statement_primary" ||
    docType === "bank_statement_secondary";
  const sourceAccountCode = isBankStmt
    ? resolveSourceAccount(att.fromEmail, att.subject, att.fileName)
    : null;
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
        } else if (r.error) {
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        } else {
          await markDocument(documentId, "processed", r.jeCount,
            ["journal_entries", "journal_lines"],
            `${r.jeCount} JEs posted, ${r.suspenseCount} in suspense`);
          await maybeArchiveThread(ctx, att.threadId);
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
          await maybeArchiveThread(ctx, att.threadId);
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
          await maybeArchiveThread(ctx, att.threadId);
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
          await maybeArchiveThread(ctx, att.threadId);
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
        // preserveFormat=true — SurePayroll parser needs original whitespace
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
        const r = await processSurePayrollPdf({
          agencyId: ctx.agencyId, documentId,
          gmailMessageId: att.messageId, gmailThreadId: att.threadId,
          pdfText: ex.text,
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
          await maybeArchiveThread(ctx, att.threadId);
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
          await maybeArchiveThread(ctx, att.threadId);
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
          await maybeArchiveThread(ctx, att.threadId);
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

  const ctx: RunCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
  const startedAt = new Date().toISOString();
  const allResults: ProcessedAttachment[] = [];

  let attachments: AttachmentInput[];
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
