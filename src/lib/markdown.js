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

// ─── Include-marker preprocessing ─────────────────────────────
// A marker occupies its own line and looks like:
//   *[Included from: Some Page Title]*      (italic-wrapped, ingestor default)
//   [Included from: Some Page Title]        (bare)
// Escaped titles like `\*Extended Life Process` are unescaped before lookup.

const INCLUDE_LINE_RE = /^[ \t]*\*?\[Included from:\s*([^\]\n]+?)\]\*?[ \t]*$/gm;
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

function bannerMissing(target) {
  return (
    `<div style="${BANNER_STYLE_MISSING}">` +
    `⚠️ <strong>Missing include:</strong> "${escapeHtml(target)}" was referenced here ` +
    `but was not migrated. Author the page or remove the include marker.` +
    `</div>`
  );
}

function bannerEmpty(target) {
  return (
    `<div style="${BANNER_STYLE_EMPTY}">` +
    `⚠️ <strong>Empty include:</strong> "${escapeHtml(target)}" exists but has no content yet.` +
    `</div>`
  );
}

function bannerCycle(target) {
  return (
    `<div style="${BANNER_STYLE_CYCLE}">` +
    `🔁 <strong>Include cycle detected:</strong> "${escapeHtml(target)}" would loop back on itself.` +
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

// ─── Strip markdown to a short preview for sidebar ────────────
export function previewText(content, n = 90) {
  if (!content) return "";
  const stripped = String(content)
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

  if (!src.trim()) return "";

  const lines = src.split(/\r?\n/);
  const out = [];
  let i = 0;
  let inCode = false;
  let codeBuf = [];
  let listType = null; // "ul" | "ol"
  let paraBuf = [];

  const flushPara = () => {
    if (paraBuf.length) {
      out.push("<p>" + inlineMd(paraBuf.join(" ")) + "</p>");
      paraBuf = [];
    }
  };
  const flushList = () => {
    if (listType) {
      out.push(`</${listType}>`);
      listType = null;
    }
  };

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
      out.push(buf.join("\n"));
      continue;
    }

    // Blank line
    if (!line.trim()) {
      flushPara(); flushList();
      i++; continue;
    }

    // Heading
    const h = /^(#{1,6})\s+(.*)$/.exec(line);
    if (h) {
      flushPara(); flushList();
      const lvl = h[1].length;
      out.push(`<h${lvl}>${inlineMd(h[2])}</h${lvl}>`);
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

    // Unordered list
    const ul = /^[-*]\s+(.*)$/.exec(line);
    if (ul) {
      flushPara();
      if (listType !== "ul") { flushList(); out.push("<ul>"); listType = "ul"; }
      out.push("<li>" + inlineMd(ul[1]) + "</li>");
      i++; continue;
    }

    // Ordered list
    const ol = /^\d+\.\s+(.*)$/.exec(line);
    if (ol) {
      flushPara();
      if (listType !== "ol") { flushList(); out.push("<ol>"); listType = "ol"; }
      out.push("<li>" + inlineMd(ol[1]) + "</li>");
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
