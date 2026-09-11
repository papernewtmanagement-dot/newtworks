-- Peter 2026-09-10 (evening):
--  * Morning kickoff opens with the 🌅 emoji again. The "Kickoff in 5!" words stay gone.
--  * WtW header gets a comma: "📈 WtW 10, Sat Sep 12".
--  * Health summary header becomes one line: "<emoji> Health, Mon DD, OT: x/x"
--    where the date is the Saturday the week ends and OT is how many are on time.
--    The separate "On pace" / "Goal hit" footer line is dropped since the header now
--    carries that same count. No blank line under the header, matching the other messages.

-- 1. WtW comma (targeted edit, asserts exactly one match).
DO $mig$
DECLARE d text; n int;
BEGIN
  d := pg_get_functiondef('public.render_team_status_block'::regproc);
  n := (SELECT count(*) FROM regexp_matches(d, $re$v_wtw\.week_of_cycle(\s*)\|\| ' ' \|\| to_char\(v_wtw\.week_ending_saturday$re$, 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'WtW header pattern matched % times, expected 1', n; END IF;
  d := regexp_replace(d, $re$v_wtw\.week_of_cycle(\s*)\|\| ' ' \|\| to_char\(v_wtw\.week_ending_saturday$re$,
                         $rep$v_wtw.week_of_cycle\1|| ', ' || to_char(v_wtw.week_ending_saturday$rep$);
  EXECUTE d;
END
$mig$;

-- 2. Morning kickoff emoji (targeted edit, asserts exactly one match).
DO $mig$
DECLARE d text; n int;
BEGIN
  d := pg_get_functiondef('public.team_checkin_send_reminder'::regproc);
  n := (SELECT count(*) FROM regexp_matches(d, $re$IF v_checkin_type = 'morning' THEN(\s*)v_text := '';$re$, 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'morning opener pattern matched % times, expected 1', n; END IF;
  d := regexp_replace(d, $re$IF v_checkin_type = 'morning' THEN(\s*)v_text := '';$re$,
                         $rep$IF v_checkin_type = 'morning' THEN\1v_text := '🌅 ';$rep$);
  EXECUTE d;
END
$mig$;

-- 3. Health summary header.
CREATE OR REPLACE FUNCTION public.team_health_checkin_compile(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb;
  v_local_time text;
  v_chat_id bigint;
  v_today date;
  v_week_start date;
  v_target int := 5;
  v_text text;
  v_lines text := '';
  v_extra text[] := ARRAY[]::text[];
  v_response jsonb;
  v_message_id bigint;
  v_row record;
  v_at_or_above_target int := 0;
  v_on_pace int := 0;
  v_on_time_threshold int;
  v_responded_count int := 0;
  v_expected_count int := 0;
  v_line text;
  v_progress_bar text;
  v_dow int;
  v_is_saturday boolean;
  v_header text;
  v_is_recovery boolean := false;
  v_can_still_hit boolean;
  v_encouragement_pool text[] := ARRAY[
    'To everyone short of five — the goal is a goal, not a verdict. You showed up, that counts.',
    'Didn''t quite stack five? Even Rocky had off weeks. The training montage continues.',
    'Whoever came up short — five workouts is a tall order, and showing up at all is half the battle.',
    'For the ones who didn''t get there — the couch is undefeated this round, but it doesn''t get the last word.',
    'Off weeks happen to everyone. The work you did still counts.',
    'Didn''t hit five? The streak is just a number — what matters is the next rep.',
    'Anyone short of goal: gravity''s been winning since forever. You got a few back this week. Take the win.',
    'Five''s a stretch goal, not a baseline. Anything north of zero is a deposit in the bank.'
  ];
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, 'health_eve', 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, 'health_eve', 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, 'health_eve', 'compile') THEN
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
  v_week_start := (v_today - (v_dow || ' days')::interval)::date;
  v_is_saturday := (v_dow = 6);
  v_on_time_threshold := GREATEST(0, v_dow - 1);

  PERFORM public.telegram_recover_checkins(v_today, 'health_eve');

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  SELECT count(*)::int INTO v_expected_count
  FROM public.get_expected_teammates(p_agency_id, 'health_checkin');

  FOR v_row IN
    WITH expected AS (
      SELECT team_id, first_name FROM public.get_expected_teammates(p_agency_id, 'health_checkin')
    ),
    hits_calc AS (
      SELECT * FROM public.compute_team_health_weekly_hits(p_agency_id, v_today)
    )
    SELECT e.first_name,
      COALESCE(hc.hits, 0) AS hits,
      COALESCE(hc.days_responded, 0) AS days_responded
    FROM expected e
    LEFT JOIN hits_calc hc ON hc.team_id = e.team_id
    ORDER BY hits DESC NULLS LAST, e.first_name
  LOOP
    v_progress_bar := '';
    FOR i IN 1..v_target LOOP
      IF i <= v_row.hits THEN v_progress_bar := v_progress_bar || '🟩';
      ELSE v_progress_bar := v_progress_bar || '⬜';
      END IF;
    END LOOP;

    -- Can this person still mathematically hit the target this week?
    -- Assumes today's response is already counted in v_row.hits.
    v_can_still_hit := (v_row.hits + (6 - v_dow)) >= v_target;

    IF v_row.hits >= v_target THEN
      v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
        || ' ' || v_progress_bar || '  🎉 goal hit — keep stacking';
      v_at_or_above_target := v_at_or_above_target + 1;
    ELSIF NOT v_can_still_hit THEN
      IF v_is_saturday AND v_row.hits = 0 THEN
        v_line := '• ' || v_row.first_name || ': 0/' || v_target
          || ' ' || v_progress_bar || '  the couch ran the table this week';
      ELSE
        v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
          || ' ' || v_progress_bar || '  each rep counts';
      END IF;
    ELSIF v_row.hits = v_target - 1 AND v_dow = 5 THEN
      v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
        || ' ' || v_progress_bar || '  one more workout';
    ELSIF v_row.hits = 0 AND v_dow >= 4 THEN
      v_line := '• ' || v_row.first_name || ': 0/' || v_target
        || ' ' || v_progress_bar || '  weekend left to make a dent';
    ELSIF v_row.hits = 0 THEN
      v_line := '• ' || v_row.first_name || ': 0/' || v_target
        || ' ' || v_progress_bar || '  early in the week — plenty of room';
    ELSE
      v_line := '• ' || v_row.first_name || ': ' || v_row.hits || '/' || v_target
        || ' ' || v_progress_bar || '  keep going';
    END IF;

    v_lines := v_lines || v_line || E'\n';

    IF v_row.hits >= v_on_time_threshold THEN
      v_on_pace := v_on_pace + 1;
    END IF;
    IF v_row.days_responded > 0 THEN
      v_responded_count := v_responded_count + 1;
    END IF;
  END LOOP;

  -- One-line header: emoji, "Health", the Saturday the week ends, on-time count.
  v_header := CASE WHEN v_is_saturday THEN '🏁' ELSE '💪' END
    || ' Health, ' || to_char(v_week_start + 6, 'Mon DD')
    || ', OT: ' || v_on_pace || '/' || v_expected_count || E'\n';
  v_text := v_header || v_lines;

  IF v_at_or_above_target = v_expected_count AND v_expected_count > 0 THEN
    IF v_is_saturday THEN
      v_extra := v_extra || '🔥 Whole team finished at goal. That''s how a week closes.'::text;
    ELSE
      v_extra := v_extra || '🔥 Whole team at goal. That''s what showing up looks like.'::text;
    END IF;
  ELSIF v_is_saturday THEN
    v_extra := v_extra || v_encouragement_pool[1 + floor(random() * array_length(v_encouragement_pool, 1))::int];
  ELSIF v_dow = 5 THEN
    v_extra := v_extra || 'One day left — Saturday close coming.'::text;
  END IF;

  IF v_is_saturday THEN
    v_extra := v_extra || 'Week''s in the books. Fresh slate tomorrow.'::text;
  END IF;

  IF array_length(v_extra, 1) > 0 THEN
    v_text := v_text || E'\n' || array_to_string(v_extra, E'\n\n');
  END IF;

  v_response := public.telegram_send_message(v_chat_id, v_text);
  IF (v_response->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'Telegram send failed: %', v_response::text;
  END IF;
  v_message_id := (v_response->'result'->>'message_id')::bigint;

  UPDATE public.team_checkin_runs
  SET compile_results_at = now(),
      compile_results_message_id = v_message_id,
      responders_count = v_responded_count,
      expected_count = v_expected_count,
      updated_at = now()
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = 'health_eve';

  RETURN jsonb_build_object('records_processed', v_responded_count,
    'output_summary', format('health_eve compile%s (dow=%s, sat=%s): %s/%s hit goal, %s/%s on time, %s/%s reporting',
      CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END,
      v_dow, v_is_saturday, v_at_or_above_target, v_expected_count,
      v_on_pace, v_expected_count, v_responded_count, v_expected_count));
END;
$function$;