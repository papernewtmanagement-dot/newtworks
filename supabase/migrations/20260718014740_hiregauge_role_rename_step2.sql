-- Step 2 of 12: rename cts_sales_* framework functions to cts_sales_outbound_*
-- Bodies byte-equivalent; only function names and callee references change.
-- Server-side pg_get_functiondef eliminates transcription risk.

DO $migration$
DECLARE
  def_os text;
  def_comps text;
  def_comps_adj text;
  def_best_fit text;
  def_all_comps text;
  def_verdict text;
  def_trait_value text;
BEGIN
  -- 1. Create cts_sales_outbound_os from current cts_sales_os body (name-swapped)
  SELECT replace(pg_get_functiondef(oid),
                 'FUNCTION public.cts_sales_os(',
                 'FUNCTION public.cts_sales_outbound_os(')
    INTO def_os
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='cts_sales_os';
  IF def_os IS NULL THEN RAISE EXCEPTION 'cts_sales_os not found'; END IF;
  EXECUTE def_os;

  -- 2. Create cts_sales_outbound_competencies
  SELECT replace(pg_get_functiondef(oid),
                 'FUNCTION public.cts_sales_competencies(',
                 'FUNCTION public.cts_sales_outbound_competencies(')
    INTO def_comps
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='cts_sales_competencies';
  IF def_comps IS NULL THEN RAISE EXCEPTION 'cts_sales_competencies not found'; END IF;
  EXECUTE def_comps;

  -- 3. Create cts_sales_outbound_competencies_adjusted
  SELECT replace(pg_get_functiondef(oid),
                 'FUNCTION public.cts_sales_competencies_adjusted(',
                 'FUNCTION public.cts_sales_outbound_competencies_adjusted(')
    INTO def_comps_adj
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='cts_sales_competencies_adjusted';
  IF def_comps_adj IS NULL THEN RAISE EXCEPTION 'cts_sales_competencies_adjusted not found'; END IF;
  EXECUTE def_comps_adj;

  -- 4. Update cts_best_fit_role: swap its callee from cts_sales_os to cts_sales_outbound_os
  SELECT replace(pg_get_functiondef(oid),
                 'public.cts_sales_os(',
                 'public.cts_sales_outbound_os(')
    INTO def_best_fit
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='cts_best_fit_role';
  IF def_best_fit IS NULL THEN RAISE EXCEPTION 'cts_best_fit_role not found'; END IF;
  EXECUTE def_best_fit;

  -- 5. Update cts_all_competencies: swap 2 callees (comps + comps_adjusted)
  --    comps_adjusted swap MUST come first — otherwise the shorter substring corrupts the longer.
  SELECT replace(
           replace(pg_get_functiondef(oid),
                   'public.cts_sales_competencies_adjusted(',
                   'public.cts_sales_outbound_competencies_adjusted('),
           'public.cts_sales_competencies(',
           'public.cts_sales_outbound_competencies(')
    INTO def_all_comps
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='cts_all_competencies';
  IF def_all_comps IS NULL THEN RAISE EXCEPTION 'cts_all_competencies not found'; END IF;
  EXECUTE def_all_comps;

  -- 6. Update hiregauge_three_construct_verdict: swap 1 callee (comps_adjusted)
  SELECT replace(pg_get_functiondef(oid),
                 'public.cts_sales_competencies_adjusted(',
                 'public.cts_sales_outbound_competencies_adjusted(')
    INTO def_verdict
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='hiregauge_three_construct_verdict';
  IF def_verdict IS NULL THEN RAISE EXCEPTION 'hiregauge_three_construct_verdict not found'; END IF;
  EXECUTE def_verdict;

  -- 7. Update _hiregauge_get_trait_value: swap 1 callee (cts_sales_competencies in 'maintains_high_activity' branch)
  SELECT replace(pg_get_functiondef(oid),
                 'public.cts_sales_competencies(',
                 'public.cts_sales_outbound_competencies(')
    INTO def_trait_value
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace AND proname='_hiregauge_get_trait_value';
  IF def_trait_value IS NULL THEN RAISE EXCEPTION '_hiregauge_get_trait_value not found'; END IF;
  EXECUTE def_trait_value;
END
$migration$;

-- 8. Drop old function names (no more callers reference them after steps 4-7 above)
DROP FUNCTION public.cts_sales_os(integer, integer, integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION public.cts_sales_competencies(integer, integer, integer, integer, integer, integer, integer, integer, integer);
DROP FUNCTION public.cts_sales_competencies_adjusted(uuid);

-- 9. Sanity: verify no dangling references, and confirm no overloads got created
DO $verify$
DECLARE
  offenders text[];
  overload_counts jsonb;
BEGIN
  SELECT array_agg(proname ORDER BY proname)
    INTO offenders
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace
      AND (prosrc ~ 'cts_sales_os\s*\(' OR prosrc ~ 'cts_sales_competencies\s*\(' OR prosrc ~ 'cts_sales_competencies_adjusted\s*\(');
  IF offenders IS NOT NULL AND array_length(offenders, 1) > 0 THEN
    RAISE EXCEPTION 'dangling references to old names found in: %', offenders;
  END IF;

  -- Overload check: each of the 3 new fns should have exactly 1 signature; each of the 3 old fns should have 0
  SELECT jsonb_object_agg(proname, cnt)
    INTO overload_counts
    FROM (
      SELECT proname, count(*)::int AS cnt
      FROM pg_proc
      WHERE pronamespace='public'::regnamespace
        AND proname IN (
          'cts_sales_outbound_os','cts_sales_outbound_competencies','cts_sales_outbound_competencies_adjusted',
          'cts_sales_os','cts_sales_competencies','cts_sales_competencies_adjusted'
        )
      GROUP BY proname
    ) t;
  IF NOT (
      COALESCE((overload_counts->>'cts_sales_outbound_os')::int, 0) = 1
      AND COALESCE((overload_counts->>'cts_sales_outbound_competencies')::int, 0) = 1
      AND COALESCE((overload_counts->>'cts_sales_outbound_competencies_adjusted')::int, 0) = 1
      AND COALESCE((overload_counts->>'cts_sales_os')::int, 0) = 0
      AND COALESCE((overload_counts->>'cts_sales_competencies')::int, 0) = 0
      AND COALESCE((overload_counts->>'cts_sales_competencies_adjusted')::int, 0) = 0
    ) THEN
    RAISE EXCEPTION 'signature check failed: %', overload_counts;
  END IF;
END
$verify$;
