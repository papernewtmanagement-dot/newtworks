-- Reference intake: derived plain-text copy of the reference write-up.
--
-- PROBLEM (found 2026-08-22): every reference row stores the write-up TWICE.
-- Marie's mail client sends a plain-text part and an HTML part carrying the same
-- content, and the ingest stores whatever Composio hands back as the message
-- text, which is both parts concatenated. All three live rows are ~50% duplicate
-- markup (3760/4848/4291 chars stored, 1967/2531/2254 of that a marked-up twin).
-- Left alone this shows raw tags on the candidate page and would feed any future
-- scoring pass the same reference twice.
--
-- WHY A GENERATED COLUMN RATHER THAN A PARSER FIX:
--   1. reference_ingest.ts's own design record states "the body IS the reference;
--      Peter reads it verbatim" — so `body` must keep holding the message exactly
--      as received. This is additive; nothing stored is moved or overwritten.
--   2. Derived-and-stored means it cannot drift from `body`, and it applies to
--      every future row without depending on which code path wrote it. A parser
--      fix would cover only the one path, and would need a document-processor
--      redeploy (which resets verify_jwt on every deploy).
--   3. Deterministic, no language model — consistent with the intake design
--      record's standing bar for this path.
--
-- The HTML twin always opens with the mail client's own wrapper div. Where that
-- marker appears after some plain text, the plain text before it is the whole
-- write-up. Where a message arrives HTML-only (no plain part), tags are unwound
-- and the common entities decoded, &amp; last so nothing double-decodes.

ALTER TABLE public.hiring_candidate_references
  ADD COLUMN IF NOT EXISTS body_text text
  GENERATED ALWAYS AS (
    CASE
      WHEN strpos(body, '<div dir="ltr">') > 1
        THEN btrim(left(body, strpos(body, '<div dir="ltr">') - 1))
      WHEN body ~ '<[a-zA-Z][^>]*>'
        THEN btrim(
               replace(replace(replace(replace(replace(replace(
                 regexp_replace(
                   regexp_replace(body, '<br[[:space:]]*/?>', E'\n', 'g'),
                   '<[^>]+>', '', 'g'),
                 '&nbsp;', ' '), '&#39;', ''''), '&quot;', '"'),
                 '&lt;', '<'), '&gt;', '>'), '&amp;', '&')
             )
      ELSE btrim(body)
    END
  ) STORED;

COMMENT ON COLUMN public.hiring_candidate_references.body_text IS
  'Derived plain-text copy of the reference write-up, with the duplicate HTML twin removed. Read this for display and scoring; body keeps the message exactly as received.';
