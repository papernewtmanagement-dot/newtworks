// =========================================================================
// parsers/resume_manual_batch.ts
// =========================================================================
// Hand-forwarded resume batches — bare resume PDFs attached to an email with
// an empty body, forwarded by a person rather than sent by a job board.
//
// Called from index.ts when classifyDocument() returns "resume_manual_batch".
//
// WHY THIS EXISTS (found 2026-08-03):
//   Resume PDFs only reached hiring_candidates by two routes, and both were
//   gated on the SENDER:
//     - careerplug_applicant       → sender must be careerplug.com
//     - mode=sf_forwarded_applicant → sender must be Peter's State Farm
//                                     mailbox AND subject must say "Applicant"
//   Marie forwards raw resume PDFs from her own Gmail with an empty body and
//   subjects like "Applicants - Career Plug 3" / "Applicants - Indeed 08/01".
//   Those matched neither route, so classifyDocument() returned "skip" — no
//   documents row, no candidate row, no error, nothing to notice. Roughly 80
//   resumes accumulated that way across five threads before anyone looked.
//
// WHAT THIS DOES, per PDF:
//   1. Extract the resume text column-aware (same primitives the CareerPlug
//      and State-Farm-forward paths use), fall back to plain extraction.
//   2. Identify the candidate from the TEXT, not the filename. Filenames in
//      these batches are inconsistent enough to be useless as an identity
//      source: "First_Last_Resume.pdf", "ResumeFIRSTLAST.pdf",
//      "ALL_CAPS_Resume.pdf", and bare "Resume.pdf" all appear.
//   3. Upsert through upsert_candidate_from_careerplug — the same routine the
//      CareerPlug path uses, so the four layers of duplicate protection are
//      shared rather than reinvented. The idempotency key is
//      "<messageId>:<fileName>" because one message carries many resumes.
//   4. Store the resume text on the candidate row, never clobbering text that
//      is already there.
//
// FAILURE POSTURE — deliberate:
//   Identity extraction degrades instead of failing. The language model is
//   tried twice; if it does not answer, a deterministic pass pulls the email
//   address and phone number by pattern and takes the name from the first
//   plausible line of the resume. A candidate row with a shaky name that
//   Peter can correct in the app is strictly better than a resume that
//   vanishes, because the fetcher's duplicate check (message id + file name)
//   means a file abandoned once is never offered again. Only when BOTH the
//   language model and the deterministic pass come up with no email and no
//   name does this give up — and then it raises an alert and reports the
//   error upward so index.ts leaves the thread in the inbox.
//
// KNOWN WART: upsert_candidate_from_careerplug hardcodes
// ingestion_metadata.source = "careerplug" for every caller. Rows created
// here therefore read as CareerPlug-sourced. Real provenance is recoverable
// from ingestion_metadata.source_message (sender, subject, message id), which
// this parser fills in. Changing the routine's hardcoded label is a separate
// job affecting the live CareerPlug path, so it is not done here.
// =========================================================================

// deno-lint-ignore-file no-explicit-any

import { sb } from "../lib/supabase.ts";
import { parseWithLLM } from "../lib/llm.ts";
import { extractPdfTextColumnAware, extractPdfTextPlain } from "./pdf_columnar.ts";
import { reformatResumeSeparators } from "./resume_reformat.ts";
import { writeResumeTextIfEmpty } from "./resume_ingest.ts";
import { recoverTextFromScannedFile, type TextRecoveryDeps } from "../lib/text_recovery.ts";

interface RmbIdentity {
  first_name: string | null;
  last_name: string | null;
  email: string | null;
  phone: string | null;
}

export interface RmbArgs {
  agencyId: string;
  documentId: string;
  messageId: string;
  fromEmail: string;
  subject: string;
  receivedAt: string;   // ISO 8601
  fileName: string;
  bytesB64: string;
  resumeUrl: string | null;  // Drive link, when the Drive upload succeeded

  // Gmail's own id for this attachment. Needed only to fetch the original
  // again when the file turns out to be a scan with no text in it. Null for
  // files that came out of a zip, which have no attachment of their own.
  gmailAttachmentId?: string | null;

  // Credentials for the scanned-file text recovery step. Omit to switch that
  // step off entirely — the parser then behaves exactly as it did before.
  recovery?: TextRecoveryDeps;
}

