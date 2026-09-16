-- One place that records Marie's answer about Leslie's goals.
--
-- The bot asks on the 1st. Two ways in, both landing here:
--   1. A plain message from Marie in the Paper Newt Management group inside the
--      window after the question goes out. No window, no capture — the bot does
--      not keep everything said in that group.
--   2. /goals <answer>, which works any time, for when she answers later.
--
-- Returns what happened so the caller can say something useful back.
CREATE OR REPLACE FUNCTION public.leslie_monthly_record_reply(
  p_agency_id        uuid,
  p_telegram_user_id bigint,
  p_text             text,
  p_message_id       bigint DEFAULT NULL,
  p_force            boolean DEFAULT false,
  p_window_hours     integer DEFAULT 72
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

  UPDATE public.leslie_monthly_checkin
  SET marie_reply_text = p_text,
      marie_reply_at = now(),
      marie_reply_message_id = p_message_id,
      updated_at = now()
  WHERE id = v_row.id;

  RETURN jsonb_build_object('recorded', true, 'review_month', v_row.review_month);
END;
$function$;

-- Who answers the Leslie goals question. Kept in settings rather than hardcoded
-- so it survives the person changing.
INSERT INTO public.settings (agency_id, setting_key, setting_value)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'leslie_goals_answerer_team_id', 'd7431075-d29f-4833-9503-430945894b04')
ON CONFLICT (agency_id, setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;

-- The chatbot_messages trigger was the old route in. It never fired, because the
-- telegram function drops everything outside the team group, so nothing from the
-- management group ever reached chatbot_messages. Replaced by the call above.
DROP TRIGGER IF EXISTS trg_leslie_capture_reply ON public.chatbot_messages;
DROP FUNCTION IF EXISTS public.leslie_monthly_capture_reply();
