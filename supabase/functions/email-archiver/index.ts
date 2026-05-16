// =========================================================================
// email-archiver  (BCC dedicated Edge Function)
// =========================================================================
// PURPOSE: Daily inbox hygiene.
//   1. Fetch Gmail messages older than N days that still carry INBOX label.
//   2. For each message with attachments: download via Composio, upload to
//      Google Drive at BCC/Documents/YYYY-MM/<category>/<filename>, and log
//      the row into public.documents.
//   3. Batch-remove INBOX label from those messages (chunks of 1000).
//   4. Honor preserve_starred: skip messages with STARRED label.
//
// INVOKED BY: dispatch_email_archiver(p_agency_id, p_recipe_id) via the
//   automation-runner pipeline. Recipe row sets composio_action='INTERNAL'
//   and internal_handler='dispatch_email_archiver'.
//
// SAFETY: Idempotent. Re-running cannot duplicate Drive uploads because we
//   first check the documents table for an existing row with the same
//   upload_source=gmail:<messageId>. Re-running on a message whose INBOX
//   label was already removed is a no-op at the Gmail layer.
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
const DEFAULT_ARCHIVE_OLDER_THAN_DAYS = 30;
const DRIVE_FOLDER_BASE = "BCC/Documents";
const BATCH_SIZE = 1000;

function jsonResponse(body: any, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function getSetting(agencyId: string, key: string): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) throw new Error(`settings read failed (${key}): ${error.message}`);
  return data?.setting_value ?? null;
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

// Classify an email subject/sender into a Drive folder category. Mirrors the
// document-processor classifier loosely but is intentionally permissive — when
// in doubt we drop into "general" so nothing is lost.
function categorizeForDrive(subject: string, fromAddr: string): string {
  const s = (subject || "").toLowerCase();
  const f = (fromAddr || "").toLowerCase();

  if (s.includes("comp recap") || s.includes("daily comp")) return "comp_recap";
  if (s.includes("deduction")) return "deductions";
  if (s.includes("payroll") || f.includes("gusto") || f.includes("adp") || f.includes("paychex")) return "payroll";
  if (s.includes("bank statement") || f.includes("usbank") || f.includes("us bank")) return "bank_statements";
  if (s.includes("credit card") || f.includes("americanexpress") || f.includes("chase")) return "credit_card_statements";
  if (s.includes("producer production") || s.includes("monthly production")) return "production_reports";
  if (s.includes("invoice") || s.includes("receipt")) return "receipts";
  if (s.includes("contract") || s.includes("agreement")) return "contracts";
  return "general";
}

