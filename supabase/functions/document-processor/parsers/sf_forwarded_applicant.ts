// =========================================================================
// parsers/sf_forwarded_applicant.ts
// =========================================================================
// SF Outlook forwarded applicant intake (Uriah Grady / Autopilot Recruiting).
//
// Called from index.ts when body.mode === "sf_forwarded_applicant".
// Handles the pattern where Peter's SF work Outlook receives an applicant
// email from a recruiter, then forwards it to paper.newt.management@gmail.com
// with the resume + CTS profile + recruiter phone-interview notes attached.
//
// Priscilla Brito (2026-07-15) was the case that surfaced this gap: the
// standard CareerPlug path only catches emails FROM careerplug.com, and the
// standard attachment path skips because no classifier rule matches SF
// forwards.
//
// Flow (mirrors processCareerplugMode structure):
//   1. GMAIL_FETCH_EMAILS with SF-forward query
//   2. For each unprocessed message:
//        a. GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID (full) → get body + attachment IDs
//        b. Extract candidate name from subject
//              subject shape: "FW: [EXTERNAL] Applicant <FirstName> <LastName>"
//        c. Identify + download each PDF attachment (resume, CTS profile, notes)
//        d. Extract CTS scores from CTS PDF via unpdf + Groq
//        e. Upload PDFs to Drive Applicants folder
//        f. Upsert row into team_assessments
//        g. Star + Applicants-label the Gmail message
//   3. Return summary
// =========================================================================

// deno-lint-ignore-file no-explicit-any

import { callComposio } from "../lib/composio.ts";
import { sb } from "../lib/supabase.ts";
import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";

interface SFForwardBody {
  agency_id?: string;
  shared_secret?: string;
  mode?: string;
  gmail_query?: string;
  max_results?: number;
}

interface SFForwardCtx {
  agencyId: string;
  composioApiKey: string;
  composioUserId: string;
  gmailAccountId: string;
  driveAccountId: string | null;
}

interface CtsScores {
  first_name: string | null;
  last_name: string | null;
  email: string | null;
  phone: string | null;
  deadline_motivation: number | null;
  recognition_drive: number | null;
  assertiveness: number | null;
  independent_spirit: number | null;
  analytical: number | null;
  compassion: number | null;
  self_promotion: number | null;
  belief_in_others: number | null;
  optimism: number | null;
  lss_math_accuracy: number | null;
  lss_verbal_accuracy: number | null;
  lss_problem_solving_accuracy: number | null;
  lss_total_accuracy: number | null;
  lss_math_speed_seconds: number | null;
  lss_verbal_speed_seconds: number | null;
  lss_problem_solving_speed_seconds: number | null;
  reliability: string | null;              // "very high" | "high" | "moderate" | "low" | "very low"
  response_distortion: string | null;
  assessment_date: string | null;          // YYYY-MM-DD
}

// Same as CareerPlug — Applicants label + Drive folder in paper.newt.management
const APPLICANTS_GMAIL_LABEL_ID  = "Label_20";
const APPLICANTS_DRIVE_FOLDER_ID = "1GI0h2mEiuGb7BmQevkqpqQ9WM1CWVK4K";

const GROQ_ENDPOINT = "https://api.groq.com/openai/v1/chat/completions";
const GROQ_MODEL_FALLBACK = "openai/gpt-oss-120b";

// ---------- Subject → candidate name -----------------------------------------

// Expected shapes:
//   "FW: [EXTERNAL] Applicant Priscilla Brito"
//   "FWD: [EXTERNAL] Applicant Jane Doe"
//   "[EXTERNAL] Applicant John A. Smith"
//   "Applicant Priscilla Brito"
function extractCandidateNameFromSubject(subject: string): { first_name: string | null; last_name: string | null; raw: string } {
  const cleaned = (subject || "")
    .replace(/^(FW|FWD|Fw|Fwd|fw|fwd)\s*:\s*/i, "")
    .replace(/\[EXTERNAL\]\s*/i, "")
    .replace(/^Applicant\s+/i, "")
    .trim();
  if (!cleaned) return { first_name: null, last_name: null, raw: subject };
  const parts = cleaned.split(/\s+/).filter(Boolean);
  if (parts.length === 0) return { first_name: null, last_name: null, raw: subject };
  if (parts.length === 1) return { first_name: parts[0], last_name: null, raw: cleaned };
  return { first_name: parts[0], last_name: parts.slice(1).join(" "), raw: cleaned };
}

