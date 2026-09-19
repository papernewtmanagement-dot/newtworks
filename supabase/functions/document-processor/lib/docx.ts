// =========================================================================
// lib/docx.ts
// =========================================================================
// Reading the text out of a Word (.docx) file.
//
// WHY THIS EXISTS (2026-09-19):
//   Every resume route in classifier.ts required a .pdf file name, so a Word
//   resume matched nothing and classified as "skip" — no documents row, no
//   candidate row, no error. Ramon Alonzo's resume, forwarded 2026-09-10, was
//   dropped exactly that way and never reached hiring_candidates.
//
//   The classifier half of that fix is two characters. This is the other half,
//   and it has to come first: widening the classifier without being able to
//   READ a Word file would only have turned a silent skip into a loud error.
//
// HOW IT WORKS, with no new dependency:
//   A .docx is an ordinary zip archive of XML parts. The visible text of the
//   document lives in word/document.xml; headers and footers sit in their own
//   parts alongside it. zip-js is already a dependency of this function
//   (index.ts uses it to unpack .zip attachments), so this opens the file with
//   the same library and reads only the parts it needs.
//
// ORDER OF THE TEXT — body first, then headers, then footers. Identity
//   extraction downstream takes the candidate's name from the first plausible
//   line of the text, and on a resume that is the first line of the body. Page
//   numbers and other header furniture must not get there ahead of it.
//
// ONE COPY ONLY. Both places that turn attachment bytes into text call this:
//   extractText in index.ts, and rmbExtractResumeText in
//   parsers/resume_manual_batch.ts. Do not write a third.
//
// BUNDLER NOTE. The zip-js import below must stay character-for-character
//   identical to the one at the top of index.ts. scripts/bundle_document_
//   processor.py keeps only the FIRST import it sees for a given external
//   module and drops every later one, so two different symbol lists for the
//   same module would leave whichever file bundles second missing its symbols
//   at runtime.
//
// WHAT THIS DOES NOT HANDLE: legacy .doc (Word 97 binary). That is not a zip
//   and cannot be read without a real parser, which is why the classifier
//   accepts .docx only.
// =========================================================================

import { BlobReader, ZipReader, Uint8ArrayWriter } from "jsr:@zip-js/zip-js@2";

export const DOCX_MIME_TYPE =
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

/**
 * True when this attachment is a Word .docx, by file name or by mime type.
 *
 * Deliberately NOT sniffed from the file's own bytes: a .docx and an ordinary
 * .zip attachment both start with the same zip signature, and .zip already has
 * its own route (archive_bundle, unpacked and reclassified entry by entry).
 * Sniffing would hijack it.
 */
export function isDocxAttachment(fileName: string, mimeType?: string | null): boolean {
  if (/\.docx$/i.test(fileName)) return true;
  return (mimeType ?? "").trim().toLowerCase() === DOCX_MIME_TYPE;
}

/** XML entity decode. &amp; goes LAST so "&amp;lt;" does not become "<". */
function docxDecodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#x([0-9a-fA-F]+);/g, (_m, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_m, d) => String.fromCodePoint(parseInt(d, 10)))
    .replace(/&amp;/g, "&");
}

/**
 * Turn one Word XML part into plain text.
 *
 * Properties blocks go first: they describe how a paragraph or run LOOKS and
 * carry no visible text, but they do contain <w:tab> elements defining tab
 * stops, which would otherwise be mistaken for real tabs in the content.
 *
 * Then the elements that are genuinely breaks become breaks, and then every
 * remaining tag is dropped. That blanket strip is safe here because in this
 * format all visible text sits BETWEEN tags — never inside one — so nothing
 * readable lives in what is being removed.
 */
