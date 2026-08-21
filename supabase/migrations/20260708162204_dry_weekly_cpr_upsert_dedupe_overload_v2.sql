-- Pair 3 (Tier 2): drop the 4-arg overload of weekly_cpr_upsert_in_progress.
-- (v2: also cleans up the accidental placeholder overload from v1.)
--
-- Sequence:
--   1) Drop the accidental placeholder team_checkin_compile_results(uuid,date)
--      created when v1 used the wrong signature.
--   2) Rewrite the real team_checkin_compile_results(uuid,uuid) so it calls
--      the 2-arg weekly_cpr_upsert_in_progress. Rest of body verbatim from
--      pg_proc pre-change.
--   3) Drop the 4-arg weekly_cpr_upsert_in_progress overload — no more callers.

-- (1) Clean up the placeholder from v1
DROP FUNCTION IF EXISTS public.team_checkin_compile_results(UUID, DATE);

-- (2) Rewrite the real one with the 2-arg wcuip call
CREATE OR REPLACE FUNCTION public.team_checkin_compile_results(p_agency_id UUID, p_recipe_id UUID)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_dow int;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_type_label text;
  v_block record;
  v_cpr_id uuid;
  v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  -- Recovery-aware DST gate
  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'compile') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to compile');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_dow := extract(dow FROM v_today)::int;

  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  v_type_label := CASE v_checkin_type WHEN 'eod' THEN 'EOD' ELSE initcap(v_checkin_type) END;

  SELECT * INTO v_block FROM public.render_team_status_block(
    p_agency_id, v_today, v_checkin_type,
    '📊 ' || v_type_label || ' Checkin Results'
  );
  v_text := v_block.block_text;

  -- Friday EOD wrapup addendum
  IF v_checkin_type = 'eod' AND v_dow = 5 THEN
    v_text := v_text || E'\n\n━━━━━━━━━━━━━━━━━━━\n'
      || E'📝 Weekly wrapup — email to paper.newt.management@gmail.com:\n\n'
      || E'1. Attach your FIT Scorecard from this week.\n'
      || E'2. Main personal obstacle from this week.\n'
      || E'3. One goal for next week — 1% gain in sales points?\n'
      || E'4. One way to improve office efficiency?\n'
      || E'5. Brags for each teammate.';
  END IF;

  -- Retargeted to 2-arg overload (Tier-2 DRY 2026-07-08); team totals were
  -- dead params in the 4-arg version anyway.
  v_cpr_id := public.weekly_cpr_upsert_in_progress(p_agency_id, v_today);

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      responders_count = v_block.fresh_count,
      expected_count = v_block.expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_block.fresh_count + v_block.carried_count,
    'output_summary', format('%s compile%s: %s/%s reporting; team %s/%s; cpr_id=%s',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_block.fresh_count, v_block.expected_count,
      v_block.team_total_quotes, v_block.team_total_sales, v_cpr_id)
  );
END;
$$;

-- (3) Drop the 4-arg overload — no callers remain
DROP FUNCTION IF EXISTS public.weekly_cpr_upsert_in_progress(UUID, DATE, NUMERIC, NUMERIC);
