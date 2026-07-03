-- 2026-07-03: get_current_bonus_pool - scalar wrapper for the team bonus pool.
-- Sourced from compute_weekly_comp_residual_pool diagnostics (no duplicate math).
-- Default p_week_end_date = current or next Saturday (Sunday-anchored week ending).
-- Superseded by 20260703205600 (adds smart default + explicit out-of-range error).

CREATE OR REPLACE FUNCTION public.get_current_bonus_pool(
  p_agency_id     uuid,
  p_week_end_date date DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_target_date date;
  v_diag        jsonb;
BEGIN
  v_target_date := COALESCE(
    p_week_end_date,
    CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7)
  );

  SELECT diagnostics INTO v_diag
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_target_date)
  LIMIT 1;

  IF v_diag IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         'no roster rows returned - check active team or pool schedule for this week',
      'computed_at',   now()
    );
  END IF;

  RETURN jsonb_build_object(
    'agency_id',         p_agency_id,
    'week_end_date',     v_target_date,
    'annual_envelope',   (v_diag->>'annual_envelope')::numeric,
    'annual_bonus_pool', (v_diag->>'annual_bonus_pool')::numeric,
    'weekly_bonus_pool', ROUND((v_diag->>'annual_bonus_pool')::numeric / 52.0, 2),
    'team_total_base',   (v_diag->>'team_total_base')::numeric,
    'team_total_comm',   (v_diag->>'team_total_comm')::numeric,
    'team_total_burden', (v_diag->>'team_total_burden')::numeric,
    'pool_basis',        v_diag->'pool_basis',
    'schedule',          v_diag->'schedule',
    'computed_at',       now()
  );
END;
$function$;
