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
import { processSurePayrollParsed, parseSurePayrollText, parseSurePayrollCsvText, type ParsedSurePayroll } from "./parsers/surepayroll.ts";
import { processPfaStatement } from "./parsers/pfa_statement.ts";
import { processCallLogMode } from "./parsers/sf_daily_call_log.ts";
import { processCareerplugMode } from "./parsers/careerplug_applicant.ts";
import { processResumeManualBatch } from "./parsers/resume_manual_batch.ts";
import { processSFForwardedApplicantMode } from "./parsers/sf_forwarded_applicant.ts";
import { processWrapupMode } from "./parsers/wrapup_ingest.ts";
import { processWrapupNoSendMode } from "./parsers/wrapup_no_send.ts";
import { postJournalEntry, resetReferenceCounters } from "./gl-poster.ts";
import { createSuspenseTask } from "./suspense.ts";

interface RunCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
  // Drive folder that recovered scanned files get filed into. Null puts them
  // in the Drive root.
  driveParentFolderId?: string | null;
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

  // Set when a documents row already exists for this attachment but was left
  // mid-flight, and the file is being offered again. The handler updates that
  // row instead of inserting a second one. See retryableDocumentId().
  retryDocumentId?: string | null;
  retryCount?: number;
}

// Statuses that mean a documents row is finished, deliberately parked, or owned
// by another process. A row in any of these is never offered again:
//   processed / filed / archived / skipped / duplicate  finished
//   error                        finished; an alert was already raised
//   unpacked                     zip container, already expanded
//   archive_failed               document handled; only the Gmail archive failed
//   queued_for_llm               llm-queue-drainer owns it
//   stored_pending_walkthrough   deliberately held for review
//   held_reconciliation_mismatch deliberately held for review
const DOC_STATUS_NO_RETRY = new Set([
  "processed", "filed", "archived", "skipped", "duplicate", "error",
  "unpacked", "archive_failed", "queued_for_llm",
  "stored_pending_walkthrough", "held_reconciliation_mismatch",
]);

const DOC_MAX_RETRIES = 3;

/**
 * A documents row already exists for this attachment. Decide whether it
 * represents finished work (skip the file) or a run that died partway through
 * (offer the file again).
 *
 * Found 2026-08-04: in a 143-file resume backlog run, four files had their
 * documents row inserted and then the run ended — wall clock, most likely —
 * before the handler reached a terminal status. They sat at "received"
 * indefinitely, because the duplicate check above skipped any existing row
 * regardless of its status, so the file was never offered again. That is silent,
 * permanent loss of a real applicant. Three older rows were stranded the same
 * way, two of them credit-card statement bundles.
 *
 * Returns the document id to reuse when the row should be retried, else null.
 * The attempt counter keeps a document that dies every single time from being
 * picked up on every tick forever.
 */
function retryableDocumentId(
  existing: { id?: string; processing_status?: string; retry_count?: number } | null | undefined,
  fileName: string,
): string | null {
  if (!existing?.id) return null;
  const status = existing.processing_status ?? "";
  if (DOC_STATUS_NO_RETRY.has(status)) return null;
  const tries = existing.retry_count ?? 0;
  if (tries >= DOC_MAX_RETRIES) {
    console.warn(`[fetch] ${fileName}: document ${existing.id} still at "${status}" after ${tries} attempts — giving up, not offering again`);
    return null;
  }
  console.log(`[fetch] ${fileName}: offering document ${existing.id} again, stuck at "${status}" (attempt ${tries + 1} of ${DOC_MAX_RETRIES})`);
  return existing.id;
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

        // Idempotency: (gmail_message_id, file_name). Message ID is a stable
        // Gmail identifier; filenames within a single message are unique in
        // practice. Prior key was file_name alone across all-of-gmail, which
        // silently skipped generic-named repeats (SF sending "Payroll Summary.pdf"
        // collided with a legacy row from a prior week). Attachment IDs are
        // NOT stable across Gmail API calls, so cannot be part of the key.
        const msgId = m.messageId ?? m.id;
        const { data: existing } = await sb
          .from("documents")
          .select("id, processing_status, retry_count")
          .eq("agency_id", ctx.agencyId)
          .eq("gmail_message_id", msgId)
          .eq("file_name", filename)
          .maybeSingle();
        const retryId = retryableDocumentId(existing, filename);
        if (existing?.id && !retryId) continue;

        attachments.push({
          retryDocumentId: retryId,
          retryCount: existing?.retry_count ?? 0,
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

      // Idempotency: same as above — (gmail_message_id, file_name).
      const msgId = m.id;
      const { data: existing } = await sb
        .from("documents")
        .select("id, processing_status, retry_count")
        .eq("agency_id", ctx.agencyId)
        .eq("gmail_message_id", msgId)
        .eq("file_name", filename)
        .maybeSingle();
      const retryId = retryableDocumentId(existing, filename);
      if (existing?.id && !retryId) continue;

      attachments.push({
        retryDocumentId: retryId,
        retryCount: existing?.retry_count ?? 0,
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

/**
 * Pull the storage key out of a Composio download link — the link's path IS
 * the key. GOOGLEDRIVE_UPLOAD_FILE wants that key, not a URL and not bytes.
 */
function storageKeyFromDownloadUrl(url: string): string | null {
  try {
    const path = new URL(url).pathname.replace(/^\/+/, "");
    return path.length > 0 ? decodeURIComponent(path) : null;
  } catch {
    return null;
  }
}

async function downloadAttachmentBytes(
  ctx: RunCtx, att: AttachmentInput,
): Promise<{ ok: true; bytesB64: string; s3Key: string | null } | { ok: false; error: string }> {
  // Inner zip files have no storage key of their own — they were never
  // downloaded separately, so there is nothing for Drive to pick up.
  if (att.bytesB64) return { ok: true, bytesB64: att.bytesB64, s3Key: null };
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
      return { ok: true, bytesB64: btoa(bin), s3Key: storageKeyFromDownloadUrl(s3url) };
    } catch (e) {
      return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  }
  // Fallback for older Composio response shapes
  const fallback = res.data?.data ?? res.data?.bytes;
  if (typeof fallback === "string") return { ok: true, bytesB64: fallback, s3Key: null };
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
  // careerplug_applicant had no entry, so its resumes were filed under a
  // folder literally named "undefined". Fixed 2026-08-03 alongside adding
  // resume_manual_batch, which would have hit the same hole.
  careerplug_applicant: "applicant-resumes",
  resume_manual_batch: "applicant-resumes",
  archive_bundle: "_archive-bundles",
  skip: "unsorted",
};

/**
 * Which published set of Google Drive tools the folder helpers ask for.
 *
 * Composio publishes its tools in dated sets, and a request that does not name
 * one gets the oldest set — which is missing tools the account genuinely has,
 * and answers "Tool ... not found" when you reach for them. That reads exactly
 * like a permission problem and is not one. See the long note in lib/composio.ts.
 *
 * Named here rather than globally because a newer set can change the shape of
 * what comes back, and the payroll, statement and comp parsers read those
 * shapes. The plain upload below deliberately does NOT name a set: it works on
 * the oldest one, and there is nothing to gain by moving it.
 */
const DRIVE_FOLDER_TOOLKIT_VERSION = "20260721_00";

/** Folder ids worked out during this run. Keyed "<parent id>/<folder name>". */
const driveFolderCache = new Map<string, string>();

/**
 * Find a folder by name inside a parent, creating it if it is not there.
 * Returns null if neither works, and the caller then files one level up rather
 * than not at all.
 */
async function resolveDriveFolder(
  ctx: RunCtx, name: string, parentId: string,
): Promise<string | null> {
  const key = `${parentId}/${name}`;
  const cached = driveFolderCache.get(key);
  if (cached) return cached;
  if (!ctx.driveAccountId) return null;

  const find = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.driveAccountId,
    toolSlug: "GOOGLEDRIVE_FIND_FOLDER",
    toolArguments: { name_exact: name, parent_folder_id: parentId },
    toolkitVersion: DRIVE_FOLDER_TOOLKIT_VERSION,
  });
  const files = find.ok ? (find.data?.files ?? find.data?.data?.files ?? []) : [];
  let id: string = Array.isArray(files) && files.length > 0 ? (files[0]?.id ?? "") : "";

  if (!id) {
    const made = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.driveAccountId,
      toolSlug: "GOOGLEDRIVE_CREATE_FOLDER",
      toolArguments: { name, parent_id: parentId },
      toolkitVersion: DRIVE_FOLDER_TOOLKIT_VERSION,
    });
    id = made.ok ? (made.data?.id ?? made.data?.data?.id ?? "") : "";
    if (!id) {
      console.warn(`[document-processor] could not find or create Drive folder "${name}" under ${parentId}: ${find.error ?? ""} ${made.error ?? ""}`);
      return null;
    }
  }

  driveFolderCache.set(key, id);
  return id;
}

