// src/lib/markdown.js
// ─────────────────────────────────────────────────────────────
// Shared markdown → HTML pipeline for Handbook, Playbook, Admin books.
// Extracted 2026-07-04 from three byte-identical copies previously living
// inside src/modules/{Handbook,Playbook,Admin}.jsx.
//
// mdToHtml(md, options?)
//   options.resolveInclude(title) — optional callback enabling
//     Confluence-style [Included from: Title] transclusion. Returns:
//       { status: 'ok', md: string }   — replace marker with this markdown
//       { status: 'empty' }            — target exists but has no content
//       { status: 'missing' }          — target not found in any book
//     If not provided (or returns null), markers pass through unchanged.
//
// Handles:
//   - Headings #..######
//   - Paragraphs
//   - Bullet lists (- / *) and ordered lists (N.)
//   - Bold **/__, italic */_, inline `code`
//   - [text](url) links (safe schemes only)
//   - Horizontal rules --- *** ___
//   - Fenced code ```...```
//   - GFM pipe tables (with :---: alignment)
//   - Blockquotes (> prefix)
//   - HTML passthrough for <details>, <summary>, <blockquote>, <table>,
//     <div>, <figure>, <aside>
//   - Unescapes \* \_ \` \[ \]
//   - Optional [Included from: X] transclusion (recursive w/ cycle guard)
// ─────────────────────────────────────────────────────────────

export function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// ─── Script-voice + placeholder styling ───────────────────────
// Inline (not class-only) so the same markup renders correctly in the
// ContentEditor live preview, which does not load Manual.jsx's style block.
const SAY_STYLE =
  "color:#047857;";
const THEM_STYLE =
  "color:#B91C1C;";
const FILL_STYLE =
  "color:#6B5227;background:#F2E8D5;border-radius:3px;padding:0 3px;" +
  "font-weight:600;white-space:nowrap;";

