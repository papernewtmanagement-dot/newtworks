-- Telegram check-in rebuild (Peter spec 2026-09-14), part 1 of 4.
-- Two shared functions so midday and EOD stop being two copies of the same code.

-- 1. One delete-prior helper. Finds the message id in a slot on a check-in run,
--    deletes it from Telegram, and blanks the column so it is never retried.
--    slot: 'reminder' = the check-in message, 'summary' = a compile message,
--    'nag' = the tag-missing nudge.
CREATE OR REPLACE FUNCTION public.team_checkin_delete_message(
  p_agency_id uuid,
  p_chat_id bigint,
  p_checkin_type text,
  p_slot text,
  p_on_date date DEFAULT NULL,
  p_before_date date DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
AS $function$
DECLARE
  v_date date; v_msg bigint; v_floor date;
BEGIN
  IF p_slot NOT IN ('reminder', 'summary', 'nag') THEN
    RAISE EXCEPTION 'team_checkin_delete_message: bad slot %', p_slot;
  END IF;
  IF p_chat_id IS NULL THEN RETURN NULL; END IF;

  -- Telegram only lets a bot delete its own message for 48 hours, so anything
  -- older than a week is not worth an API call.
  v_floor := COALESCE(p_on_date, p_before_date,
                      (now() AT TIME ZONE 'America/Chicago')::date) - 7;

  SELECT r.checkin_date,
         CASE p_slot
           WHEN 'reminder' THEN r.reminder_message_id
           WHEN 'summary'  THEN r.compile_results_message_id
           ELSE r.tag_missing_message_id END
    INTO v_date, v_msg
  FROM public.team_checkin_runs r
  WHERE r.agency_id = p_agency_id
    AND r.checkin_type = p_checkin_type
    AND r.checkin_date >= v_floor
    AND (p_on_date IS NULL OR r.checkin_date = p_on_date)
    AND (p_before_date IS NULL OR r.checkin_date < p_before_date)
    AND CASE p_slot
          WHEN 'reminder' THEN r.reminder_message_id
          WHEN 'summary'  THEN r.compile_results_message_id
          ELSE r.tag_missing_message_id END IS NOT NULL
  ORDER BY r.checkin_date DESC
  LIMIT 1;

  IF v_msg IS NULL THEN RETURN NULL; END IF;

  BEGIN
    PERFORM public.telegram_delete_message(p_chat_id, v_msg);
  EXCEPTION WHEN OTHERS THEN
    -- A failed delete must never stop the message that is about to go out.
    NULL;
  END;

  UPDATE public.team_checkin_runs
  SET reminder_message_id =
        CASE WHEN p_slot = 'reminder' THEN NULL ELSE reminder_message_id END,
      compile_results_message_id =
        CASE WHEN p_slot = 'summary' THEN NULL ELSE compile_results_message_id END,
      tag_missing_message_id =
        CASE WHEN p_slot = 'nag' THEN NULL ELSE tag_missing_message_id END,
      updated_at = now()
  WHERE agency_id = p_agency_id
    AND checkin_type = p_checkin_type
    AND checkin_date = v_date;

  RETURN v_msg;
END;
$function$;

COMMENT ON FUNCTION public.team_checkin_delete_message(uuid, bigint, text, text, date, date) IS
'Single delete-prior helper for every Telegram check-in message. Deletes the message in one slot of one run row and blanks the column so it is not retried. Peter spec 2026-09-14.';


-- 2. One builder for the midday and the EOD message. They differ only by the
--    lead emoji and the two EOD-only links, so both are arguments, not copies.
--    This is the old results template: it IS the message that gets sent at
--    12:00 and at 17:00. There is no separate summary message any more.
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
  v_text := v_block.block_text;

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

  -- The nag at +20 reads team_checkin_acks, so the react line has to be here.
  v_text := v_text || E'\n\n👍 React when you have read this.';

  RETURN QUERY SELECT
    v_text,
    CASE WHEN v_is_eod THEN 'HTML' ELSE NULL END::text,
    v_block.expected_count,
    v_block.fresh_count,
    v_block.team_total_quotes,
    v_block.team_total_sales;
END;
$function$;

COMMENT ON FUNCTION public.team_checkin_build_results_message(uuid, text, date) IS
'Single builder for the midday and EOD Telegram check-in messages. Lead emoji and the two EOD links are the only differences. Peter spec 2026-09-14.';