/**
 * Where a document belongs: <Newtworks root>/Documents/<year-month>/<type>.
 *
 * This is the structure the agency has always used. It was lost on 2026-08-04
 * when the upload was repaired, because the working upload tool places files by
 * folder id and only the root folder's id was known. Both folder tools turn out
 * to be reachable once a tool set is named, so the structure is back.
 *
 * Every step falls back one level up. A file in the right year but the wrong
 * type folder can be moved later; a file that never got filed cannot.
 */
async function documentFolderId(
  ctx: RunCtx, docType: DocType, txnDate: string,
): Promise<string | null> {
  const root = ctx.driveParentFolderId ?? null;
  if (!root) return null;

  const yearMonth = /^\d{4}-\d{2}/.test(txnDate ?? "")
    ? txnDate.slice(0, 7)
    : new Date().toISOString().slice(0, 7);
  const leaf = DRIVE_FOLDER_BY_DOCTYPE[docType] ?? "unsorted";

  const documents = await resolveDriveFolder(ctx, "Documents", root);
  if (!documents) return root;
  const month = await resolveDriveFolder(ctx, yearMonth, documents);
  if (!month) return documents;
  const typeFolder = await resolveDriveFolder(ctx, leaf, month);
  return typeFolder ?? month;
}

// FIXED 2026-08-04. This had been failing on EVERY document for weeks and
// saying nothing. GOOGLEDRIVE_UPLOAD_FILE requires a single `file_to_upload`
// object holding the file's name, type and storage key; the old call passed
// `file_name`, `file_path` and `content_base64`, which are not fields the tool
// accepts, so every upload was rejected as invalid input. Because the failure
// returned null quietly, nothing was filed to Drive and nothing was raised —
// 148 resumes, the August bank statements, payroll and card statements all have
// no Drive copy as a result.
//
// KNOWN LIMIT, follow-on work: the tool places files by folder ID, not by path,
// and only the Newtworks root folder ID is known. So everything lands in that
// one folder rather than the year-month and document-type folders the old path
// string described. That structure needs the folder IDs resolved (or created)
// before it can be restored. One flat folder beats nothing being filed at all,
// which is the state this replaces.
async function uploadToDrive(
  ctx: RunCtx, att: AttachmentInput, bytesB64: string,
  docType: DocType, txnDate: string, s3Key?: string | null,
): Promise<{ driveFileId: string; driveUrl: string } | null> {
  if (!ctx.driveAccountId) return null;

  // No storage key means the file was never staged where Drive can fetch it
  // (inner zip members). Skip rather than fail loudly — the zip itself is filed.
  if (!s3Key) return null;

  // Year-month and document-type folder, created on first use.
  const folderId = await documentFolderId(ctx, docType, txnDate);

  const res = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.driveAccountId,
    toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
    toolArguments: {
      file_to_upload: {
        name: att.fileName,
        mimetype: att.mimeType || "application/pdf",
        s3key: s3Key,
      },
      ...(folderId ? { folder_to_upload_to: folderId } : {}),
    },
  });

  if (!res.ok) {
    // Say so. A silent null here is exactly what hid this for weeks.
    console.error(`[document-processor] drive_upload_failed: ${att.fileName} docType=${docType} reason="${res.error}"`);
    try {
      await sb.from("alerts").insert({
        agency_id: ctx.agencyId,
        alert_type: "drive_upload_failed",
        severity: "warning",
        title: `Could not file ${att.fileName} to Drive`,
        message: `The Drive upload was rejected: ${res.error}\n\nThe document was still processed; only its Drive copy is missing.`,
        module_reference: "document-processor",
        is_read: false,
        is_resolved: false,
        created_at: new Date().toISOString(),
      });
    } catch (_e) { /* alerting must never break processing */ }
    return null;
  }

  return {
    driveFileId: res.data?.id ?? res.data?.data?.id ?? res.data?.file_id ?? "",
    driveUrl: res.data?.webViewLink ?? res.data?.display_url ?? res.data?.url ?? "",
  };
}

