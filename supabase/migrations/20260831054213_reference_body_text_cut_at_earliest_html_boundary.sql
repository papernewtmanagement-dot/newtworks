-- Reference emails arrive twice inside one message: a plain-text write-up
-- followed by an HTML copy of the same write-up. body_text keeps the plain
-- half. The first version of that expression looked for exactly one boundary
-- marker, '<div dir="ltr">', because that is where Marie's mail client starts
-- its twin.
--
-- Stephanie's client starts its twin at '<html>' instead, and TWO things went
-- wrong. Where her message contained no '<div dir="ltr">' at all the cut never
-- happened and the fallback stripped tags off the twin rather than removing
-- it, so the write-up appeared twice. Where her forwarded message DID contain
-- '<div dir="ltr">' — 2,404 characters deep inside the twin — the cut landed
-- past the real boundary and left raw markup sitting in the column.
--
-- Fix: cut at the EARLIEST boundary present, not at one named marker. The
-- tag-stripping fallback stays exactly as it was for messages that carry no
-- boundary at all, and it is still only a fallback: it must never run on text
-- that was cut cleanly, because the plain half legitimately contains angle
-- brackets ('<tel:...>', '<https://...>', and the interview scripts' own
-- <APPLICANT> placeholders) that are not markup. That distinction is why this
-- is two branches and not one, and it is the same trap migration
-- 20260822070324 already fixed once.

CREATE OR REPLACE FUNCTION public.reference_body_plaintext(p_body text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  WITH boundary AS (
    SELECT min(pos) AS at
    FROM (VALUES
      (nullif(strpos(p_body, '<html'), 0)),
      (nullif(strpos(p_body, '<HTML'), 0)),
      (nullif(strpos(p_body, '<!DOCTYPE'), 0)),
      (nullif(strpos(p_body, '<!doctype'), 0)),
      (nullif(strpos(p_body, '<body'), 0)),
      (nullif(strpos(p_body, '<div dir="ltr">'), 0))
    ) AS m(pos)
  )
  SELECT CASE
    WHEN (SELECT at FROM boundary) > 1
      THEN btrim(left(p_body, (SELECT at FROM boundary) - 1))
    WHEN p_body ~* '</?(div|span|br|p|a|b|i|u|em|strong|font|table|tr|td|th|ul|ol|li|img|blockquote|h[1-6])[[:space:]/>]'
      THEN btrim(replace(replace(replace(replace(replace(replace(
             regexp_replace(regexp_replace(p_body, '<br[[:space:]]*/?>', E'\n', 'gi'),
                            '<[^>]+>', '', 'g'),
           '&nbsp;', ' '), '&#39;', ''''), '&quot;', '"'), '&lt;', '<'), '&gt;', '>'), '&amp;', '&'))
    ELSE btrim(p_body)
  END;
$fn$;

COMMENT ON FUNCTION public.reference_body_plaintext(text) IS
  'Derives the plain-text half of a reference email. Cuts at the earliest HTML boundary; tag-strips only when no boundary exists. Backs the generated column hiring_candidate_references.body_text.';

-- A generated column expression cannot be altered in place, so the column is
-- dropped and rebuilt. It is derived from body, which is untouched, so nothing
-- is lost. Verified before running: no view, index or constraint depends on it.
ALTER TABLE public.hiring_candidate_references DROP COLUMN IF EXISTS body_text;

ALTER TABLE public.hiring_candidate_references
  ADD COLUMN body_text text
  GENERATED ALWAYS AS (public.reference_body_plaintext(body)) STORED;

COMMENT ON COLUMN public.hiring_candidate_references.body_text IS
  'Plain-text half of the reference email, derived from body. body stays verbatim; this is additive.';
