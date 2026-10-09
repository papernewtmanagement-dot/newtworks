// =========================================================================
// parsers/cts_site.ts
// =========================================================================
// Reads finished CTS Sales Profiles straight off the vendor's admin site
// (app.ctssalesprofile.com). No AI anywhere: the report page is plain HTML
// tables, so every score is read from its own labelled cell.
//
// Peter, 2026-10-09: this replaces Alvi downloading the PDFs by hand. The site
// is checked when the CTS "Profile Complete" notice reaches the inbox, plus a
// once-a-day backup sweep. Each finished, unarchived Candidate profile is
// opened at View Reports > SF Sales (Likert) (older profiles: the report named
// "SF Selling Team Member"), read, its PDF downloaded, and once Newtworks holds
// the result the profile is archived in CTS so the next sweep skips it.
//
// This file only talks to the site. Matching, filing the PDF and saving the
// scores happen in index.ts through the same path every CTS result takes:
// processOneAttachment -> record_cts_result(), the only writer.
//
// Site mechanics (worked out 2026-10-09; see operational_rule "CTS automatic
// pull - design, login, site mechanics"):
//   - Login: GET /admin for cookies, then POST /ajax ajax_nav=login with
//     user_type_ids=1,2,3,6 (Administrator). tz must be a short offset like
//     "-5"; a zone name overflows their column and their server returns 500.
//   - Pages: POST /access { nav, sub_nav, auth_id }.
//   - Completed list hides archived profiles unless filter_archived=1.
//   - Report menu per profile: POST /ajax ajax_nav=report_link_dropdown.
//   - PDF: the report URL with pdf=1 (the page's download button).
//   - Archive: POST /ajax ajax_nav=toggle_archived. It is a TOGGLE, so it is
//     only ever sent for a profile this run just read off the unarchived list.
//   - The server drops the connection on rapid repeat calls: pace, retry once.
// =========================================================================

const CTS_BASE = "https://app.ctssalesprofile.com";
const CTS_PAUSE_MS = 1200;
const CTS_TIMEOUT_MS = 30000;

export const CTS_SITE_PRIMARY_TRAITS: Record<string, string> = {
  "deadline motivation": "deadline_motivation",
  "recognition drive": "recognition_drive",
  "assertiveness": "assertiveness",
  "independent spirit": "independent_spirit",
  "analytical": "analytical",
  "compassion": "compassion",
  "self promotion": "self_promotion",
  "belief in others": "belief_in_others",
  "optimism": "optimism",
};

// Same keys the PDF path stores (parsers/cts_profile.ts CTS_SALES_COMPETENCIES).
export const CTS_SITE_COMPETENCIES: Record<string, string> = {
  "maintains high activity": "maintains_high_activity",
  "handles rejection": "handles_rejection",
  "prospects in community": "prospects_in_community",
  "dials cold calls": "dials_cold_calls",
  "listens discovers needs": "listens_discovers_needs",
  "presents solutions": "presents_solutions",
  "handles objections gets decisions referrals reviews": "gets_decisions_handles_objections_referrals",
  "gets decisions handles objections referrals": "gets_decisions_handles_objections_referrals",
  "receives coaching": "receives_coaching",
  "positively influences team": "positively_influences_team",
  "posivitely influences team": "positively_influences_team",
};

export interface CtsSiteSession {
  cookies: Map<string, string>;
  authId: string;
}

export interface CtsSiteProfile {
  codeId: string;       // the site's internal id for this profile
  userId: string | null;
  name: string;
  email: string | null;
  completed: string | null; // YYYY-MM-DD
  codeNumber: string | null; // the 12-digit code in the notice email
  category: string;     // "Candidate" or "Employee"
}

export interface CtsSiteReport {
  reportName: string;   // e.g. "SF Sales (Likert)"
  url: string;
}

function sleep(ms: number) { return new Promise((r) => setTimeout(r, ms)); }

function absorbCookies(jar: Map<string, string>, res: Response) {
  const list: string[] = typeof (res.headers as any).getSetCookie === "function"
    ? (res.headers as any).getSetCookie()
    : (res.headers.get("set-cookie") ? [res.headers.get("set-cookie") as string] : []);
  for (const c of list) {
    const pair = c.split(";")[0];
    const i = pair.indexOf("=");
    if (i > 0) jar.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
  }
}

function cookieHeader(jar: Map<string, string>): string {
  return [...jar.entries()].map(([k, v]) => `${k}=${v}`).join("; ");
}