// ---- documents row ---------------------------------------------------------

async function insertSourceDocument(
  ctx: RunCtx, att: AttachmentInput, docType: DocType,
  drive: { driveFileId: string; driveUrl: string } | null,
  sourceAccountCode: string | null,
  uploadSource: string,
): Promise<string> {
  const row = {
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
    gmail_attachment_id: att.attachmentId || null,
    notes: `subject: ${att.subject}${att.parentArchive ? ` | extracted_from: ${att.parentArchive}` : ""}`,
  };

  // This attachment is being offered again because its previous row was left
  // mid-flight. Update that row in place rather than inserting a second one, so
  // a retry never turns into a duplicate document. The attempt counter is what
  // eventually stops a file that fails every time. See retryableDocumentId().
  if (att.retryDocumentId) {
    const { data: retried, error: retryErr } = await sb
      .from("documents")
      .update({
        ...row,
        retry_count: (att.retryCount ?? 0) + 1,
        processed_at: null,
        records_created: 0,
        tables_updated: [],
      })
      .eq("id", att.retryDocumentId)
      .select("id")
      .single();
    if (retryErr || !retried) {
      throw new Error(`document retry update failed: ${retryErr?.message ?? "unknown"}`);
    }
    return retried.id;
  }

  const { data, error } = await sb
    .from("documents")
    .insert(row)
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
): Promise<{ jeCount: number; suspenseCount: number; queueId?: string; error?: string; held?: boolean }> {
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

  // ---- Reconciliation guard (Step 6 of reconciliation guard build) ----
  // Same identity as llm-queue-drainer v5: closing == opening +
  // sum(txn.signedAmount) +/- RECON_EPSILON. Mismatch OR missing balances ->
  // hold: no statement_balances write, no JE posts. Handler internally
  // flips documents.processing_status to 'held_reconciliation_mismatch',
  // stashes parsed JSON in documents.notes, records reconciliation_delta,
  // and emits a high-severity alert. Successful parses also record the
  // near-zero delta for audit trail.
  const RECON_EPSILON = 0.01;
  const openBal = parsed.openingBalance;
  const closeBal = parsed.closingBalance;
  let reconDelta: number | null = null;
  let reconHeldReason: string | null = null;

  if (openBal === null || closeBal === null) {
    reconHeldReason = `missing balance from parser: opening=${openBal === null ? "null" : openBal}, closing=${closeBal === null ? "null" : closeBal}`;
  } else {
    const txnSum = parsed.transactions.reduce((acc, r) => acc + r.txn.signedAmount, 0);
    const expected = openBal + txnSum;
    reconDelta = Math.round((closeBal - expected) * 100) / 100;
    if (Math.abs(reconDelta) > RECON_EPSILON) {
      reconHeldReason = `delta=$${reconDelta.toFixed(2)} exceeds epsilon $${RECON_EPSILON.toFixed(2)} (opening=$${openBal.toFixed(2)}, sum_txns=$${txnSum.toFixed(2)}, expected_close=$${expected.toFixed(2)}, actual_close=$${closeBal.toFixed(2)}, ${parsed.transactions.length} txns)`;
    }
  }

  if (reconHeldReason !== null) {
    const heldNotes = JSON.stringify({
      held: "reconciliation_mismatch",
      reason: reconHeldReason,
      reconciliation_delta: reconDelta,
      source_account_code: sourceAccountCode,
      account_last4: parsed.accountLast4,
      statement_period: parsed.statementPeriod,
      opening_balance: openBal,
      closing_balance: closeBal,
      txn_count: parsed.transactions.length,
      parsed_transactions: parsed.transactions.map((r) => ({
        date: r.date,
        payee: r.txn.payee,
        memo: r.txn.memo,
        amount: r.txn.signedAmount,
      })),
    });
    await sb.from("documents").update({
      processing_status: "held_reconciliation_mismatch",
      reconciliation_delta: reconDelta,
      notes: heldNotes,
      processed_at: new Date().toISOString(),
    }).eq("id", documentId);
    await sb.from("alerts").insert({
      agency_id: ctx.agencyId,
      alert_type: "reconciliation_mismatch",
      severity: "high",
      title: `Statement reconciliation mismatch — ${att.fileName}`,
      message: `Parsed ${att.fileName} for account ${sourceAccountCode} does not tie to the printed statement summary. ${reconHeldReason}. Held for review — no journal entries posted, no statement_balances written.`,
      module_reference: "document-processor",
      related_id: documentId,
      is_read: false,
      is_resolved: false,
      created_at: new Date().toISOString(),
    });
    console.warn(`[document-processor] reconciliation_mismatch doc=${documentId} account=${sourceAccountCode}: ${reconHeldReason}`);
    return { jeCount: 0, suspenseCount: 0, held: true, error: `held_reconciliation_mismatch: ${reconHeldReason}` };
  }

  // Success path: record near-zero delta for audit trail.
  await sb.from("documents").update({ reconciliation_delta: reconDelta }).eq("id", documentId);

  // Write the statement header (opening/closing balance, period) to
  // statement_balances first — independent of per-txn GL posting so the
  // balance snapshot lands even if a downstream JE hiccups. Failures here
  // are logged but non-fatal; the JE loop still runs.
  const balWrite = await writeStatementBalance({
    agencyId: ctx.agencyId,
    documentId,
    accountCode: sourceAccountCode,
    accountLast4: parsed.accountLast4,
    statementPeriodStart: parsed.statementPeriod.start,
    statementPeriodEnd: parsed.statementPeriod.end,
    openingBalance: parsed.openingBalance,
    closingBalance: parsed.closingBalance,
  });
  if (!balWrite.ok) {
    console.warn(`[document-processor] statement_balance_write_failed doc=${documentId} account=${sourceAccountCode}: ${balWrite.error}`);
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

// Prefix for statements whose account cannot be determined from the email.
// The chart of accounts is numeric, so any value carrying this prefix fails
// the account lookup loudly instead of filing money to the wrong account.
const UNMAPPED = "UNMAPPED-";

function resolveSourceAccount(fromEmail: string, subject: string, fileName: string): string {
  const blob = (fromEmail + " " + subject + " " + fileName).toLowerCase();

  // ---- US Bank PERSONAL sub-account routing (Alvi's zip labels, added
  // 2026-07-27). Order matters — most specific first. These must be checked
  // BEFORE the generic "us bank" fallback below, or personal statements
  // silently route to the agency Income account (COA-007) and post to the
  // wrong entity. Kids Profit Disc account was ingested manually 2026-07-27
  // as one-off; going forward the labels below auto-route.
  if (/kids[\s_-]?profit[\s_-]?disc|\b6730\b/.test(blob)) return "1072";
  if (/us[\s_-]?bank[\s_-]?personal[\s_-]?checking|personal[\s_-]?checking|\b0353\b/.test(blob)) return "1070";
  if (/tithe[\s_-]?tax|\b6755\b/.test(blob)) return "1073";
  if (/us[\s_-]?bank[\s_-]?other[\s_-]?income|other[\s_-]?income|\b2545\b/.test(blob)) return "1071";
  if (/sf[\s_-]?personal[\s_-]?cc|\b8847\b/.test(blob)) return "2173";

  // ---- US Bank AGENCY sub-account routing (order matters — most specific first).
  // File naming convention (Marie's spec): "US Bank {Label} {YY-MM}.pdf" where
  // Label is one of Income (3977, acct 1012), Expenses (4335, acct 1011), CC
  // (3447, acct 2113). Account numbers also match if statement text is scanned in.
  if (/us\s*bank\s*income|\b3977\b/.test(blob)) return "1012";
  if (/us\s*bank\s*expenses|\b4335\b/.test(blob)) return "1011";
  if (/us\s*bank\s*cc|\b3447\b/.test(blob)) return "2113";
  // Generic US Bank fallback — Income (conservative default, matches historic behavior)
  if (/usbank|us[\s_-]?bank/.test(blob)) return "1012";

  // ---- Non-US-Bank personal accounts (Alvi's zip labels, added 2026-07-27).
  // RBFCU savings and Discover Tithe CC both live on Peter's personal entity.
  if (/rbfcu|randolph[\s_-]?brooks|\b6596\b/.test(blob)) return "1076";
  if (/discover[\s_-]?tithe|discover[\s_-]?cc|\b3208\b/.test(blob)) return "2171";

  // ---- Personal CC catchalls (last-4 hits from statement text) ------------
  if (/\b1006\b/.test(blob)) return "2170"; // AMEX Personal
  if (/\b7435\b/.test(blob)) return "2172"; // Capital One Personal

  // ---- Chase — Marketing 1 is the only Chase card on file (credit_accounts
  // last4 7762, alternate 7770 -> acct 2110). No "Marketing 2" card or account
  // exists, so a generic Chase match is Marketing 1.
  if (/chase[\s\-_]*(mktg|marketing)[\s\-_]*1/.test(blob)) return "2110";
  if (/chase/.test(blob)) return "2110";

  // Truist/TRB (4 accounts), State Farm Bank checking 2353, and Capital One
  // Spark are all is_active=false in bank_accounts / credit_accounts. Retired.
  // A statement from one of these is a surprise and must stop, not route.
  if (/truist|trb/.test(blob)) return UNMAPPED + "TRB-RETIRED";
  if (/statefarm|sf[\s.-]?ach/.test(blob)) return UNMAPPED + "SF-BANK-RETIRED";
  if (/amex|american[\s_-]?express/.test(blob)) return "2141"; // AMEX Discretionary (PaperNewt, last4 1003)
  if (/capital[\s_-]?one/.test(blob)) return "2172"; // only active Cap One card is Personal 7435
  if (/citi/.test(blob)) return "2140"; // credit_accounts: Citi 1247 -> 2140 PaperNewt printing card
  if (/spark/.test(blob)) return UNMAPPED + "SPARK-RETIRED";
  // No silent default. Returning an account here guesses whose money this is;
  // an unrecognised statement must stop and be looked at instead.
  return UNMAPPED + "UNRECOGNISED";
}

// ---- statement_balances writer --------------------------------------------
// Called after a bank statement parses successfully. Upserts one row per
// (agency_id, account_code, statement_period_end) so re-processing the same
// statement PDF overwrites in place rather than duplicating. Business entity
// comes from chart_of_accounts; account kind is inferred from the COA code
// prefix (CC → credit, else bank). Added 2026-07-27 alongside the Alvi zip
// classifier fallback — this is what makes statement_balances actually populate
// from ingested statements rather than needing a manual backfill.
async function writeStatementBalance(opts: {
  agencyId: string;
  documentId: string;
  accountCode: string;
  accountLast4: string | null;
  statementPeriodStart: string;
  statementPeriodEnd: string;
  openingBalance: number | null;
  closingBalance: number | null;
}): Promise<{ ok: boolean; error?: string }> {
  // Look up the business entity from chart_of_accounts.
  const { data: coa, error: coaErr } = await sb
    .from("chart_of_accounts")
    .select("business_entity_id, account_subtype")
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .maybeSingle();
  if (coaErr) {
    return { ok: false, error: `chart_of_accounts lookup failed: ${coaErr.message}` };
  }
  const businessEntityId = coa?.business_entity_id ?? null;
  if (!businessEntityId) {
    return { ok: false, error: `no chart_of_accounts row for ${opts.accountCode}` };
  }
  // Infer kind: any code with "-CC-" in it is a credit card; everything else
  // is a bank account. Matches the existing statement_balances.account_kind
  // convention (values already in the table: "bank", "credit").
  const accountKind = /-CC-/i.test(opts.accountCode) ? "credit" : "bank";

  // Upsert-by-natural-key: (agency_id, account_code, statement_period_end).
  // No explicit unique constraint exists, so do it in two steps: try UPDATE
  // by that key, INSERT if nothing was touched. Both branches use the same
  // source label so we can tell downstream that this row came from the
  // document-processor pipeline (vs. manual backfill or gl-cutover).
  const upd = await sb
    .from("statement_balances")
    .update({
      business_entity_id: businessEntityId,
      account_last4: opts.accountLast4,
      account_kind: accountKind,
      statement_period_start: opts.statementPeriodStart,
      opening_balance: opts.openingBalance,
      closing_balance: opts.closingBalance,
      source_document_id: opts.documentId,
      source: "document_processor",
      notes: `auto-ingested via document-processor from statement PDF`,
      updated_at: new Date().toISOString(),
    })
    .eq("agency_id", opts.agencyId)
    .eq("account_code", opts.accountCode)
    .eq("statement_period_end", opts.statementPeriodEnd)
    .select("id");
  if (upd.error) return { ok: false, error: `statement_balances update failed: ${upd.error.message}` };
  if (upd.data && upd.data.length > 0) return { ok: true };

  const ins = await sb.from("statement_balances").insert({
    agency_id: opts.agencyId,
    business_entity_id: businessEntityId,
    account_code: opts.accountCode,
    account_last4: opts.accountLast4,
    account_kind: accountKind,
    statement_period_start: opts.statementPeriodStart,
    statement_period_end: opts.statementPeriodEnd,
    opening_balance: opts.openingBalance,
    closing_balance: opts.closingBalance,
    source_document_id: opts.documentId,
    source: "document_processor",
    notes: `auto-ingested via document-processor from statement PDF`,
  });
  if (ins.error) return { ok: false, error: `statement_balances insert failed: ${ins.error.message}` };
  return { ok: true };
}

// ---- Gmail thread archive --------------------------------------------------
// After a doc finishes successfully, check whether every document tied to the
// same gmail_thread_id is in a terminal state (processed/error/skipped). If so,
// archive the thread in Gmail by removing the INBOX label. Sets
// documents.gmail_archived_at for all rows in the thread so we know it happened.
// Gmail label routing per docType. Created 2026-07-14. Update this map when
// adding a new docType. Nulls skip label-add (still removes INBOX).
const ARCHIVE_LABEL_FOR_DOCTYPE: Record<string, string | null> = {
  bank_statement_primary:   null, // deleted 2026-07-29 in Gmail-label reorg
  bank_statement_secondary: null,
  bank_statement_pfa:       null, // deleted 2026-07-29
  comp_recap_1h:            "Label_24", // "SF Compensation"
  comp_recap_daily:         "Label_24",
  deduction_statement:      "Label_25", // "SF Deductions"
  surepayroll_payroll:      "Label_26", // "Payroll"
  adp_payroll:              "Label_26",
  commission_report:        null, // deleted 2026-07-29
  team_production:          null,
  careerplug_applicant:     "Label_20", // "Applicants" (attachment pipeline)
  resume_manual_batch:      "Label_20", // "Applicants" (hand-forwarded batches)
};

async function maybeArchiveThread(ctx: RunCtx, threadId: string | null | undefined, docType?: string): Promise<void> {
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
        ...(docType && ARCHIVE_LABEL_FOR_DOCTYPE[docType]
          ? { add_label_ids: [ARCHIVE_LABEL_FOR_DOCTYPE[docType]!] }
          : {}),
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
  const attachmentS3Key = dl.s3Key;

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
    const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate, attachmentS3Key);
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

  const drive = await uploadToDrive(ctx, att, bytesB64, docType, txnDate, attachmentS3Key);
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
        } else if (r.held) {
          // Reconciliation guard held the parse. Handler already wrote
          // documents.processing_status='held_reconciliation_mismatch',
          // reconciliation_delta, notes payload, and emitted the alert.
          // Do NOT call markDocument here — it would overwrite those writes.
          // Do NOT archive the Gmail thread — the document needs human review.
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
        // PDF path: extractText uses unpdf with preserveFormat=true (parser needs
        // original whitespace). CSV path: extractText auto-decodes text bytes.
        const isCsv = /\.csv$/i.test(att.fileName);
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
        let parsed: ParsedSurePayroll;
        try {
          parsed = isCsv ? parseSurePayrollCsvText(ex.text) : parseSurePayrollText(ex.text);
        } catch (e) {
          const err = `parser: ${(e as Error).message}`;
          await markDocument(documentId, "error", 0, [], err);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: err, sourceLabel: uploadSource,
          });
          break;
        }
        const r = await processSurePayrollParsed({
          agencyId: ctx.agencyId, documentId,
          gmailMessageId: att.messageId, gmailThreadId: att.threadId,
          parsed,
          sourceText: ex.text,
          sourceFormat: isCsv ? "csv" : "pdf",
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
          await maybeArchiveThread(ctx, att.threadId, docType);
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
      case "resume_manual_batch": {
        // Hand-forwarded resume PDF (see parsers/resume_manual_batch.ts).
        // Identity comes out of the resume text, then the candidate is
        // upserted through the shared CareerPlug routine.
        const r = await processResumeManualBatch({
          agencyId: ctx.agencyId,
          documentId,
          messageId: att.messageId,
          fromEmail: att.fromEmail,
          subject: att.subject,
          receivedAt: att.receivedAt,
          fileName: att.fileName,
          bytesB64,
          resumeUrl: drive?.driveUrl ?? null,
          gmailAttachmentId: att.attachmentId,
          recovery: {
            composioApiKey: ctx.composioApiKey,
            composioUserId: ctx.composioUserId,
            gmailAccountId: ctx.gmailAccountId,
            driveAccountId: ctx.driveAccountId,
            driveParentFolderId: ctx.driveParentFolderId ?? null,
          },
        });
        if (r.ok) {
          // Text recognition produced a Drive copy. Keep it on the row — these
          // resumes have otherwise never had one, because the normal Drive
          // upload returns quietly when it fails.
          if (r.recoveredDriveFileId && !drive?.driveFileId) {
            await sb.from("documents")
              .update({ drive_file_id: r.recoveredDriveFileId, drive_url: r.recoveredDriveUrl ?? null })
              .eq("id", documentId);
          }
          await markDocument(documentId, "processed", 1, ["hiring_candidates"],
            `Resume ingested for ${r.candidateName ?? "unnamed candidate"} (${r.action}, identity via ${r.identitySource}, text via ${r.textSource ?? "pdf"}); candidate ${r.candidateId ?? "unknown"}`);
          await maybeArchiveThread(ctx, att.threadId, docType);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "processed", jeCount: 0, suspenseCount: 0,
            sourceLabel: uploadSource,
          });
        } else {
          // Leave the thread in the inbox on failure — an alert was already
          // raised inside the parser, and the thread staying visible is the
          // backstop against a resume disappearing quietly.
          await markDocument(documentId, "error", 0, [], r.error);
          results.push({
            documentId, fileName: att.fileName, fromEmail: att.fromEmail,
            docType, status: "error", jeCount: 0, suspenseCount: 0,
            error: r.error, sourceLabel: uploadSource,
          });
        }
        break;
      }
      case "careerplug_applicant": {
        // CareerPlug resume PDF that arrived through the standard attachment
        // path (parent notification email is handled by processCareerplugMode).
        // Persist the document row as processed and archive the thread. Linking
        // the resume to a hiring_candidates row happens in the mode path when
        // the parent notification is parsed.
        await markDocument(documentId, "processed", 0, ["documents"],
          "CareerPlug resume stored via attachment pipeline; linkage handled by mode=careerplug");
        await maybeArchiveThread(ctx, att.threadId, docType);
        results.push({
          documentId, fileName: att.fileName, fromEmail: att.fromEmail,
          docType, status: "processed", jeCount: 0, suspenseCount: 0,
          sourceLabel: uploadSource,
        });
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

// ---- mode: resume_text_recovery --------------------------------------------
// Deliberate re-run for forwarded resumes that failed because the file was a
// scan or a photo with no text in it.
//
// WHY A SEPARATE DOOR: those rows sit at processing_status "error", and "error"
// is in the do-not-retry set, so the mid-flight retry guard treats them as
// finished and the mail fetcher will never offer them again. Nothing reopens
// them on its own. This is the door.
//
// It does NOT re-download the original bytes. By definition these files have no
// text to extract, so handing the parser an empty body lets its own recovery
// step fetch the original from Gmail and run Drive text recognition — one fewer
// round trip per file, and one code path instead of two.
//
// Body: { agency_id, shared_secret, mode: "resume_text_recovery",
//         document_ids?: string[], limit?: number, dry_run?: boolean }
// With no document_ids it picks up every forwarded resume still failing for
// this reason, oldest first.
interface TextRecoveryOutcome {
  documentId: string;
  fileName: string;
  status: "recovered" | "still_failing" | "unrecoverable" | "would_run";
  candidateId?: string | null;
  candidateName?: string | null;
  error?: string;
}

async function processResumeTextRecoveryMode(
  ctx: RunCtx, body: any,
): Promise<{
  considered: number; recovered: number; stillFailing: number;
  unrecoverable: number; dryRun: boolean; outcomes: TextRecoveryOutcome[];
}> {
  const documentIds: string[] = Array.isArray(body?.document_ids)
    ? body.document_ids.filter((x: unknown) => typeof x === "string")
    : [];
  const limit = Math.min(Math.max(Number(body?.limit) || 40, 1), 100);
  const dryRun = body?.dry_run === true;

  // Text already read out of the scans by the caller, keyed by document id.
  // This door exists because reading a scan needs a Google Drive tool that this
  // function's Composio key cannot see, while the same tool works fine from an
  // interactive session. Rather than leave real applicants stranded waiting on
  // that permission, the reading can happen outside and the text be handed in
  // here. Everything downstream — identity, candidate row, Drive link — runs
  // exactly as it does on the automatic path.
  const handedIn = new Map<
    string,
    { text: string; driveFileId: string | null; driveUrl: string | null }
  >();
  if (Array.isArray(body?.recovered)) {
    for (const r of body.recovered) {
      const id = typeof r?.document_id === "string" ? r.document_id : null;
      const text = typeof r?.text === "string" ? r.text : "";
      if (id && text.trim().length >= 40) {
        handedIn.set(id, {
          text,
          driveFileId: typeof r?.drive_file_id === "string" ? r.drive_file_id : null,
          driveUrl: typeof r?.drive_url === "string" ? r.drive_url : null,
        });
      }
    }
  }

  let q = sb
    .from("documents")
    .select("id, file_name, gmail_message_id, gmail_attachment_id, uploaded_by, uploaded_at")
    .eq("agency_id", ctx.agencyId)
    .eq("groq_classification", "resume_manual_batch")
    .eq("processing_status", "error");

  if (documentIds.length > 0) {
    q = q.in("id", documentIds);
  } else {
    // Only the rows that failed for lack of readable text. Leaves alone the
    // ones that failed for any other reason, which need a different fix.
    q = q.ilike("notes", "%image-only PDF%");
  }

  const { data: rows, error: selErr } = await q
    .order("created_at", { ascending: true })
    .limit(limit);

  if (selErr) {
    return { considered: 0, recovered: 0, stillFailing: 0, unrecoverable: 0, dryRun, outcomes: [] };
  }

  const outcomes: TextRecoveryOutcome[] = [];
  let recovered = 0, stillFailing = 0, unrecoverable = 0;

  for (const row of rows ?? []) {
    const fileName = (row as any).file_name ?? "(unnamed)";
    const messageId = (row as any).gmail_message_id as string | null;
    const attachmentId = (row as any).gmail_attachment_id as string | null;

    const supplied = handedIn.get((row as any).id) ?? null;

    // No way back to the original file. Say so rather than failing vaguely.
    // Text handed in with the request makes this moot: nothing needs fetching.
    if (!supplied && (!messageId || !attachmentId)) {
      unrecoverable++;
      outcomes.push({
        documentId: (row as any).id, fileName, status: "unrecoverable",
        error: "no Gmail message id or attachment id on this row, so the original file cannot be fetched again",
      });
      continue;
    }

    if (dryRun) {
      outcomes.push({ documentId: (row as any).id, fileName, status: "would_run" });
      continue;
    }

    const r = await processResumeManualBatch({
      agencyId: ctx.agencyId,
      documentId: (row as any).id,
      messageId: messageId ?? "",
      fromEmail: (row as any).uploaded_by ?? "",
      // The original subject line was overwritten by the failure message when
      // the row first errored, so it is genuinely gone. Left blank rather than
      // invented.
      subject: "",
      receivedAt: (row as any).uploaded_at ?? new Date().toISOString(),
      fileName,
      bytesB64: "",   // deliberate — see the note above
      resumeUrl: null,
      gmailAttachmentId: attachmentId,
      preRecoveredText: supplied?.text ?? null,
      preRecoveredDriveFileId: supplied?.driveFileId ?? null,
      preRecoveredDriveUrl: supplied?.driveUrl ?? null,
      recovery: {
        composioApiKey: ctx.composioApiKey,
        composioUserId: ctx.composioUserId,
        gmailAccountId: ctx.gmailAccountId,
        driveAccountId: ctx.driveAccountId,
        driveParentFolderId: ctx.driveParentFolderId ?? null,
      },
    });

    if (r.ok) {
      if (r.recoveredDriveFileId) {
        await sb.from("documents")
          .update({ drive_file_id: r.recoveredDriveFileId, drive_url: r.recoveredDriveUrl ?? null })
          .eq("id", (row as any).id);
      }
      await markDocument((row as any).id, "processed", 1, ["hiring_candidates"],
        `Resume recovered by text recognition for ${r.candidateName ?? "unnamed candidate"} (${r.action}, identity via ${r.identitySource}); candidate ${r.candidateId ?? "unknown"}`);
      recovered++;
      outcomes.push({
        documentId: (row as any).id, fileName, status: "recovered",
        candidateId: r.candidateId, candidateName: r.candidateName,
      });
    } else {
      await markDocument((row as any).id, "error", 0, [], r.error);
      stillFailing++;
      outcomes.push({
        documentId: (row as any).id, fileName, status: "still_failing", error: r.error,
      });
    }
  }

  return {
    considered: (rows ?? []).length,
    recovered, stillFailing, unrecoverable, dryRun, outcomes,
  };
}

// ---- mode: drive_backfill --------------------------------------------------
// Files a Drive copy for documents that never got one.
//
// WHY THIS IS NEEDED: the Drive upload was rejecting every single file for
// weeks and returning quietly, so nothing was filed and nothing was raised. It
// was repaired on 2026-08-04, but by then 148 resumes, the August bank
// statements, payroll and the card statements all had no Drive copy. Those
// documents were processed correctly — their figures are in the books. It is
// only the filed copy that is missing.
//
// LIMIT: this refiles from Gmail using the message and attachment ids already
// on the row, so it only works while the original email is still in the
// mailbox. Anything older than that cannot be recovered from here and needs the
// file from another source.
//
// Body: { agency_id, shared_secret, mode: "drive_backfill",
//         limit?: number, document_ids?: string[], dry_run?: boolean,
//         classification?: string }
interface DriveBackfillOutcome {
  documentId: string;
  fileName: string;
  status: "filed" | "gone_from_gmail" | "upload_failed" | "would_run";
  driveFileId?: string;
  error?: string;
}

async function processDriveBackfillMode(
  ctx: RunCtx, body: any,
): Promise<{
  considered: number; filed: number; goneFromGmail: number;
  uploadFailed: number; dryRun: boolean; outcomes: DriveBackfillOutcome[];
}> {
  const documentIds: string[] = Array.isArray(body?.document_ids)
    ? body.document_ids.filter((x: unknown) => typeof x === "string")
    : [];
  const limit = Math.min(Math.max(Number(body?.limit) || 25, 1), 100);
  const dryRun = body?.dry_run === true;
  const classification = typeof body?.classification === "string" ? body.classification : null;

  let q = sb
    .from("documents")
    .select("id, file_name, groq_classification, gmail_message_id, gmail_attachment_id, uploaded_at")
    .eq("agency_id", ctx.agencyId)
    .is("drive_file_id", null)
    .not("gmail_message_id", "is", null)
    .not("gmail_attachment_id", "is", null);

  if (documentIds.length > 0) q = q.in("id", documentIds);
  if (classification) q = q.eq("groq_classification", classification);

  // Newest first on purpose: the newest are the ones still inside the mailbox,
  // so the runs that can actually succeed happen before the ones that cannot.
  const { data: rows, error: selErr } = await q
    .order("uploaded_at", { ascending: false })
    .limit(limit);

  if (selErr) {
    return { considered: 0, filed: 0, goneFromGmail: 0, uploadFailed: 0, dryRun, outcomes: [] };
  }

  const outcomes: DriveBackfillOutcome[] = [];
  let filed = 0, goneFromGmail = 0, uploadFailed = 0;

  for (const row of rows ?? []) {
    const id = (row as any).id as string;
    const fileName = (row as any).file_name ?? "(unnamed)";
    const docType = ((row as any).groq_classification ?? "skip") as DocType;
    const uploadedAt = (row as any).uploaded_at ?? new Date().toISOString();

    if (dryRun) {
      outcomes.push({ documentId: id, fileName, status: "would_run" });
      continue;
    }

    // Ask Gmail for the attachment. The reply carries a temporary signed link
    // whose path is the storage key the upload tool wants. The bytes themselves
    // are not needed — Drive collects the file itself.
    const gm = await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_GET_ATTACHMENT",
      toolArguments: {
        message_id: (row as any).gmail_message_id,
        attachment_id: (row as any).gmail_attachment_id,
        file_name: fileName,
        user_id: "me",
      },
    });
    const s3url = gm.ok
      ? (gm.data?.file?.s3url ?? gm.data?.data?.file?.s3url ?? null)
      : null;
    if (!s3url) {
      goneFromGmail++;
      outcomes.push({
        documentId: id, fileName, status: "gone_from_gmail",
        error: gm.ok ? "Gmail returned no download link" : String(gm.error).slice(0, 300),
      });
      continue;
    }

    let s3Key: string | null = null;
    try {
      const path = new URL(s3url).pathname.replace(/^\/+/, "");
      s3Key = path.length > 0 ? decodeURIComponent(path) : null;
    } catch { s3Key = null; }
    if (!s3Key) {
      uploadFailed++;
      outcomes.push({ documentId: id, fileName, status: "upload_failed", error: "could not read a storage key out of the Gmail link" });
      continue;
    }

    const att: AttachmentInput = {
      messageId: (row as any).gmail_message_id,
      threadId: "",
      fromEmail: "",
      subject: "",
      receivedAt: uploadedAt,
      fileName,
      mimeType: fileName.toLowerCase().endsWith(".zip") ? "application/zip" : "application/pdf",
      attachmentId: (row as any).gmail_attachment_id,
    } as AttachmentInput;

    // Filed by the date the document arrived. The original path used the
    // document's own transaction date, which is not on this row — close enough
    // for a copy whose only job is to be findable.
    const drive = await uploadToDrive(ctx, att, "", docType, String(uploadedAt).slice(0, 10), s3Key);
    if (!drive || !drive.driveFileId) {
      uploadFailed++;
      outcomes.push({ documentId: id, fileName, status: "upload_failed", error: "Drive rejected the upload; an alert was raised with the reason" });
      continue;
    }

    await sb.from("documents")
      .update({ drive_file_id: drive.driveFileId, drive_url: drive.driveUrl || null })
      .eq("id", id);

    filed++;
    outcomes.push({ documentId: id, fileName, status: "filed", driveFileId: drive.driveFileId });
  }

  return {
    considered: (rows ?? []).length,
    filed, goneFromGmail, uploadFailed, dryRun, outcomes,
  };
}

