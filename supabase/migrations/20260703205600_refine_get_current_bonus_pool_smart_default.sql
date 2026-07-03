-- 2026-07-03: refine get_current_bonus_pool default behavior
-- If p_week_end_date is NULL and the computed current-week Saturday has no schedule row,
-- fall back to the first upcoming scheduled week (so calls with no args always return meaningful numbers).
-- Explicit p_week_end_date is not second-guessed - returns clear error if invalid.

CREATE OR REPLACE FUNCTION public.get_current_bonus_pool(
  p_agency_id     uuid,
  p_week_end_date date DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_target_date  date;
  v_diag         jsonb;
  v_schedule_pct numeric;
BEGIN
  -- Resolve target date
  IF p_week_end_date IS NULL THEN
    -- Default: current-or-next Saturday (week ending, Sunday-anchored week)
    v_target_date := CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7);
    -- If that Saturday has no schedule row, bump to first upcoming scheduled week
    IF NOT EXISTS (
      SELECT 1 FROM public.team_comp_pool_schedule
      WHERE agency_id = p_agency_id AND week_end_date = v_target_date
    ) THEN
      SELECT MIN(week_end_date) INTO v_target_date
      FROM public.team_comp_pool_schedule
      WHERE agency_id = p_agency_id AND week_end_date >= CURRENT_DATE;
    END IF;
  ELSE
    v_target_date := p_week_end_date;
  END IF;

  -- If still no schedule row (e.g. explicit past date or after plan end), return clear error
  SELECT pool_pct INTO v_schedule_pct
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id AND week_end_date = v_target_date;

  IF v_schedule_pct IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         format('no team_comp_pool_schedule row for week ending %s (plan window: check public.team_comp_pool_schedule)', v_target_date),
      'computed_at',   now()
    );
  END IF;

  -- Pull first row's diagnostics (envelope/pool/team totals are constant across rows)
  SELECT diagnostics INTO v_diag
  FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_target_date)
  LIMIT 1;

  IF v_diag IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id',     p_agency_id,
      'week_end_date', v_target_date,
      'error',         'no roster rows returned - check active team',
      'computed_at',   now()
    );
  END IF;

  RETURN jsonb_build_object(
    'agency_id',         p_agency_id,
    'week_end_date',     v_target_date,
    'annual_envelope',   (v_diag->>'annual_envelope')::numeric,
    'annual_bonus_pool', ROUND((v_diag->>'annual_bonus_pool')::numeric, 2),
    'weekly_bonus_pool', ROUND((v_diag->>'annual_bonus_pool')::numeric / 52.0, 2),
    'team_total_base',   (v_diag->>'team_total_base')::numeric,
    'team_total_comm',   ROUND((v_diag->>'team_total_comm')::numeric, 2),
    'team_total_burden', ROUND((v_diag->>'team_total_burden')::numeric, 2),
    'pool_basis',        v_diag->'pool_basis',
    'schedule',          v_diag->'schedule',
    'computed_at',       now()
  );
END;
$function$;
