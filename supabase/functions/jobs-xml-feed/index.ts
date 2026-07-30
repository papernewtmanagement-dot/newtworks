// jobs-xml-feed edge function
// Serves the Indeed Apply / ZipRecruiter XML Feed Import spec for
// Peter Story State Farm agency at:
//   GET /jobs.xml  (Vercel rewrites → /functions/v1/jobs-xml-feed)
//
// Feed shape follows docs.indeed.com/job-sync-xml/xml-feed and is
// compatible with ZipRecruiter's XML Feed Import (standard <url> + <job>).
// Indeed Apply metadata (indeed-apply-data) is conditionally emitted only
// when settings row indeed_apply_client_id is present; until then Indeed
// falls back to plain URL routing to the careers detail page, which is
// still fully valid.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const AGENCY_NAME = "Peter Story State Farm";
const AGENCY_STREET = "28120 US Hwy 281 N, Suite 125";
const AGENCY_CATEGORY = "Insurance";
const CAREERS_BASE_URL = "https://newtworks.vercel.app/careers";
const INDEED_WEBHOOK_URL = "https://newtworks.vercel.app/webhooks/indeed";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// ─────────────────────────────────────────────────────────────────────────
// XML helpers
// ─────────────────────────────────────────────────────────────────────────

// Wrap arbitrary text in a CDATA section. Split on the "]]>" terminator to
// avoid closing the section prematurely if the input contains it.
function cdata(s: unknown): string {
  const raw = String(s ?? "");
  return `<![CDATA[${raw.replace(/\]\]>/g, "]]]]><![CDATA[>")}]]>`;
}

// Escape only the characters that break URL-encoded query strings inside
// indeed-apply-data. The value is URL-encoded then CDATA-wrapped.
function urlEnc(s: string): string {
  return encodeURIComponent(s);
}

function rfc2822Date(d: Date): string {
  return d.toUTCString();
}

// Convert plaintext description (which is what our postings currently
// store) into a lightweight HTML block: paragraph breaks on double
// newlines, <br> on single newlines within a paragraph, and simple
// bullet detection on lines starting with "- ".
function descriptionToHtml(text: string): string {
  const paragraphs = text.split(/\n{2,}/).map((para) => {
    const lines = para.split(/\n/).map((l) => l.trim()).filter(Boolean);
    if (lines.length === 0) return "";
    const isBulletBlock = lines.every((l) => l.startsWith("- "));
    if (isBulletBlock) {
      const items = lines.map((l) => `<li>${escapeHtml(l.slice(2).trim())}</li>`).join("");
      return `<ul>${items}</ul>`;
    }
    return `<p>${lines.map(escapeHtml).join("<br>")}</p>`;
  });
  return paragraphs.filter(Boolean).join("");
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]!));
}

function formatSalary(min: number | null, max: number | null, period: string | null): string {
  if (!min && !max) return "";
  const fmt = (n: number) =>
    period === "hour" ? `$${n}` : `$${n.toLocaleString()}`;
  const suffix = period === "hour" ? " per hour" : period === "year" ? " per year" : "";
  if (min && max) return `${fmt(min)} - ${fmt(max)}${suffix}`;
  return `${fmt(min || max || 0)}${suffix}`;
}

function jobTypeIndeed(t: string): string {
  return {
    full_time: "fulltime",
    part_time: "parttime",
    contract: "contract",
    temporary: "temporary",
    internship: "internship",
  }[t] || "fulltime";
}

// ─────────────────────────────────────────────────────────────────────────
// Indeed Apply metadata block
// ─────────────────────────────────────────────────────────────────────────

// Build the base64-encoded JSON questions array Indeed Apply expects.
// Each question shape: { id, question, required, type }.
// yes_no → type "yesno" with options ["Yes","No"] handled by Indeed UI.
// open_text → type "multiline".
function buildQuestionsBase64(
  screenerQuestions: Array<{ question_code: string; question_text: string; answer_type: string; is_required: boolean }>,
): string {
  const shaped = screenerQuestions.map((q) => ({
    id: q.question_code,
    question: q.question_text,
    required: q.is_required,
    type: q.answer_type === "yes_no" ? "yesno" : "multiline",
  }));
  // btoa doesn't handle non-ASCII cleanly; JSON is ASCII in our case, so
  // this is safe. If descriptions ever include unicode, upgrade to a
  // TextEncoder + base64 path.
  return btoa(JSON.stringify(shaped));
}

function buildIndeedApplyData(params: {
  apiToken: string;
  posting: any;
  screenerQuestions: any[];
  jobUrl: string;
  postUrl: string;
  location: string;
}): string {
  const q = params.screenerQuestions.length > 0
    ? buildQuestionsBase64(params.screenerQuestions)
    : "";
  const parts: string[] = [
    `indeed-apply-apiToken=${urlEnc(params.apiToken)}`,
    `indeed-apply-jobId=${urlEnc(params.posting.posting_slug)}`,
    `indeed-apply-jobUrl=${urlEnc(params.jobUrl)}`,
    `indeed-apply-jobTitle=${urlEnc(params.posting.job_title)}`,
    `indeed-apply-jobCompanyName=${urlEnc(AGENCY_NAME)}`,
    `indeed-apply-jobLocation=${urlEnc(params.location)}`,
    `indeed-apply-postUrl=${urlEnc(params.postUrl)}`,
    `indeed-apply-name=required`,
    `indeed-apply-email=required`,
    `indeed-apply-phone=required`,
    `indeed-apply-resume=required`,
    `indeed-apply-coverletter=optional`,
  ];
  if (q) parts.push(`indeed-apply-questions=${urlEnc(q)}`);
  return parts.join("&");
}

