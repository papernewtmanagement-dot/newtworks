CREATE OR REPLACE FUNCTION public.run_weekly_cpr_auto_send(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  -- Wrapper for Layer A dispatch (run_internal_recipe → this). Delegates to
  -- try_send_weekly_cpr_recap which contains its own eligibility + send logic
  -- AND its own automation_run_log insert (skip/success paths). The generic
  -- log insert automation-runner.ts does after this call is a SECOND row —
  -- kept intentionally (self-logged row has the authoritative detail), but
  -- visibility fix (2026-08-11, see op-rule) makes that second row accurate
  -- instead of always "0 processed / no summary returned."
  v_result := public.try_send_weekly_cpr_recap();
  RETURN v_result || jsonb_build_object(
    'records_processed', CASE WHEN COALESCE((v_result->>'skipped')::boolean, false) THEN 0 ELSE 1 END,
    'output_summary', CASE
      WHEN COALESCE((v_result->>'skipped')::boolean, false) THEN 'Skipped: ' || COALESCE(v_result->>'reason', 'unknown')
      ELSE COALESCE(v_result->>'day', '') || ' auto-send dispatched, success=' ||
        COALESCE(v_result->'send_result'->>'success', 'unknown')
    END
  );
END;
$function$