// ---------- Attachment role identification -----------------------------------

type AttachmentRole = "resume" | "cts" | "notes" | "unknown";

function attachmentRole(filename: string): AttachmentRole {
  const f = filename.toLowerCase();
  if (/profile[_\s]?report|likert|sf[_\s]?sales|\bcts\b/.test(f)) return "cts";
  if (/resume|\bcv\b|curriculum/.test(f)) return "resume";
  if (/notes|interview|phone|screen/.test(f)) return "notes";
  return "unknown";
}

// ---------- Groq CTS extraction ----------------------------------------------

const CTS_EXTRACT_SYSTEM = `You extract Cognitive Traits Survey (CTS) scores from a State Farm sales-role assessment PDF text. The PDF contains 9 personality trait scores (0-100), LSS math/verbal/problem-solving accuracy (integers) and speed (seconds), reliability + response_distortion band labels ("very high", "high", "moderate", "low", "very low"), and candidate name/email/phone.

Return ONLY valid JSON matching the requested schema. Never invent values. When a field is not confidently readable, return null. Speed values are always in seconds (integer). Accuracy values are integers (math 0-15, verbal 0-15, problem solving 0-9, total 0-35 typical). Trait scores are integers 0-100.`;

const CTS_EXTRACT_USER_TMPL = (pdfText: string) => `Extract from this CTS Profile Report PDF text. Return JSON with this exact shape:

{
  "first_name": string|null,
  "last_name": string|null,
  "email": string|null,
  "phone": string|null,
  "deadline_motivation": int|null,
  "recognition_drive": int|null,
  "assertiveness": int|null,
  "independent_spirit": int|null,
  "analytical": int|null,
  "compassion": int|null,
  "self_promotion": int|null,
  "belief_in_others": int|null,
  "optimism": int|null,
  "lss_math_accuracy": int|null,
  "lss_verbal_accuracy": int|null,
  "lss_problem_solving_accuracy": int|null,
  "lss_total_accuracy": int|null,
  "lss_math_speed_seconds": int|null,
  "lss_verbal_speed_seconds": int|null,
  "lss_problem_solving_speed_seconds": int|null,
  "reliability": "very high"|"high"|"moderate"|"low"|"very low"|null,
  "response_distortion": "very high"|"high"|"moderate"|"low"|"very low"|null,
  "assessment_date": "YYYY-MM-DD"|null
}

Reliability + response_distortion must be lowercase. Return null for any field not clearly present.

PDF TEXT:
${pdfText.slice(0, 20000)}

Return only the JSON object, nothing else.`;

