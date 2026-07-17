// =========================================================================
// parsers/resume_reformat.ts
// =========================================================================
// Adds visual section separators to raw resume text for readability in the
// Newtworks HRPeople UI (whitespace: pre-wrap). Mirrors the DB function
// public._resume_reformat_add_separators() exactly — keep in sync.
//
// Two things happen:
//   1. Extraction artifacts fixed: literal '\n' string (backslash-n) → real
//      newline, and (cid:127) → '•' (Type1 font glyph mapping failure that
//      unpdf leaves in when the font's bullet char isn't unicode-mapped).
//   2. Divider inserted before every recognized section header ("Objective",
//      "Skills", "Experience", "Education", etc — 50+ variants).
//
// Idempotent: input that already contains the divider is returned unchanged,
// so re-running the doc-processor on a re-extracted resume won't stack
// dividers.
// =========================================================================

const KNOWN_HEADERS: ReadonlySet<string> = new Set([
  // summary / objective
  "objective", "career objective",
  "summary", "professional summary", "profile", "profile summary", "about me",
  // experience
  "experience", "work experience", "professional experience",
  "employment history", "relevant experience", "work history",
  // skills
  "skills", "skills & abilities", "skills & competencies", "skills and competencies",
  "skills and abilities", "technical skills", "technical proficiencies",
  "core competencies", "expertise", "key skills",
  "key skills and characteristics", "areas of strength", "courses & skills",
  // education
  "education", "educational background", "education/professional development",
  "education & credentials",
  // certifications / licenses
  "certifications", "licenses", "certifications & licenses",
  "certifications and licenses", "licenses & certifications",
  // other
  "languages", "language",
  "references", "awards", "honors", "awards & recognition",
  "projects", "volunteer experience", "activities",
  "assessments", "contact", "contacts", "contact information",
  "interests", "hobbies", "publications", "affiliations",
  "key achievements", "achievements", "additional information",
  "professional development",
]);

const DIVIDER = "────────────────────────────────────────";

function isSectionHeader(line: string): boolean {
  const s = line.trim();
  if (!s || s.length > 60) return false;
  const clean = s.replace(/:+$/, "").trim();
  return KNOWN_HEADERS.has(clean.toLowerCase());
}

export function reformatResumeSeparators(raw: string): string {
  if (!raw || raw.trim() === "") return raw;
  // Idempotency guard — don't re-process text that already has our divider.
  if (raw.includes(DIVIDER)) return raw;

  let cleaned = raw.replace(/\\n/g, "\n");
  cleaned = cleaned.replace(/\(cid:127\)/g, "•");
  cleaned = cleaned.replace(/\(cid:129\)/g, "•");
  cleaned = cleaned.replace(/\(cid:9679\)/g, "●");

  const lines = cleaned.split("\n");
  const firstNonEmptyIdx = lines.findIndex((l) => l.trim() !== "");

  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === firstNonEmptyIdx) {
      out.push(line);
      continue;
    }
    if (isSectionHeader(line)) {
      while (out.length > 0 && out[out.length - 1].trim() === "") out.pop();
      out.push("");
      out.push(DIVIDER);
      out.push("");
      out.push(line.replace(/:+$/, "").trim());
    } else {
      out.push(line);
    }
  }

  // Collapse runs of 3+ blank lines to 2
  const collapsed: string[] = [];
  let blankRun = 0;
  for (const l of out) {
    if (l.trim() === "") {
      blankRun++;
      if (blankRun <= 2) collapsed.push(l);
    } else {
      blankRun = 0;
      collapsed.push(l);
    }
  }

  return collapsed.join("\n").replace(/^\n+|\n+$/g, "") + "\n";
}
