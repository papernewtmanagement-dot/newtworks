// =========================================================================
// parsers/careerplug_applicant.ts
// =========================================================================
// CareerPlug applicant notification email intake.
//
// Called from index.ts when body.mode === "careerplug". Bypasses the
// standard attachment intake pipeline because CareerPlug notifications
// carry applicant data in the email BODY, not as attachments (though a
// resume PDF may be attached — handled opportunistically).
//
// Two notification formats CareerPlug sends:
//   - Individual applicant: "New Applicant: <Name> applied for <Job>"
//                            → one applicant per email
//   - Daily Applicant Digest: "Daily Applicant Digest for <Date>"
//                            → multiple applicants grouped by job
//
// Since we have not yet observed real-world samples of these emails,
// this parser uses an LLM-first extraction. Once real samples arrive and
// the format stabilizes, a deterministic HTML/text regex path can be
// added as a fast-path with LLM as fallback.
//
// Flow:
//   1. GMAIL_FETCH_EMAILS with careerplug query (unstarred, no has:attachment)
//   2. For each unprocessed message:
//        a. GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID (full) to get body + attachments
//        b. LLM parse body -> array of applicants
//        c. For each applicant:
//             - If message has resume PDF attachment: download + upload to
//               Drive, insert documents row, capture resume_document_id
//             - Call upsert_candidate_from_careerplug RPC (idempotent)
//        d. Star the Gmail message (idempotency marker)
//        e. Archive the thread (remove INBOX label)
//   3. Return summary { ok, processed_messages, applicants_upserted, ... }
// =========================================================================

// deno-lint-ignore-file no-explicit-any

interface CareerplugBody {
  agency_id?: string;
  shared_secret?: string;
  mode?: string;
  gmail_query?: string;
  max_results?: number;
}

interface CareerplugCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
}

interface ExtractedApplicant {
  first_name: string | null;
  last_name:  string | null;
  email:      string | null;
  phone:      string | null;
  position:   string | null;
  applied_at: string | null;         // ISO 8601 if we can determine
  prescreen_score:  number | null;   // 0-100 if CareerPlug shows one
  is_fast_track:    boolean | null;
  source_platform:  string | null;   // "Indeed" | "ZipRecruiter" | "LinkedIn" | ...
  resume_url:       string | null;   // Public URL if present in the email
  careerplug_applicant_id: string | null;
  raw_line: string | null;           // optional: verbatim snippet for debug
}

// ---------- Applicant storage destinations ----------
// Gmail label + Drive folder for ingested CareerPlug applicants. Created
// 2026-07-14 via Gmail:create_label + Google Drive:create_file. Hardcoded
// here (not in settings) because these IDs never change once created — if
// they ever DO get recreated, update these two lines.
const APPLICANTS_GMAIL_LABEL_ID  = "Label_20";                          // "Applicants" label in paper.newt.management@gmail.com
const APPLICANTS_DRIVE_FOLDER_ID = "1GI0h2mEiuGb7BmQevkqpqQ9WM1CWVK4K"; // "Applicants" folder in paper.newt.management Drive root

// ---------- LLM extraction prompt ----------

const CAREERPLUG_EXTRACT_PROMPT = `You are extracting applicant data from a CareerPlug hiring platform notification email for a State Farm insurance agency.

CareerPlug sends TWO kinds of notification emails:
  1. Individual applicant email: "New Applicant: <Name> applied for <Job Title>"
     - Contains data for exactly one applicant.
  2. Daily Applicant Digest: "Daily Applicant Digest for <Date>"
     - Contains data for one or more applicants, usually grouped by job title.

Extract EVERY applicant referenced in the email body and return them as a JSON array under key "applicants".

For each applicant, extract these fields when present. Use null if a field is not present. Do not invent values.

  - first_name        (string)
  - last_name         (string)
  - email             (string)
  - phone             (string, digits only preferred but keep the original if formatted)
  - position          (string, the job title they applied to — e.g. "Sales Team Member")
  - applied_at        (ISO 8601 timestamp if the email states when the application was submitted; otherwise null)
  - prescreen_score   (integer 0-100 if a prescreen score / applicant score is shown; otherwise null)
  - is_fast_track     (boolean — true only if CareerPlug flags this applicant as "Fast Track" / "Auto Fast Track" / matches priority prescreen; otherwise null)
  - source_platform   (string — the job board the application came from: "Indeed", "ZipRecruiter", "LinkedIn", "Direct" / "Direct Apply", or similar. Null if not stated.)
  - resume_url        (string URL — a link to view/download the applicant's resume, if present. NOT a link to the applicant's profile page.)
  - careerplug_applicant_id (string — CareerPlug's internal applicant ID if it appears in a URL like /applicants/12345 or similar)
  - raw_line          (string — a short verbatim snippet from the email that this record was extracted from; useful for debugging)

Return STRICTLY this JSON shape and NOTHING else:

  { "applicants": [ { ... }, { ... } ] }

If the email does not appear to be a CareerPlug applicant notification at all, return:

  { "applicants": [] }

Do not include markdown code fences. Do not include explanation.`;