function docxXmlToText(xml: string): string {
  let s = xml;

  // Formatting and section descriptions — no visible text.
  s = s.replace(/<w:pPr>[\s\S]*?<\/w:pPr>/g, "");
  s = s.replace(/<w:rPr>[\s\S]*?<\/w:rPr>/g, "");
  s = s.replace(/<w:sectPr[\s\S]*?<\/w:sectPr>/g, "");

  // Field instructions and tracked deletions are not visible in the document,
  // so they must not end up in the extracted text either.
  s = s.replace(/<w:instrText[\s\S]*?<\/w:instrText>/g, "");
  s = s.replace(/<w:delText[\s\S]*?<\/w:delText>/g, "");

  // Real breaks.
  s = s.replace(/<w:tab\b[^>]*>/g, "\t");
  s = s.replace(/<w:br\b[^>]*>/g, "\n");
  s = s.replace(/<w:cr\b[^>]*>/g, "\n");

  // Paragraph and table structure.
  s = s.replace(/<\/w:p>/g, "\n");
  s = s.replace(/<\/w:tc>/g, "\t");
  s = s.replace(/<\/w:tr>/g, "\n");

  // Everything else.
  s = s.replace(/<[^>]+>/g, "");
  s = docxDecodeEntities(s);

  // Tidy: no trailing blanks on a line, no runs of empty lines.
  s = s.replace(/\r\n?/g, "\n");
  // Each table cell holds its own paragraph, so a cell break lands as a
  // newline immediately followed by the cell separator. Drop the newline so a
  // table row reads as one line. Nothing else produces a tab-led line: the
  // formatting blocks that define tab stops were already removed above.
  s = s.replace(/\n+(?=\t)/g, "");
  s = s.replace(/[ \t]+\n/g, "\n");
  s = s.replace(/\n{3,}/g, "\n\n");
  return s.trim();
}

/**
 * Read a base64 .docx and return its text.
 *
 * Same result shape as extractText in index.ts so the two are interchangeable
 * at the call site.
 */
export async function extractDocxText(
  bytesB64: string,
): Promise<{ ok: true; text: string } | { ok: false; error: string }> {
  try {
    const bin = atob(bytesB64);
    const buf = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);

    const reader = new ZipReader(new BlobReader(new Blob([buf])));
    try {
      const entries = await reader.getEntries();
      const decoder = new TextDecoder("utf-8");

      // Walked rather than found so the directory check narrows the entry to a
      // file, which is what carries getData. Same shape as unzipBytes in
      // index.ts.
      const readPart = async (lowerName: string): Promise<string> => {
        for (const entry of entries) {
          if (entry.directory) continue;
          if (entry.filename.toLowerCase() !== lowerName) continue;
          if (!entry.getData) return "";
          const data = await entry.getData(new Uint8ArrayWriter());
          return decoder.decode(data);
        }
        return "";
      };

      const bodyXml = await readPart("word/document.xml");
      if (!bodyXml) {
        return { ok: false, error: "not a Word document: word/document.xml is missing" };
      }

      const pieces: string[] = [];
      const body = docxXmlToText(bodyXml);
      if (body) pieces.push(body);

      // Headers, then footers, each group in file-name order so the same
      // document always reads the same way. Sorting the two groups together
      // would put "footer1" ahead of "header1" alphabetically, which is not
      // the order they appear on the page.
      const partNames = (kind: string) =>
        entries
          .filter((e) => !e.directory &&
            new RegExp(`^word/${kind}\\d*\\.xml$`, "i").test(e.filename))
          .map((e) => e.filename.toLowerCase())
          .sort();
      const extras = [...partNames("header"), ...partNames("footer")];
      for (const name of extras) {
        const t = docxXmlToText(await readPart(name));
        if (t) pieces.push(t);
      }

      const text = pieces.join("\n\n").trim();
      if (!text) {
        return { ok: false, error: "docx contained no readable text" };
      }
      return { ok: true, text };
    } finally {
      // A failure to close must never replace the real error above it.
      try { await reader.close(); } catch { /* ignore */ }
    }
  } catch (e) {
    return {
      ok: false,
      error: `docx extraction failed: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
}
