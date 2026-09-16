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

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, AGENCY_ID_DEFAULT } from "../_shared/supabase.ts";
import {
  verifyHmacSignature,
  splitFullName,
  extractResumeUrl,
  mapAnswersToScreener,
} from "../_shared/applicant_intake.ts";

const AGENCY_ID = AGENCY_ID_DEFAULT;
const supabase = sb;

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
  const valid = await verifyHmacSignature(rawBody, signature, secret, { hash: "SHA-1", encoding: "base64" });
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
