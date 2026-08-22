-- Teaches the overlap-aware experience total about seasonal roles.
--
-- A role the extractor has judged seasonal carries season_months, e.g.
-- [9,10,11] for a Halloween shop written "September 2016 to November 2025".
-- Only those months of each year inside the span are counted, instead of
-- every month between start and end. Read literally that one entry was a
-- 110-month job that swamped every other role on the resume.
--
-- Purely additive: a role without season_months behaves exactly as before,
-- so every existing stored row is unaffected.
CREATE OR REPLACE FUNCTION public.resume_experience_months(p_resume_analysis jsonb)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
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
           date_trunc('month', now())::date) AS e,
         CASE
           WHEN jsonb_typeof(r->'season_months') = 'array'
                AND jsonb_array_length(r->'season_months') > 0
           THEN ARRAY(SELECT x::int FROM jsonb_array_elements_text(r->'season_months') AS x)
         END AS season
  FROM roles
  WHERE (r->>'start') ~ '^\d{4}-\d{2}$'
),
months AS (
  SELECT DISTINCT m
  FROM dated, LATERAL generate_series(s, e - interval '1 month', interval '1 month') AS m
  WHERE e > s
    AND (season IS NULL OR EXTRACT(MONTH FROM m)::int = ANY (season))
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
$function$;
