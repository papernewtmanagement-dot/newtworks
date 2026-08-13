-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 20:11:51 UTC (ledger name: write_marketing_bonus_weekly_points_only) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712201151.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- marketing_pool_earned_weekly = just this week's marketing points value (Peter 2026-07-12).
-- Full QTD earned (points + bonus share) still stored in marketing_pool_earned_ytd for reference.
CREATE OR REPLACE FUNCTION public.write_weekly_marketing_bonus(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_report_id      UUID;
  v_quarter_start  DATE;
  v_pool           JSONB;
  v_pool_meta      JSONB;
  v_rows_updated   INT := 0;
BEGIN
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_end_date
  LIMIT 1;

  IF v_report_id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_end_date', p_week_end_date,
      'rows_updated', 0,
      'note', 'no weekly_cpr_reports row exists for this week',
      'written_at', NOW()
    );
  END IF;

  v_quarter_start := date_trunc('quarter', p_week_end_date::timestamp)::date;
  v_pool := public.compute_weekly_marketing_bonus(p_agency_id, p_week_end_date);
  v_pool_meta := jsonb_build_object(
    'basis',    v_pool->'basis',
    'envelope', v_pool->'envelope',
    'spend',    v_pool->'spend',
    'pool',     v_pool->'pool'
  );

  WITH people AS (
    SELECT
      (elem->>'team_member_id')::uuid                          AS team_member_id,
      COALESCE((elem->>'points_qtd')::numeric, 0)              AS points_qtd,
      COALESCE((elem->>'points_this_week')::numeric, 0)        AS points_this_week,
      COALESCE((elem->>'share_pct')::numeric, 0)               AS share_pct,
      COALESCE((elem->>'total_marketing_qtd')::numeric, 0)     AS earned_qtd
    FROM jsonb_array_elements(v_pool->'people') AS elem
  ),
  upd AS (
    UPDATE public.weekly_cpr_team_detail wctd
    SET
      marketing_pool_points_ytd    = p.points_qtd,
      marketing_pool_share_pct     = p.share_pct,
      marketing_pool_earned_ytd    = p.earned_qtd,
      -- Peter 2026-07-12: payroll line item = just this-week points delta (not full QTD earned)
      marketing_pool_earned_weekly = p.points_this_week,
      marketing_pool_diag          = v_pool_meta,
      updated_at = NOW()
    FROM people p
    WHERE wctd.weekly_cpr_report_id = v_report_id
      AND wctd.team_member_id = p.team_member_id
    RETURNING wctd.id
  )
  SELECT COUNT(*) INTO v_rows_updated FROM upd;

  RETURN jsonb_build_object(
    'agency_id',           p_agency_id,
    'week_end_date',       p_week_end_date,
    'weekly_cpr_report_id',v_report_id,
    'rows_updated',        v_rows_updated,
    'pool_qtd',            v_pool_meta->'pool'->>'pool_qtd',
    'envelope',            v_pool_meta->'envelope',
    'written_at',          NOW()
  );
END;
$function$;