// ---------- One-message processing ----------

interface OneMessageResult {
  status: "processed" | "skipped" | "error";
  applicants_upserted: number;
  applicants_seen: number;
  message_id: string;
  error?: string;
  actions?: Array<{ email?: string | null; name?: string | null; action: string; assessment_id?: string }>;
}

async function processCareerplugMessage(
  ctx: CareerplugCtx,
  messageId: string,
): Promise<OneMessageResult> {
  // 1. Fetch full message
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: {
      message_id: messageId,
      format: "full",
      user_id: "me",
    },
  });
  if (!msgRes.ok) {
    return { status: "error", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: `fetch message: ${msgRes.error}` };
  }
  const msg: any = msgRes.data?.response_data ?? msgRes.data ?? {};

  // Pull headers + a workable body
  const headers = msg?.payload?.headers ?? [];
  const fromEmail: string =
    msg?.from ?? msg?.sender ??
    headers.find((h: any) => h?.name === "From")?.value ?? "";
  const subject: string =
    msg?.subject ??
    headers.find((h: any) => h?.name === "Subject")?.value ?? "";
  const internalDateMs = msg?.internalDate ? Number(msg.internalDate) : Date.now();
  const receivedAtISO: string = new Date(internalDateMs).toISOString();

  // Extract text/plain preferentially, fall back to text/html stripped of tags
  const bodyText = extractBestBody(msg);
  if (!bodyText || bodyText.trim().length < 20) {
    return { status: "skipped", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: "empty or too-short body" };
  }

  // 2. LLM parse (with subject + from for context)
  const cleanedBody = stripCareerplugTrackers(bodyText);
  const llmInput =
    `SUBJECT: ${subject}\nFROM: ${fromEmail}\nRECEIVED_AT (ISO): ${receivedAtISO}\n\n=== BODY ===\n${cleanedBody.slice(0, 8000)}\n=== END BODY ===\n`;

  const parseRes = await parseWithLLM({
    agencyId: ctx.agencyId,
    composioApiKey: ctx.composioApiKey,
    composioUserId: ctx.composioUserId,
    systemPrompt: CAREERPLUG_EXTRACT_PROMPT,
    userContent: llmInput,
    documentId: null,
    purpose: "careerplug_applicant_extract",
    maxTokens: 800,
  });

  if (!parseRes.ok) {
    if ("queued" in parseRes && parseRes.queued) {
      return { status: "error", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: `LLM queued: ${parseRes.queueId}` };
    }
    return { status: "error", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: `LLM parse: ${("error" in parseRes) ? parseRes.error : "unknown"}` };
  }

  const applicants: ExtractedApplicant[] = Array.isArray(parseRes.json?.applicants)
    ? parseRes.json.applicants
    : [];

  if (applicants.length === 0) {
    // Not a CareerPlug applicant email OR LLM extracted nothing. Still star
    // the message so we don't reprocess it every cron tick.
    await starMessage(ctx, messageId);
    return { status: "skipped", applicants_upserted: 0, applicants_seen: 0, message_id: messageId, error: "LLM extracted zero applicants" };
  }

  // 3. Attachments — find any PDFs that could be resumes
  const pdfAttachments = extractPdfAttachments(msg);

  // 4. Upsert each applicant
  const actions: OneMessageResult["actions"] = [];
  let upserted = 0;
  for (let idx = 0; idx < applicants.length; idx++) {
    const a = applicants[idx];

    // Attach a resume PDF if available. When there are exactly N applicants
    // and N PDFs in the message, associate by index; otherwise attach the
    // first PDF only to the first applicant and let others be resume-less.
    let resumeDocumentId: string | null = null;
    if (pdfAttachments.length > 0) {
      const pdf = pdfAttachments.length === applicants.length
        ? pdfAttachments[idx]
        : (idx === 0 ? pdfAttachments[0] : null);
      if (pdf) {
        const stored = await storeResume(ctx, messageId, subject, receivedAtISO, pdf, a);
        if (stored.ok) resumeDocumentId = stored.documentId;
      }
    }

    // Compose upsert payload
    const payload: Record<string, unknown> = {
      first_name: a.first_name ?? null,
      last_name:  a.last_name ?? null,
      email:      a.email ?? null,
      phone:      a.phone ?? null,
      position:   a.position ?? null,
      applied_at: a.applied_at ?? receivedAtISO,
      resume_url: a.resume_url ?? null,
      resume_document_id: resumeDocumentId,
      // Distinct idempotency key per applicant when the email is a digest.
      // Individual-applicant emails have exactly 1 applicant → keeps clean gmail_msg_id.
      gmail_message_id: applicants.length === 1 ? messageId : `${messageId}:${idx}`,
      careerplug_metadata: {
        prescreen_score: a.prescreen_score,
        is_fast_track:   a.is_fast_track,
        source_platform: a.source_platform,
        careerplug_applicant_id: a.careerplug_applicant_id,
        raw_line: a.raw_line,
        gmail_source_message_id: messageId,
        gmail_from: fromEmail,
        gmail_subject: subject,
      },
    };

    const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
      p_agency_id: ctx.agencyId,
      p_payload:   payload,
    });
    if (rpcErr) {
      actions.push({ email: a.email, name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null, action: `rpc_error: ${rpcErr.message}` });
      continue;
    }
    const res = (rpcData ?? {}) as { assessment_id?: string; action?: string };
    actions.push({
      email: a.email,
      name: [a.first_name, a.last_name].filter(Boolean).join(" ") || null,
      action: res.action ?? "unknown",
      assessment_id: res.assessment_id,
    });
    if (res.action === "inserted" || res.action === "updated_by_email") upserted++;
  }

  // 5. Star + 6. Archive
  await starMessage(ctx, messageId);
  const threadId: string | null = msg?.threadId ?? msg?.thread_id ?? null;
  if (threadId) {
    try {
      await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.gmailAccountId,
        toolSlug: "GMAIL_MODIFY_THREAD_LABELS",
        toolArguments: {
          thread_id: threadId,
          remove_label_ids: ["INBOX"],
          add_label_ids: [APPLICANTS_GMAIL_LABEL_ID],
          user_id: "me",
        },
      });
    } catch (e) {
      console.warn("careerplug archive threw (non-fatal):", e);
    }
  }

  return {
    status: "processed",
    applicants_seen: applicants.length,
    applicants_upserted: upserted,
    message_id: messageId,
    actions,
  };
}

