-- Corrects the fallback branch of body_text, added minutes earlier in
-- 20260822_hiring_candidate_references_body_text_generated.
--
-- THE BUG: the fallback branch fired on `body ~ '<[a-zA-Z][^>]*>'`, meaning "any
-- angle-bracket token". Marie's reference template is full of angle-bracket
-- placeholders that are real content, not markup — <APPLICANT>, <HIM/HER>,
-- <HE/SHE>. On the three live rows the first branch wins, so nothing was
-- damaged. But a reference that arrives as plain text only, with no HTML twin,
-- would have fallen to the fallback branch and had every <APPLICANT> silently
-- deleted from the text Peter reads. Caught because a tag check on the output
-- came back true and the tags turned out to be the template's own placeholders.
--
-- THE FIX: the fallback now tests for a named HTML element rather than for angle
-- brackets, case-insensitively (texticregexeq is IMMUTABLE, so it is legal in a
-- generated column). The tag-stripping regex inside the branch is left broad on
-- purpose — once we know the message really is markup, unwinding everything in
-- angle brackets is right, and that branch does not run for plain-text mail.
--
-- Generated-column expressions cannot be altered in place, so the column is
-- dropped and re-added. It is derived data with no dependents; nothing is lost.

ALTER TABLE public.hiring_candidate_references DROP COLUMN IF EXISTS body_text;

ALTER TABLE public.hiring_candidate_references
  ADD COLUMN body_text text
  GENERATED ALWAYS AS (
    CASE
      WHEN strpos(body, '<div dir="ltr">') > 1
        THEN btrim(left(body, strpos(body, '<div dir="ltr">') - 1))
      WHEN body ~* '</?(div|span|br|p|a|b|i|u|em|strong|font|table|tr|td|th|ul|ol|li|img|blockquote|h[1-6])[[:space:]/>]'
        THEN btrim(
               replace(replace(replace(replace(replace(replace(
                 regexp_replace(
                   regexp_replace(body, '<br[[:space:]]*/?>', E'\n', 'gi'),
                   '<[^>]+>', '', 'g'),
                 '&nbsp;', ' '), '&#39;', ''''), '&quot;', '"'),
                 '&lt;', '<'), '&gt;', '>'), '&amp;', '&')
             )
      ELSE btrim(body)
    END
  ) STORED;

COMMENT ON COLUMN public.hiring_candidate_references.body_text IS
  'Derived plain-text copy of the reference write-up, with the duplicate HTML twin removed. Read this for display and scoring; body keeps the message exactly as received. Angle-bracket placeholders from the reference template (<APPLICANT>, <HIM/HER>) are content and are preserved.';
