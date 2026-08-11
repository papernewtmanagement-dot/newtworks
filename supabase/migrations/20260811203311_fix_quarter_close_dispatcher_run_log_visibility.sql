CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards_dispatcher(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today_ct date;
  v_cycle_end date;
  v_result jsonb;
BEGIN
  v_today_ct := (now() AT TIME ZONE 'America/Chicago')::date;
  v_cycle_end := (public.current_cycle_info(p_agency_id, v_today_ct)).cycle_end;

  -- Only run on quarter-close Saturday. Cron fires every Sunday 04:59 UTC (~Sat 23:59 CT),
  -- so v_today_ct at fire time is Saturday. If Saturday != cycle_end, skip.
  IF v_today_ct != v_cycle_end THEN
    RETURN jsonb_build_object(
      'skipped', true,
      'reason', 'not quarter-close week',
      'today_ct', v_today_ct,
      'cycle_end', v_cycle_end,
      'recipe_id', p_recipe_id,
      -- Visibility fix (2026-08-11): see op-rule on automation_run_log blind logging.
      'records_processed', 0,
      'output_summary', 'Skipped: not quarter-close week (today=' || v_today_ct || ', cycle_end=' || v_cycle_end || ')'
    );
  END IF;

  v_result := public.quarter_close_prize_cart_and_leaderboards(p_agency_id, v_today_ct);
  RETURN v_result || jsonb_build_object(
    'records_processed', COALESCE((v_result->>'prizes_carried')::int, 0),
    'output_summary', 'Quarter closed: ' || COALESCE((v_result->>'prizes_carried')::text, '0') || ' prize(s) carried, budget $' ||
      COALESCE(v_result->>'next_quarter_budget_dollars', '0') || ', available $' ||
      COALESCE(v_result->>'available_budget_dollars', '0')
  );
END;
$function$