// ---------- Helpers ----------

function extractBestBody(msg: any): string {
  // Composio's GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID returns body in a variety of
  // shapes. Try common paths in order:
  //   1. msg.messageText (plain, most common)
  //   2. msg.textBody / msg.plaintext_body / msg.body_text
  //   3. walk payload.parts[] for text/plain
  //   4. fallback: msg.htmlBody / msg.html_body → strip tags
  const direct: string | undefined =
    msg?.messageText ?? msg?.textBody ?? msg?.plaintext_body ?? msg?.body_text ?? msg?.snippet;
  if (typeof direct === "string" && direct.trim().length > 20) return direct;

  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const stack: any[] = [...parts];
  let htmlFallback: string | null = null;
  while (stack.length > 0) {
    const p = stack.shift();
    if (!p) continue;
    const mime: string = p.mimeType ?? p.mime_type ?? "";
    const dataB64: string | undefined = p?.body?.data ?? p?.data;
    if (dataB64) {
      const decoded = tryDecodeB64Url(dataB64);
      if (decoded !== null) {
        if (mime.startsWith("text/plain")) return decoded;
        if (mime.startsWith("text/html") && htmlFallback === null) htmlFallback = decoded;
      }
    }
    if (Array.isArray(p.parts)) stack.push(...p.parts);
  }

  if (htmlFallback) return stripHtml(htmlFallback);

  const htmlDirect: string | undefined = msg?.htmlBody ?? msg?.html_body;
  if (typeof htmlDirect === "string") return stripHtml(htmlDirect);

  return "";
}