export interface RmbResult {
  ok: boolean;
  candidateId: string | null;
  action: string;              // inserted | updated_by_email | noop_by_gmail_message_id | ...
  candidateName: string | null;
  identitySource: "llm" | "deterministic" | "none";
  // Where the resume text came from: the file's own text layer, or Drive text
  // recognition after the file proved to be a scan.
  textSource?: "pdf" | "text_recognition";
  // Set when text recognition ran. This converted document is the Drive copy
  // these resumes have otherwise never had, so the caller stores it.
  recoveredDriveFileId?: string | null;
  recoveredDriveUrl?: string | null;
  error?: string;
}

const RMB_ID_SYSTEM = `You read the text of one resume and return the candidate's identity. Return ONLY a JSON object, no prose, no markdown fences. Use null for anything the resume does not state. Never invent a name, an email address, or a phone number.`;

const RMB_ID_USER_TMPL = (resumeText: string) => `Return JSON with exactly this shape:
{"first_name":"","last_name":"","email":"","phone":""}

Rules:
- first_name / last_name: the candidate's own name, usually at the very top. Drop middle names, initials, suffixes, and credentials such as MBA or RN. If only one name is present, put it in first_name and set last_name to null.
- email: the candidate's own address. Ignore addresses belonging to former employers, schools, or references.
- phone: digits only, no punctuation, no country code.
- Nothing found for a field → null.

Resume text:
${resumeText.slice(0, 12000)}`;

// Deterministic patterns — the fallback when the language model does not answer.
const RMB_EMAIL_RE = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const RMB_PHONE_RE = /(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}/;

// Words that mark a line as a heading or contact block rather than a name.
const RMB_NOT_A_NAME_RE =
  /(resume|curriculum|vitae|objective|summary|profile|experience|education|skills|references|address|phone|email|linkedin|http|www\.|@|\d{3})/i;

