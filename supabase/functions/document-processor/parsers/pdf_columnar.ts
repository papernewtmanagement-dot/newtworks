// =========================================================================
// parsers/pdf_columnar.ts
// =========================================================================
// Column-aware PDF text extraction using pdfjs-dist positions (via unpdf's
// getDocumentProxy). Handles the two-column resume problem: pdfjs's default
// content-stream order interleaves left/right column text line-by-line, so
// a resume with a narrow left sidebar (contact/skills) and a wide right
// column (experience) comes out as jumbled text (see Cassandra Alves,
// Stephanie Rogers, Randy Castle in the 2026-07-17 audit).
//
// Approach per page:
//   1. Pull every TextItem with its (x, y, width, height) from pdfjs.
//   2. Detect a vertical whitespace band in the middle of the page — count
//      items crossing each of 200 x-slices; find the widest contiguous
//      empty stretch in the middle 60% of the page. If it's > ~3% of page
//      width, treat as a column boundary.
//   3. Bucket items into columns by their horizontal midpoint.
//   4. Within each column, group items into lines by y (bottom-origin, so
//      higher y = higher on the page), then join left-to-right.
//   5. Concatenate columns left-to-right with a blank line between.
//
// Falls back to single-column extraction (equivalent to unpdf.extractText)
// when no significant middle gap is detected on a page. Single-column pages
// come out identical to the plain unpdf path.
//
// Called by:  parsers/careerplug_applicant.ts (resume PDF extraction).
//             Not used for bank/comp/deduction/payroll — those are
//             single-column by construction and go through the existing
//             extractText() path in index.ts.
// =========================================================================

import { getDocumentProxy, extractText as unpdfExtractText } from "npm:unpdf@1.3.2";

interface PdfTextItem {
  str: string;
  x: number;       // left edge (user space, bottom-origin)
  y: number;       // baseline y (bottom-origin)
  width: number;
  height: number;
}

export async function extractPdfTextColumnAware(bytes: Uint8Array): Promise<string> {
  const pdf = await getDocumentProxy(bytes);
  const numPages: number = (pdf as any).numPages;
  const pageTexts: string[] = [];

  for (let p = 1; p <= numPages; p++) {
    const page = await (pdf as any).getPage(p);
    const viewport = page.getViewport({ scale: 1 });
    const pageWidth: number = viewport.width;
    const content = await page.getTextContent();

    const items: PdfTextItem[] = [];
    for (const raw of content.items as any[]) {
      if (!raw || typeof raw.str !== "string") continue;
      if (raw.str === "") continue;
      const transform = raw.transform;
      if (!Array.isArray(transform) || transform.length < 6) continue;
      items.push({
        str: raw.str,
        x: Number(transform[4]) || 0,
        y: Number(transform[5]) || 0,
        width: Number(raw.width) || 0,
        height: Number(raw.height) || 0,
      });
    }

    if (items.length === 0) {
      pageTexts.push("");
      continue;
    }

    const boundaries = detectColumnBoundaries(items, pageWidth);

    if (boundaries.length === 0) {
      pageTexts.push(itemsToText(items));
    } else {
      const cuts = [0, ...boundaries, pageWidth + 1e6];
      const columnItems: PdfTextItem[][] = cuts.slice(0, -1).map(() => []);
      for (const item of items) {
        const mx = item.x + item.width / 2;
        for (let c = 0; c < cuts.length - 1; c++) {
          if (mx >= cuts[c] && mx < cuts[c + 1]) {
            columnItems[c].push(item);
            break;
          }
        }
      }
      const columnTexts = columnItems
        .filter((col) => col.length > 0)
        .map((col) => itemsToText(col));
      pageTexts.push(columnTexts.join("\n\n"));
    }
  }

  return pageTexts.join("\n\n").trim();
}

/**
 * Fallback single-column extraction using unpdf's built-in extractText.
 * Exported so callers can degrade gracefully if column-aware throws.
 */
export async function extractPdfTextPlain(bytes: Uint8Array): Promise<string> {
  const pdf = await getDocumentProxy(bytes);
  const { text } = await unpdfExtractText(pdf, { mergePages: true });
  return Array.isArray(text) ? text.join("\n") : String(text ?? "");
}

// -----------------------------------------------------------------------------

