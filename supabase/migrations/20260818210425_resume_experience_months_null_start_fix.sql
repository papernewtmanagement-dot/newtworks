-- Overlap-aware total of documented work months, read from
-- resume_analysis.qualifications.prior_similar_role.roles[].
--
-- Each role written by the resume tenure extractor carries start ("YYYY-MM")
-- and end ("YYYY-MM", or NULL while current). Every calendar month covered
-- by ANY role is counted once, so concurrent jobs (a musician who also held
-- a day job) no longer double-count. Roles without a start date (older
-- hand-written entries for jobs the resume never dated) cannot be placed on
-- the timeline and contribute their tenure_months additively.
--
-- Returns NULL when no role carries usable tenure information — a resume
-- with undated jobs is "experience unknown", not "zero months". Callers must
-- treat NULL as no-adjustment (see _newtworks_role_fit_core, SJT branch).
--
-- Month arithmetic matches the extractor: a job Jun 2022 → Aug 2022 is 2
-- months (end month exclusive), so a range with equal start and end is 0.
-- Mirrors totalWorkMonths() in
-- supabase/functions/document-processor/parsers/resume_tenure_extract.ts —
-- keep the two in sync.
--
-- (Second version, same session: an undated role has no 'start' key at all,
-- so the NOT-regex test must COALESCE to '' or the row silently drops out.)
CREATE OR REPLACE FUNCTION public.resume_experience_months(p_resume_analysis jsonb)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
WITH roles AS (
  SELECT r
  FROM jsonb_array_elements(
    CASE WHEN jsonb_typeof(p_resume_analysis->'qualifications'->'prior_similar_role'->'roles') = 'array'
         THEN p_resume_analysis->'qualifications'->'prior_similar_role'->'roles'
         ELSE '[]'::jsonb END) AS r
),
dated AS (
  SELECT to_date(r->>'start', 'YYYY-MM') AS s,
         COALESCE(
           CASE WHEN (r->>'end') ~ '^\d{4}-\d{2}$' THEN to_date(r->>'end', 'YYYY-MM') END,
           date_trunc('month', now())::date) AS e
  FROM roles
  WHERE (r->>'start') ~ '^\d{4}-\d{2}$'
),
months AS (
  SELECT DISTINCT m
  FROM dated, LATERAL generate_series(s, e - interval '1 month', interval '1 month') AS m
  WHERE e > s
),
undated AS (
  SELECT COALESCE(SUM(GREATEST(0, (r->>'tenure_months')::numeric)), 0) AS mo,
         COUNT(*) AS n
  FROM roles
  WHERE NOT (COALESCE(r->>'start', '') ~ '^\d{4}-\d{2}$')
    AND COALESCE(r->>'tenure_months', '') ~ '^\d+(\.\d+)?$'
)
SELECT CASE
         WHEN (SELECT count(*) FROM dated) = 0 AND (SELECT n FROM undated) = 0 THEN NULL
         ELSE (SELECT count(*) FROM months)::numeric + (SELECT mo FROM undated)
       END;
$$;

COMMENT ON FUNCTION public.resume_experience_months(jsonb) IS
  'Overlap-aware total of documented work months from resume_analysis roles[] (start/end per role, months counted once across concurrent jobs; undated hand-written roles add tenure_months). NULL = experience unknown, never zero.';