function rmbTitleCase(s: string): string {
  return s
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

/**
 * Pull a name out of the resume text without help from the language model.
 * Looks at the first handful of non-empty lines and takes the first one that
 * looks like a person's name: two to four words, letters only, no heading
 * keywords, no contact-block markers. ALL-CAPS names are title-cased.
 */
function rmbNameFromText(text: string): { first_name: string | null; last_name: string | null } {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).slice(0, 12);
  for (const line of lines) {
    const cleaned = line.replace(/[|•·,]+/g, " ").replace(/\s+/g, " ").trim();
    if (!cleaned || cleaned.length > 60) continue;
    if (RMB_NOT_A_NAME_RE.test(cleaned)) continue;
    const words = cleaned.split(" ").filter((w) => /^[A-Za-z][A-Za-z'’.-]*$/.test(w));
    if (words.length !== cleaned.split(" ").length) continue;
    if (words.length < 2 || words.length > 4) continue;
    const named = rmbTitleCase(words.join(" ")).split(" ");
    return { first_name: named[0], last_name: named.slice(1).join(" ") };
  }
  return { first_name: null, last_name: null };
}

function rmbDeterministicIdentity(text: string): RmbIdentity {
  const email = text.match(RMB_EMAIL_RE)?.[0] ?? null;
  const phoneRaw = text.match(RMB_PHONE_RE)?.[0] ?? null;
  const phone = phoneRaw ? phoneRaw.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "") : null;
  const { first_name, last_name } = rmbNameFromText(text);
  return { first_name, last_name, email, phone };
}

function rmbCleanIdentity(raw: any): RmbIdentity {
  const str = (v: any): string | null => {
    if (typeof v !== "string") return null;
    const t = v.trim();
    if (!t || t.toLowerCase() === "null" || t.toLowerCase() === "n/a") return null;
    return t;
  };
  const phoneRaw = str(raw?.phone);
  return {
    first_name: str(raw?.first_name),
    last_name: str(raw?.last_name),
    email: str(raw?.email)?.toLowerCase() ?? null,
    phone: phoneRaw ? phoneRaw.replace(/\D/g, "").replace(/^1(?=\d{10}$)/, "") : null,
  };
}

async function rmbExtractResumeText(bytesB64: string): Promise<string | null> {
  try {
    const bin = atob(bytesB64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);

    let raw = "";
    try {
      raw = await extractPdfTextColumnAware(bytes);
    } catch (colErr) {
      console.warn(`[resume_manual_batch] column-aware extract failed, trying plain: ${colErr instanceof Error ? colErr.message : String(colErr)}`);
      try {
        raw = await extractPdfTextPlain(bytes);
      } catch (plainErr) {
        console.warn(`[resume_manual_batch] plain extract also failed: ${plainErr instanceof Error ? plainErr.message : String(plainErr)}`);
        return null;
      }
    }
    if (!raw || !raw.trim()) return null;
    return reformatResumeSeparators(raw);
  } catch (e) {
    console.warn("[resume_manual_batch] text extraction threw:", e);
    return null;
  }
}

export async function processResumeManualBatch(args: RmbArgs): Promise<RmbResult> {
  const fail = (error: string): RmbResult => ({
    ok: false, candidateId: null, action: "error",
    candidateName: null, identitySource: "none", error,
  });

  // ---- 1. Resume text --------------------------------------------------
  let resumeText = await rmbExtractResumeText(args.bytesB64);
  let textSource: "pdf" | "text_recognition" = "pdf";
  let recoveredDriveFileId: string | null = null;
  let recoveredDriveUrl: string | null = null;

  // Nothing extractable means the file is a scan or a phone photo — page
  // images with no text layer. About one in five of these resumes is. Rather
  // than losing a real applicant, send the original through Drive, which
  // performs text recognition when a page-image file is brought in as a
  // Google Doc, and carry on with the recovered text. Everything below this
  // point is unchanged, which is the whole point of doing it here.
  if (!resumeText && args.recovery && args.gmailAttachmentId) {
    const rec = await recoverTextFromScannedFile({
      deps: args.recovery,
      messageId: args.messageId,
      attachmentId: args.gmailAttachmentId,
      fileName: args.fileName,
    });
    if (rec.ok) {
      resumeText = reformatResumeSeparators(rec.text);
      textSource = "text_recognition";
      recoveredDriveFileId = rec.driveFileId;
      recoveredDriveUrl = rec.driveUrl;
      console.log(`[resume_manual_batch] ${args.fileName}: no text in the file; recovered ${rec.charCount} characters by Drive text recognition`);
    } else {
      console.warn(`[resume_manual_batch] ${args.fileName}: text recognition failed at the ${rec.stage} stage: ${rec.error}`);
    }
  }

  if (!resumeText) {
    await rmbAlert(args, "No readable text in this file, and text recognition could not recover any either. Likely a blank page, handwriting, or a photo of something that is not a document. Needs manual entry.");
    return fail("resume text extraction returned nothing, and text recognition recovered nothing either");
  }

  // ---- 2. Identity: language model first, twice ------------------------
  let identity: RmbIdentity | null = null;
  let identitySource: RmbResult["identitySource"] = "none";

  for (let attempt = 1; attempt <= 2; attempt++) {
    const res = await parseWithLLM({
      agencyId: args.agencyId,
      composioApiKey: "",   // unused by lib/llm.ts; kept for signature compatibility
      composioUserId: "",
      systemPrompt: RMB_ID_SYSTEM,
      userContent: RMB_ID_USER_TMPL(resumeText),
      documentId: args.documentId,
      purpose: "resume_identity_extract",
      maxTokens: 400,
      // llm-queue-drainer has no handler for this purpose, and the pattern
      // matching below already covers a model failure — a queued row would sit
      // pending forever. Take the plain failure instead.
      skipQueueOnFailure: true,
    });
    if (res.ok) {
      const cand = rmbCleanIdentity(res.json);
      if (cand.first_name || cand.email) {
        identity = cand;
        identitySource = "llm";
        break;
      }
    }
    // Rate limits are the common failure here (many resumes land in one run),
    // so pause before the retry rather than hammering.
    if (attempt === 1) await new Promise((r) => setTimeout(r, 4000));
  }

  // ---- 3. Deterministic fallback ---------------------------------------
  if (!identity) {
    const det = rmbDeterministicIdentity(resumeText);
    if (det.email || det.first_name) {
      identity = det;
      identitySource = "deterministic";
      console.warn(`[resume_manual_batch] ${args.fileName}: language model gave no identity; used pattern matching (email=${det.email ?? "none"}, name=${[det.first_name, det.last_name].filter(Boolean).join(" ") || "none"})`);
    }
  }

  if (!identity) {
    await rmbAlert(args, "Could not determine who this resume belongs to — no name and no email address found by either method. Needs manual entry.");
    return fail("identity extraction failed (language model and pattern matching both empty)");
  }

  // Pattern-fill anything the language model left blank. Additive only —
  // never overwrites a value the model did return.
  if (identitySource === "llm") {
    const det = rmbDeterministicIdentity(resumeText);
    identity.email = identity.email ?? det.email;
    identity.phone = identity.phone ?? det.phone;
  }

  let candidateName = [identity.first_name, identity.last_name].filter(Boolean).join(" ") || null;

  // hiring_candidates carries team_assessments_identity_check, which demands
  // either a team member id or a non-empty candidate_name. A resume that gives
  // up an email address but no name violates it and throws, and because the
  // fetcher's duplicate check means an abandoned file is never offered again,
  // that applicant is lost for good. Fall back to the part of the email address
  // before the @ sign so the row lands soft and the name can be corrected in
  // the app. (Found 2026-08-04: one resume in the first backlog run did this.)
  let nameFromEmail = false;
  if (!candidateName && identity.email) {
    const localPart = identity.email.split("@")[0]?.trim();
    if (localPart) {
      candidateName = localPart;
      nameFromEmail = true;
      console.warn(`[resume_manual_batch] ${args.fileName}: no name found by either method; using email local part "${localPart}" as candidate_name`);
    }
  }

  // ---- 4. Upsert -------------------------------------------------------
  // Idempotency key is message id + file name: one forwarded email carries
  // many resumes, so the message id alone would collapse the whole batch
  // into a single candidate.
  const payload: Record<string, unknown> = {
    first_name: identity.first_name,
    last_name: identity.last_name,
    candidate_name: candidateName,
    email: identity.email,
    phone: identity.phone,
    position: null,
    applied_at: args.receivedAt,
    resume_url: args.resumeUrl ?? recoveredDriveUrl,
    resume_document_id: args.documentId,
    gmail_message_id: `${args.messageId}:${args.fileName}`,
    careerplug_metadata: {
      gmail_source_message_id: args.messageId,
      gmail_from: args.fromEmail,
      gmail_subject: args.subject,
      source_platform: null,
    },
  };

  const { data: rpcData, error: rpcErr } = await sb.rpc("upsert_candidate_from_careerplug", {
    p_agency_id: args.agencyId,
    p_payload: payload,
  });
  if (rpcErr) {
    await rmbAlert(args, `Candidate upsert failed: ${rpcErr.message}`);
    return fail(`upsert_candidate_from_careerplug: ${rpcErr.message}`);
  }

  const res = (rpcData ?? {}) as { assessment_id?: string; action?: string };
  const candidateId = res.assessment_id ?? null;

  // ---- 5. Resume text onto the candidate row ---------------------------
  await writeResumeTextIfEmpty(candidateId, resumeText);

  // The row landed, but under a stand-in name. Say so, so it gets corrected.
  if (nameFromEmail) {
    await rmbAlert(
      args,
      `Saved, but no name could be read from this resume. The name currently shows as "${candidateName}" (taken from the email address). Please correct it on the candidate record.`,
    );
  }

  return {
    ok: true,
    candidateId,
    action: res.action ?? "unknown",
    candidateName,
    identitySource,
    textSource,
    recoveredDriveFileId,
    recoveredDriveUrl,
  };
}

async function rmbAlert(args: RmbArgs, message: string): Promise<void> {
  try {
    await sb.from("alerts").insert({
      agency_id: args.agencyId,
      alert_type: "resume_ingest_failed",
      severity: "warning",
      title: `Resume could not be ingested — ${args.fileName}`,
      message: `${message}\n\nFrom: ${args.fromEmail}\nSubject: "${args.subject}"\nFile: ${args.fileName}`,
      module_reference: "document-processor",
      related_id: args.documentId,
      is_read: false,
      is_resolved: false,
      created_at: new Date().toISOString(),
    });
  } catch (e) {
    console.warn("[resume_manual_batch] alert insert failed (non-fatal):", e);
  }
}