function yyyymm(d: Date): string {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

// Resolve the immediate parent folder by name within DRIVE_FOLDER_BASE/YYYY-MM/<category>.
// Auto-creates each segment if missing. Returns the leaf folder ID.
async function ensureDriveFolder(opts: {
  apiKey: string;
  userId: string;
  driveAccountId: string;
  category: string;
  emailDate: Date;
}): Promise<string | null> {
  const segments = [DRIVE_FOLDER_BASE, yyyymm(opts.emailDate), opts.category];
  // Walk the path, creating folders as needed. Each segment is created under
  // its parent. Root folder ("BCC") is created under My Drive root if absent.
  let parentId: string | null = null; // null = My Drive root
  for (const segment of segments) {
    // Look up existing folder with this name under parentId
    const searchQuery = parentId
      ? `name = '${segment.replace(/'/g, "\\'")}' and mimeType = 'application/vnd.google-apps.folder' and '${parentId}' in parents and trashed = false`
      : `name = '${segment.replace(/'/g, "\\'")}' and mimeType = 'application/vnd.google-apps.folder' and 'root' in parents and trashed = false`;

    const findRes = await callComposio({
      apiKey: opts.apiKey,
      userId: opts.userId,
      connectedAccountId: opts.driveAccountId,
      toolSlug: "GOOGLEDRIVE_FIND_FILE",
      toolArguments: { query: searchQuery, page_size: 1 },
    });

    if (findRes.ok && findRes.data?.files?.length > 0) {
      parentId = findRes.data.files[0].id;
      continue;
    }

    // Create it
    const createRes = await callComposio({
      apiKey: opts.apiKey,
      userId: opts.userId,
      connectedAccountId: opts.driveAccountId,
      toolSlug: "GOOGLEDRIVE_CREATE_FOLDER",
      toolArguments: parentId
        ? { folder_name: segment, parent_id: parentId }
        : { folder_name: segment },
    });
    if (!createRes.ok) {
      console.warn(`[ensureDriveFolder] create '${segment}' failed: ${createRes.error}`);
      return null;
    }
    parentId = createRes.data?.id || createRes.data?.file?.id || null;
    if (!parentId) {
      console.warn(`[ensureDriveFolder] no id returned for '${segment}'`);
      return null;
    }
  }
  return parentId;
}

async function archiveAttachmentToDrive(opts: {
  apiKey: string;
  userId: string;
  gmailAccountId: string;
  driveAccountId: string;
  messageId: string;
  attachmentId: string;
  filename: string;
  mimeType: string;
  folderId: string;
}): Promise<{ driveFileId: string | null; driveUrl: string | null }> {
  // Step 1: fetch the attachment bytes from Gmail (returns base64 data)
  const attachRes = await callComposio({
    apiKey: opts.apiKey,
    userId: opts.userId,
    connectedAccountId: opts.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: opts.messageId,
      attachment_id: opts.attachmentId,
      user_id: "me",
    },
  });
  if (!attachRes.ok) {
    console.warn(`[archiveAttachment] fetch failed for ${opts.filename}: ${attachRes.error}`);
    return { driveFileId: null, driveUrl: null };
  }

  const b64data = attachRes.data?.data || attachRes.data?.attachment_data;
  if (!b64data) {
    console.warn(`[archiveAttachment] no data returned for ${opts.filename}`);
    return { driveFileId: null, driveUrl: null };
  }

  // Step 2: upload to Drive
  const uploadRes = await callComposio({
    apiKey: opts.apiKey,
    userId: opts.userId,
    connectedAccountId: opts.driveAccountId,
    toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
    toolArguments: {
      file_name: opts.filename,
      file_content: b64data,
      parent_id: opts.folderId,
      mime_type: opts.mimeType,
    },
  });
  if (!uploadRes.ok) {
    console.warn(`[archiveAttachment] upload failed for ${opts.filename}: ${uploadRes.error}`);
    return { driveFileId: null, driveUrl: null };
  }

  const driveFileId = uploadRes.data?.id || uploadRes.data?.file?.id || null;
  const driveUrl = uploadRes.data?.webViewLink || uploadRes.data?.web_view_link
    || (driveFileId ? `https://drive.google.com/file/d/${driveFileId}/view` : null);

  return { driveFileId, driveUrl };
}

interface ArchiveResult {
  status: "success" | "failed";
  records_processed: number;
  output_summary: string;
  error?: string;
  details: {
    messages_scanned: number;
    messages_archived: number;
    attachments_uploaded: number;
    starred_skipped: number;
    already_archived: number;
  };
}

