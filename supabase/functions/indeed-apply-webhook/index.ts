// indeed-apply-webhook edge function
// Receives Indeed Apply direct-employer submissions at:
//   POST /webhooks/indeed  (Vercel rewrites → /functions/v1/indeed-apply-webhook)
//
// Spec: docs.indeed.com/indeed-apply/webhook-payload
// Flow:
//   1. Read raw body (bytes signed by Indeed).
//   2. Verify HMAC-SHA1 via X-Indeed-Signature header + settings.indeed_apply_webhook_secret.
//   3. Parse JSON.
//   4. Match Indeed jobId → local posting_slug.
//   5. Insert job_applications row with source='indeed_direct'.
//   6. Evaluate screener answers against job_screener_questions.knockout_on.
//   7. If clean: insert hiring_candidates row, backfill hiring_candidate_id + routed_at.
//   8. Return 200. Non-200 triggers Indeed retry — reserve for real ingestion errors.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// ─────────────────────────────────────────────────────────────────────────
// HMAC-SHA1 verify (constant-time compare)
// ─────────────────────────────────────────────────────────────────────────

async function verifyIndeedSignature(rawBody: string, signature: string, secret: string): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const macBuf = await crypto.subtle.sign("HMAC", key, enc.encode(rawBody));
  const macBytes = new Uint8Array(macBuf);
  const expected = btoa(String.fromCharCode(...macBytes));

  // Constant-time compare — length mismatch is short-circuit safe here
  // since attackers can already observe length via signature header.
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  }
  return diff === 0;
}

// ─────────────────────────────────────────────────────────────────────────
// Payload extraction
// ─────────────────────────────────────────────────────────────────────────

// Indeed's applicant.fullName is a single string — split on last space so
// last-name-with-suffix (e.g. "Mary Van Buren") folds into last_name.
function splitFullName(fullName: string | undefined | null): { first: string | null; last: string | null } {
  if (!fullName) return { first: null, last: null };
  const trimmed = fullName.trim();
  const lastSpace = trimmed.lastIndexOf(" ");
  if (lastSpace < 0) return { first: trimmed, last: null };
  return { first: trimmed.slice(0, lastSpace).trim(), last: trimmed.slice(lastSpace + 1).trim() };
}

// Indeed returns applicant.resume as either { url: "..." } or { text: "..." }
// or { file: "<base64>", fileName, contentType }. We store url when we have
// it, and drop the raw file content into raw_payload for later handling.
function extractResumeUrl(resume: any): string | null {
  if (!resume) return null;
  if (typeof resume === "string") return resume;
  if (resume.url) return String(resume.url);
  return null;
}