// ─────────────────────────────────────────────────────────────────────────
// Feed builder
// ─────────────────────────────────────────────────────────────────────────

async function buildFeed(): Promise<string> {
  // Postings: active AND published to either board
  const { data: postings, error } = await supabase
    .from("job_postings")
    .select("*")
    .eq("agency_id", AGENCY_ID)
    .eq("is_active", true)
    .or("publish_to_indeed.eq.true,publish_to_ziprecruiter.eq.true")
    .order("posting_slug");

  if (error) throw new Error(`Postings query: ${error.message}`);

  // Optional Indeed Apply token from settings; falsy means plain-URL apply.
  const { data: tokenRow } = await supabase
    .from("settings")
    .select("setting_value")
    .eq("agency_id", AGENCY_ID)
    .eq("setting_key", "indeed_apply_client_id")
    .maybeSingle();
  const indeedApplyToken = tokenRow?.setting_value?.trim() || null;

  // Screener bank for the agency, hashed by code for cheap per-posting lookup
  const { data: allQuestions } = await supabase
    .from("job_screener_questions")
    .select("question_code, question_text, answer_type, is_required, is_active")
    .eq("agency_id", AGENCY_ID)
    .eq("is_active", true);
  const qBank = new Map((allQuestions || []).map((q) => [q.question_code, q]));

  const now = new Date();
  const jobs: string[] = [];

  for (const p of postings || []) {
    const jobUrl = `${CAREERS_BASE_URL}/${p.posting_slug}`;
    const location = [p.city, p.state].filter(Boolean).join(", ");
    const screenerQuestions = (p.screener_codes || [])
      .map((c: string) => qBank.get(c))
      .filter(Boolean);

    const indeedApplyBlock = indeedApplyToken
      ? `\n    <indeed-apply-data>${cdata(buildIndeedApplyData({
          apiToken: indeedApplyToken,
          posting: p,
          screenerQuestions,
          jobUrl,
          postUrl: INDEED_WEBHOOK_URL,
          location,
        }))}</indeed-apply-data>`
      : "";

    const postedAt = p.first_published_at
      ? new Date(p.first_published_at)
      : new Date(p.created_at);

    const salaryStr = formatSalary(
      p.salary_min ? Number(p.salary_min) : null,
      p.salary_max ? Number(p.salary_max) : null,
      p.salary_period,
    );

    jobs.push(`  <job>
    <title>${cdata(p.job_title)}</title>
    <date>${cdata(rfc2822Date(postedAt))}</date>
    <referencenumber>${cdata(p.posting_slug)}</referencenumber>
    <url>${cdata(jobUrl)}</url>
    <company>${cdata(AGENCY_NAME)}</company>
    <sourcename>${cdata(AGENCY_NAME)}</sourcename>
    <streetaddress>${cdata(AGENCY_STREET)}</streetaddress>
    <city>${cdata(p.city || "")}</city>
    <state>${cdata(p.state || "")}</state>
    <country>${cdata(p.country || "US")}</country>
    <postalcode>${cdata(p.postal_code || "")}</postalcode>
    <description>${cdata(descriptionToHtml(p.description_body || ""))}</description>
    <salary>${cdata(salaryStr)}</salary>
    <jobtype>${cdata(jobTypeIndeed(p.employment_type))}</jobtype>
    <category>${cdata(AGENCY_CATEGORY)}</category>${indeedApplyBlock}
  </job>`);
  }

  const feed = `<?xml version="1.0" encoding="utf-8"?>
<source>
  <publisher>${cdata(AGENCY_NAME)}</publisher>
  <publisherurl>${cdata(CAREERS_BASE_URL)}</publisherurl>
  <lastBuildDate>${cdata(rfc2822Date(now))}</lastBuildDate>
${jobs.join("\n")}
</source>
`;

  // Bookkeeping: stamp last_published_at (and first_published_at if unset)
  // so the DB reflects feed publication history. Fire and forget — a slow
  // update should not block the feed response.
  const nowIso = now.toISOString();
  for (const p of postings || []) {
    const patch: Record<string, string> = { last_published_at: nowIso };
    if (!p.first_published_at) patch.first_published_at = nowIso;
    supabase.from("job_postings").update(patch).eq("id", p.id).then(() => {});
  }

  return feed;
}

// ─────────────────────────────────────────────────────────────────────────
// Serve
// ─────────────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const xml = await buildFeed();
    return new Response(xml, {
      status: 200,
      headers: {
        "content-type": "application/xml; charset=utf-8",
        // 15-minute cache. Indeed polls at ~hourly cadence per their docs;
        // ZipRecruiter is similar. Cache reduces DB churn on their crawls.
        "cache-control": "public, max-age=900, s-maxage=900",
      },
    });
  } catch (e) {
    console.error("jobs-xml-feed error", e);
    return new Response("Feed unavailable", { status: 500 });
  }
});
