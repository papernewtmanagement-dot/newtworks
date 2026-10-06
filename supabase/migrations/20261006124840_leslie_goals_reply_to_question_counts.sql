-- Leslie monthly goals: a Telegram reply to the question counts whenever it comes.
-- The bot asks "Reply here." A reply to that exact message is an answer, so it
-- is recorded on that month's row without the window. A plain message from
-- Marie still has to land inside the window; /goals (p_force) still skips it.
DROP FUNCTION IF EXISTS public.leslie_monthly_record_reply(uuid, bigint, text, bigint, boolean, integer);

CREATE OR REPLACE FUNCTION public.leslie_monthly_record_reply(
  p_agency_id uuid,
  p_telegram_user_id bigint,
  p_text text,
  p_message_id bigint DEFAULT NULL::bigint,
  p_force boolean DEFAULT false,
  p_window_hours integer DEFAULT 72,
  p_reply_to_message_id bigint DEFAULT NULL::bigint
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_marie_team_id uuid;
  v_speaker       uuid;
  v_row           public.leslie_monthly_checkin%ROWTYPE;
  v_via           text;
BEGIN
  IF p_text IS NULL OR btrim(p_text) = '' THEN
    RETURN jsonb_build_object('recorded', false, 'reason', 'empty_text');
  END IF;

  SELECT setting_value::uuid INTO v_marie_team_id
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'leslie_goals_answerer_team_id';

  SELECT t.id INTO v_speaker
  FROM public.team t
  WHERE t.agency_id = p_agency_id AND t.telegram_user_id = p_telegram_user_id;

  IF v_speaker IS NULL OR v_marie_team_id IS NULL OR v_speaker <> v_marie_team_id THEN
    RETURN jsonb_build_object('recorded', false, 'reason', 'not_the_answerer');
  END IF;

  -- A reply to the question itself answers that month, whenever it comes.
  IF p_reply_to_message_id IS NOT NULL THEN
    SELECT * INTO v_row
    FROM public.leslie_monthly_checkin c
    WHERE c.agency_id = p_agency_id
      AND c.sent_message_id = p_reply_to_message_id
      AND c.marie_reply_text IS NULL
    ORDER BY c.sent_at DESC
    LIMIT 1;
    IF v_row.id IS NOT NULL THEN
      v_via := 'reply_to_question';
    END IF;
  END IF;

  IF v_row.id IS NULL THEN
    SELECT * INTO v_row
    FROM public.leslie_monthly_checkin c
    WHERE c.agency_id = p_agency_id
      AND c.sent_at IS NOT NULL
      AND c.marie_reply_text IS NULL
    ORDER BY c.sent_at DESC
    LIMIT 1;

    IF v_row.id IS NULL THEN
      RETURN jsonb_build_object('recorded', false, 'reason', 'nothing_waiting');
    END IF;

    IF NOT p_force AND now() - v_row.sent_at > make_interval(hours => p_window_hours) THEN
      RETURN jsonb_build_object('recorded', false, 'reason', 'outside_window',
                                'review_month', v_row.review_month,
                                'window_hours', p_window_hours);
    END IF;
    v_via := CASE WHEN p_force THEN 'goals_command' ELSE 'in_window' END;
  END IF;

  UPDATE public.leslie_monthly_checkin
  SET marie_reply_text = p_text,
      marie_reply_at = now(),
      marie_reply_message_id = p_message_id,
      updated_at = now()
  WHERE id = v_row.id;

  RETURN jsonb_build_object('recorded', true, 'review_month', v_row.review_month, 'via', v_via);
END;
$function$;

REVOKE ALL ON FUNCTION public.leslie_monthly_record_reply(uuid, bigint, text, bigint, boolean, integer, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.leslie_monthly_record_reply(uuid, bigint, text, bigint, boolean, integer, bigint) TO service_role;

