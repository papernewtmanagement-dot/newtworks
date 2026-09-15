-- The acknowledgment line has its own function now (20260914183211) because a
-- text reply counts as seen. Call it instead of keeping a second copy of the
-- wording here, and drop the recover call that pointed at a dropped function.
CREATE OR REPLACE FUNCTION public.team_checkin_build_results_message(
  p_agency_id uuid,
  p_checkin_type text,
  p_date date
) RETURNS TABLE(
  message_text text,
  parse_mode text,
  expected_count integer,
  fresh_count integer,
  team_quotes numeric,
  team_sales numeric
)
LANGUAGE plpgsql
AS $function$
DECLARE
  v_is_eod boolean; v_lead text; v_label text;
  v_block record; v_text text; v_commits text; v_votes int;
  v_pfa_url text := 'https://newtworks.vercel.app/pfa';
  v_wrapup_url text := 'https://newtworks.vercel.app/?tab=checklist';
BEGIN
  IF p_checkin_type NOT IN ('midday', 'eod') THEN
    RAISE EXCEPTION 'team_checkin_build_results_message: unsupported checkin_type %',
      p_checkin_type;
  END IF;

  v_is_eod := (p_checkin_type = 'eod');
  v_lead   := CASE WHEN v_is_eod THEN '🌙' ELSE '☀️' END;
  v_label  := CASE WHEN v_is_eod THEN 'EOD' ELSE 'Midday' END;

  -- Kept from the old compile step so the in-progress CPR row still gets made.
  PERFORM public.weekly_cpr_upsert_in_progress(p_agency_id, p_date);

  SELECT * INTO v_block FROM public.render_team_status_block(
    p_agency_id, p_date, p_checkin_type,
    v_lead || ' ' || v_label || ' ' || to_char(p_date, 'Mon DD'));
  v_text := rtrim(v_block.block_text, E'\n');

  IF v_block.encouragement_text IS NOT NULL THEN
    v_text := v_text || E'\n' || v_block.encouragement_text;
  END IF;

  v_commits := public.render_daily_commits_block(p_agency_id, p_date, true, v_is_eod);
  IF v_commits IS NOT NULL THEN
    v_text := v_text || E'\n\n' || v_commits;
  END IF;

  -- EOD-only lines. The wrap-up link runs every day now, not only Friday
  -- (Peter 2026-09-14).
  IF v_is_eod THEN
    v_text := v_text || E'\n\n💰 <a href="' || v_pfa_url
                     || E'">Don''t forget deposit records</a>';
    v_text := v_text || E'\n📝 <a href="' || v_wrapup_url
                     || E'">Don''t forget wrap-up</a>';
  END IF;

  SELECT COUNT(*)::int INTO v_votes
  FROM public.time_off_requests
  WHERE agency_id = p_agency_id AND status = 'voting' AND vote_closes_at > now();
  IF v_votes = 1 THEN
    v_text := v_text || E'\n\n🗳️ Vote Required';
  ELSIF v_votes > 1 THEN
    v_text := v_text || E'\n\n🗳️ Vote Required (' || v_votes::text || ')';
  END IF;

  -- The nag at +20 reads team_checkin_acks, so the acknowledgment line has to be
  -- here. One copy of the wording lives in team_checkin_reminder_ack_line().
  v_text := v_text || E'\n\n' || public.team_checkin_reminder_ack_line();

  RETURN QUERY SELECT
    v_text,
    CASE WHEN v_is_eod THEN 'HTML' ELSE NULL END::text,
    v_block.expected_count,
    v_block.fresh_count,
    v_block.team_total_quotes,
    v_block.team_total_sales;
END;
$function$;


-- Same removal in the nag: Production is the source for quotes and sales now, so
-- there is nothing to re-read out of old group messages.
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0;
  v_run record; v_elapsed numeric; v_stage text;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';

  -- Peter: no morning nags, ever.
  IF v_checkin_type = 'morning' THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: morning never nags');
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  SELECT reminder_sent_at, tag_missing_at, tag_missing_message_id
  INTO v_run
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;

  IF v_run.reminder_sent_at IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no check-in message went out today, nothing to tag');
  END IF;

  v_elapsed := EXTRACT(EPOCH FROM (now() - v_run.reminder_sent_at)) / 60.0;

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_elapsed >= 60 THEN
    v_stage := 'retire';
  ELSIF v_elapsed >= 40
        AND COALESCE(v_run.tag_missing_at, v_run.reminder_sent_at)
            < v_run.reminder_sent_at + INTERVAL '40 minutes' THEN
    v_stage := 'second';
  ELSIF v_elapsed >= 20 AND v_elapsed < 40 AND v_run.tag_missing_at IS NULL THEN
    v_stage := 'first';
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing due at +%s min',
        v_checkin_type, round(v_elapsed)));
  END IF;

  -- Take the standing nag down and post nothing.
  IF v_stage = 'retire' THEN
    IF public.team_checkin_delete_message(
         p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today) IS NOT NULL THEN
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('%s nag: retired at +%s min',
          v_checkin_type, round(v_elapsed)));
    END IF;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag: nothing standing to retire', v_checkin_type));
  END IF;

  FOR v_missing IN
    SELECT m.team_id AS id, m.first_name
    FROM public.team_checkin_missing_acks(p_agency_id, v_today, v_checkin_type) m
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  -- Everyone acknowledged. Take down any standing nag and go quiet.
  IF v_missing_count = 0 THEN
    PERFORM public.team_checkin_delete_message(
      p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today);
    UPDATE public.team_checkin_runs
    SET tag_missing_at = now(), updated_at = now()
    WHERE agency_id = p_agency_id AND checkin_date = v_today AND checkin_type = v_checkin_type;
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s nag (+%s min): silent (everyone acknowledged)',
        v_checkin_type, round(v_elapsed)));
  END IF;

  -- Delete then repost, so the second nag replaces the first.
  PERFORM public.team_checkin_delete_message(
    p_agency_id, v_chat_id, v_checkin_type, 'nag', v_today);

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
    'output_summary', format('%s nag (%s, +%s min): %s have not acknowledged',
      v_checkin_type, v_stage, round(v_elapsed), v_missing_count));
END;
$function$;