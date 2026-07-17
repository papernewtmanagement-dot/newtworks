// =========================================================================
// parsers/resume_ingest.ts
// =========================================================================
// Shared resume-ingest primitives used by BOTH applicant intake modes
// (careerplug and sf_forwarded_applicant). The two modes parse different
// input formats — CareerPlug is an email body, SF forward is a subject +
// CTS attachment — but the resume-processing tail is identical:
//   1. Download the PDF bytes from the Composio s3url
//   2. Extract text column-aware (fallback to plain unpdf if that throws)
//   3. Reformat with section-divider separators
//   4. Write to hiring_candidates.resume_extracted_text ONLY when empty
//      (never clobbers hand-corrected text on a re-run)
//
// Both mode parsers call these two functions instead of inlining the block.
// Any future extraction/formatting improvements happen here once.
// =========================================================================

import { extractPdfTextColumnAware, extractPdfTextPlain } from "./pdf_columnar.ts";
import { reformatResumeSeparators } from "./resume_reformat.ts";
import { sb } from "../lib/supabase.ts";

/**
 * Fetch a resume PDF from the given Composio s3url, extract text
 * column-aware (with plain-unpdf fallback), and run through the reformatter.
 *
 * Returns the ready-to-store resume text, or null if any step failed — a
 * null return should be treated as non-fatal: the caller can still land the
 * candidate row with resume_url populated and resume_extracted_text NULL,
 * and Peter can re-run extraction later.
 */
export async function extractResumeTextFromS3url(s3url: string): Promise<string | null> {
  try {
    const r = await fetch(s3url);
    if (!r.ok) {
      console.warn(`resume s3url fetch for text extraction returned HTTP ${r.status}`);
      return null;
    }
    const buf = new Uint8Array(await r.arrayBuffer());

    let raw = "";
    try {
      raw = await extractPdfTextColumnAware(buf);
    } catch (colErr) {
      console.warn(`resume column-aware extract failed; falling back to plain unpdf: ${colErr instanceof Error ? colErr.message : String(colErr)}`);
      try {
        raw = await extractPdfTextPlain(buf);
      } catch (plainErr) {
        console.warn(`resume plain unpdf also failed: ${plainErr instanceof Error ? plainErr.message : String(plainErr)}`);
        return null;
      }
    }

    if (!raw || raw.trim().length === 0) return null;
    return reformatResumeSeparators(raw);
  } catch (e) {
    console.warn("extractResumeTextFromS3url threw (non-fatal):", e);
    return null;
  }
}

/**
 * Write resume_extracted_text to a hiring_candidates row, BUT ONLY when
 * the column is currently NULL or empty. Never clobbers hand-corrected
 * text on a re-run of the same message.
 *
 * Non-fatal on any failure — logs a warning and moves on. The candidate
 * row itself was already inserted upstream, so a failed backfill just
 * means the row keeps resume_extracted_text NULL until the next run.
 */
export async function writeResumeTextIfEmpty(
  candidateId: string | null | undefined,
  resumeText: string | null | undefined,
): Promise<void> {
  if (!candidateId || !resumeText) return;
  try {
    const { error } = await sb
      .from("hiring_candidates")
      .update({ resume_extracted_text: resumeText })
      .eq("id", candidateId)
      .or("resume_extracted_text.is.null,resume_extracted_text.eq.");
    if (error) {
      console.warn(`resume_extracted_text update for ${candidateId} failed: ${error.message}`);
    }
  } catch (e) {
    console.warn(`resume_extracted_text update threw for ${candidateId}:`, e);
  }
}
