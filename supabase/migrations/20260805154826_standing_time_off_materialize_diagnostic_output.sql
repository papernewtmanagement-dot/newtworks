CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.materialize_standing_time_off(p_agency_id, NULL::date, false);

  -- 2026-08-05 fix: the 3-arg function's rich diagnostic (created count,
  -- and WHY each standing preference was or wasn't materialized this week)
  -- was being silently discarded every single week. automation-runner only
  -- reads keys named records_processed / output_summary from the RPC
  -- result; this function's jsonb never had those keys, so every run of
  -- "Standing Time Off Materialize (Sunday)" logged the generic fallback
  -- "INTERNAL recipe completed (no summary returned)" with records_processed
  -- forced to 0 -- even on weeks where rows were correctly created. This is
  -- why John Kostov's missed 2026-07-31 Win-the-Week Friday went undiagnosed:
  -- the run succeeded, but the log carried none of the detail needed to see
  -- who was skipped or why. Mapping the real fields through closes that gap
  -- going forward.
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'created')::int, 0),
    'output_summary', format(
      'week %s-%s (prior Sat %s): won_prior_week=%s, created=%s, skipped(dup=%s trigger=%s personal_min=%s ineligible_role=%s)',
      v_result->>'week_start', v_result->>'week_end', v_result->>'prior_cpr_sat',
      v_result->>'won_prior_week', v_result->>'created', v_result->>'skipped_dup',
      v_result->>'skipped_trigger', v_result->>'skipped_personal_min', v_result->>'skipped_ineligible_role'
    )
  );
END;
$function$;