// ---- mode: composio_probe --------------------------------------------------
// Asks Composio, using THIS function's own key, what it can actually see and
// do. It exists because a tool working from an interactive session proves
// nothing about whether this function can reach it — the two authenticate
// differently. Learning that the hard way cost four deploy cycles on
// 2026-08-04, at roughly eight minutes each. Probe first, design second.
//
// Body: { agency_id, shared_secret, mode: "composio_probe",
//         toolkit?: "googledrive",          // list every tool the key can see
//         calls?: [ { slug, account?: "gmail" | "drive", arguments? } ] }
//
// Reads only. Writes nothing, changes nothing, and every result comes back in
// the reply rather than the log, because the log cannot be read after the fact.
async function processComposioProbeMode(ctx: RunCtx, body: any): Promise<any> {
  const out: any = {
    composio_user_id: ctx.composioUserId,
    gmail_account_id: ctx.gmailAccountId,
    drive_account_id: ctx.driveAccountId,
  };

  const toolkit = typeof body?.toolkit === "string" ? body.toolkit : null;
  if (toolkit) {
    try {
      const res = await fetch(
        `https://backend.composio.dev/api/v3/tools?toolkit_slugs=${encodeURIComponent(toolkit)}&limit=500`,
        { headers: { "x-api-key": ctx.composioApiKey } },
      );
      const text = await res.text();
      let parsed: any = {};
      try { parsed = JSON.parse(text); } catch { parsed = { raw: text.slice(0, 1500) }; }
      const items = parsed?.items ?? parsed?.data ?? null;
      out.toolkit = toolkit;
      out.toolkit_http_status = res.status;
      if (Array.isArray(items)) {
        out.toolkit_tool_count = items.length;
        out.toolkit_tools = items
          .map((t: any) => t?.slug ?? t?.name)
          .filter((x: unknown) => typeof x === "string")
          .sort();
      } else {
        out.toolkit_raw = JSON.stringify(parsed).slice(0, 1500);
      }
    } catch (e) {
      out.toolkit_error = e instanceof Error ? e.message : String(e);
    }
  }

  const calls = Array.isArray(body?.calls) ? body.calls.slice(0, 12) : [];
  if (calls.length > 0) {
    out.calls = [];
    for (const c of calls) {
      const slug = typeof c?.slug === "string" ? c.slug : null;
      if (!slug) continue;
      const account = c?.account === "drive" ? ctx.driveAccountId : ctx.gmailAccountId;
      if (!account) {
        out.calls.push({ slug, ok: false, error: "no connected account of that kind is stored" });
        continue;
      }
      const args = c?.arguments && typeof c.arguments === "object" ? c.arguments : {};
      const r = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: account,
        toolSlug: slug,
        toolArguments: args,
      });
      out.calls.push({
        slug,
        ok: r.ok,
        http_status: r.httpStatus,
        error: r.error ? String(r.error).slice(0, 400) : null,
        data_preview: r.data ? JSON.stringify(r.data).slice(0, 1000) : null,
      });
    }
  }

  return out;
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
  const driveFolderId = await getSetting(agencyId, "drive_newtworks_root_folder_id");
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
  if (mode === "careerplug") {
    const cpCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
    const startedAt = new Date().toISOString();
    const result = await processCareerplugMode(cpCtx, body);
    return jsonResponse({ ok: true, mode: "careerplug", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "sf_forwarded_applicant") {
    const sfCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId };
    const startedAt = new Date().toISOString();
    const result = await processSFForwardedApplicantMode(sfCtx, body);
    return jsonResponse({ ok: true, mode: "sf_forwarded_applicant", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "wrapup") {
    const wupCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId };
    const startedAt = new Date().toISOString();
    const result = await processWrapupMode(wupCtx, body);
    return jsonResponse({ ok: true, mode: "wrapup", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "resume_text_recovery") {
    // Re-run forwarded resumes that failed for lack of readable text, pushing
    // each one through Drive text recognition. See the note on the function.
    const trCtx: RunCtx = {
      agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
      driveParentFolderId: driveFolderId,
    };
    const startedAt = new Date().toISOString();
    const result = await processResumeTextRecoveryMode(trCtx, body);
    return jsonResponse({ ok: true, mode: "resume_text_recovery", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "drive_backfill") {
    // File the Drive copies lost while the upload was silently failing.
    const bfCtx: RunCtx = {
      agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
      driveParentFolderId: driveFolderId,
    };
    const startedAt = new Date().toISOString();
    const result = await processDriveBackfillMode(bfCtx, body);
    return jsonResponse({ ok: true, mode: "drive_backfill", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "composio_probe") {
    // Read-only capability check. See the note on the function above.
    const prCtx: RunCtx = {
      agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
      driveParentFolderId: driveFolderId,
    };
    const startedAt = new Date().toISOString();
    const result = await processComposioProbeMode(prCtx, body);
    return jsonResponse({ ok: true, mode: "composio_probe", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }
  if (mode === "no_send_check") {
    // Wrap-up no-send check (2026-07-22). Fires once per week at Fri 7 PM CT.
    // Emails each teammate who submitted nothing + one group Telegram to PJS
    // Agency chat. Pass body.dry_run=true to preview without sending.
    const nsCtx = { agencyId, composioApiKey, composioUserId, gmailAccountId };
    const startedAt = new Date().toISOString();
    const result = await processWrapupNoSendMode(nsCtx, body);
    return jsonResponse({ ok: true, mode: "no_send_check", started_at: startedAt, finished_at: new Date().toISOString(), ...result });
  }

  const ctx: RunCtx = {
    agencyId, composioApiKey, composioUserId, gmailAccountId, driveAccountId,
    driveParentFolderId: driveFolderId,
  };
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
