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

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { sb, AGENCY_ID_DEFAULT } from "../_shared/supabase.ts";
import {
  verifyHmacSignature,
  pickString,
  extractApplicant,
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

  const valid = await verifyHmacSignature(rawBody, signature, secret, {
    hash: "SHA-256",
    encoding: "hex",
    stripPrefix: /^sha256=/i,
  });
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
