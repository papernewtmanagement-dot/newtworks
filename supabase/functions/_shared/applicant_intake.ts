// applicant_intake.ts — shared helpers for job-board apply webhooks.
//
// Consumers: indeed-apply-webhook, zip-apply-webhook.
//
// One implementation per job. Before 2026-09-16 each webhook carried its own
// copy of the HMAC verify, the name splitter, the resume-URL picker and the
// screener-answer mapper, and the two copies had already drifted apart.
// Everything here is the superset behaviour, so each webhook still does
// exactly what it did before.

// ─────────────────────────────────────────────────────────────────────────
// Signature verification
// ─────────────────────────────────────────────────────────────────────────

export type HmacHash = "SHA-1" | "SHA-256";
export type HmacEncoding = "base64" | "hex";

// Verifies an HMAC signature over the raw request bytes.
//
// Indeed signs with SHA-1 and sends base64, unprefixed, case-sensitive.
// ZipRecruiter signs with SHA-256 and sends lowercase hex, optionally
// prefixed "sha256=". Both are the same job with different dials, so the
// dials are arguments.
//
// The compare is constant-time. A length mismatch short-circuits, which is
// safe here because the caller can already see the signature length.
export async function verifyHmacSignature(
  rawBody: string,
  signature: string,
  secret: string,
  opts: { hash: HmacHash; encoding: HmacEncoding; stripPrefix?: RegExp },
): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: opts.hash },
    false,
    ["sign"],
  );
  const macBuf = await crypto.subtle.sign("HMAC", key, enc.encode(rawBody));
  const macBytes = new Uint8Array(macBuf);

  const expected = opts.encoding === "base64"
    ? btoa(String.fromCharCode(...macBytes))
    : Array.from(macBytes).map((b) => b.toString(16).padStart(2, "0")).join("");

  let sigNorm = opts.stripPrefix ? signature.replace(opts.stripPrefix, "").trim() : signature;
  if (opts.encoding === "hex") sigNorm = sigNorm.toLowerCase();

  if (expected.length !== sigNorm.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ sigNorm.charCodeAt(i);
  }
  return diff === 0;
}

// ─────────────────────────────────────────────────────────────────────────
// Payload extraction
// ─────────────────────────────────────────────────────────────────────────

// First candidate that is present and not blank once trimmed, else null.
export function pickString(...candidates: unknown[]): string | null {
  for (const c of candidates) {
    if (c == null) continue;
    const s = String(c).trim();
    if (s) return s;
  }
  return null;
}

// Both boards can send the applicant name as one string. Split on the LAST
// space so a multi-word first name stays whole and a suffix folds into the
// last name (for example "Mary Van Buren" gives last "Buren").
export function splitFullName(
  fullName: string | undefined | null,
): { first: string | null; last: string | null } {
  if (!fullName) return { first: null, last: null };
  const trimmed = fullName.trim();
  const lastSpace = trimmed.lastIndexOf(" ");
  if (lastSpace < 0) return { first: trimmed, last: null };
  return { first: trimmed.slice(0, lastSpace).trim(), last: trimmed.slice(lastSpace + 1).trim() };
}

// Resume shapes seen in the wild across both boards:
//   resume: "https://..."            plain URL string
//   resume: { url: "..." }
//   resume: { text | file, ... }     no URL, caller keeps the raw payload
//   applicant.resumeUrl / .resume_url
// applicant is optional — Indeed has no second-chance field.
export function extractResumeUrl(resume: any, applicant?: any): string | null {
  if (typeof resume === "string" && resume.trim()) return resume.trim();
  if (resume?.url) return String(resume.url);
  return pickString(applicant?.resumeUrl, applicant?.resume_url);
}

// Pulls a normalized applicant off a payload whose field naming varies.
export function extractApplicant(payload: any): {
  firstName: string | null; lastName: string | null;
  email: string | null; phone: string | null;
  resumeUrl: string | null; coverLetter: string | null;
} {
  const a = payload?.applicant || payload?.candidate || {};

  // Name may arrive split or combined.
  let firstName = pickString(a.firstName, a.first_name, a.givenName);
  let lastName = pickString(a.lastName, a.last_name, a.familyName);
  if (!firstName && !lastName) {
    const full = pickString(a.name, a.fullName, a.full_name);
    const split = splitFullName(full);
    firstName = split.first;
    lastName = split.last;
  }

  return {
    firstName,
    lastName,
    email: pickString(a.email, a.emailAddress, a.email_address),
    phone: pickString(a.phone, a.phoneNumber, a.phone_number, a.mobile),
    resumeUrl: extractResumeUrl(a.resume, a),
    coverLetter: pickString(a.coverLetter, a.cover_letter, a.coverletter),
  };
}

// ─────────────────────────────────────────────────────────────────────────
// Screener answers
// ─────────────────────────────────────────────────────────────────────────

// Maps a board's answered questions onto our screener bank and reports the
// first knockout hit.
//
// Match order:
//   1. question id / questionId / code / question_id against question_code
//   2. first 40 characters of the echoed question text against question_text
//      (our texts are long enough that a 40-character prefix is unambiguous)
//
// Anything unmatched is kept verbatim under an _unmapped_ key so the stored
// raw payload keeps full context while knockout logic ignores it.
export function mapAnswersToScreener(
  boardQuestions: any[],
  screenerBank: Array<{ question_code: string; question_text: string; knockout_on: string[] | null }>,
): { answers: Record<string, string>; knockoutReason: string | null } {
  const answers: Record<string, string> = {};
  let knockoutReason: string | null = null;

  for (const q of boardQuestions || []) {
    const rawAnswer = pickString(q?.answer, q?.response, q?.value) || "";
    const normalized = rawAnswer.toLowerCase();

    const idCandidate = pickString(q?.id, q?.questionId, q?.code, q?.question_id);
    let matched = idCandidate
      ? screenerBank.find((s) => s.question_code === idCandidate)
      : null;

    if (!matched) {
      const qText = pickString(q?.question, q?.questionText, q?.text)?.slice(0, 40);
      if (qText) {
        matched = screenerBank.find((s) => s.question_text.slice(0, 40) === qText);
      }
    }

    if (matched) {
      answers[matched.question_code] = normalized;
      if (matched.knockout_on && matched.knockout_on.includes(normalized)) {
        knockoutReason = matched.question_code;
      }
    } else {
      const label = pickString(q?.id, q?.question, q?.text) || "unknown";
      answers[`_unmapped_${label.slice(0, 20)}`] = rawAnswer;
    }
  }

  return { answers, knockoutReason };
}