function inlineMd(s) {
  if (!s) return "";
  let out = String(s);

  // Unescape \* \_ before inline parsing so escaped bold/italic still renders.
  out = out.replace(/\\([*_`\[\]])/g, "$1");

  // Protect {{faq: topic_key}} markers from the emphasis pass below. Unlike
  // {{say:}}/{{them:}}, topic_key is a plain [a-z0-9_]+ identifier that must
  // survive to the post-mdToHtml substitution pass (applyFaqSubstitution)
  // completely unmangled — the underscore-italic regex further down would
  // otherwise turn "ac_breakdown_bridge" into "ac<em>breakdown</em>bridge"
  // and break the exact-text match that substitution depends on. Swapped
  // for a null-byte placeholder here, restored verbatim (not reprocessed)
  // at the end of this function, after every other inline transform.
  const faqPlaceholders = [];
  out = out.replace(/\{\{faq:\s*([a-z0-9_]+)\s*\}\}/gi, (_m, key) => {
    faqPlaceholders.push(`{{faq: ${key.toLowerCase()}}}`);
    return `\u0000FAQ${faqPlaceholders.length - 1}\u0000`;
  });

  // Info popovers: [[info: content]] → native popover button + popover pair.
  // Uses HTML popover attribute (Chrome 114+, Safari 17+, Firefox 125+).
  // Content emitted verbatim into the popover span; subsequent inline passes
  // in this same function process any bold/italic/link/code inside it.
  // See persistent_memory operational_rule "Manuals Info style".
  out = out.replace(/\[\[info:\s*([\s\S]+?)\s*\]\]/g, (m, content) => {
    const id = "nfo-" + Math.random().toString(36).slice(2, 10);
    return `<button type="button" class="newtworks-info-btn" popovertarget="${id}" aria-label="More info">\u24d8</button><span popover="auto" id="${id}" class="newtworks-info-popover" role="tooltip">${content}</span>`;
  });

  // Links [text](url) — guard against javascript: scheme.
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, txt, url) => {
    const safe = /^(https?:|mailto:|#|\/)/i.test(url) ? url : "#";
    return `<a href="${safe}" target="_blank" rel="noreferrer noopener">${txt}</a>`;
  });

  // CommonMark autolinks: <https://…> and <mailto:…>. Must run BEFORE the
  // bold/italic passes so `_` inside URLs isn't consumed as emphasis, and
  // BEFORE any HTML escape so the browser doesn't see an unknown tag.
  out = out.replace(/<(https?:\/\/[^\s<>]+)>/g, (m, url) =>
    `<a href="${url}" target="_blank" rel="noreferrer noopener">${url}</a>`
  );
  out = out.replace(/<(mailto:[^\s<>]+)>/g, (m, url) =>
    `<a href="${url}">${url.replace(/^mailto:/, "")}</a>`
  );

  // ─── Script-voice markers ───────────────────────────────────
  // Restores the colour coding the Confluence process manual used to carry.
  //   {{say: ...}}  → the words WE say out loud   (green)
  //   {{them: ...}} → the words the CUSTOMER says (red)
  // Emitted as inline spans so they nest inside lists, bold, and <details>.
  // Inner content is left as markdown — later passes in this same function
  // handle any bold/italic/link/placeholder inside the marker.
  out = out.replace(/\{\{say:\s*([\s\S]+?)\s*\}\}/g, (m, t) =>
    `<span class="newtworks-say" style="${SAY_STYLE}">${t}</span>`
  );
  out = out.replace(/\{\{them:\s*([\s\S]+?)\s*\}\}/g, (m, t) =>
    `<span class="newtworks-them" style="${THEM_STYLE}">${t}</span>`
  );

  // ─── Fill-in placeholders ──────────────────────────────────
  // Script placeholders are authored as <NAME>, <ME>, <$$$>, <ALL/MOST>.
  // Nothing else in this pipeline escapes angle brackets, so the browser
  // was parsing these as unknown HTML elements and dropping them entirely —
  // the blanks were invisible on the rendered page. Escape them and give
  // them the gold treatment the source manual used.
  out = out.replace(NW_FILL_RE, (m, t) =>
    `<span class="newtworks-fill" style="${FILL_STYLE}">&lt;${t}&gt;</span>`
  );

  // Bold (** or __)
  out = out.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");

  // Italic (* or _), not consuming **
  out = out.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
  out = out.replace(/(^|[^_])_([^_\n]+)_(?!_)/g, "$1<em>$2</em>");

  // Inline code
  out = out.replace(/`([^`\n]+)`/g, "<code>$1</code>");

  // Restore protected {{faq: topic_key}} markers verbatim — never reprocessed.
  if (faqPlaceholders.length) {
    out = out.replace(/\u0000FAQ(\d+)\u0000/g, (_m, idx) => faqPlaceholders[Number(idx)]);
  }

  return out;
}

// HAZARD: this comment block and the const below it were flattened onto one
// physical line by shell quoting when b313c1d was written. That left the
// const sitting behind a // comment, so NW_FILL_RE was never declared and a
// stray $ at line start threw ReferenceError the moment this module was
// imported. It compiled clean and broke only at runtime. Repaired in
// 93c1e19. Edit this block with a file write, never an inline shell string,
// and confirm the module still imports before pushing.
// Fill-in blanks: anything in angle brackets that is NOT a known HTML tag and
// does not open an HTML comment. Widened 2026-08-07 - the old
// /<([A-Z$][^<>\n]{0,40})>/ silently swallowed real blanks that began with a
// digit, a lower-case letter or a space, or that ran past 40 characters:
// <10X>, <30% of Coverage A>, <insert target date>, <n>, and
// <NAME THE VALUABLES THAT YOU ITEMIZED ALONG WITH THEIR COSTS>. Those
// rendered as unknown elements and vanished off the page.
const NW_FILL_RE = new RegExp(
  "<(?!!)(?!/?(?:" +
  "a|p|br|hr|b|i|u|em|strong|span|div|section|article|header|footer|nav|" +
  "table|thead|tbody|tfoot|colgroup|col|tr|td|th|caption|ul|ol|li|dl|dt|dd|" +
  "details|summary|blockquote|figure|figcaption|aside|img|h[1-6]|code|pre|" +
  "small|sup|sub|mark|" +
  "svg|g|rect|text|tspan|line|circle|ellipse|path|polyline|polygon|defs|" +
  "title|desc|use|clipPath|linearGradient|stop" +
  ")(?:[\\s/>]|$))([^<>\\n]{1,140})>",
  "g"
);

// build nudge 2026-08-07
const PASSTHROUGH_TAGS = ["details", "summary", "blockquote", "table", "div", "figure", "aside", "svg"];

// Slugify heading text for id attribute (used by mdToHtml heading render)
function slugifyHeading(text) {
  return String(text)
    .replace(/<[^>]+>/g, "")                          // strip inline HTML
    .replace(/`([^`\n]+)`/g, "$1")                   // inline code
    .replace(/\*\*([^*\n]+)\*\*/g, "$1")         // bold **
    .replace(/__([^_\n]+)__/g, "$1")                 // bold __
    .replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1$2")  // italic *
    .replace(/(^|[^_])_([^_\n]+)_(?!_)/g, "$1$2")    // italic _
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")     // [text](url) -> text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")                    // strip non-alphanumeric (keep space/hyphen)
    .trim()
    .replace(/\s+/g, "-")                            // spaces -> hyphens
    .replace(/-+/g, "-")                              // collapse repeated hyphens
    .replace(/^-|-$/g, "");                           // trim leading/trailing hyphens
}

// ─── Include-marker preprocessing ─────────────────────────────
// A marker occupies its own line and looks like:
//   *[Included from: Some Page Title]*      (italic-wrapped, ingestor default)
//   [Included from: Some Page Title]        (bare)
// Escaped titles like `\*Extended Life Process` are unescaped before lookup.

const INCLUDE_LINE_RE = /^[ \t]*\*?\[Included from:\s*([^\]\n]+?)\]\*?[ \t]*$/gm;
const EXCERPT_LINE_RE = /^[ \t]*\*?\[Embedded excerpt from:\s*([^\]\n]+?)\]\*?[ \t]*$/gm;
const GLOSSARY_TAG_RE = /\{\{glossary:([a-z0-9_-]+)\}\}/gi;
const GLOSSARY_ALL_RE = /\{\{glossary_all\}\}/gi;
const FAQ_TAG_RE = /\{\{faq:\s*([a-z0-9_]+)\s*\}\}/gi;
const MAX_INCLUDE_DEPTH = 6;

const BANNER_STYLE_MISSING =
  'margin:12px 0;padding:10px 14px;background:#fef3c7;border-left:4px solid #f59e0b;' +
  'border-radius:4px;color:#78350f;font-size:14px;';
const BANNER_STYLE_EMPTY =
  'margin:12px 0;padding:10px 14px;background:#fef3c7;border-left:4px solid #f59e0b;' +
  'border-radius:4px;color:#78350f;font-size:14px;';
const BANNER_STYLE_CYCLE =
  'margin:12px 0;padding:10px 14px;background:#fee2e2;border-left:4px solid #dc2626;' +
  'border-radius:4px;color:#7f1d1d;font-size:14px;';

function bannerMissing(target, kind) {
  const k = kind || "include";
  return (
    `<div style="${BANNER_STYLE_MISSING}">` +
    `⚠️ <strong>Missing ${k}:</strong> "${escapeHtml(target)}" was referenced here ` +
    `but was not migrated. Author the page or remove the ${k} marker.` +
    `</div>`
  );
}

function bannerEmpty(target, kind) {
  const k = kind || "include";
  return (
    `<div style="${BANNER_STYLE_EMPTY}">` +
    `⚠️ <strong>Empty ${k}:</strong> "${escapeHtml(target)}" exists but has no content yet.` +
    `</div>`
  );
}

function bannerCycle(target, kind) {
  const k = kind || "include";
  return (
    `<div style="${BANNER_STYLE_CYCLE}">` +
    `🔁 <strong>${k[0].toUpperCase() + k.slice(1)} cycle detected:</strong> "${escapeHtml(target)}" would loop back on itself.` +
    `</div>`
  );
}

function expandIncludes(md, resolveInclude, visited, depth) {
  if (!resolveInclude) return md;
  if (depth > MAX_INCLUDE_DEPTH) return md;
  return md.replace(INCLUDE_LINE_RE, (_match, rawTarget) => {
    // Unescape Confluence-style escaped asterisks in titles like `\*Extended Life Process`
    const target = String(rawTarget).replace(/\\\*/g, "*").trim();
    const key = target.toLowerCase();

    if (visited.has(key)) return bannerCycle(target);

    let resolved;
    try {
      resolved = resolveInclude(target);
    } catch (_e) {
      resolved = null;
    }

    if (!resolved || resolved.status === "missing") return bannerMissing(target);
    if (resolved.status === "empty") return bannerEmpty(target);
    if (resolved.status !== "ok" || typeof resolved.md !== "string") return bannerMissing(target);

    const nextVisited = new Set(visited);
    nextVisited.add(key);
    return expandIncludes(resolved.md, resolveInclude, nextVisited, depth + 1);
  });
}

// ─── Marker discovery (admin edit-affordance UI only) ─────────
// Scans raw markdown for every top-level [Included from: X] / [Embedded
// excerpt from: X] marker and returns [{kind:'include'|'excerpt', title}]
// in document order, de-duplicated by (kind, lowercase title). Read-only —
// does not touch rendering. Does NOT recurse into a resolved fragment's own
// content; call it again against a fragment's own `content` once loaded to
// discover markers nested inside IT (see Manual.jsx's included-section
// quick editor, which does exactly that to support drilling into chains
// like FIT Conversations).
export function extractTransclusionMarkers(md) {
  const src = String(md || "");
  const out = [];
  const seen = new Set();
  const push = (kind, rawTitle) => {
    const title = String(rawTitle).replace(/\\\*/g, "*").trim();
    if (!title) return;
    const key = kind + "::" + title.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ kind, title });
  };
  const incRe = new RegExp(INCLUDE_LINE_RE.source, INCLUDE_LINE_RE.flags);
  let m;
  while ((m = incRe.exec(src))) push("include", m[1]);
  const excRe = new RegExp(EXCERPT_LINE_RE.source, EXCERPT_LINE_RE.flags);
  while ((m = excRe.exec(src))) push("excerpt", m[1]);
  return out;
}

// ─── Excerpt preprocessing ────────────────────────────────────
// [Embedded excerpt from: X] markers are Confluence's named-excerpt-include
// macro. Semantically identical to [Included from: X] (title lookup + inline
// substitution), but the source table is different: excerpts live in a
// dedicated `manual_type='excerpt'` scope, loaded via a separate query in
// the consumer (see Manual.jsx). Cycle guard + banner reuse the include
// machinery with a "excerpt" kind label.

function expandExcerpts(md, resolveExcerpt, visited, depth) {
  if (!resolveExcerpt) return md;
  if (depth > MAX_INCLUDE_DEPTH) return md;
  return md.replace(EXCERPT_LINE_RE, (_match, rawTarget) => {
    const target = String(rawTarget).replace(/\\\*/g, "*").trim();
    const key = target.toLowerCase();

    if (visited.has(key)) return bannerCycle(target, "excerpt");

    let resolved;
    try {
      resolved = resolveExcerpt(target);
    } catch (_e) {
      resolved = null;
    }

    if (!resolved || resolved.status === "missing") return bannerMissing(target, "excerpt");
    if (resolved.status === "empty") return bannerEmpty(target, "excerpt");
    if (resolved.status !== "ok" || typeof resolved.md !== "string") return bannerMissing(target, "excerpt");

    const nextVisited = new Set(visited);
    nextVisited.add(key);
    return expandExcerpts(resolved.md, resolveExcerpt, nextVisited, depth + 1);
  });
}

// ─── Glossary preprocessing ───────────────────────────────────
// {{glossary:tag}}     → replaced with a callout block rendering the term + definition
// {{glossary_all}}     → replaced with every active term rendered as callouts (in sort order)
// Definitions are markdown; they are rendered to HTML at preprocessing time so the
// main parser sees a self-contained HTML block and passes it through cleanly.
// Note: the Glossary handbook page itself renders via a dedicated component
// (DYNAMIC_HANDBOOK_PAGES dispatch in Handbook.jsx). These placeholders are
// primarily for inline references on other pages.

const GLOSSARY_CALLOUT_STYLE =
  'margin:14px 0;padding:14px 18px;background:#f8fafc;border:1px solid #e2e8f0;' +
  'border-left:4px solid #64748b;border-radius:6px;color:#0f172a;';
const GLOSSARY_TERM_STYLE =
  'font-size:13px;font-weight:700;letter-spacing:0.06em;color:#475569;' +
  'text-transform:uppercase;margin-bottom:6px;';
const GLOSSARY_MISSING_STYLE =
  'margin:12px 0;padding:10px 14px;background:#fef3c7;border-left:4px solid #f59e0b;' +
  'border-radius:4px;color:#78350f;font-size:14px;';

function renderGlossaryEntry(entry) {
  const defHtml = mdToHtml(entry.definition || "");
  return [
    `<div style="${GLOSSARY_CALLOUT_STYLE}">`,
    `<div style="${GLOSSARY_TERM_STYLE}">${escapeHtml(entry.term)}</div>`,
    `<div>`,
    defHtml,
    `</div>`,
    `</div>`,
  ].join("\n");
}

function bannerGlossaryMissing(tag) {
  return (
    `<div style="${GLOSSARY_MISSING_STYLE}">` +
    `⚠️ <strong>Missing glossary term:</strong> "${escapeHtml(tag)}" was referenced here ` +
    `but is not defined in the Glossary. Add the term or remove the placeholder.` +
    `</div>`
  );
}

function expandGlossary(md, resolveGlossary) {
  if (!resolveGlossary) return md;
  let out = md;
  out = out.replace(GLOSSARY_ALL_RE, () => {
    let all;
    try { all = resolveGlossary(null); } catch (_e) { all = null; }
    if (!Array.isArray(all) || all.length === 0) return "";
    return all.map(renderGlossaryEntry).join("\n");
  });
  out = out.replace(GLOSSARY_TAG_RE, (_m, rawTag) => {
    const tag = String(rawTag).trim();
    let entry;
    try { entry = resolveGlossary(tag); } catch (_e) { entry = null; }
    if (!entry) return bannerGlossaryMissing(tag);
    return renderGlossaryEntry(entry);
  });
  return out;
}

// ─── Knowledge & FAQ preprocessing ─────────────────────────────
// {{faq: topic_key}}  → an IN-PLACE insertion, not a whole-block replacement.
// The page body keeps its own <details>/<summary>Knowledge &amp; FAQ</summary>
// wrapper, "ℹ️ INFO" line, tag line, and every non-question line — those are
// hand-authored content the table doesn't (and shouldn't) try to hold. The
// marker only stands in for that one tag group's Q&A bullets, written on its
// own blockquote line: "> {{faq: topic_key}}".
//
// Substitution runs AFTER the main parser, on the rendered HTML, not on the
// raw markdown. A marker alone on a blockquote line parses to a plain
// <p>{{faq: topic_key}}</p> (mdToHtml doesn't run the list parser inside a
// blockquote, so this is a predictable, matchable shape) — that whole <p> is
// swapped for the rendered Q&A HTML. This sidesteps the blockquote/list
// parsing quirk entirely instead of fighting it pre-parse.
//
// A topic_key with no matching rows renders NOTHING at that spot — no empty
// box, no error banner — since the surrounding wrapper/tag line is already
// real content and an empty callout there would look broken, not helpful.
// Only rows with status='approved' AND is_active=true are ever handed to
// this renderer (see buildFaqLookup below) — draft/retired rows never reach
// this function, so there is no separate filter to apply here.

const FAQ_HTML_MARKER_RE = /<p>\{\{faq:\s*([a-z0-9_]+)\s*\}\}<\/p>/gi;

function renderFaqAnswer(answer) {
  const lines = String(answer || "")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
  if (lines.length === 0) return "";
  if (lines.length === 1) return `<p>${escapeHtml(lines[0])}</p>`;
  return `<ul>` + lines.map((l) => `<li>${escapeHtml(l)}</li>`).join("") + `</ul>`;
}

// Q&A pairs only — no wrapper, no INFO line, no tag line. Those all stay in
// the page body under Ruling 10; this function must never emit them, even
// if it's tempting to for a "complete-looking" fragment.
function renderFaqGroup(rows) {
  const parts = [];
  for (const item of rows) {
    parts.push(`<p><strong>${escapeHtml(item.question || "")}</strong></p>`);
    parts.push(renderFaqAnswer(item.answer));
  }
  return parts.join("");
}

function applyFaqSubstitution(html, resolveFaq) {
  if (!resolveFaq) return html;
  return html.replace(FAQ_HTML_MARKER_RE, (_m, rawKey) => {
    const key = String(rawKey).trim().toLowerCase();
    let rows;
    try { rows = resolveFaq(key); } catch (_e) { rows = null; }
    if (!Array.isArray(rows) || rows.length === 0) return "";
    return renderFaqGroup(rows);
  });
}

// ─── Strip markdown to a short preview for sidebar ────────────
export function previewText(content, n = 90) {
  if (!content) return "";
  const stripped = String(content)
    .replace(/\[\[info:\s*[\s\S]+?\s*\]\]/g, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/[#>*_`\[\]\(\)\\]/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return stripped.length > n ? stripped.slice(0, n - 1).trimEnd() + "…" : stripped;
}

// ─── Chart preprocessing ──────────────────────────────────────
// {{chart: Title | label=value | label=value ...}}
//   → a compact self-contained inline-SVG horizontal bar chart.
//
// Options are segments beginning with "!":
//   !hi=4 PM      highlight this row (repeatable)
//   !max=100      fix the axis maximum instead of deriving it from the data
//   !unit=%       suffix appended to every printed value
//
// Values may carry thousands separators and a trailing % ("9,250", "37%").
// A trailing % on any value implies !unit=% unless one is given.
//
// Emitted as one <svg> with no external dependency, so it survives the same
// pass-through path the glossary callouts use and needs no chart library on
// the markdown side. Deliberately NOT the recharts route the CPR module uses:
// that renders inside a React component tree, and manual pages are an HTML
// string. See persistent_memory operational_rule "Manuals charts".

const CHART_RE = /\{\{chart:\s*([\s\S]+?)\s*\}\}/gi;

const CHART_BAR = "#94a3b8";
const CHART_BAR_HI = "#16a34a";
const CHART_TEXT = "#475569";
const CHART_VALUE = "#0f172a";

function parseChartNumber(raw) {
  const s = String(raw).trim();
  const pct = /%\s*$/.test(s);
  const n = parseFloat(s.replace(/,/g, "").replace(/%/g, ""));
  return { n: Number.isFinite(n) ? n : null, pct };
}

function formatChartNumber(n, unit) {
  const body = Number.isInteger(n) ? n.toLocaleString("en-US") : String(n);
  return unit ? `${body}${unit}` : body;
}

function renderChart(spec) {
  const segs = String(spec).split("|").map((s) => s.trim()).filter(Boolean);
  if (!segs.length) return "";

  let title = "";
  const rows = [];
  const highlights = [];
  let fixedMax = null;
  let unit = "";
  let sawPct = false;

  segs.forEach((seg, idx) => {
    if (seg.startsWith("!")) {
      const m = /^!\s*([a-z]+)\s*=\s*([\s\S]+)$/i.exec(seg);
      if (!m) return;
      const key = m[1].toLowerCase();
      const val = m[2].trim();
      if (key === "hi") highlights.push(val.toLowerCase());
      else if (key === "max") { const p = parseChartNumber(val); if (p.n !== null) fixedMax = p.n; }
      else if (key === "unit") unit = val;
      return;
    }
    const eq = seg.indexOf("=");
    if (eq === -1) {
      if (idx === 0 && !title) title = seg;
      return;
    }
    const label = seg.slice(0, eq).trim();
    const parsed = parseChartNumber(seg.slice(eq + 1));
    if (parsed.n === null) return;
    if (parsed.pct) sawPct = true;
    rows.push({ label, value: parsed.n });
  });

  if (!rows.length) return "";
  if (!unit && sawPct) unit = "%";

  const dataMax = rows.reduce((a, r) => Math.max(a, r.value), 0);
  const max = fixedMax !== null ? fixedMax : dataMax;
  if (!(max > 0)) return "";

  // Geometry: fixed viewBox, scaled by the browser to the container width.
  const LABEL_W = 54;
  const VALUE_W = 46;
  const PLOT_W = 200;
  const ROW_H = 17;
  const BAR_H = 10;
  const TITLE_H = title ? 20 : 4;
  const W = LABEL_W + PLOT_W + VALUE_W;
  const H = TITLE_H + rows.length * ROW_H + 4;

  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="100%" style="max-width:420px;` +
      `margin:8px 0;font-family:inherit;display:block;" role="img" ` +
      `aria-label="${escapeHtml(title || "chart")}">`,
  ];

  if (title) {
    parts.push(
      `<text x="0" y="12" font-size="10" font-weight="700" fill="${CHART_TEXT}" ` +
        `letter-spacing="0.05em">${escapeHtml(title.toUpperCase())}</text>`
    );
  }

  rows.forEach((r, i) => {
    const y = TITLE_H + i * ROW_H;
    const isHi = highlights.includes(r.label.toLowerCase());
    const w = Math.max(max > 0 ? (r.value / max) * PLOT_W : 0, r.value > 0 ? 1.5 : 0);
    parts.push(
      `<text x="0" y="${y + BAR_H - 1}" font-size="9" fill="${CHART_TEXT}">${escapeHtml(r.label)}</text>`,
      `<rect x="${LABEL_W}" y="${y}" width="${w.toFixed(1)}" height="${BAR_H}" rx="2" ` +
        `fill="${isHi ? CHART_BAR_HI : CHART_BAR}"/>`,
      `<text x="${LABEL_W + PLOT_W + 6}" y="${y + BAR_H - 1}" font-size="9" ` +
        `font-weight="${isHi ? 700 : 400}" fill="${CHART_VALUE}">` +
        `${escapeHtml(formatChartNumber(r.value, unit))}</text>`
    );
  });

  parts.push(`</svg>`);
  return parts.join("");
}

// ─── Line chart preprocessing ─────────────────────────────────
// {{line: Title | !x=lbl;lbl;lbl | Series name=v;v;v | Series name=v;v;v}}
//
// Semicolons separate points so that thousands separators stay usable inside
// a value ("9,250;1,750;550"). Series are plotted against the shared !x axis
// and drawn in declaration order; a legend appears whenever there is more
// than one. Same option set as {{chart:}}: !max, !unit. A trailing % on any
// value implies !unit=%.
//
// Use a line for anything ordered — elapsed time, hour of day, attempt
// number, day of week. Reserve {{chart:}} bars for unordered comparisons.

const LINE_RE = /\{\{line:\s*([\s\S]+?)\s*\}\}/gi;

const LINE_COLORS = ["#16a34a", "#64748b", "#d97706", "#2563eb"];
const LINE_GRID = "#e2e8f0";

function renderLine(spec) {
  const segs = String(spec).split("|").map((s) => s.trim()).filter(Boolean);
  if (!segs.length) return "";

  let title = "";
  let xLabels = [];
  let fixedMax = null;
  let unit = "";
  let sawPct = false;
  const series = [];

  segs.forEach((seg, idx) => {
    if (seg.startsWith("!")) {
      const m = /^!\s*([a-z]+)\s*=\s*([\s\S]+)$/i.exec(seg);
      if (!m) return;
      const key = m[1].toLowerCase();
      const val = m[2].trim();
      if (key === "x") xLabels = val.split(";").map((v) => v.trim());
      else if (key === "max") { const p = parseChartNumber(val); if (p.n !== null) fixedMax = p.n; }
      else if (key === "unit") unit = val;
      return;
    }
    const eq = seg.indexOf("=");
    if (eq === -1) {
      if (idx === 0 && !title) title = seg;
      return;
    }
    const name = seg.slice(0, eq).trim();
    const pts = seg.slice(eq + 1).split(";").map((v) => {
      const p = parseChartNumber(v);
      if (p.pct) sawPct = true;
      return p.n;
    });
    if (pts.some((n) => n !== null)) series.push({ name, pts });
  });

  if (!series.length) return "";
  if (!unit && sawPct) unit = "%";

  const n = Math.max(xLabels.length, ...series.map((s) => s.pts.length));
  if (n < 2) return "";

  let dataMax = 0;
  series.forEach((s) => s.pts.forEach((v) => { if (v !== null && v > dataMax) dataMax = v; }));
  const max = fixedMax !== null ? fixedMax : dataMax;
  if (!(max > 0)) return "";

  const multi = series.length > 1;
  const W = 320;
  const PAD_L = 36;
  const PAD_R = 8;
  const PAD_T = (title ? 16 : 4) + (multi ? 13 : 0);
  const PLOT_H = 88;
  const PAD_B = 20;
  const H = PAD_T + PLOT_H + PAD_B;
  const plotW = W - PAD_L - PAD_R;

  const xAt = (i) => PAD_L + (n === 1 ? plotW / 2 : (i / (n - 1)) * plotW);
  const yAt = (v) => PAD_T + PLOT_H - (v / max) * PLOT_H;

  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="100%" style="max-width:480px;` +
      `margin:10px 0;font-family:inherit;display:block;" role="img" ` +
      `aria-label="${escapeHtml(title || "line chart")}">`,
  ];

  if (title) {
    parts.push(
      `<text x="0" y="10" font-size="10" font-weight="700" fill="${CHART_TEXT}" ` +
        `letter-spacing="0.05em">${escapeHtml(title.toUpperCase())}</text>`
    );
  }

  if (multi) {
    let lx = 0;
    series.forEach((s, si) => {
      const c = LINE_COLORS[si % LINE_COLORS.length];
      parts.push(
        `<rect x="${lx}" y="${(title ? 16 : 4) + 1}" width="7" height="7" rx="1.5" fill="${c}"/>`,
        `<text x="${lx + 10}" y="${(title ? 16 : 4) + 7.5}" font-size="8" fill="${CHART_TEXT}">` +
          `${escapeHtml(s.name)}</text>`
      );
      lx += 10 + 6 + String(s.name).length * 4.3 + 10;
    });
  }

  // Horizontal gridlines at 0, half, max, with value labels.
  [0, max / 2, max].forEach((v) => {
    const y = yAt(v);
    parts.push(
      `<line x1="${PAD_L}" y1="${y.toFixed(1)}" x2="${W - PAD_R}" y2="${y.toFixed(1)}" ` +
        `stroke="${LINE_GRID}" stroke-width="1"/>`,
      `<text x="${PAD_L - 4}" y="${(y + 3).toFixed(1)}" font-size="8" text-anchor="end" ` +
        `fill="${CHART_TEXT}">${escapeHtml(formatChartNumber(Math.round(v), unit))}</text>`
    );
  });

  // Series lines and point markers.
  series.forEach((s, si) => {
    const c = LINE_COLORS[si % LINE_COLORS.length];
    const pts = [];
    s.pts.forEach((v, i) => {
      if (v === null) return;
      pts.push(`${xAt(i).toFixed(1)},${yAt(v).toFixed(1)}`);
    });
    if (pts.length > 1) {
      parts.push(
        `<polyline points="${pts.join(" ")}" fill="none" stroke="${c}" stroke-width="2" ` +
          `stroke-linejoin="round" stroke-linecap="round"/>`
      );
    }
    s.pts.forEach((v, i) => {
      if (v === null) return;
      parts.push(
        `<circle cx="${xAt(i).toFixed(1)}" cy="${yAt(v).toFixed(1)}" r="2.2" fill="${c}"/>`
      );
    });
  });

  // X axis labels, thinned so they never collide on a long series. The last
  // label is always drawn; if thinning left one immediately beside it, that
  // neighbour is dropped rather than allowed to overlap.
  const step = n > 8 ? 2 : 1;
  const idxs = [];
  for (let i = 0; i < n; i += step) idxs.push(i);
  if (idxs[idxs.length - 1] !== n - 1) idxs.push(n - 1);
  if (idxs.length > 1 && idxs[idxs.length - 1] - idxs[idxs.length - 2] === 1) {
    idxs.splice(idxs.length - 2, 1);
  }
  idxs.forEach((i) => {
    const lbl = xLabels[i];
    if (!lbl) return;
    const anchor = i === 0 ? "start" : i === n - 1 ? "end" : "middle";
    parts.push(
      `<text x="${xAt(i).toFixed(1)}" y="${PAD_T + PLOT_H + 12}" font-size="8" ` +
        `text-anchor="${anchor}" fill="${CHART_TEXT}">${escapeHtml(lbl)}</text>`
    );
  });

  parts.push(`</svg>`);
  return parts.join("");
}

