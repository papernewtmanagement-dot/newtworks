-- LOCKED DESIGN FACT: ledger holds 2026-01-01 forward ONLY. 2025 and earlier lives in
-- prior_year_pl, which covers through December 2025. Posting a pre-2026 statement into
-- ledger double-counts it against prior_year_pl.
--
-- The recipe wrapper passed NULL for p_from, so the nightly automation had no floor and
-- would sweep in any pre-2026 statements row present. On 2026-08-09 a verification run
-- did exactly that: 70 December 2025 rows were posted. Removed here, and the floor is
-- now hard-coded in the wrapper so no future nightly run can repeat it.

DELETE FROM public.ledger
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND source = 'statement_gl_writer'
  AND entry_date < '2026-01-01';

CREATE OR REPLACE FUNCTION public.statement_gl_writer_recipe(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Hard 2026-01-01 floor: pre-2026 profit and loss comes from prior_year_pl, never here.
  RETURN public.statement_gl_writer(p_agency_id, NULL::uuid, DATE '2026-01-01', NULL::date, FALSE);
END;
$function$;
