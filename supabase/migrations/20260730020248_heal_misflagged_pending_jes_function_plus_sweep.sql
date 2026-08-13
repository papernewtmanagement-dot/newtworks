-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 02:02:48 UTC (ledger name: heal_misflagged_pending_jes_function_plus_sweep) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730020248.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Self-heal function: any JE marked pending_review but with NO lines on *Unclassified / SUSP /
-- UNCL accounts is a mis-flagged JE (past manual line-swaps that forgot to flip status). Flip it.
-- Excludes JEs whose descriptions match Peter's known re-route holds (property taxes).

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
      -- Never auto-heal explicit holds (property tax re-route candidates)
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
    WHERE je.id IN (SELECT id FROM targets)
      AND NOT p_dry_run
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

-- Run the sweep now to catch any misflagged JEs that landed after Pass 3.
SELECT public.heal_misflagged_pending_jes('126794dd-25ff-47d2-a436-724499733365'::uuid, false) AS result;
