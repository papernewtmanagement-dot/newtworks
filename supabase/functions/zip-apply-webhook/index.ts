// zip-apply-webhook edge function
// Receives ZipRecruiter Apply Webhook submissions at:
//   POST /webhooks/ziprecruiter  (Vercel rewrites → /functions/v1/zip-apply-webhook)
//
// ZR's Apply Webhook spec is less publicly documented than Indeed's, so this
// handler is intentionally flexible about payload shape. Standard patterns:
//   - Header X-ZipRecruiter-Signature (some integrations use X-Signature)
//   - HMAC-SHA256, hex-encoded
//   - Shared secret provisioned during onboarding (atsintegrations@ziprecruiter.com)
//   - JSON body with { applicationId, jobId, applicant: {...}, questions: [...] }
//
// Flow mirrors indeed-apply-webhook but adjusted for ZR conventions.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// ─────────────────────────────────────────────────────────────────────────
// HMAC-SHA256 verify (constant-time compare, hex-encoded)
// ─────────────────────────────────────────────────────────────────────────

async function verifyZipSignature(rawBody: string, signature: string, secret: string): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const macBuf = await crypto.subtle.sign("HMAC", key, enc.encode(rawBody));
  const macBytes = new Uint8Array(macBuf);
  const expectedHex = Array.from(macBytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // ZR sends either raw hex or "sha256=<hex>" prefixed. Accept both.
  const sigNorm = signature.replace(/^sha256=/i, "").trim().toLowerCase();

  if (expectedHex.length !== sigNorm.length) return false;
  let diff = 0;
  for (let i = 0; i < expectedHex.length; i++) {
    diff |= expectedHex.charCodeAt(i) ^ sigNorm.charCodeAt(i);
  }
  return diff === 0;
}

// ─────────────────────────────────────────────────────────────────────────
// Payload extraction — flexible about field naming
// ─────────────────────────────────────────────────────────────────────────

function pickString(...candidates: unknown[]): string | null {
  for (const c of candidates) {
    if (c == null) continue;
    const s = String(c).trim();
    if (s) return s;
  }
  return null;
}

function splitFullName(fullName: string | null): { first: string | null; last: string | null } {
  if (!fullName) return { first: null, last: null };
  const trimmed = fullName.trim();
  const lastSpace = trimmed.lastIndexOf(" ");
  if (lastSpace < 0) return { first: trimmed, last: null };
  return { first: trimmed.slice(0, lastSpace).trim(), last: trimmed.slice(lastSpace + 1).trim() };
}

function extractResumeUrl(resume: any, applicant: any): string | null {
  // ZR variants seen in the wild:
  //   applicant.resume: "https://..."          (plain URL string)
  //   applicant.resume: { url: "..." }
  //   applicant.resumeUrl: "..."
  //   applicant.resume_url: "..."
  if (typeof resume === "string" && resume.trim()) return resume.trim();
  if (resume?.url) return String(resume.url);
  return pickString(applicant?.resumeUrl, applicant?.resume_url);
}