async function extractCtsScoresFromPdf(pdfText: string, groqKey: string, model: string): Promise<CtsScores | null> {
  const resp = await fetch(GROQ_ENDPOINT, {
    method: "POST",
    headers: { "Authorization": `Bearer ${groqKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model,
      temperature: 0.1,
      max_tokens: 1500,
      messages: [
        { role: "system", content: CTS_EXTRACT_SYSTEM },
        { role: "user",   content: CTS_EXTRACT_USER_TMPL(pdfText) },
      ],
      response_format: { type: "json_object" },
    }),
  });
  if (!resp.ok) {
    console.warn(`CTS extract Groq ${resp.status}: ${(await resp.text()).slice(0, 300)}`);
    return null;
  }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (!content) return null;
  try { return JSON.parse(content) as CtsScores; }
  catch (e) { console.warn("CTS extract JSON parse fail:", (e as Error).message); return null; }
}

// ---------- PDF byte helpers -------------------------------------------------

// Fetches attachment metadata from Gmail. Returns both s3url (for downloading
// bytes to feed unpdf) and s3key (for handing to Drive UPLOAD_FILE without
// round-tripping through base64). Composio's Drive UPLOAD_FILE schema wants
// s3key of a file already in its S3 bucket; the older {file_content, is_base64}
// shape silently uploads 0-byte placeholders.
async function fetchAttachmentInfo(
  ctx: SFForwardCtx, messageId: string, attachmentId: string,
): Promise<{ ok: true; s3url: string; s3key: string } | { ok: false; error: string }> {
  const getRes = await callComposio({
    apiKey: ctx.composioApiKey,
    userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_GET_ATTACHMENT",
    toolArguments: {
      message_id: messageId,
      attachment_id: attachmentId,
      user_id: "me",
      file_name: "attachment.pdf",
    },
  });
  if (!getRes.ok) return { ok: false, error: `attachment fetch: ${getRes.error}` };
  const s3url = getRes.data?.file?.s3url ?? getRes.data?.downloaded_file_content?.s3url;
  if (!s3url) return { ok: false, error: "no s3url on attachment response" };
  const m = s3url.match(/https?:\/\/[^/]+\/(.+?)\?/);
  const s3key = m ? m[1] : null;
  if (!s3key) return { ok: false, error: "could not extract s3key from s3url" };
  return { ok: true, s3url, s3key };
}

async function s3urlToBytesB64(s3url: string): Promise<{ ok: true; b64: string } | { ok: false; error: string }> {
  try {
    const r = await fetch(s3url);
    if (!r.ok) return { ok: false, error: `s3url fetch HTTP ${r.status}` };
    const buf = new Uint8Array(await r.arrayBuffer());
    let bin = "";
    const CHUNK = 0x8000;
    for (let i = 0; i < buf.length; i += CHUNK) bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
    return { ok: true, b64: btoa(bin) };
  } catch (e) {
    return { ok: false, error: `s3url fetch threw: ${e instanceof Error ? e.message : String(e)}` };
  }
}

async function extractPdfText(bytesB64: string): Promise<string | null> {
  try {
    const bin = atob(bytesB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const pdf = await getDocumentProxy(bytes);
    const { text } = await unpdfExtractText(pdf, { mergePages: true });
    const merged = Array.isArray(text) ? text.join("\n") : String(text ?? "");
    return merged.trim() || null;
  } catch { return null; }
}

async function uploadPdfToDrive(
  ctx: SFForwardCtx, s3key: string, targetName: string,
): Promise<{ fileId: string | null; url: string | null }> {
  if (!ctx.driveAccountId) return { fileId: null, url: null };
  try {
    const up = await callComposio({
      apiKey: ctx.composioApiKey, userId: ctx.composioUserId,
      connectedAccountId: ctx.driveAccountId,
      toolSlug: "GOOGLEDRIVE_UPLOAD_FILE",
      toolArguments: {
        file_to_upload: {
          name: targetName,
          mimetype: "application/pdf",
          s3key,
        },
        folder_to_upload_to: APPLICANTS_DRIVE_FOLDER_ID,
      },
    });
    if (!up.ok) { console.warn(`Drive upload ${targetName} failed: ${up.error}`); return { fileId: null, url: null }; }
    const fileId = up.data?.id ?? up.data?.fileId ?? up.data?.response_data?.id ?? null;
    const url    = fileId ? `https://drive.google.com/file/d/${fileId}/view` : null;
    return { fileId, url };
  } catch (e) {
    console.warn(`Drive upload ${targetName} threw:`, e);
    return { fileId: null, url: null };
  }
}

async function starAndLabel(ctx: SFForwardCtx, messageId: string): Promise<void> {
  try {
    await callComposio({
      apiKey: ctx.composioApiKey, userId: ctx.composioUserId,
      connectedAccountId: ctx.gmailAccountId,
      toolSlug: "GMAIL_MODIFY_LABELS",
      toolArguments: {
        message_id: messageId,
        add_label_ids: ["STARRED", APPLICANTS_GMAIL_LABEL_ID],
        remove_label_ids: [],
        user_id: "me",
      },
    });
  } catch (e) {
    console.warn(`star/label ${messageId} failed:`, e);
  }
}

// ---------- Message processor ------------------------------------------------

interface SFForwardMessageResult {
  message_id: string;
  status: "processed" | "skipped" | "error";
  candidate_name?: string;
  assessment_id?: string;
  attachments_seen?: number;
  attachments_by_role?: Record<string, number>;
  error?: string;
}

async function processSFForwardMessage(ctx: SFForwardCtx, messageId: string): Promise<SFForwardMessageResult> {
  const msgRes = await callComposio({
    apiKey: ctx.composioApiKey, userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID",
    toolArguments: {
      message_id: messageId,
      user_id: "me",
      format: "full",
    },
  });
  if (!msgRes.ok) return { message_id: messageId, status: "error", error: `fetch message: ${msgRes.error}` };
  const msg = msgRes.data;
  const subject = msg?.subject ?? msg?.messageSubject ?? "";
  const receivedAt = msg?.messageTimestamp ?? msg?.internalDate ?? new Date().toISOString();
  const receivedAtISO = typeof receivedAt === "string" ? receivedAt : new Date(Number(receivedAt)).toISOString();
  const attachments: any[] = msg?.attachmentList ?? msg?.attachments ?? [];

  if (attachments.length === 0) {
    return { message_id: messageId, status: "skipped", error: "no attachments" };
  }

  const { first_name, last_name } = extractCandidateNameFromSubject(subject);
  const candidateName = [first_name, last_name].filter(Boolean).join(" ") || "Unknown";

  // Role-tag each attachment
  const byRole: Record<AttachmentRole, any[]> = { resume: [], cts: [], notes: [], unknown: [] };
  for (const a of attachments) {
    const filename = a.filename ?? a.fileName ?? "unknown.pdf";
    const role = attachmentRole(filename);
    byRole[role].push({ ...a, filename, role });
  }
  const roleCount: Record<string, number> = {
    resume: byRole.resume.length, cts: byRole.cts.length,
    notes: byRole.notes.length, unknown: byRole.unknown.length,
  };

  // Need at minimum a CTS PDF to insert an assessment row
  if (byRole.cts.length === 0) {
    return {
      message_id: messageId, status: "skipped",
      candidate_name: candidateName, attachments_seen: attachments.length,
      attachments_by_role: roleCount,
      error: "no CTS profile PDF identified",
    };
  }

  // Load Groq creds
  const { data: groqSetting } = await sb.from("settings")
    .select("setting_value").eq("agency_id", ctx.agencyId).eq("setting_key", "groq_api_key").maybeSingle();
  const groqKey = groqSetting?.setting_value ?? null;
  if (!groqKey) return { message_id: messageId, status: "error", error: "groq_api_key missing" };
  const { data: modelSetting } = await sb.from("settings")
    .select("setting_value").eq("agency_id", ctx.agencyId).eq("setting_key", "groq_model_default").maybeSingle();
  const model = modelSetting?.setting_value ?? GROQ_MODEL_FALLBACK;

  // Extract CTS scores from the CTS PDF. Fetch info once, use s3url for
  // downloading bytes to feed unpdf and reuse s3key for the Drive upload.
  const ctsAtt = byRole.cts[0];
  const ctsInfo = await fetchAttachmentInfo(ctx, messageId, ctsAtt.attachmentId ?? ctsAtt.id);
  if (!ctsInfo.ok) return { message_id: messageId, status: "error", error: `CTS attachment: ${ctsInfo.error}` };
  const ctsBytes = await s3urlToBytesB64(ctsInfo.s3url);
  if (!ctsBytes.ok) return { message_id: messageId, status: "error", error: `CTS bytes: ${ctsBytes.error}` };
  const ctsText = await extractPdfText(ctsBytes.b64);
  if (!ctsText) return { message_id: messageId, status: "error", error: "CTS PDF text extraction failed" };

  const scores = await extractCtsScoresFromPdf(ctsText, groqKey, model);
  if (!scores) return { message_id: messageId, status: "error", error: "CTS Groq extraction returned null" };

  // Upload all PDFs to Drive (best-effort; not blocking). Reuse the s3key
  // Composio already generated when we fetched attachment metadata — no
  // point in round-tripping bytes through the edge fn.
  const dateSlug = (scores.assessment_date || receivedAtISO.slice(0, 10)).replace(/-/g, "");
  const nameSlug = candidateName.replace(/\s+/g, " ").trim();

  const uploads: { role: string; url: string | null; fileId: string | null; filename: string }[] = [];
  for (const [role, atts] of Object.entries(byRole)) {
    for (const a of atts as any[]) {
      const attId = a.attachmentId ?? a.id;
      // For the CTS attachment we already have s3key from the earlier fetch.
      const info = (role === "cts") ? { ok: true as const, s3key: ctsInfo.s3key }
                                    : await fetchAttachmentInfo(ctx, messageId, attId);
      if (!info.ok) { uploads.push({ role, url: null, fileId: null, filename: a.filename }); continue; }
      const roleLabel = role === "resume" ? "Resume" : role === "cts" ? "CTS Profile" : role === "notes" ? "Recruiter Notes" : "Applicant Document";
      const targetName = `${roleLabel} - ${nameSlug} - ${dateSlug}.pdf`;
      const up = await uploadPdfToDrive(ctx, info.s3key, targetName);
      uploads.push({ role, url: up.url, fileId: up.fileId, filename: a.filename });
    }
  }
  const resumeUrl = uploads.find((u) => u.role === "resume")?.url ?? null;

  // Assemble the team_assessments row
  const finalFirstName = scores.first_name || first_name;
  const finalLastName  = scores.last_name  || last_name;

  // Dedup: is there already a row for this candidate/agency?
  //   Match by (email if present) OR by (first+last name)
  let existingId: string | null = null;
  if (scores.email) {
    const { data } = await sb.from("team_assessments")
      .select("id").eq("agency_id", ctx.agencyId).eq("email", scores.email).maybeSingle();
    existingId = data?.id ?? null;
  }
  if (!existingId && finalFirstName && finalLastName) {
    const { data } = await sb.from("team_assessments")
      .select("id").eq("agency_id", ctx.agencyId)
      .eq("first_name", finalFirstName).eq("last_name", finalLastName).maybeSingle();
    existingId = data?.id ?? null;
  }

  const rowPayload: Record<string, any> = {
    agency_id: ctx.agencyId,
    assessment_date: scores.assessment_date || receivedAtISO.slice(0, 10),
    candidate_name: candidateName,
    first_name: finalFirstName,
    last_name: finalLastName,
    email: scores.email,
    phone: scores.phone,
    status: "interview",  // arrives already-screened by recruiter
    reliability: scores.reliability,
    response_distortion: scores.response_distortion,
    deadline_motivation: scores.deadline_motivation,
    recognition_drive:   scores.recognition_drive,
    assertiveness:       scores.assertiveness,
    independent_spirit:  scores.independent_spirit,
    analytical:          scores.analytical,
    compassion:          scores.compassion,
    self_promotion:      scores.self_promotion,
    belief_in_others:    scores.belief_in_others,
    optimism:            scores.optimism,
    lss_math_accuracy:              scores.lss_math_accuracy,
    lss_verbal_accuracy:            scores.lss_verbal_accuracy,
    lss_problem_solving_accuracy:   scores.lss_problem_solving_accuracy,
    lss_total_accuracy:             scores.lss_total_accuracy,
    lss_math_speed_seconds:         scores.lss_math_speed_seconds,
    lss_verbal_speed_seconds:       scores.lss_verbal_speed_seconds,
    lss_problem_solving_speed_seconds: scores.lss_problem_solving_speed_seconds,
    resume_url: resumeUrl,
  };
  const noteBlock = `Ingested from SF-forwarded email ${messageId} by sf_forwarded_applicant parser on ${new Date().toISOString().slice(0,10)}. Subject: "${subject}". Attachments: ${uploads.map((u) => `${u.role}=${u.filename}${u.url ? ` → ${u.url}` : ""}`).join("; ")}`;

  let assessmentId: string | null;
  if (existingId) {
    // Only overwrite CTS + resume_url; preserve any human-added claude_summary/notes/etc
    const { data, error } = await sb.from("team_assessments")
      .update(rowPayload).eq("id", existingId).select("id").single();
    if (error) return { message_id: messageId, status: "error", error: `update assessment: ${error.message}` };
    assessmentId = data?.id ?? existingId;
    // Append rather than overwrite notes
    await sb.from("team_assessments").update({
      notes: (await sb.from("team_assessments").select("notes").eq("id", assessmentId).maybeSingle()).data?.notes
        ? undefined  // preserve existing notes if any; TODO: append instead
        : noteBlock,
    }).eq("id", assessmentId);
  } else {
    rowPayload.notes = noteBlock;
    const { data, error } = await sb.from("team_assessments")
      .insert(rowPayload).select("id").single();
    if (error) return { message_id: messageId, status: "error", error: `insert assessment: ${error.message}` };
    assessmentId = data?.id ?? null;
  }

  await starAndLabel(ctx, messageId);

  return {
    message_id: messageId, status: "processed",
    candidate_name: candidateName, assessment_id: assessmentId ?? undefined,
    attachments_seen: attachments.length, attachments_by_role: roleCount,
  };
}

// ---------- Mode entry point -------------------------------------------------

export async function processSFForwardedApplicantMode(
  ctx: SFForwardCtx, body: SFForwardBody,
): Promise<{
  ok: boolean;
  processed_messages: number;
  assessments_upserted: number;
  skipped: number;
  errors: number;
  message_count: number;
  results: SFForwardMessageResult[];
  error?: string;
}> {
  // Default query: SF-forwarded applicant emails not yet labeled Applicants
  const query = body.gmail_query ??
    `from:peter.story.yrru@statefarm.com subject:"Applicant" -label:Applicants newer_than:14d`;
  const maxResults = body.max_results ?? 20;

  const listRes = await callComposio({
    apiKey: ctx.composioApiKey, userId: ctx.composioUserId,
    connectedAccountId: ctx.gmailAccountId,
    toolSlug: "GMAIL_FETCH_EMAILS",
    toolArguments: {
      query, max_results: maxResults, user_id: "me",
      include_payload: false, verbose: false,
    },
  });
  if (!listRes.ok) {
    return { ok: false, processed_messages: 0, assessments_upserted: 0, skipped: 0, errors: 1, message_count: 0, results: [], error: `gmail fetch: ${listRes.error}` };
  }
  const list: any = listRes.data;
  const messages: any[] = list?.messages ?? list?.response_data?.messages ?? [];

  const results: SFForwardMessageResult[] = [];
  let processed = 0, skipped = 0, errors = 0, upserted = 0;

  for (const m of messages) {
    const msgId = m.messageId ?? m.id;
    if (!msgId) continue;
    try {
      const r = await processSFForwardMessage(ctx, msgId);
      results.push(r);
      if (r.status === "processed") { processed++; if (r.assessment_id) upserted++; }
      else if (r.status === "skipped") skipped++;
      else errors++;
    } catch (e) {
      errors++;
      results.push({ message_id: msgId, status: "error", error: e instanceof Error ? e.message : String(e) });
    }
  }

  return { ok: true, processed_messages: processed, assessments_upserted: upserted, skipped, errors, message_count: messages.length, results };
}