async function runEmailArchiver(opts: {
  agencyId: string;
  recipeId: string;
}): Promise<ArchiveResult> {
  const details = {
    messages_scanned: 0,
    messages_archived: 0,
    attachments_uploaded: 0,
    starred_skipped: 0,
    already_archived: 0,
  };

  // Load recipe input_config
  const { data: recipe, error: recipeErr } = await sb
    .from("automation_recipes")
    .select("input_config")
    .eq("id", opts.recipeId)
    .maybeSingle();
  if (recipeErr || !recipe) {
    return {
      status: "failed",
      records_processed: 0,
      output_summary: "Recipe not found",
      error: recipeErr?.message || "no row",
      details,
    };
  }

  const config = recipe.input_config || {};
  const archiveOlderThanDays = Number(config.archive_older_than_days) || DEFAULT_ARCHIVE_OLDER_THAN_DAYS;
  const preserveStarred = config.preserve_starred !== false;
  const routeAttachmentsToDrive = config.route_attachments_to_drive !== false;

  // Load credentials
  const apiKey = await getSetting(opts.agencyId, "composio_api_key");
  const userId = await getSetting(opts.agencyId, "composio_user_id");
  const gmailAccountId = await getSetting(opts.agencyId, "composio_gmail_account_id");
  const driveAccountId = await getSetting(opts.agencyId, "composio_googledrive_account_id");

  if (!apiKey || !userId || !gmailAccountId) {
    return {
      status: "failed",
      records_processed: 0,
      output_summary: "Missing Composio credentials",
      error: `Missing one of: composio_api_key, composio_user_id, composio_gmail_account_id`,
      details,
    };
  }
  if (routeAttachmentsToDrive && !driveAccountId) {
    return {
      status: "failed",
      records_processed: 0,
      output_summary: "Drive routing enabled but composio_googledrive_account_id missing",
      error: "Missing composio_googledrive_account_id",
      details,
    };
  }

  // Build Gmail search query. "older_than:30d" returns mail older than 30 days.
  // We also require label:inbox so we only touch active inbox items.
  const queryParts = [`older_than:${archiveOlderThanDays}d`, "label:inbox"];
  if (preserveStarred) queryParts.push("-is:starred");
  const gmailQuery = queryParts.join(" ");

  // Paginate through results, collecting message IDs.
  const candidateMessageIds: string[] = [];
  let pageToken: string | undefined = undefined;
  let pageCount = 0;
  const MAX_PAGES = 10; // 10 * 500 = 5000 messages per run, hard ceiling

  while (pageCount < MAX_PAGES) {
    const fetchArgs: Record<string, any> = {
      query: gmailQuery,
      max_results: 500,
      ids_only: true,
      user_id: "me",
      include_payload: false,
    };
    if (pageToken) fetchArgs.page_token = pageToken;

    const fetchRes = await callComposio({
      apiKey,
      userId,
      connectedAccountId: gmailAccountId,
      toolSlug: "GMAIL_FETCH_EMAILS",
      toolArguments: fetchArgs,
    });
    if (!fetchRes.ok) {
      return {
        status: "failed",
        records_processed: 0,
        output_summary: `GMAIL_FETCH_EMAILS failed`,
        error: fetchRes.error || "unknown",
        details,
      };
    }

    const messages = fetchRes.data?.messages || [];
    for (const m of messages) {
      const mid = m?.messageId || m?.id;
      if (mid) candidateMessageIds.push(mid);
    }
    details.messages_scanned += messages.length;

    pageToken = fetchRes.data?.nextPageToken;
    if (!pageToken) break;
    pageCount++;
  }

  if (candidateMessageIds.length === 0) {
    return {
      status: "success",
      records_processed: 0,
      output_summary: `0 emails matched archive criteria (older_than:${archiveOlderThanDays}d, label:inbox${preserveStarred ? ", excluding starred" : ""})`,
      details,
    };
  }

  // Per-message handling — only when attachment routing is enabled.
  // For each message we (a) check if already archived (idempotency), (b)
  // fetch the message payload, (c) route any attachments to Drive, (d) log
  // to documents. Then we batch-remove INBOX in chunks at the end.
  const messageIdsToArchive: string[] = [];

  if (routeAttachmentsToDrive) {
    for (const mid of candidateMessageIds) {
      // Idempotency check: have we already processed this message?
      const { data: existing } = await sb
        .from("documents")
        .select("id")
        .eq("agency_id", opts.agencyId)
        .eq("upload_source", `gmail:${mid}`)
        .limit(1)
        .maybeSingle();
      if (existing) {
        details.already_archived++;
        messageIdsToArchive.push(mid); // still remove INBOX label
        continue;
      }

      // Fetch full message to find attachments
      const msgRes = await callComposio({
        apiKey,
        userId,
        connectedAccountId: gmailAccountId,
        toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
        toolArguments: { message_id: mid, user_id: "me", format: "FULL" },
      });
      if (!msgRes.ok) {
        console.warn(`[archiver] fetch msg ${mid} failed: ${msgRes.error}`);
        continue;
      }

      const msg = msgRes.data || {};
      const headers = msg?.payload?.headers || [];
      const getHeader = (name: string) =>
        (headers.find((h: any) => h.name?.toLowerCase() === name.toLowerCase())?.value) || "";
      const subject = getHeader("Subject");
      const fromAddr = getHeader("From");
      const dateStr = getHeader("Date");
      const emailDate = dateStr ? new Date(dateStr) : new Date();

      // Walk payload parts for attachments
      const attachments: Array<{ id: string; filename: string; mimeType: string }> = [];
      const walkParts = (part: any) => {
        if (!part) return;
        if (part.filename && part.body?.attachmentId) {
          attachments.push({
            id: part.body.attachmentId,
            filename: part.filename,
            mimeType: part.mimeType || "application/octet-stream",
          });
        }
        if (Array.isArray(part.parts)) part.parts.forEach(walkParts);
      };
      walkParts(msg.payload);

      if (attachments.length === 0) {
        // No attachments to archive; just log a stub document row so future
        // runs short-circuit on the idempotency check.
        await sb.from("documents").insert({
          agency_id: opts.agencyId,
          file_name: `(email) ${subject || "(no subject)"}`,
          file_type: "email",
          upload_source: `gmail:${mid}`,
          processing_status: "archived",
          processing_type: "email_only",
          uploaded_by: fromAddr || "unknown",
          uploaded_at: emailDate.toISOString(),
          processed_at: new Date().toISOString(),
          notes: `Archived by email-archiver. No attachments.`,
        });
        messageIdsToArchive.push(mid);
        details.messages_archived++;
        continue;
      }

      // Has attachments → ensure folder, upload each, log a doc row per attachment
      const category = categorizeForDrive(subject, fromAddr);
      const folderId = await ensureDriveFolder({
        apiKey,
        userId,
        driveAccountId: driveAccountId!,
        category,
        emailDate,
      });
      if (!folderId) {
        console.warn(`[archiver] could not resolve Drive folder for ${mid}; skipping uploads but archiving message`);
        messageIdsToArchive.push(mid);
        continue;
      }

      for (const att of attachments) {
        const { driveFileId, driveUrl } = await archiveAttachmentToDrive({
          apiKey,
          userId,
          gmailAccountId,
          driveAccountId: driveAccountId!,
          messageId: mid,
          attachmentId: att.id,
          filename: att.filename,
          mimeType: att.mimeType,
          folderId,
        });
        if (driveFileId) details.attachments_uploaded++;

        await sb.from("documents").insert({
          agency_id: opts.agencyId,
          file_name: att.filename,
          file_type: att.mimeType,
          upload_source: `gmail:${mid}`,
          drive_file_id: driveFileId,
          drive_url: driveUrl,
          processing_status: driveFileId ? "archived" : "archive_failed",
          processing_type: "email_attachment",
          groq_classification: category,
          uploaded_by: fromAddr || "unknown",
          uploaded_at: emailDate.toISOString(),
          processed_at: new Date().toISOString(),
          notes: `Archived by email-archiver from email subject: ${(subject || "").slice(0, 100)}`,
        });
      }

      messageIdsToArchive.push(mid);
      details.messages_archived++;
    }
  } else {
    // No Drive routing — just archive everything (remove INBOX label)
    messageIdsToArchive.push(...candidateMessageIds);
    details.messages_archived = candidateMessageIds.length;
  }

  // Batch-remove INBOX label in chunks of 1000
  for (let i = 0; i < messageIdsToArchive.length; i += BATCH_SIZE) {
    const chunk = messageIdsToArchive.slice(i, i + BATCH_SIZE);
    if (chunk.length === 0) continue;
    const batchRes = await callComposio({
      apiKey,
      userId,
      connectedAccountId: gmailAccountId,
      toolSlug: "GMAIL_BATCH_MODIFY_MESSAGES",
      toolArguments: {
        userId: "me",
        messageIds: chunk,
        addLabelIds: [],
        removeLabelIds: ["INBOX"],
      },
    });
    if (!batchRes.ok) {
      // Don't fail the whole run if one batch fails — log and continue.
      console.warn(`[archiver] batch ${i / BATCH_SIZE} failed: ${batchRes.error}`);
    }
  }

  return {
    status: "success",
    records_processed: details.messages_archived,
    output_summary: `Archived ${details.messages_archived} emails (scanned ${details.messages_scanned}, attachments uploaded ${details.attachments_uploaded}, already-archived ${details.already_archived})`,
    details,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed. Use POST." }, 405);
  }

  let body: any = {};
  try {
    const text = await req.text();
    body = text ? JSON.parse(text) : {};
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  const agencyId: string | undefined = body.agency_id;
  const recipeId: string | undefined = body.recipe_id;
  const sharedSecret: string | undefined = body.shared_secret;

  if (!agencyId) return jsonResponse({ error: "Missing agency_id" }, 400);
  if (!recipeId) return jsonResponse({ error: "Missing recipe_id" }, 400);
  if (!sharedSecret) return jsonResponse({ error: "Missing shared_secret" }, 401);

  // Validate shared secret against settings
  const expectedSecret = await getSetting(agencyId, "automation_runner_cron_secret");
  if (!expectedSecret || sharedSecret !== expectedSecret) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  try {
    const result = await runEmailArchiver({ agencyId, recipeId });
    return jsonResponse(result, result.status === "success" ? 200 : 500);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return jsonResponse({ status: "failed", error: msg, output_summary: msg.slice(0, 200), records_processed: 0 }, 500);
  }
});
