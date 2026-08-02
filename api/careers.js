// api/careers — Vercel Edge Function.
//
// WHY THIS LIVES ON VERCEL AND NOT SUPABASE:
// Supabase Edge Functions do not serve HTML. Any GET response with a
// content type of text/html is rewritten to text/plain and given a
// locked-down security header, so the page arrives as unstyled raw source.
// This is a documented platform restriction, not a configuration problem.
// Page rendering therefore happens here. Form submissions still POST to the
// Supabase "careers-site" function, because receiving data is a plain API
// operation and is allowed there.
//
// ROUTING: vercel.json rewrites /careers and /careers/* to this file and
// passes the original path through the "p" query parameter, because a
// rewrite replaces the visible path with /api/careers.
//
// KEYS: reads use the browser-safe key only. job_postings and
// job_screener_questions both carry public read policies for active rows.

// careers-site edge function
// Serves the public careers surface for Peter Story State Farm agency:
//   GET  /careers                → listing of active postings
//   GET  /careers/<slug>         → job detail + apply form
//   POST /careers/<slug>/apply   → application submission
//   GET  /careers/terms          → Terms of Service
//   GET  /careers/privacy        → Privacy Policy
//   GET  /careers/apply-received → confirmation page
// Vercel rewrites /careers/* on newtworks domain → this function.

import { createClient } from "@supabase/supabase-js";

const AGENCY_ID = "126794dd-25ff-47d2-a436-724499733365";
const AGENCY_NAME = "Peter Story State Farm";
const AGENCY_ADDRESS_LINES = ["28120 US Hwy 281 N, Suite 125", "San Antonio, TX 78260"];
const AGENCY_PHONE = "830-980-8100";
const AGENCY_CONTACT_EMAIL = "paper.newt.management@gmail.com";

const supabase = createClient(
  process.env.VITE_SUPABASE_URL,
  process.env.VITE_SUPABASE_ANON_KEY
);

// ────────────────────────────────────────────────────────────────────────────
// HTML helpers
// ────────────────────────────────────────────────────────────────────────────

function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