function extractApplicant(payload: any): {
  firstName: string | null; lastName: string | null;
  email: string | null; phone: string | null;
  resumeUrl: string | null; coverLetter: string | null;
} {
  const a = payload?.applicant || payload?.candidate || {};

  // Name may be split or combined
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

function mapAnswersToScreener(
  zipQuestions: any[],
  screenerBank: Array<{ question_code: string; question_text: string; knockout_on: string[] | null }>,
): { answers: Record<string, string>; knockoutReason: string | null } {
  const answers: Record<string, string> = {};
  let knockoutReason: string | null = null;

  for (const zq of zipQuestions || []) {
    const rawAnswer = pickString(zq?.answer, zq?.response, zq?.value) || "";
    const normalized = rawAnswer.toLowerCase();

    // Try id/questionId/code match first
    const idCandidate = pickString(zq?.id, zq?.questionId, zq?.code, zq?.question_id);
    let matched = idCandidate
      ? screenerBank.find((q) => q.question_code === idCandidate)
      : null;

    // Fall back to 40-char question-text prefix match
    if (!matched) {
      const qText = pickString(zq?.question, zq?.questionText, zq?.text)?.slice(0, 40);
      if (qText) {
        matched = screenerBank.find((q) => q.question_text.slice(0, 40) === qText);
      }
    }

    if (matched) {
      answers[matched.question_code] = normalized;
      if (matched.knockout_on && matched.knockout_on.includes(normalized)) {
        knockoutReason = matched.question_code;
      }
    } else {
      const label = pickString(zq?.id, zq?.question, zq?.text) || "unknown";
      answers[`_unmapped_${label.slice(0, 20)}`] = rawAnswer;
    }
  }

  return { answers, knockoutReason };
}

// ─────────────────────────────────────────────────────────────────────────
// Main handler
// ─────────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const rawBody = await req.text();

  const { data: secretRow } = await supabase
    .from("settings")
    .select("setting_value")
    .eq("agency_id", AGENCY_ID)
    .eq("setting_key", "ziprecruiter_apply_webhook_secret")
    .maybeSingle();
  const secret = secretRow?.setting_value?.trim();

  if (!secret) {
    console.warn("zip-apply-webhook: no webhook secret configured");
    return new Response("Webhook secret not configured", { status: 503 });
  }

  // ZR uses one of these headers depending on integration version.
  const signature = req.headers.get("x-ziprecruiter-signature")
    || req.headers.get("x-zip-signature")
    || req.headers.get("x-signature")
    || "";
  if (!signature) {
    return new Response("Missing signature", { status: 401 });
  }

  const valid = await verifyZipSignature(rawBody, signature, secret);
  if (!valid) {
    console.warn("zip-apply-webhook: signature mismatch");
    return new Response("Invalid signature", { status: 401 });
  }

  let payload: any;
  try {
    payload = JSON.parse(rawBody);
  } catch (_e) {
    return new Response("Invalid JSON", { status: 400 });
  }

  try {
    // Resolve posting by ZR jobId (echoes our referencenumber = posting_slug)
    const jobId = pickString(
      payload?.job?.jobId, payload?.job?.id, payload?.jobId,
      payload?.job?.referenceNumber, payload?.job?.reference_number,
      payload?.externalJobId, payload?.feedJobId,
    );

    let jobPostingId: string | null = null;
    let screenerCodes: string[] = [];

    if (jobId) {
      const { data: posting } = await supabase
        .from("job_postings")
        .select("id, screener_codes")
        .eq("agency_id", AGENCY_ID)
        .eq("posting_slug", jobId)
        .maybeSingle();
      if (posting) {
        jobPostingId = posting.id;
        screenerCodes = posting.screener_codes || [];
      }
    }

    const screenerQuery = supabase
      .from("job_screener_questions")
      .select("question_code, question_text, knockout_on")
      .eq("agency_id", AGENCY_ID)
      .eq("is_active", true);
    const { data: screenerBank } = screenerCodes.length > 0
      ? await screenerQuery.in("question_code", screenerCodes)
      : await screenerQuery;

    const { firstName, lastName, email, phone, resumeUrl, coverLetter } = extractApplicant(payload);

    const { answers, knockoutReason } = mapAnswersToScreener(
      payload?.questions || payload?.screeningQuestions || payload?.screening_questions || [],
      screenerBank || [],
    );

    const { data: appRow, error: appErr } = await supabase
      .from("job_applications")
      .insert({
        agency_id: AGENCY_ID,
        job_posting_id: jobPostingId,
        source: "zip_direct",
        first_name: firstName,
        last_name: lastName,
        email,
        phone,
        resume_url: resumeUrl,
        cover_letter_text: coverLetter,
        screener_answers: answers,
        knockout_reason: knockoutReason,
        raw_payload: payload,
      })
      .select("id")
      .single();

    if (appErr) {
      console.error("zip-apply-webhook: insert failed", appErr);
      return new Response("Insert failed", { status: 500 });
    }

    if (!knockoutReason && email) {
      const nowIso = new Date().toISOString();
      const { data: cand } = await supabase
        .from("hiring_candidates")
        .insert({
          agency_id: AGENCY_ID,
          first_name: firstName,
          last_name: lastName,
          candidate_name: [firstName, lastName].filter(Boolean).join(" ") || null,
          email,
          phone,
          resume_url: resumeUrl,
          status: "applied",
          status_updated_at: nowIso,
          applied_at: nowIso,
          source_channel: "zip_direct",
          job_posting_id: jobPostingId,
          ingestion_metadata: {
            source: "zip_direct",
            job_application_id: appRow.id,
            zip_application_id: pickString(payload?.applicationId, payload?.application_id, payload?.id),
            screener_answers: answers,
          },
        })
        .select("id")
        .single();

      if (cand) {
        await supabase
          .from("job_applications")
          .update({ hiring_candidate_id: cand.id, routed_at: nowIso })
          .eq("id", appRow.id);
      }
    }

    return new Response(JSON.stringify({ received: true, application_id: appRow.id }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    console.error("zip-apply-webhook: unexpected error", e);
    return new Response("Server error", { status: 500 });
  }
});