/** One paced request with a single retry on a dropped connection. */
async function ctsFetch(
  jar: Map<string, string>, url: string,
  init: { method?: string; form?: Record<string, string>; ajax?: boolean } = {},
): Promise<Response> {
  let lastErr: unknown = null;
  for (let attempt = 0; attempt < 2; attempt++) {
    await sleep(attempt === 0 ? CTS_PAUSE_MS : CTS_PAUSE_MS * 3);
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), CTS_TIMEOUT_MS);
    try {
      const headers: Record<string, string> = {
        "User-Agent": "Mozilla/5.0 (Newtworks CTS pull)",
        Cookie: cookieHeader(jar),
        Referer: `${CTS_BASE}/admin`,
      };
      if (init.ajax) headers["X-Requested-With"] = "XMLHttpRequest";
      let body: string | undefined;
      if (init.form) {
        headers["Content-Type"] = "application/x-www-form-urlencoded";
        body = new URLSearchParams(init.form).toString();
      }
      const res = await fetch(url, { method: init.method ?? (body ? "POST" : "GET"), headers, body, signal: ctl.signal, redirect: "follow" });
      absorbCookies(jar, res);
      return res;
    } catch (e) {
      lastErr = e;
    } finally {
      clearTimeout(t);
    }
  }
  throw new Error(`CTS site did not answer ${url.replace(/auth_id=[^;&]+/, "auth_id=…")}: ${lastErr instanceof Error ? lastErr.message : String(lastErr)}`);
}