function expandLines(md) {
  if (!md || md.indexOf("{{line:") === -1) return md;
  return md.replace(LINE_RE, (_m, spec) => renderLine(spec));
}

function expandCharts(md) {
  if (!md || md.indexOf("{{chart:") === -1) return md;
  return md.replace(CHART_RE, (_m, spec) => renderChart(spec));
}

// ─── Markdown → HTML ──────────────────────────────────────────
export function mdToHtml(md, options = {}) {
  let src = String(md || "");

  if (options && typeof options.resolveInclude === "function") {
    src = expandIncludes(src, options.resolveInclude, new Set(), 0);
  }

  if (options && typeof options.resolveExcerpt === "function") {
    src = expandExcerpts(src, options.resolveExcerpt, new Set(), 0);
  }

  if (options && typeof options.resolveGlossary === "function") {
    src = expandGlossary(src, options.resolveGlossary);
  }

  // No resolver needed — chart data is authored inline in the marker.
  src = expandCharts(src);
  src = expandLines(src);

  if (!src.trim()) return "";

  const lines = src.split(/\r?\n/);
  const out = [];
  let i = 0;
  let inCode = false;
  let codeBuf = [];
  // Stack of open lists, each { type: "ul"|"ol", indent: number }.
  // Nesting is depth-driven by leading-space indent, dynamically mapped —
  // any leading whitespace greater than the current top opens a nested list.
  let listStack = [];
  let paraBuf = [];

  const flushPara = () => {
    if (paraBuf.length) {
      out.push("<p>" + inlineMd(paraBuf.join(" ")) + "</p>");
      paraBuf = [];
    }
  };
  // Close nested lists until the topmost open list has indent <= keepIndent.
  // keepIndent = -1 closes everything.
  const flushListsBelow = (keepIndent) => {
    while (listStack.length > 0 && listStack[listStack.length - 1].indent > keepIndent) {
      out.push("</li>");
      out.push(`</${listStack[listStack.length - 1].type}>`);
      listStack.pop();
    }
  };
  const flushList = () => flushListsBelow(-1);

  while (i < lines.length) {
    const line = lines[i];

    // Code fence
    if (/^```/.test(line)) {
      if (inCode) {
        out.push(`<pre><code>${escapeHtml(codeBuf.join("\n"))}</code></pre>`);
        codeBuf = [];
        inCode = false;
      } else {
        flushPara(); flushList();
        inCode = true;
      }
      i++; continue;
    }
    if (inCode) { codeBuf.push(line); i++; continue; }

    // HTML block passthrough
    const htmlOpen = new RegExp(`^\\s*<(${PASSTHROUGH_TAGS.join("|")})\\b`, "i").exec(line);
    if (htmlOpen) {
      flushPara(); flushList();
      const tag = htmlOpen[1].toLowerCase();
      const closeRe = new RegExp(`</\\s*${tag}\\s*>`, "i");
      // Single-line self-contained block
      if (closeRe.test(line)) {
        out.push(line);
        i++; continue;
      }
      // Multi-line: consume until matching close
      const buf = [line];
      i++;
      let depth = 1;
      const openRe = new RegExp(`<\\s*${tag}\\b`, "gi");
      while (i < lines.length && depth > 0) {
        buf.push(lines[i]);
        const ln = lines[i];
        const opens = (ln.match(openRe) || []).length;
        const closes = (ln.match(new RegExp(`</\\s*${tag}\\s*>`, "gi")) || []).length;
        depth += opens - closes;
        i++;
        if (depth <= 0) break;
      }
      // For <details>, recursively parse markdown inside so bullets/bold/etc render.
      // Other passthrough tags stay as raw HTML.
      if (tag === "details") {
        const blockText = buf.join("\n");
        const wrapMatch = blockText.match(/^([\s\S]*?<details\b[^>]*>)([\s\S]*)<\/details\s*>\s*$/i);
        if (wrapMatch) {
          const opener = wrapMatch[1].trim();
          let inner = wrapMatch[2];
          let summaryHtml = "";
          const sumMatch = inner.match(/<summary\b[^>]*>([\s\S]*?)<\/summary\s*>/i);
          if (sumMatch) {
            summaryHtml = `<summary>${inlineMd(sumMatch[1].trim())}</summary>`;
            inner = inner.replace(sumMatch[0], "");
          }
          const innerHtml = mdToHtml(inner, options);
          out.push(`${opener}\n${summaryHtml}\n${innerHtml}\n</details>`);
        } else {
          out.push(buf.join("\n"));
        }
      } else {
        out.push(buf.join("\n"));
      }
      continue;
    }

    // Blank line
    if (!line.trim()) {
      flushPara(); flushList();
      i++; continue;
    }

    // Heading — emits id attribute for section anchor links.
    // Manual inline anchor (`<a id="foo"></a>`) inside the heading wins over auto-slug;
    // otherwise the id is auto-generated from slugified heading text.
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      flushPara(); flushList();
      const lvl = h[1].length;
      const manualAnchor = h[2].match(/<a\s+id="([^"]+)"[^>]*>\s*<\/a>/i);
      let idAttr = "";
      let text = h[2];
      if (manualAnchor) {
        idAttr = ` id="${manualAnchor[1]}"`;
        text = h[2].replace(/<a\s+id="[^"]+"[^>]*>\s*<\/a>/gi, "");
      } else {
        const slug = slugifyHeading(h[2]);
        if (slug) idAttr = ` id="${slug}"`;
      }
      out.push(`<h${lvl}${idAttr}>${inlineMd(text)}</h${lvl}>`);
      i++; continue;
    }

    // Horizontal rule
    if (/^[-*_]{3,}\s*$/.test(line)) {
      flushPara(); flushList();
      out.push("<hr/>");
      i++; continue;
    }

    // Markdown pipe table (GFM-style)
    const _isPipeRow = (s) => /^\s*\|.*\|\s*$/.test(s);
    const _isPipeSep = (s) => /^\s*\|[\s\-:|]+\|\s*$/.test(s);
    if (_isPipeRow(line) && i + 1 < lines.length && _isPipeSep(lines[i + 1])) {
      flushPara(); flushList();

      const splitRow = (s) => {
        const inner = s.trim().replace(/^\|/, "").replace(/\|$/, "");
        const parts = [];
        let buf = "";
        for (let k = 0; k < inner.length; k++) {
          if (inner[k] === "\\" && inner[k + 1] === "|") { buf += "|"; k++; continue; }
          if (inner[k] === "|") { parts.push(buf.trim()); buf = ""; continue; }
          buf += inner[k];
        }
        parts.push(buf.trim());
        return parts;
      };

      const sepCells = splitRow(lines[i + 1]);
      const align = sepCells.map(c => {
        const L = c.startsWith(":");
        const R = c.endsWith(":");
        if (L && R) return "center";
        if (R) return "right";
        if (L) return "left";
        return null;
      });

      const headerCells = splitRow(line);
      i += 2;
      const bodyRows = [];
      while (i < lines.length && _isPipeRow(lines[i]) && !_isPipeSep(lines[i])) {
        bodyRows.push(splitRow(lines[i]));
        i++;
      }

      const cell = (tag, txt, idx) => {
        const a = align[idx];
        const styleAttr = a ? ` style="text-align:${a}"` : "";
        return `<${tag}${styleAttr}>${inlineMd(txt)}</${tag}>`;
      };

      let html = `<div class="newtworks-table-wrap" style="overflow-x:auto;-webkit-overflow-scrolling:touch;"><table>`;
      html += "<thead><tr>";
      headerCells.forEach((c, idx) => { html += cell("th", c, idx); });
      html += "</tr></thead><tbody>";
      bodyRows.forEach(row => {
        html += "<tr>";
        for (let k = 0; k < headerCells.length; k++) {
          html += cell("td", row[k] ?? "", k);
        }
        html += "</tr>";
      });
      html += "</tbody></table></div>";
      out.push(html);
      continue;
    }

    // Markdown blockquote (single-line style: "> text")
    const bq = /^>\s?(.*)$/.exec(line);
    if (bq) {
      flushPara(); flushList();
      const buf = [bq[1]];
      i++;
      while (i < lines.length) {
        const nxt = /^>\s?(.*)$/.exec(lines[i]);
        if (!nxt) break;
        buf.push(nxt[1]);
        i++;
      }
      const inner = buf
        .map(seg => seg.trim() ? `<p>${inlineMd(seg)}</p>` : "")
        .filter(Boolean)
        .join("");
      out.push(`<blockquote>${inner}</blockquote>`);
      continue;
    }

    // Unordered / ordered list (supports nesting via leading whitespace).
    // Deeper indent than the current top opens a nested <ul>/<ol> inside the
    // still-open parent <li>. Shallower indent pops levels. Same indent, same
    // type continues the list; same indent, different type swaps.
    const ul = /^(\s*)[-*]\s+(.*)$/.exec(line);
    const ol = ul ? null : /^(\s*)\d+\.\s+(.*)$/.exec(line);
    if (ul || ol) {
      flushPara();
      const m = ul || ol;
      const kind = ul ? "ul" : "ol";
      const indent = m[1].length;
      const content = m[2];

      // Close any lists deeper than this indent
      flushListsBelow(indent);

      const top = listStack[listStack.length - 1];

      if (!top || top.indent < indent) {
        // Open a new (possibly nested) list. Do NOT close the parent's <li>
        // — the nested list belongs inside it.
        out.push(`<${kind}>`);
        listStack.push({ type: kind, indent });
        out.push("<li>" + inlineMd(content));
      } else {
        // Same indent level. Close previous <li>. If list type differs, swap.
        if (top.type !== kind) {
          out.push("</li>");
          out.push(`</${top.type}>`);
          listStack.pop();
          out.push(`<${kind}>`);
          listStack.push({ type: kind, indent });
        } else {
          out.push("</li>");
        }
        out.push("<li>" + inlineMd(content));
      }
      i++; continue;
    }

    // Paragraph
    flushList();
    paraBuf.push(line);
    i++;
  }
  flushPara(); flushList();
  if (inCode) out.push(`<pre><code>${escapeHtml(codeBuf.join("\n"))}</code></pre>`);
  let result = out.join("\n");

  if (options && typeof options.resolveFaq === "function") {
    result = applyFaqSubstitution(result, options.resolveFaq);
  }

  return result;
}

// ─── Helper: build a title→content lookup from rows ───────────
// Consumers call this once at mount, then pass a resolveInclude closure
// to mdToHtml that reads from the map. Titles are normalized to lowercase
// trimmed keys so lookups are case-/whitespace-insensitive.
export function buildIncludeLookup(rows) {
  const map = new Map();
  for (const r of (rows || [])) {
    if (!r || r.is_active === false) continue;
    if (r.archived_at) continue;
    const t = r.title;
    if (!t) continue;
    map.set(String(t).trim().toLowerCase(), {
      content: r.content == null ? "" : String(r.content),
      title: t,
    });
  }
  return map;
}

// Convenience: pair with buildIncludeLookup to make a resolver in one call.
export function makeIncludeResolver(lookup) {
  return function resolveInclude(target) {
    if (!lookup) return { status: "missing" };
    const hit = lookup.get(String(target).trim().toLowerCase());
    if (!hit) return { status: "missing" };
    if (!hit.content || !hit.content.trim()) return { status: "empty" };
    return { status: "ok", md: hit.content };
  };
}

// ─── Glossary lookup helpers ──────────────────────────────────
// Glossary entries live in the handbook table as children of the Glossary page.
// buildGlossaryLookup accepts handbook rows (title, content, confluence_page_id,
// sort_order) and derives a tag from the confluence_page_id after stripping the
// 'newtworks-native-glossary-' prefix (e.g. 'newtworks-native-glossary-quote' → 'quote').
export const GLOSSARY_CPID_PREFIX = "newtworks-native-glossary-";

function tagFromCpid(cpid) {
  const s = String(cpid || "").trim();
  if (s.toLowerCase().startsWith(GLOSSARY_CPID_PREFIX)) {
    return s.slice(GLOSSARY_CPID_PREFIX.length).toLowerCase();
  }
  // Fallback: slugify title-style row identifiers.
  return s.toLowerCase();
}

export function buildGlossaryLookup(rows) {
  const active = (rows || []).filter((r) => r && r.is_active !== false && (r.confluence_page_id || r.tag));
  const ordered = active.slice().sort((a, b) => {
    const ao = a.sort_order == null ? 999999 : a.sort_order;
    const bo = b.sort_order == null ? 999999 : b.sort_order;
    if (ao !== bo) return ao - bo;
    return String(a.title || a.term || "").localeCompare(String(b.title || b.term || ""));
  });
  const map = new Map();
  for (const r of ordered) {
    const tag = r.tag != null ? String(r.tag).trim().toLowerCase() : tagFromCpid(r.confluence_page_id);
    if (!tag) continue;
    map.set(tag, {
      tag,
      term: (r.title != null ? String(r.title) : (r.term != null ? String(r.term) : tag)),
      definition: (r.content != null ? String(r.content) : (r.definition != null ? String(r.definition) : "")),
      sort_order: r.sort_order,
    });
  }
  return { map, ordered: ordered.map((r) => {
    const tag = r.tag != null ? String(r.tag).trim().toLowerCase() : tagFromCpid(r.confluence_page_id);
    return {
      tag,
      term: (r.title != null ? String(r.title) : (r.term != null ? String(r.term) : tag)),
      definition: (r.content != null ? String(r.content) : (r.definition != null ? String(r.definition) : "")),
    };
  }) };
}

// Convenience: pair with buildGlossaryLookup to make a resolver in one call.
// Call with a tag string to get one entry, or with null/undefined to get all ordered entries.
export function makeGlossaryResolver(lookup) {
  return function resolveGlossary(tag) {
    if (!lookup) return tag == null ? [] : null;
    if (tag == null) return lookup.ordered.slice();
    return lookup.map.get(String(tag).trim().toLowerCase()) || null;
  };
}

// ─── Excerpt lookup helpers ───────────────────────────────────
// Identical shape to buildIncludeLookup / makeIncludeResolver — kept as
// distinct exports so consumers can pass a separately-queried row set
// (typically manual_type='excerpt') without collision with the current
// manual's rows.

export function buildExcerptLookup(rows) {
  return buildIncludeLookup(rows);
}

export function makeExcerptResolver(lookup) {
  return makeIncludeResolver(lookup);
}

// ─── FAQ lookup helpers ────────────────────────────────────────
// Knowledge & FAQ bank rows live in public.knowledge_faqs, one row per
// question/answer pair, grouped under topic_key (one tag-line group on one
// manual page). Only approved, active rows are kept here — this is the one
// place that filter is enforced for rendering, so draft/retired rows can
// never reach the {{faq: topic_key}} renderer through any code path, no
// matter who is viewing the page. The approval screen at /knowledge-faqs
// queries the table directly (bypassing this lookup) to show drafts.
export function buildFaqLookup(rows) {
  const map = new Map();
  for (const r of (rows || [])) {
    if (!r || r.status !== "approved" || r.is_active === false) continue;
    const key = r.topic_key ? String(r.topic_key).trim().toLowerCase() : "";
    if (!key) continue;
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(r);
  }
  for (const list of map.values()) {
    list.sort((a, b) => {
      const ao = a.sort_order == null ? 999999 : a.sort_order;
      const bo = b.sort_order == null ? 999999 : b.sort_order;
      return ao - bo;
    });
  }
  return map;
}

// Convenience: pair with buildFaqLookup to make a resolver in one call.
export function makeFaqResolver(lookup) {
  return function resolveFaq(topicKey) {
    if (!lookup) return null;
    return lookup.get(String(topicKey).trim().toLowerCase()) || null;
  };
}
