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

function inlineMd(s) {
  if (!s) return "";
  let out = String(s);

  // Unescape \* \_ before inline parsing so escaped bold/italic still renders.
  out = out.replace(/\\([*_`\[\]])/g, "$1");

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

  // Bold (** or __)
  out = out.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  out = out.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");

  // Italic (* or _), not consuming **
  out = out.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
  out = out.replace(/(^|[^_])_([^_\n]+)_(?!_)/g, "$1<em>$2</em>");

  // Inline code
  out = out.replace(/`([^`\n]+)`/g, "<code>$1</code>");

  return out;
}

const PASSTHROUGH_TAGS = ["details", "summary", "blockquote", "table", "div", "figure", "aside"];

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
          const innerHtml = mdToHtml(inner);
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

      let html = `<div style="overflow-x:auto;-webkit-overflow-scrolling:touch;"><table>`;
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
  return out.join("\n");
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