function page(title, body, extraHead = "") {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${esc(title)}</title>
  <meta property="og:site_name" content="${esc(AGENCY_NAME)}">
  <meta property="og:title" content="${esc(title)}">
  <meta property="og:type" content="website">
  <style>
    :root {
      --ink: #1a1a1a; --ink-soft: #4a4a4a; --line: #e5e5e5;
      --bg: #ffffff; --card: #fafafa; --accent: #b32229;
      --accent-hover: #8f1a1f; --success: #1f7a3d;
    }
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
      color: var(--ink); background: var(--bg); margin: 0; line-height: 1.55;
      -webkit-font-smoothing: antialiased;
    }
    .container { max-width: 780px; margin: 0 auto; padding: 24px 20px 60px; }
    header.site {
      border-bottom: 1px solid var(--line); padding: 20px 0 16px; margin-bottom: 28px;
    }
    header.site .agency { font-size: 20px; font-weight: 700; letter-spacing: -0.01em; }
    header.site .tagline { font-size: 14px; color: var(--ink-soft); margin-top: 2px; }
    h1 { font-size: 28px; line-height: 1.2; margin: 0 0 8px; letter-spacing: -0.015em; }
    h2 { font-size: 20px; margin: 32px 0 12px; letter-spacing: -0.01em; }
    p { margin: 0 0 14px; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .meta { color: var(--ink-soft); font-size: 15px; margin-bottom: 20px; }
    .meta span + span::before { content: "·"; margin: 0 8px; color: var(--line); }
    .job-list { list-style: none; padding: 0; margin: 0; }
    .job-list li { border: 1px solid var(--line); border-radius: 8px; padding: 18px 20px; margin-bottom: 14px; background: var(--bg); }
    .job-list li:hover { border-color: var(--accent); }
    .job-list a { color: var(--ink); font-weight: 600; font-size: 17px; }
    .job-list .job-meta { color: var(--ink-soft); font-size: 14px; margin-top: 4px; }
    .body-text { white-space: pre-wrap; font-size: 16px; }
    .btn {
      display: inline-block; background: var(--accent); color: white; padding: 12px 22px;
      border-radius: 6px; font-weight: 600; font-size: 16px; border: none; cursor: pointer;
      text-decoration: none;
    }
    .btn:hover { background: var(--accent-hover); text-decoration: none; }
    .btn.secondary { background: transparent; color: var(--accent); border: 1px solid var(--accent); }
    form.apply { margin-top: 24px; }
    form.apply .field { margin-bottom: 18px; }
    form.apply label { display: block; font-weight: 600; margin-bottom: 6px; font-size: 15px; }
    form.apply .helper { color: var(--ink-soft); font-size: 14px; margin-bottom: 6px; white-space: pre-wrap; }
    form.apply input[type=text], form.apply input[type=email], form.apply input[type=tel],
    form.apply textarea, form.apply select {
      width: 100%; padding: 10px 12px; border: 1px solid var(--line); border-radius: 6px;
      font-size: 16px; font-family: inherit; background: white;
    }
    form.apply textarea { min-height: 100px; resize: vertical; }
    form.apply .radio-group label {
      display: block; font-weight: 400; padding: 8px 0; cursor: pointer;
    }
    form.apply .radio-group input { margin-right: 8px; }
    form.apply .required::after { content: " *"; color: var(--accent); }
    footer.site {
      border-top: 1px solid var(--line); margin-top: 60px; padding-top: 24px;
      color: var(--ink-soft); font-size: 13px;
    }
    footer.site a { color: var(--ink-soft); }
    footer.site .disclaimer { margin-top: 16px; font-style: italic; }
    .notice {
      background: var(--card); border-left: 3px solid var(--accent); padding: 14px 16px;
      margin: 20px 0; border-radius: 4px; font-size: 15px;
    }
    .back-link { display: inline-block; margin-bottom: 20px; font-size: 14px; color: var(--ink-soft); }
    .back-link::before { content: "← "; }
    ${extraHead}
  </style>
</head>
<body>
<div class="container">
  <header class="site">
    <div class="agency">${esc(AGENCY_NAME)}</div>
    <div class="tagline">Careers — join our team in San Antonio</div>
  </header>
  ${body}
  <footer class="site">
    <p>${esc(AGENCY_NAME)} · ${AGENCY_ADDRESS_LINES.map(esc).join(" · ")} · ${esc(AGENCY_PHONE)}</p>
    <p><a href="/careers">All openings</a> · <a href="/careers/terms">Terms of Service</a> · <a href="/careers/privacy">Privacy Policy</a></p>
    <p class="disclaimer">This position is with a State Farm independent contractor agent, not with State Farm Insurance Companies. State Farm agents are independent contractors who hire their own employees. State Farm agents' employees are not employees of State Farm.</p>
  </footer>
</div>
</body>
</html>`;
}

function formatSalary(min, max, period) {
  if (!min && !max) return "";
  const fmt = (n) => period === "hour" ? `$${n}` : `$${n.toLocaleString()}`;
  const suffix = period === "hour" ? "/hour" : period === "year" ? "/year" : "";
  if (min && max) return `${fmt(min)} - ${fmt(max)}${suffix}`;
  return `${fmt(min || max || 0)}${suffix}`;
}

function typeLabel(t) {
  return { full_time: "Full Time", part_time: "Part Time", contract: "Contract", temporary: "Temporary" }[t] || t;
}

function locationLabel(mode, city, state) {
  if (mode === "remote") return "Fully Remote (US)";
  const base = [city, state].filter(Boolean).join(", ");
  return mode === "hybrid" ? `Hybrid · ${base}` : base;
}

// ────────────────────────────────────────────────────────────────────────────
// Route: GET /careers (listing)
// ────────────────────────────────────────────────────────────────────────────

async function renderListing() {
  const { data: postings, error } = await supabase
    .from("job_postings")
    .select("posting_slug, job_title, employment_type, location_mode, city, state, salary_min, salary_max, salary_period")
    .eq("agency_id", AGENCY_ID)
    .eq("is_active", true)
    .eq("publish_to_careers_page", true)
    .order("job_title");

  if (error) return new Response(`Error loading postings: ${error.message}`, { status: 500 });

  const items = (postings || []).map(p => `
    <li>
      <a href="/careers/${esc(p.posting_slug)}">${esc(p.job_title)}</a>
      <div class="job-meta">
        ${esc(typeLabel(p.employment_type))} · ${esc(locationLabel(p.location_mode, p.city, p.state))}
        ${p.salary_min ? " · " + esc(formatSalary(p.salary_min, p.salary_max, p.salary_period)) : ""}
      </div>
    </li>`).join("");

  const body = `
    <h1>Open Positions</h1>
    <p class="meta">We hire slowly and coach hard. If you want a career, not a job, keep reading.</p>
    ${(postings && postings.length > 0)
      ? `<ul class="job-list">${items}</ul>`
      : `<div class="notice">No positions are currently open. Please check back soon.</div>`}
    <h2>About our agency</h2>
    <p>We're an established San Antonio agency helping customers with Auto, Home, Life, Retirement Planning, Business, College Planning, Health, and Renters coverage. Our office is in the Timberwood Park area of San Antonio.</p>
    <p>We take work seriously and take care of each other. Every seat on our team is part of how customers feel about us, and everyone here should be doing better a year from now than they are today.</p>
  `;

  return htmlResponse(page(`Careers — ${AGENCY_NAME}`, body));
}

// ────────────────────────────────────────────────────────────────────────────
// Route: GET /careers/<slug> (job detail + apply form)
// ────────────────────────────────────────────────────────────────────────────

async function renderJobDetail(slug) {
  const { data: posting, error } = await supabase
    .from("job_postings")
    .select("*")
    .eq("agency_id", AGENCY_ID)
    .eq("posting_slug", slug)
    .eq("is_active", true)
    .eq("publish_to_careers_page", true)
    .maybeSingle();

  if (error) return new Response(`Error: ${error.message}`, { status: 500 });
  if (!posting) return new Response("Position not found or no longer open.", { status: 404 });

  const { data: questions } = await supabase
    .from("job_screener_questions")
    .select("question_code, question_text, answer_type, options, is_required")
    .eq("agency_id", AGENCY_ID)
    .in("question_code", posting.screener_codes)
    .eq("is_active", true);

  // Preserve the order defined in posting.screener_codes
  const questionMap = new Map((questions || []).map(q => [q.question_code, q]));
  const orderedQuestions = posting.screener_codes
    .map((c) => questionMap.get(c))
    .filter(Boolean);

  const screenerFields = orderedQuestions.map((q) => {
    const req = q.is_required ? "required" : "";
    const reqCls = q.is_required ? "required" : "";
    if (q.answer_type === "yes_no") {
      return `
        <div class="field">
          <label class="${reqCls}">${esc(q.question_text.split("\n")[0])}</label>
          ${q.question_text.includes("\n") ? `<div class="helper">${esc(q.question_text.split("\n").slice(1).join("\n").trim())}</div>` : ""}
          <div class="radio-group">
            <label><input type="radio" name="q_${esc(q.question_code)}" value="yes" ${req}> Yes</label>
            <label><input type="radio" name="q_${esc(q.question_code)}" value="no" ${req}> No</label>
          </div>
        </div>`;
    }
    if (q.answer_type === "open_text") {
      return `
        <div class="field">
          <label class="${reqCls}" for="q_${esc(q.question_code)}">${esc(q.question_text)}</label>
          <textarea id="q_${esc(q.question_code)}" name="q_${esc(q.question_code)}" ${req}></textarea>
        </div>`;
    }
    return "";
  }).join("");

  const body = `
    <a href="/careers" class="back-link">All openings</a>
    <h1>${esc(posting.job_title)}</h1>
    <p class="meta">
      <span>${esc(typeLabel(posting.employment_type))}</span>
      <span>${esc(locationLabel(posting.location_mode, posting.city, posting.state))}</span>
      ${posting.salary_min ? `<span>${esc(formatSalary(posting.salary_min, posting.salary_max, posting.salary_period))}</span>` : ""}
    </p>
    <div class="body-text">${esc(posting.description_body)}</div>

    <h2>Apply</h2>
    <p>Fill out the form below. We read every application. If your answers are a fit, you'll hear from us within a few business days.</p>
    <form class="apply" method="POST" action="/careers/${esc(posting.posting_slug)}/apply">
      <div class="field">
        <label class="required" for="first_name">First name</label>
        <input type="text" id="first_name" name="first_name" required>
      </div>
      <div class="field">
        <label class="required" for="last_name">Last name</label>
        <input type="text" id="last_name" name="last_name" required>
      </div>
      <div class="field">
        <label class="required" for="email">Email</label>
        <input type="email" id="email" name="email" required>
      </div>
      <div class="field">
        <label class="required" for="phone">Phone</label>
        <input type="tel" id="phone" name="phone" required>
      </div>
      <div class="field">
        <label for="resume_url">Resume link (Google Drive, Dropbox, or a hosted PDF URL — optional)</label>
        <input type="text" id="resume_url" name="resume_url">
      </div>
      <div class="field">
        <label for="cover_letter_text">Anything you'd like us to know (optional)</label>
        <textarea id="cover_letter_text" name="cover_letter_text"></textarea>
      </div>
      ${screenerFields}
      <div class="notice">
        By submitting this application, you agree to our <a href="/careers/terms">Terms of Service</a> and <a href="/careers/privacy">Privacy Policy</a>.
      </div>
      <button type="submit" class="btn">Submit application</button>
    </form>
  `;

  return htmlResponse(page(`${posting.job_title} — ${AGENCY_NAME}`, body));
}

// ────────────────────────────────────────────────────────────────────────────
// Route: GET /careers/apply-received
// ────────────────────────────────────────────────────────────────────────────

function renderThankYou() {
  const body = `
    <a href="/careers" class="back-link">All openings</a>
    <h1>Thanks for applying</h1>
    <p>We've received your application and will review it carefully.</p>
    <p>If your background is a strong fit for the seat, you'll hear from us within a few business days with next steps. If not, we'll still let you know either way — we don't ghost people.</p>
    <p style="margin-top: 32px;"><a href="/careers" class="btn secondary">Back to all openings</a></p>
  `;
  return htmlResponse(page(`Application received — ${AGENCY_NAME}`, body));
}

// ────────────────────────────────────────────────────────────────────────────
// Route: GET /careers/terms
// ────────────────────────────────────────────────────────────────────────────

function renderTerms() {
  const body = `
    <a href="/careers" class="back-link">All openings</a>
    <h1>Terms of Service</h1>
    <p class="meta">Last updated: ${new Date().toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" })}</p>

    <h2>1. Acceptance</h2>
    <p>By using this careers site to view job postings, submit an application, or otherwise interact with ${esc(AGENCY_NAME)} (referred to below as "we," "us," or "the Agency"), you agree to these Terms of Service. If you do not agree, please do not use this site.</p>

    <h2>2. Purpose</h2>
    <p>This site exists solely to publish open positions at the Agency and to allow prospective candidates to submit applications for those positions. It does not sell products, provide insurance quotes, or offer financial advice. Insurance and financial services are handled through our main agency website and licensed team members.</p>

    <h2>3. Your responsibilities</h2>
    <p>When you submit an application, you agree that the information you provide is truthful and accurate to the best of your knowledge. Providing false information may result in your application being disqualified or, if you are hired, in termination.</p>

    <h2>4. No employment contract</h2>
    <p>Submitting an application does not create an employment relationship, promise of employment, or contract of any kind. All hiring decisions are made solely by the Agency, at its discretion, and are subject to background verification, licensing requirements, and other lawful conditions.</p>

    <h2>5. State Farm relationship</h2>
    <p>${esc(AGENCY_NAME)} is a State Farm independent contractor agent, not State Farm Insurance Companies. Any position offered through this site is a position with the Agency, not with State Farm Insurance Companies. State Farm agents are independent contractors who hire their own employees. State Farm agents' employees are not employees of State Farm.</p>

    <h2>6. Communications</h2>
    <p>By providing your contact information, you consent to us contacting you about your application by email, phone, or text message. You can opt out of text messages at any time by replying STOP.</p>

    <h2>7. Third parties</h2>
    <p>If you arrived at this site through Indeed, ZipRecruiter, or another third-party job board, those platforms have their own terms and privacy policies that govern your interaction with them. Our terms apply only to your interaction with this careers site and the Agency directly.</p>

    <h2>8. Changes</h2>
    <p>We may update these Terms from time to time. The date at the top of this page reflects the most recent update. Continued use of the site after changes are posted constitutes acceptance of the updated Terms.</p>

    <h2>9. Contact</h2>
    <p>Questions about these Terms can be sent to <a href="mailto:${esc(AGENCY_CONTACT_EMAIL)}">${esc(AGENCY_CONTACT_EMAIL)}</a>.</p>
  `;
  return htmlResponse(page(`Terms of Service — ${AGENCY_NAME}`, body));
}

// ────────────────────────────────────────────────────────────────────────────
// Route: GET /careers/privacy
// ────────────────────────────────────────────────────────────────────────────

function renderPrivacy() {
  const body = `
    <a href="/careers" class="back-link">All openings</a>
    <h1>Privacy Policy</h1>
    <p class="meta">Last updated: ${new Date().toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" })}</p>

    <h2>1. Scope</h2>
    <p>This Privacy Policy explains how ${esc(AGENCY_NAME)} (referred to below as "we," "us," or "the Agency") collects, uses, and protects information you provide when you apply for a position through this careers site.</p>

    <h2>2. What we collect</h2>
    <p>When you submit an application, we collect the information you provide, which typically includes:</p>
    <ul>
      <li>Your name, email address, and phone number</li>
      <li>A resume or resume link, if you choose to upload or share one</li>
      <li>Answers to job-specific screener questions (for example, work authorization, license status, willingness to complete a background check)</li>
      <li>Any additional information you include in a cover letter or comment field</li>
    </ul>
    <p>We may also automatically collect basic technical information about your visit, such as your browser type, the page that referred you to us, and the time of your submission.</p>

    <h2>3. How we use it</h2>
    <p>We use the information you provide to:</p>
    <ul>
      <li>Evaluate your application against the requirements of the position you applied for</li>
      <li>Contact you about your application and, if applicable, schedule interviews or assessments</li>
      <li>Verify information you provided, including through background checks when applicable</li>
      <li>Keep records of applications for a reasonable period, in line with employment record-keeping practices</li>
    </ul>

    <h2>4. Who we share it with</h2>
    <p>We do not sell your personal information. We may share your application information with:</p>
    <ul>
      <li>Team members within the Agency who are involved in the hiring process</li>
      <li>Third-party service providers who help us with background checks, assessments, or hiring workflow (only to the extent needed to provide those services)</li>
      <li>Government agencies or legal authorities when required by law</li>
    </ul>
    <p>We do not share your application information with State Farm Insurance Companies as part of the hiring process. State Farm agents make their own employment decisions and hire their own employees.</p>

    <h2>5. Retention</h2>
    <p>We keep application information for as long as needed for hiring decisions and to comply with applicable record-keeping requirements. You may request that we delete your application information by emailing <a href="mailto:${esc(AGENCY_CONTACT_EMAIL)}">${esc(AGENCY_CONTACT_EMAIL)}</a>, and we will honor that request unless we are required to retain the information by law.</p>

    <h2>6. Security</h2>
    <p>We take reasonable steps to protect the information you provide, including storing it in a database with access limited to authorized team members. No method of transmission over the internet is 100% secure, but we work to protect your information consistent with industry practices.</p>

    <h2>7. Third-party job boards</h2>
    <p>If you arrived at this careers site through Indeed, ZipRecruiter, or another job board, those platforms have their own privacy policies that govern the information they collect from you. This Privacy Policy applies only to information you submit directly to us.</p>

    <h2>8. Your choices</h2>
    <p>You can:</p>
    <ul>
      <li>Choose not to apply, or not to provide optional information (such as a cover letter or resume link)</li>
      <li>Opt out of text messages at any time by replying STOP</li>
      <li>Request access to, correction of, or deletion of your application information by emailing us</li>
    </ul>

    <h2>9. Children</h2>
    <p>This site is not intended for individuals under the age of 18. We do not knowingly collect application information from minors.</p>

    <h2>10. Changes</h2>
    <p>We may update this Privacy Policy from time to time. The date at the top of this page reflects the most recent update.</p>

    <h2>11. Contact</h2>
    <p>Questions about this Privacy Policy or your application information can be sent to <a href="mailto:${esc(AGENCY_CONTACT_EMAIL)}">${esc(AGENCY_CONTACT_EMAIL)}</a>.</p>
  `;
  return htmlResponse(page(`Privacy Policy — ${AGENCY_NAME}`, body));
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers + router
// ────────────────────────────────────────────────────────────────────────────

function htmlResponse(html, status = 200) {
  return new Response(html, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "public, max-age=60, s-maxage=300",
    },
  });
}

// ────────────────────────────────────────────────────────────────────────────
// Vercel Edge entrypoint
// ────────────────────────────────────────────────────────────────────────────

export const config = { runtime: "edge" };

export default async function handler(req) {
  const url = new URL(req.url);

  // vercel.json hands us the original path in "p" (no leading slash).
  const raw = (url.searchParams.get("p") || "").replace(/^\/+/, "").replace(/\/+$/, "");
  const path = raw === "" ? "/" : "/" + raw;

  try {
    if (req.method !== "GET" && req.method !== "HEAD") {
      return new Response("Method not allowed", { status: 405 });
    }

    if (path === "/") return await renderListing();
    if (path === "/terms") return renderTerms();
    if (path === "/privacy") return renderPrivacy();
    if (path === "/apply-received") return renderThankYou();

    const slugMatch = path.match(/^\/([^\/]+)$/);
    if (slugMatch) return await renderJobDetail(slugMatch[1]);

    return new Response("Not found.", { status: 404 });
  } catch (e) {
    console.error("careers page error", e);
    return new Response("Something went wrong. Please try again.", { status: 500 });
  }
}