// Indeed sends questions in one of two shapes depending on whether the feed
// used indeed-apply-questions metadata:
//   [{ id, question, answer }, ...]                 (id-tagged path)
//   [{ question, answer }, ...]                     (text-only fallback)
// We prefer id match against our question_code. On text-only fallback we
// substring-match question text against our screener bank as a best-effort.
function mapAnswersToScreener(
  indeedQuestions: any[],
  screenerBank: Array<{ question_code: string; question_text: string; knockout_on: string[] | null }>,
): { answers: Record<string, string>; knockoutReason: string | null } {
  const answers: Record<string, string> = {};
  let knockoutReason: string | null = null;

  for (const iq of indeedQuestions || []) {
    const rawAnswer = String(iq?.answer ?? "").trim();
    const normalized = rawAnswer.toLowerCase();

    // Prefer id/questionId → code match
    const idCandidate = String(iq?.id ?? iq?.questionId ?? "").trim();
    let matched = idCandidate
      ? screenerBank.find((q) => q.question_code === idCandidate)
      : null;

    // Fall back: match on question_text prefix (first 40 chars of Indeed's
    // echoed question). Screener question texts are long enough that a
    // 40-char prefix is unambiguous within our small bank.
    if (!matched) {
      const iqText = String(iq?.question ?? "").trim().slice(0, 40);
      if (iqText) {
        matched = screenerBank.find((q) => q.question_text.slice(0, 40) === iqText);
      }
    }

    if (matched) {
      answers[matched.question_code] = normalized;
      if (matched.knockout_on && matched.knockout_on.includes(normalized)) {
        knockoutReason = matched.question_code;
      }
    } else {
      // Unknown question — preserve verbatim so the raw_payload retains
      // full context but knockout logic ignores it.
      answers[`_unmapped_${(iq?.id || iq?.question || "").slice(0, 20)}`] = rawAnswer;
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

  // 1. Read the raw body first — HMAC is computed over exact bytes.
  const rawBody = await req.text();

  // 2. Fetch the shared secret. If unset, hard-fail with 503 so Indeed's
  // health checks make it obvious we're not configured yet.
  const { data: secretRow } = await supabase
    .from("settings")
    .select("setting_value")
    .eq("agency_id", AGENCY_ID)
    .eq("setting_key", "indeed_apply_webhook_secret")
    .maybeSingle();
  const secret = secretRow?.setting_value?.trim();

  if (!secret) {
    console.warn("indeed-apply-webhook: no webhook secret configured");
    return new Response("Webhook secret not configured", { status: 503 });
  }

  // 3. Verify signature. Indeed sends X-Indeed-Signature as base64 HMAC-SHA1.
  const signature = req.headers.get("x-indeed-signature") || "";
  if (!signature) {
    return new Response("Missing signature", { status: 401 });
  }
  const valid = await verifyIndeedSignature(rawBody, signature, secret);
  if (!valid) {
    console.warn("indeed-apply-webhook: signature mismatch");
    return new Response("Invalid signature", { status: 401 });
  }

  // 4. Parse JSON — return 400 on malformed so Indeed doesn't retry a
  // permanent error.
  let payload: any;
  try {
    payload = JSON.parse(rawBody);
  } catch (_e) {
    return new Response("Invalid JSON", { status: 400 });
  }

  try {
    // 5. Resolve posting by Indeed jobId (our posting_slug via
    // referencenumber in the feed).
    const jobId = String(payload?.job?.jobId ?? "").trim();
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

    // 6. Load screener bank for the posting (or the full agency bank if
    // posting unknown — we still want to attempt knockout mapping).
    const screenerQuery = supabase
      .from("job_screener_questions")
      .select("question_code, question_text, knockout_on")
      .eq("agency_id", AGENCY_ID)
      .eq("is_active", true);
    const { data: screenerBank } = screenerCodes.length > 0
      ? await screenerQuery.in("question_code", screenerCodes)
      : await screenerQuery;

    // 7. Extract candidate fields.
    const applicant = payload?.applicant || {};
    const { first: firstName, last: lastName } = splitFullName(applicant?.fullName);
    const email = String(applicant?.email ?? "").trim() || null;
    const phone = String(applicant?.phoneNumber ?? applicant?.phone ?? "").trim() || null;
    const resumeUrl = extractResumeUrl(applicant?.resume);
    const coverLetter = String(applicant?.coverletter ?? applicant?.coverLetter ?? "").trim() || null;

    // 8. Map screener answers.
    const { answers, knockoutReason } = mapAnswersToScreener(
      payload?.questions || [],
      screenerBank || [],
    );

    // 9. Insert into job_applications. Store raw_payload = full body so we
    // can rebuild anything later if extraction missed a field.
    const { data: appRow, error: appErr } = await supabase
      .from("job_applications")
      .insert({
        agency_id: AGENCY_ID,
        job_posting_id: jobPostingId,
        source: "indeed_direct",
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
      console.error("indeed-apply-webhook: insert failed", appErr);
      // Return 500 so Indeed retries — this is a transient DB issue,
      // not a bad payload.
      return new Response("Insert failed", { status: 500 });
    }

    // 10. Route to hiring_candidates when not knocked out.
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
          source_channel: "indeed_direct",
          job_posting_id: jobPostingId,
          ingestion_metadata: {
            source: "indeed_direct",
            job_application_id: appRow.id,
            indeed_application_id: payload?.id || null,
            indeed_analytics_id: payload?.analyticsId || null,
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
    console.error("indeed-apply-webhook: unexpected error", e);
    return new Response("Server error", { status: 500 });
  }
});