export async function ctsLogin(email: string, password: string): Promise<CtsSiteSession> {
  const jar = new Map<string, string>();
  const first = await ctsFetch(jar, `${CTS_BASE}/admin`);
  await first.text();
  const res = await ctsFetch(jar, `${CTS_BASE}/ajax`, {
    ajax: true,
    form: {
      user_type_ids: "1,2,3,6",
      email, password,
      ajax_nav: "login",
      device_id: "", os: "Linux", browser: "Chrome", screen_res: "1920x1080", tz: "-5",
    },
  });
  const text = await res.text();
  let j: any = null;
  try { j = JSON.parse(text); } catch { /* handled below */ }
  if (!res.ok || !j || String(j.success) !== "1") {
    throw new Error(`CTS login failed (HTTP ${res.status})`);
  }
  const content = String(j.content ?? "");
  const m = content.match(/name=["']auth_id["'][^>]*value=["']([^"']+)/) ??
            content.match(/value=["']([^"']+)["'][^>]*name=["']auth_id/);
  if (!m) throw new Error("CTS login answered without a session id");
  return { cookies: jar, authId: m[1] };
}

function cellText(html: string): string {
  return html.replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
    .replace(/\s+/g, " ").trim();
}

function usDateToIso(s: string): string | null {
  const m = s.match(/(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  return m ? `${m[3]}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}` : null;
}

/** Every finished profile not yet archived in CTS. */
export async function ctsListUnarchivedCompleted(s: CtsSiteSession): Promise<CtsSiteProfile[]> {
  const res = await ctsFetch(s.cookies, `${CTS_BASE}/access`, {
    form: { nav: "profiles", sub_nav: "completed", auth_id: s.authId },
  });
  const html = await res.text();
  if (!/Completed Profiles/i.test(html)) throw new Error("CTS completed-profiles page did not load");
  // The archived filter must be on Hide, or archived people would come back.
  const filt = html.match(/<select[^>]*name="filter_archived"[\s\S]*?<\/select>/);
  if (filt && !/<option value="0" selected>/.test(filt[0])) {
    throw new Error("CTS completed list is showing archived profiles; refusing to read it");
  }
  const tbody = html.match(/<table id="main_table"[\s\S]*?<tbody>([\s\S]*?)<\/tbody>/);
  if (!tbody) throw new Error("CTS completed list has no table");

  // Per-row user id comes from the click handlers further down the page.
  const userIdByCode = new Map<string, string>();
  for (const m of html.matchAll(/\.UD_(\d+)', function\(e\) \{ submit_user_details_form\('(\d+)', '\1'/g)) {
    userIdByCode.set(m[1], m[2]);
  }

  const out: CtsSiteProfile[] = [];
  for (const row of tbody[1].matchAll(/<tr>([\s\S]*?)<\/tr>/g)) {
    const cells = [...row[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)].map((c) => c[1]);
    if (cells.length < 8) continue;
    const code = cells[0].match(/class="UD_(\d+)"/);
    if (!code) continue;
    // Archived column: the checkbox carries "checked" when archived.
    const archived = /class="TA_\d+"\s+checked/.test(cells[7]);
    if (archived) continue;
    out.push({
      codeId: code[1],
      userId: userIdByCode.get(code[1]) ?? null,
      name: cellText(cells[0]),
      email: cellText(cells[1]) || null,
      completed: usDateToIso(cellText(cells[2])),
      codeNumber: cellText(cells[3]) || null,
      category: cellText(cells[4]),
    });
  }
  return out;
}

/**
 * The report to read for one profile: SF Sales (Likert), or for older
 * profiles the report named "SF Selling Team Member". Null when neither is on
 * the profile's menu.
 */
export async function ctsFindSalesReport(s: CtsSiteSession, codeId: string): Promise<CtsSiteReport | null> {
  const res = await ctsFetch(s.cookies, `${CTS_BASE}/ajax`, {
    ajax: true, form: { ajax_nav: "report_link_dropdown", auth_id: s.authId, code_id: codeId },
  });
  const j = await res.json().catch(() => null);
  const html = String(j?.content ?? "");
  const links = [...html.matchAll(/href="?([^"\s>]+)"?>([^<]+)<\/a>/g)]
    .map((m) => ({ url: m[1], name: m[2].trim() }))
    .filter((l) => l.url.startsWith("http"));
  const pick = links.find((l) => /^SF Sales \(Likert\)$/i.test(l.name)) ??
               links.find((l) => /SF Selling Team Member/i.test(l.name));
  return pick ? { reportName: pick.name, url: pick.url } : null;
}

export async function ctsFetchReportHtml(s: CtsSiteSession, report: CtsSiteReport): Promise<string> {
  const res = await ctsFetch(s.cookies, report.url);
  const html = await res.text();
  if (!res.ok || !/Profile Report/i.test(html)) throw new Error(`report page did not load (HTTP ${res.status})`);
  return html;
}

/** The report's own download button: same report, pdf=1. */
export async function ctsDownloadReportPdf(s: CtsSiteSession, report: CtsSiteReport): Promise<Uint8Array> {
  const url = report.url.replace(/;?$/, ";") + "pdf=1;";
  const res = await ctsFetch(s.cookies, url);
  const buf = new Uint8Array(await res.arrayBuffer());
  const isPdf = buf.length > 4 && buf[0] === 0x25 && buf[1] === 0x50 && buf[2] === 0x44 && buf[3] === 0x46; // %PDF
  if (!res.ok || !isPdf) throw new Error(`PDF download did not return a PDF (HTTP ${res.status}, ${buf.length} bytes)`);
  return buf;
}

/** Archive one profile in CTS. Only call for a profile read off the unarchived list this run. */
export async function ctsArchiveProfile(s: CtsSiteSession, codeId: string): Promise<boolean> {
  const res = await ctsFetch(s.cookies, `${CTS_BASE}/ajax`, {
    ajax: true, form: { ajax_nav: "toggle_archived", auth_id: s.authId, code_id: codeId },
  });
  const j = await res.json().catch(() => null);
  return res.ok && (j === null || String(j?.success ?? "1") === "1");
}

function labelKey(label: string): string {
  return label.replace(/\?/g, " ").toLowerCase().replace(/[^a-z]+/g, " ").trim();
}

function slug(label: string): string {
  return labelKey(label).replace(/\s+/g, "_");
}

function intOrNull(s: string | undefined): number | null {
  if (s == null) return null;
  const m = s.match(/-?\d+/);
  return m ? Number(m[0]) : null;
}

const CTS_SITE_MONTHS: Record<string, string> = {
  jan: "01", feb: "02", mar: "03", apr: "04", may: "05", jun: "06",
  jul: "07", aug: "08", sep: "09", oct: "10", nov: "11", dec: "12",
};

export type CtsSiteParse =
  | { ok: true; candidateName: string | null; reportDate: string | null; payload: Record<string, unknown> }
  | { ok: false; candidateName: string | null; error: string };

/**
 * Read one report page into the payload record_cts_result() takes. Same keys
 * the PDF path writes. Every number comes from its own labelled table cell,
 * so there is nothing to guess; a missing piece is a refusal, never a blank.
 */
export function parseCtsReportHtml(html: string, reportName: string): CtsSiteParse {
  const page = html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, "");
  const text = cellText(page);

  const head = text.match(/Sales Profile Report for\s+(.+?)\s+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?,?\s+(\d{1,2}),?\s+(\d{4})/i);
  const candidateName = head ? head[1].trim() : null;
  const reportDate = head ? `${head[4]}-${CTS_SITE_MONTHS[head[2].toLowerCase().slice(0, 3)]}-${head[3].padStart(2, "0")}` : null;

  const ego = page.match(/Ego Drive Score\s*<span class="egodrivescore">\s*(\d+)/i);
  const emp = page.match(/Empathy Score\s*<span class="egodrivescore">\s*(\d+)/i);
  const validity = (name: string) => {
    const m = page.match(new RegExp(`<h3>\\s*${name}\\s*</h3>\\s*<h2[^>]*>\\s*(Low|Moderate|High)\\s*</h2>`, "i"));
    return m ? m[1].toLowerCase() : null;
  };

  // Each block is a <table class="chart"> whose first header names it.
  const tables = new Map<string, string[][]>();
  for (const t of page.matchAll(/<table class="chart">([\s\S]*?)<\/table>/g)) {
    const th = t[1].match(/<th>([\s\S]*?)<\/th>/);
    const title = th ? cellText(th[1]) : "";
    const rows: string[][] = [];
    for (const r of t[1].matchAll(/<tr class="table-data">([\s\S]*?)<\/tr>/g)) {
      const cells = [...r[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/g)]
        .map((c) => c[1]).filter((c) => !/bar-wrapper/.test(c)).map(cellText);
      if (cells.length && cells[0]) rows.push(cells);
    }
    tables.set(title.toLowerCase(), rows);
  }

  const traitRows = tables.get("primary traits") ?? [];
  const primary: Record<string, number | null> = {};
  for (const k of Object.values(CTS_SITE_PRIMARY_TRAITS)) primary[k] = null;
  for (const r of traitRows) {
    const key = CTS_SITE_PRIMARY_TRAITS[labelKey(r[0])];
    if (key) primary[key] = intOrNull(r[1]);
  }
  const traitsFound = Object.values(primary).filter((v) => v !== null).length;
  if (traitsFound < 9) {
    return { ok: false, candidateName, error: `${reportName}: read ${traitsFound} of 9 primary traits off the page` };
  }

  const compRows = tables.get("sales competencies") ?? [];
  const comps: Record<string, number | null> = {};
  const isLikert = /likert/i.test(reportName);
  if (isLikert) for (const k of new Set(Object.values(CTS_SITE_COMPETENCIES))) comps[k] = null;
  for (const r of compRows) {
    const key = CTS_SITE_COMPETENCIES[labelKey(r[0])] ?? slug(r[0]);
    comps[key] = intOrNull(r[1]);
  }
  const compsFound = Object.values(comps).filter((v) => v !== null).length;
  if (isLikert && compsFound < 9) {
    return { ok: false, candidateName, error: `${reportName}: read ${compsFound} of 9 sales competencies off the page` };
  }

  const lssRow = (rows: string[][], name: string) => {
    const r = rows.find((x) => labelKey(x[0]) === name);
    if (!r) return null;
    const cand = intOrNull(r[3]);
    return cand === null ? null : { ideal_min: intOrNull(r[1]), ideal_max: intOrNull(r[2]), candidate: cand };
  };
  const acc = tables.get("lss accuracy") ?? [];
  const spd = tables.get("lss speed") ?? [];
  const lssAccuracy: Record<string, unknown> = {};
  const lssSpeed: Record<string, unknown> = {};
  for (const [label, key] of [["math", "math"], ["verbal", "verbal"], ["problem solving", "problem_solving"]]) {
    const a = lssRow(acc, label); if (a) lssAccuracy[key] = a;
    const sp = lssRow(spd, label); if (sp) lssSpeed[key] = sp;
  }
  const totalRow = acc.find((x) => /^total/i.test(x[0]));
  if (totalRow) {
    const nums = totalRow.slice(1).map(intOrNull).filter((n) => n !== null) as number[];
    const max = totalRow[0].match(/out of\s+(\d+)/i);
    if (nums.length >= 2) {
      lssAccuracy.total = { ideal_min: nums[0], max_possible: max ? Number(max[1]) : null, candidate: nums[nums.length - 1] };
    }
  }

  const payload: Record<string, unknown> = {
    ego_drive: ego ? Number(ego[1]) : null,
    empathy: emp ? Number(emp[1]) : null,
    reliability: validity("Reliability"),
    response_distortion: validity("Response Distortion"),
    primary_traits: primary,
    sales_competencies: comps,
    lss_accuracy: lssAccuracy,
    lss_speed: lssSpeed,
    report_date: reportDate,
    report_name: reportName,
    candidate_name_on_report: candidateName,
    parsed_at: new Date().toISOString(),
  };
  return { ok: true, candidateName, reportDate, payload };
}