function detectColumnBoundaries(items: PdfTextItem[], pageWidth: number): number[] {
  if (items.length < 20 || pageWidth <= 0) return [];

  const NUM_BANDS = 200;
  const bandWidth = pageWidth / NUM_BANDS;
  const bandCounts = new Array(NUM_BANDS).fill(0);
  for (const item of items) {
    const bStart = Math.max(0, Math.floor(item.x / bandWidth));
    const bEnd = Math.min(NUM_BANDS - 1, Math.floor((item.x + Math.max(0, item.width)) / bandWidth));
    for (let b = bStart; b <= bEnd; b++) bandCounts[b]++;
  }

  // Only consider gaps whose CENTER lands in the middle 60% of the page
  // (between 20% and 80%). Anything closer to the edges is a page margin,
  // not a column boundary.
  const minCenterBand = Math.floor(NUM_BANDS * 0.2);
  const maxCenterBand = Math.floor(NUM_BANDS * 0.8);

  let bestStart = -1;
  let bestWidth = 0;
  let curStart = -1;
  for (let b = 0; b < NUM_BANDS; b++) {
    if (bandCounts[b] === 0) {
      if (curStart < 0) curStart = b;
    } else {
      if (curStart >= 0) {
        const w = b - curStart;
        const centerBand = curStart + Math.floor(w / 2);
        if (w > bestWidth && centerBand >= minCenterBand && centerBand <= maxCenterBand) {
          bestWidth = w;
          bestStart = curStart;
        }
        curStart = -1;
      }
    }
  }
  if (curStart >= 0) {
    const w = NUM_BANDS - curStart;
    const centerBand = curStart + Math.floor(w / 2);
    if (w > bestWidth && centerBand >= minCenterBand && centerBand <= maxCenterBand) {
      bestWidth = w;
      bestStart = curStart;
    }
  }

  // Require the gap to be wider than 3% of page width. On US letter (612pt)
  // that's ~18pt — about the width of a comfortable column gutter.
  const MIN_GAP_BANDS = Math.max(3, Math.floor(NUM_BANDS * 0.03));
  if (bestWidth < MIN_GAP_BANDS || bestStart < 0) return [];

  const boundaryX = (bestStart + bestWidth / 2) * bandWidth;
  return [boundaryX];
}

/**
 * Group items into lines by y (with a small tolerance for baseline drift),
 * sort lines top-to-bottom, then within each line sort left-to-right and
 * insert spaces where the horizontal gap between items exceeds ~30% of the
 * previous glyph width.
 */
function itemsToText(items: PdfTextItem[]): string {
  const LINE_TOL = 3; // points

  // Sort by y descending (top-of-page first, since pdfjs uses bottom-origin),
  // then x ascending as a stable secondary key.
  const sorted = [...items].sort((a, b) => {
    if (Math.abs(b.y - a.y) > LINE_TOL) return b.y - a.y;
    return a.x - b.x;
  });

  const lines: PdfTextItem[][] = [];
  let curLine: PdfTextItem[] = [];
  let curLineY: number | null = null;

  for (const item of sorted) {
    if (curLineY === null || Math.abs(item.y - curLineY) <= LINE_TOL) {
      curLine.push(item);
      // Use the first-seen y as the line's anchor — keeps tolerance stable.
      if (curLineY === null) curLineY = item.y;
    } else {
      lines.push(curLine);
      curLine = [item];
      curLineY = item.y;
    }
  }
  if (curLine.length > 0) lines.push(curLine);

  const out: string[] = [];
  for (const line of lines) {
    const s = lineToString(line);
    if (s.trim().length > 0) out.push(s);
  }
  return out.join("\n");
}

function lineToString(items: PdfTextItem[]): string {
  if (items.length === 0) return "";
  items.sort((a, b) => a.x - b.x);
  let out = items[0].str;
  for (let i = 1; i < items.length; i++) {
    const prev = items[i - 1];
    const cur = items[i];
    const prevRight = prev.x + prev.width;
    const gap = cur.x - prevRight;
    const avgCharW = prev.width / Math.max(prev.str.length, 1);
    const prevEndsSpace = /\s$/.test(prev.str);
    const curStartsSpace = /^\s/.test(cur.str);
    if (gap > avgCharW * 0.3 && !prevEndsSpace && !curStartsSpace) out += " ";
    out += cur.str;
  }
  return out;
}