function tryDecodeB64Url(b64: string): string | null {
  try {
    // Gmail base64url → base64
    const std = b64.replace(/-/g, "+").replace(/_/g, "/");
    const bin = atob(std);
    // Interpret as UTF-8
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
  } catch (_e) {
    return null;
  }
}

function stripCareerplugTrackers(text: string): string {
  // CareerPlug notification bodies are ~90% base64 tracking URLs. Every
  // clickable text is followed by a parenthesized URL blob. Strip them —
  // they carry zero applicant signal and blow past Groq's TPM budget.
  return text
    .replace(/\(\s*https?:\/\/email\.reply\.careerplug\.com\/[^\s)]+\s*\)/gi, "")
    .replace(/https?:\/\/email\.reply\.careerplug\.com\/[^\s)]+/gi, "")
    .replace(/[ \t]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n");
}

function stripHtml(html: string): string {
  return html
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/p>/gi, "\n\n")
    .replace(/<\/tr>/gi, "\n")
    .replace(/<\/td>/gi, "\t")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

interface PdfAttachment {
  filename: string;
  attachmentId: string;
  mimeType: string;
}

function extractPdfAttachments(msg: any): PdfAttachment[] {
  const out: PdfAttachment[] = [];
  const list1 = msg?.attachmentList as any[] | undefined;
  if (Array.isArray(list1)) {
    for (const a of list1) {
      if (!a?.filename || !a?.attachmentId) continue;
      const mime = a?.mimeType ?? "application/octet-stream";
      if (mime === "application/pdf" || /\.pdf$/i.test(a.filename)) {
        out.push({ filename: a.filename, attachmentId: a.attachmentId, mimeType: mime });
      }
    }
    if (out.length > 0) return out;
  }
  const parts: any[] = msg?.payload?.parts ?? msg?.parts ?? [];
  const stack: any[] = [...parts];
  while (stack.length > 0) {
    const p = stack.shift();
    if (!p) continue;
    const filename: string | undefined = p?.filename;
    const attId: string | undefined = p?.body?.attachmentId ?? p?.attachmentId;
    const mime: string = p?.mimeType ?? p?.mime_type ?? "";
    if (filename && attId && (mime === "application/pdf" || /\.pdf$/i.test(filename))) {
      out.push({ filename, attachmentId: attId, mimeType: mime });
    }
    if (Array.isArray(p.parts)) stack.push(...p.parts);
  }
  return out;
}

async function starMessage(ctx: CareerplugCtx, messageId: string): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey,
      userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_ADD_LABEL_TO_EMAIL",
      toolArguments: {
        message_id: messageId,
        label_ids: ["STARRED"],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn("careerplug star threw (non-fatal):", e);
  }
}

interface StoreResumeResult {
  ok: boolean;
  documentId?: string;
  error?: string;
}

