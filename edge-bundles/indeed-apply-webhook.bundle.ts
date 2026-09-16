// =========================================================================
// indeed-apply-webhook bundle (auto-generated)
// Source of truth: supabase/functions/indeed-apply-webhook/ + supabase/functions/_shared/
// This single-file bundle is what gets deployed to the Supabase edge runtime.
// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py indeed-apply-webhook`.
// =========================================================================

import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

// ==================== _shared/supabase.ts ====================
// =========================================================================
// _shared/supabase.ts
// =========================================================================
// Canonical Supabase client + settings + response helpers for ALL Newtworks
// edge functions. Source of truth for code that used to be copy-pasted into
// every function (client creation, getSetting, jsonResponse, stripFences).
//
// Edge functions deploy as single-file bundles: `scripts/bundle_edge_fn.py`
// inlines this file into each function's bundle. Never edit a bundle by hand;
// edit here and rebundle every consumer.
// =========================================================================


const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Service role — bypasses RLS. Same client options every function used.
const sb: SupabaseClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Single-agency install. Functions that accept agency_id in the request body
// should still prefer the body value; this is the fallback.
const AGENCY_ID_DEFAULT = "126794dd-25ff-47d2-a436-724499733365";

// -------------------------------------------------------------------------
// Settings
// -------------------------------------------------------------------------
// Two variants on purpose — they preserve the two behaviors that existed in
// the wild before consolidation:
//   getSetting        — THROWS if the settings table read itself errors
//                       (infra failure ≠ missing row). Use on critical paths.
//   getSettingOrNull  — swallows read errors, returns null. Use where the
//                       caller treats "can't read" the same as "not set".
// Both return null when the row simply doesn't exist.
// -------------------------------------------------------------------------

async function getSetting(
  agencyId: string,
  key: string,
): Promise<string | null> {
  const { data, error } = await sb
    .from("settings")
    .select("setting_value")
    .eq("agency_id", agencyId)
    .eq("setting_key", key)
    .maybeSingle();
  if (error) {
    throw new Error(
      `settings read failed for agency ${agencyId} key ${key}: ${error.message}`,
    );
  }
  return data?.setting_value ?? null;
}

async function getSettingOrNull(
  agencyId: string,
  key: string,
): Promise<string | null> {
  try {
    const { data } = await sb
      .from("settings")
      .select("setting_value")
      .eq("agency_id", agencyId)
      .eq("setting_key", key)
      .maybeSingle();
    return (data?.setting_value as string | null) ?? null;
  } catch (_e) {
    return null;
  }
}

// Batch read — one query for N keys. Missing keys come back as null.
async function getSettings(
  agencyId: string,
  keys: string[],
): Promise<Record<string, string | null>> {
  const out: Record<string, string | null> = {};
  for (const k of keys) out[k] = null;
  const { data, error } = await sb
    .from("settings")
    .select("setting_key,setting_value")
    .eq("agency_id", agencyId)
    .in("setting_key", keys);
  if (error) {
    throw new Error(`settings batch read failed for agency ${agencyId}: ${error.message}`);
  }
  for (const row of data ?? []) {
    out[(row as any).setting_key] = (row as any).setting_value ?? null;
  }
  return out;
}

// -------------------------------------------------------------------------
// HTTP responses
// -------------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function corsJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// -------------------------------------------------------------------------
// Text helpers
// -------------------------------------------------------------------------

// Strip ```json fences an LLM wrapped around its output.
function stripFences(s: string): string {
  return s
    .trim()
    .replace(/^```(?:json)?\s*/i, "")
    .replace(/\s*```\s*$/i, "")
    .trim();
}

// ==================== _shared/applicant_intake.ts ====================
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

type HmacHash = "SHA-1" | "SHA-256";
type HmacEncoding = "base64" | "hex";

// Verifies an HMAC signature over the raw request bytes.
//
// Indeed signs with SHA-1 and sends base64, unprefixed, case-sensitive.
// ZipRecruiter signs with SHA-256 and sends lowercase hex, optionally
// prefixed "sha256=". Both are the same job with different dials, so the
// dials are arguments.
//
// The compare is constant-time. A length mismatch short-circuits, which is
// safe here because the caller can already see the signature length.
async function verifyHmacSignature(
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
function pickString(...candidates: unknown[]): string | null {
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
function splitFullName(
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
function extractResumeUrl(resume: any, applicant?: any): string | null {
  if (typeof resume === "string" && resume.trim()) return resume.trim();
  if (resume?.url) return String(resume.url);
  return pickString(applicant?.resumeUrl, applicant?.resume_url);
}

// Pulls a normalized applicant off a payload whose field naming varies.
function extractApplicant(payload: any): {
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
function mapAnswersToScreener(
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

// ==================== indeed-apply-webhook/index.ts ====================
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
