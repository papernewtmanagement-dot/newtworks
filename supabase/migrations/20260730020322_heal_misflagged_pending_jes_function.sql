-- Self-heal function for misflagged pending JEs.
-- Past manual line-swap sessions (chat_backfill_*, ad-hoc reclassifications) sometimes updated
-- journal_lines.account_id from *Unclassified/SUSP to a target COA WITHOUT flipping
-- journal_entries.classification_status. Pass 3 caught 24 of these; this heals future recurrences.

CREATE OR REPLACE FUNCTION public.heal_misflagged_pending_jes(
  p_agency_id uuid,
  p_dry_run boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_healed int := 0;
BEGIN
  WITH pending AS (
    SELECT je.id FROM public.journal_entries je
    WHERE je.agency_id = p_agency_id AND je.classification_status = 'pending_review'
  ),
  je_has_susp AS (
    SELECT DISTINCT je.id FROM public.journal_entries je
    JOIN public.journal_lines jl ON jl.journal_entry_id = je.id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE je.id IN (SELECT id FROM pending)
      AND (coa.account_name = '*Unclassified' OR coa.account_code LIKE '%SUSP%' OR coa.account_code LIKE '%UNCL%')
  ),
  targets AS (
    SELECT p.id FROM pending p
    WHERE p.id NOT IN (SELECT id FROM je_has_susp)
      AND p.id NOT IN (
        SELECT je.id FROM public.journal_entries je
        WHERE je.description ILIKE '%JP Bexar%' OR je.description ILIKE '%COMAL COUNTY%'
      )
  ),
  upd AS (
    UPDATE public.journal_entries je
    SET classification_status = 'classified',
        classified_by = COALESCE(je.classified_by, 'heal_misflagged_pending_jes'),
        classified_at = COALESCE(je.classified_at, NOW())
    WHERE je.id IN (SELECT id FROM targets) AND NOT p_dry_run
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_healed
  FROM (
    SELECT CASE WHEN p_dry_run
      THEN (SELECT COUNT(*) FROM targets)
      ELSE (SELECT COUNT(*) FROM upd)
    END AS n
  ) x, generate_series(1, x.n);

  RETURN jsonb_build_object('ok', TRUE, 'dry_run', p_dry_run, 'healed', v_healed);
END;
$$;