async function storeResume(
  ctx: CareerplugCtx,
  messageId: string,
  subject: string,
  receivedAtISO: string,
  pdf: PdfAttachment,
  a: ExtractedApplicant,
): Promise<StoreResumeResult> {
  // 1. Download attachment bytes
  const getRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: messageId,
      attachment_id: pdf.attachmentId,
      file_name: pdf.filename,
      user_id: "me",
    },
  });
  if (!getRes.ok) return { ok: false, error: `GMAIL_GET_ATTACHMENT: ${getRes.error}` };
  const file = getRes.data?.file ?? getRes.data?.data?.file;
  const s3url = file?.s3url;
  let bytesB64 = "";
  if (s3url) {
    try {
      const r = await fetch(s3url);
      if (!r.ok) return { ok: false, error: `s3url fetch HTTP ${r.status}` };
      const buf = new Uint8Array(await r.arrayBuffer());
      let bin = "";
      const CHUNK = 0x8000;
      for (let i = 0; i < buf.length; i += CHUNK) {
        bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
      }
      bytesB64 = btoa(bin);
    } catch (e) {
      return { ok: false, error: `s3url threw: ${e instanceof Error ? e.message : String(e)}` };
    }
  } else {
    const fallback = getRes.data?.data ?? getRes.data?.bytes;
    if (typeof fallback === "string") bytesB64 = fallback;
    else return { ok: false, error: "no s3url and no inline bytes" };
  }

  // 2. Compose a stable filename: "Resume - <FirstLast> - <YYYYMMDD>.pdf"
  const nameSlug = [a.first_name, a.last_name].filter(Boolean).join(" ") || "unknown";
  const dateSlug = receivedAtISO.slice(0, 10).replace(/-/g, "");
  const targetName = `Resume - ${nameSlug} - ${dateSlug}.pdf`;

  // 3. Upload to Drive if we have a drive account, else skip Drive step
  let driveFileId: string | null = null;
  let driveUrl:    string | null = null;
  if (ctx.driveAccountId) {
    try {
      const uploadRes = await callComposio({
        apiKey: ctx.composioApiKey,
        userId: ctx.composioUserId,
        connectedAccountId: ctx.driveAccountId,
        toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
        toolArguments: {
          file_name: targetName,
          mime_type: "application/pdf",
          file_content: bytesB64,           // base64 body
          is_base64: true,
          folder_to_upload_to: APPLICANTS_DRIVE_FOLDER_ID,
        },
      });
      if (uploadRes.ok) {
        driveFileId = uploadRes.data?.id ?? uploadRes.data?.fileId ?? uploadRes.data?.response_data?.id ?? null;
        driveUrl    = uploadRes.data?.webViewLink ?? uploadRes.data?.web_view_link ?? uploadRes.data?.response_data?.webViewLink ?? null;
      } else {
        console.warn(`resume Drive upload failed (non-fatal): ${uploadRes.error}`);
      }
    } catch (e) {
      console.warn("resume Drive upload threw (non-fatal):", e);
    }
  }

  // 4. Insert documents row
  const { data: docRow, error: docErr } = await sb
    .from("documents")
    .insert({
      agency_id: ctx.agencyId,
      file_name: targetName,
      groq_classification: "careerplug_resume",
      upload_source: "gmail",
      gmail_message_id: messageId,
      drive_file_id: driveFileId,
      drive_url: driveUrl,
      processing_status: "processed",
      uploaded_at: receivedAtISO,
    })
    .select("id")
    .single();
  if (docErr || !docRow) {
    return { ok: false, error: `documents insert: ${docErr?.message ?? "unknown"}` };
  }
  return { ok: true, documentId: docRow.id as string };
}

// ---------- Mode entry point ----------

export async function processCareerplugMode(
  ctx: CareerplugCtx,
  body: CareerplugBody,
): Promise<{
  ok: boolean;
  processed_messages: number;
  applicants_upserted: number;
  applicants_seen: number;
  skipped: number;
  errors: number;
  message_count: number;
  results: any[];
  error?: string;
}> {
  const query = body.gmail_query ??
    `(from:careerplug.com OR from:careerplug OR subject:"new applicant" OR subject:"applicant digest") -label:Applicants newer_than:14d`;
  const maxResults = body.max_results ?? 20;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: {
      query,
      max_results: maxResults,
      user_id: "me",
      include_payload: false,
      verbose: false,
    },
  });
  if (!listRes.ok) {
    return { ok: false, processed_messages: 0, applicants_upserted: 0, applicants_seen: 0, skipped: 0, errors: 1, message_count: 0, results: [], error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: any[] = [];
  let applicantsUpserted = 0;
  let applicantsSeen = 0;
  let processed = 0;
  let skipped = 0;
  let errors = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processCareerplugMessage(ctx, msgId);
      results.push(r);
      if (r.status === "processed") {
        processed++;
        applicantsUpserted += r.applicants_upserted;
        applicantsSeen     += r.applicants_seen;
      } else if (r.status === "skipped") {
        skipped++;
      } else {
        errors++;
      }
    } catch (e) {
      errors++;
      results.push({ message_id: msgId, status: "error", error: e instanceof Error ? e.message : String(e) });
    }
  }

  return {
    ok: true,
    processed_messages: processed,
    applicants_upserted: applicantsUpserted,
    applicants_seen: applicantsSeen,
    skipped,
    errors,
    message_count: messages.length,
    results,
  };
}
