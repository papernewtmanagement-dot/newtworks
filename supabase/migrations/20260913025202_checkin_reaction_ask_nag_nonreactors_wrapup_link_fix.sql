-- Peter 2026-09-11: every check-in needs an emoji reaction as proof of reading,
-- and whoever has not reacted gets nagged.
--   :00  reminder  - numbers from Production, ends with the ask for a reaction
--   :15  tag-missing - names whoever has not reacted yet
--   :30  compile   - final numbers, deletes the reminder and the nag
-- The reaction lands on the REMINDER, which is why the nag at :15 works and why
-- team_checkin_record_ack stores the ack before the reminder is deleted.

-- 1. Reminder: ask for the reaction.
DO $do$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_checkin_send_reminder';

  IF position('v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);' in v_src) = 0 THEN
    RAISE EXCEPTION 'team_checkin_send_reminder anchor drifted - not patching';
  END IF;

  v_new := replace(v_src,
    '  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);',
    '  -- Proof of reading (Peter 2026-09-11). The nag at :15 reads team_checkin_acks.' || E'\n' ||
    '  v_text := v_text || E''\n\n👍 React when you have read this.'';' || E'\n\n' ||
    '  v_response := public.telegram_send_message(v_chat_id, v_text, v_parse_mode);');

  EXECUTE v_new;
END
$do$;

-- 2. Tag-missing: nag whoever has not reacted, instead of whoever has not texted numbers.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0; v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_follow_up_window_open(p_agency_id, v_checkin_type, INTERVAL '15 minutes')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'tag_missing')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'compile') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to tag');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  FOR v_missing IN
    SELECT m.team_id AS id, m.first_name
    FROM public.team_checkin_missing_acks(p_agency_id, v_today, v_checkin_type) m
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  IF v_missing_count = 0 THEN
    UPDATE public.team_checkin_runs
    SET tag_missing_at = now(), updated_at = now()
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type
      AND tag_missing_at IS NULL;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing%s: silent (everyone reacted)',
        v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END));
  END IF;

  v_text := '👀 Still need a reaction from: ' || trim(v_missing_tags);
  v_response := public.telegram_send_message(v_chat_id, v_text);

  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET tag_missing_at = now(), tag_missing_message_id = v_message_id,
      tag_missing_team_ids = v_missing_ids, updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  RETURN jsonb_build_object('records_processed', v_missing_count,
    'output_summary', format('%s tag-missing%s: %s have not reacted',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_missing_count));
END;
$function$;

-- 3. Compile: count reactions as the responders, and repoint the Friday wrap-up
--    line. The Daily Wrap-up manual page and the wrap-up email were both deleted
--    2026-09-12; the wrap-up is filled in on the Checklist tab now.
DO $do$
DECLARE v_src text; v_new text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_src
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'team_checkin_compile_results';

  IF position('v_wrapup_url text := ''https://newtworks.vercel.app/processes/1590689841'';' in v_src) = 0
     OR position('responders_count = v_block.fresh_count,' in v_src) = 0
     OR position('📝 Weekly wrapup' in v_src) = 0 THEN
    RAISE EXCEPTION 'team_checkin_compile_results anchors drifted - not patching';
  END IF;

  v_new := replace(v_src,
    'v_wrapup_url text := ''https://newtworks.vercel.app/processes/1590689841'';',
    'v_wrapup_url text := ''https://newtworks.vercel.app/?tab=checklist'';');

  v_new := replace(v_new,
    E'    v_text := v_text || E''\\n\\n📝 Weekly wrapup — email paper.newt.management@gmail.com. ''\n      || E''What to include: <a href="'' || v_wrapup_url || E''">Daily Wrap-up</a>'';',
    E'    v_text := v_text || E''\\n\\n📝 Weekly wrap-up — fill it in on the ''\n      || E''<a href="'' || v_wrapup_url || E''">Checklist tab</a>'';');

  v_new := replace(v_new,
    '      responders_count = v_block.fresh_count,',
    '      responders_count = (SELECT count(*)::int FROM public.team_checkin_acks a' || E'\n' ||
    '        WHERE a.agency_id = p_agency_id AND a.checkin_date = v_today' || E'\n' ||
    '          AND a.checkin_type = v_checkin_type),');

  EXECUTE v_new;
END
$do$;
