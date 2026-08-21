-- 1) Patch tag-missing to be SILENT when everyone has already submitted.
--    Old behavior: posted "✅ All checked in!" to Telegram regardless.
--    New behavior: if v_missing_count = 0, skip the send and skip the run-row
--    update entirely. The compile message at :30 still confirms the result.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_input_config jsonb;
  v_checkin_type text;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_text text;
  v_response jsonb;
  v_message_id bigint;
  v_missing record;
  v_missing_tags text := '';
  v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
BEGIN
  SELECT input_config INTO v_input_config
  FROM public.automation_recipes WHERE id = p_recipe_id;

  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF NOT public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time)
    );
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  FOR v_missing IN
    SELECT
      t.id,
      t.first_name,
      tmap.telegram_username,
      tmap.telegram_user_id
    FROM public.team t
    LEFT JOIN public.team_telegram_map tmap
      ON tmap.team_id = t.id AND tmap.agency_id = t.agency_id
    LEFT JOIN public.team_checkins tc
      ON tc.team_id = t.id
      AND tc.agency_id = t.agency_id
      AND tc.checkin_date = v_today
      AND tc.checkin_type = v_checkin_type
    WHERE t.agency_id = p_agency_id
      AND t.archived_at IS NULL
      AND t.is_test_user IS NOT TRUE
      AND (
        t.include_in_team_checkins = true OR
        (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')
      )
      AND COALESCE(t.tag_in_team_reminders, true) = true
      AND tc.id IS NULL
    ORDER BY t.first_name
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    IF v_missing.telegram_username IS NOT NULL THEN
      v_missing_tags := v_missing_tags || '@' || v_missing.telegram_username || ' ';
    ELSE
      v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
    END IF;
  END LOOP;

  -- Silent path: if everyone has already checked in, do NOT send a message
  -- and do NOT update tag_missing_* fields on the run row. Just return.
  IF v_missing_count = 0 THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('%s tag-missing: silent (everyone already in)', v_checkin_type)
    );
  END IF;

  v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;

  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET tag_missing_at = now(),
      tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_date = v_today
    AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object(
    'records_processed', v_missing_count,
    'output_summary', format('%s tag-missing: %s pending', v_checkin_type, v_missing_count)
  );
END;
$function$;

-- 2) Shift midday tag-missing 12:05 → 12:15
UPDATE public.automation_recipes
SET cron_expression = '15 17,18 * * 1-5',
    input_config = jsonb_set(input_config, '{local_time}', '"12:15"'),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_tag_missing'
  AND input_config->>'checkin_type' = 'midday';

-- 3) Shift midday compile 12:15 → 12:30
UPDATE public.automation_recipes
SET cron_expression = '30 17,18 * * 1-5',
    input_config = jsonb_set(input_config, '{local_time}', '"12:30"'),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results'
  AND input_config->>'checkin_type' = 'midday';

-- 4) Shift EOD tag-missing 17:05 → 17:15
UPDATE public.automation_recipes
SET cron_expression = '15 22,23 * * 1-5',
    input_config = jsonb_set(input_config, '{local_time}', '"17:15"'),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_tag_missing'
  AND input_config->>'checkin_type' = 'eod';

-- 5) Shift EOD compile 17:15 → 17:30
UPDATE public.automation_recipes
SET cron_expression = '30 22,23 * * 1-5',
    input_config = jsonb_set(input_config, '{local_time}', '"17:30"'),
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler = 'team_checkin_compile_results'
  AND input_config->>'checkin_type' = 'eod';
