// careers-site edge function — APPLICATION INTAKE ONLY.
//
// Supabase Edge Functions cannot serve HTML: any GET response with a
// content type of text/html is rewritten to text/plain and given a
// locked-down security header, so pages arrive as unstyled raw source.
// That is a documented platform restriction.
//
// Page rendering therefore lives on Vercel at api/careers.js. This function
// keeps only the one job Supabase is right for: receiving the submitted
// application form, writing it to the database, and routing it into the
// hiring pipeline. That is a plain data operation and is fully supported.
//
// ROUTE (single):
//   POST /careers/<slug>/apply   — via the vercel.json rewrite
//
// This function needs the privileged key because it inserts into
// job_applications and hiring_candidates. The Vercel page-rendering side
// deliberately uses the browser-safe key and cannot write.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";

// Applicants must land back on the public site. req.url here is the
// supabase.co origin, so deriving the redirect from it sends them nowhere.
const SITE_ORIGIN = "https://newtworks.vercel.app";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

async function handleApply(slug: string, req: Request): Promise<Response> {
  const form = await req.formData();

  const { data: posting } = await supabase
    .from("job_postings")
    .select("id, screener_codes, job_title")
    .eq("agency_id", AGENCY_ID)
    .eq("posting_slug", slug)
    .eq("is_active", true)
    .maybeSingle();

  if (!posting) return new Response("Position not found.", { status: 404 });

  const { data: questions } = await supabase
    .from("job_screener_questions")
    .select("question_code, knockout_on")
    .eq("agency_id", AGENCY_ID)
    .in("question_code", posting.screener_codes);

  const screenerAnswers: Record<string, string> = {};
  let knockoutReason: string | null = null;

  for (const q of questions || []) {
    const val = String(form.get(`q_${q.question_code}`) || "").toLowerCase().trim();
    screenerAnswers[q.question_code] = val;
    if (q.knockout_on && q.knockout_on.includes(val)) {
      knockoutReason = q.question_code;
    }
  }

  const firstName = String(form.get("first_name") || "").trim();
  const lastName = String(form.get("last_name") || "").trim();
  const email = String(form.get("email") || "").trim();
  const phone = String(form.get("phone") || "").trim();
  const resumeUrl = String(form.get("resume_url") || "").trim() || null;
  const coverLetter = String(form.get("cover_letter_text") || "").trim() || null;

  const rawPayload = {
    submitted_at: new Date().toISOString(),
    user_agent: req.headers.get("user-agent") || null,
    referer: req.headers.get("referer") || null,
    form: Object.fromEntries(form.entries()),
  };

  const { data: appRow, error: appErr } = await supabase
    .from("job_applications")
    .insert({
      agency_id: AGENCY_ID,
      job_posting_id: posting.id,
      source: "careers_page",
      first_name: firstName || null,
      last_name: lastName || null,
      email: email || null,
      phone: phone || null,
      resume_url: resumeUrl,
      cover_letter_text: coverLetter,
      screener_answers: screenerAnswers,
      knockout_reason: knockoutReason,
      raw_payload: rawPayload,
    })
    .select("id")
    .single();

  if (appErr) return new Response(`Application error: ${appErr.message}`, { status: 500 });

  // Route to hiring_candidates only if not knocked out.
  //
  // This goes through upsert_candidate_from_job_board rather than a direct
  // insert. That function calls find_existing_candidate first, so somebody who
  // already has a row gets their blank fields filled in instead of a second row.
  // Matching and filling both live in the database so this page, the Indeed
  // webhook and the ZipRecruiter webhook all behave identically.
  //
  // assessment_date is intentionally NOT stamped here — it stays null until
  // the candidate actually completes the assessment.
  //
  // The job_applications row is already saved at this point, so a failure here
  // is logged and the application is still kept.
  if (!knockoutReason && email) {
    const nowIso = new Date().toISOString();
    const { data: upsert, error: upsertErr } = await supabase.rpc(
      "upsert_candidate_from_job_board",
      {
        p_agency_id: AGENCY_ID,
        p_payload: {
          first_name: firstName || null,
          last_name: lastName || null,
          email: email || null,
          phone: phone || null,
          resume_url: resumeUrl,
          position: posting.job_title || null,
          job_posting_id: posting.id,
          source_channel: "careers_page",
          applied_at: nowIso,
          ingestion_metadata: {
            source: "careers_page",
            job_application_id: appRow.id,
            screener_answers: screenerAnswers,
          },
        },
      },
    );

    if (upsertErr) {
      console.error("careers-site: candidate upsert failed", upsertErr);
    }

    const candidateId = (upsert as any)?.candidate_id ?? null;
    if (candidateId) {
      await supabase
        .from("job_applications")
        .update({ hiring_candidate_id: candidateId, routed_at: nowIso })
        .eq("id", appRow.id);
    }
  }

  return Response.redirect(SITE_ORIGIN + "/careers/apply-received", 303);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // The path can arrive as /functions/v1/careers-site/..., /careers-site/...,
  // or /careers/... depending on the caller. Each prefix is stripped only at a
  // path boundary — an unanchored /careers strip would eat the front of
  // /careers-site and leave "-site", matching nothing.
  let path = url.pathname
    .replace(/^\/functions\/v1\/careers-site(?=\/|$)/, "")
    .replace(/^\/careers-site(?=\/|$)/, "")
    .replace(/^\/careers(?=\/|$)/, "");
  if (path === "") path = "/";

  try {
    if (req.method !== "POST") {
      return new Response(
        "This endpoint receives job applications only. Open positions are at " +
          SITE_ORIGIN + "/careers",
        { status: 405 }
      );
    }

    const applyMatch = path.match(/^\/([^\/]+)\/apply$/);
    if (applyMatch) return await handleApply(applyMatch[1], req);

    return new Response("Not found.", { status: 404 });
  } catch (e) {
    console.error("careers-site error", e);
    return new Response("Something went wrong. Please try again.", { status: 500 });
  }
});
