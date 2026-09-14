-- Peter 2026-09-14: a text reply in the team group counts as seen, exactly like a
-- thumbs up. Taking a reaction back does NOT undo an acknowledgment that came
-- from text - they did read it, and the words are still sitting in the channel.
ALTER TABLE public.team_checkin_acks
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'reaction';

COMMENT ON COLUMN public.team_checkin_acks.source IS
  'reaction = emoji on the reminder; text = they wrote something in the group while the check-in was open.';

-- One writer for acknowledgments. Everything still lands through here.
CREATE OR REPLACE FUNCTION public.team_checkin_record_ack(p_message_id bigint, p_telegram_user_id bigint, p_emoji text, p_removed boolean DEFAULT false, p_source text DEFAULT 'reaction')
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_run record;
  v_team_id uuid;
BEGIN
  SELECT agency_id, checkin_date, checkin_type INTO v_run
  FROM public.team_checkin_runs
  WHERE reminder_message_id = p_message_id
    AND checkin_date >= (now() AT TIME ZONE 'America/Chicago')::date - 1
  ORDER BY checkin_date DESC
  LIMIT 1;

  IF v_run.agency_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_a_checkin_message');
  END IF;

  SELECT id INTO v_team_id
  FROM public.team
  WHERE agency_id = v_run.agency_id AND telegram_user_id = p_telegram_user_id
  LIMIT 1;

  IF v_team_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'unknown_telegram_user');
  END IF;

  IF p_removed THEN
    -- Only a reaction can be taken back. A text acknowledgment stands.
    DELETE FROM public.team_checkin_acks
    WHERE agency_id = v_run.agency_id AND checkin_date = v_run.checkin_date
      AND checkin_type = v_run.checkin_type AND team_id = v_team_id
      AND source = 'reaction';
    RETURN jsonb_build_object('ok', true, 'action', 'cleared',
      'checkin_type', v_run.checkin_type, 'team_id', v_team_id);
  END IF;

  INSERT INTO public.team_checkin_acks (
    agency_id, checkin_date, checkin_type, team_id, telegram_user_id, message_id, emoji, reacted_at, source)
  VALUES (v_run.agency_id, v_run.checkin_date, v_run.checkin_type, v_team_id,
          p_telegram_user_id, p_message_id, p_emoji, now(), COALESCE(p_source, 'reaction'))
  ON CONFLICT (agency_id, checkin_date, checkin_type, team_id) DO UPDATE
    SET emoji = EXCLUDED.emoji, reacted_at = now(), message_id = EXCLUDED.message_id,
        telegram_user_id = EXCLUDED.telegram_user_id,
        -- text wins and stays: it cannot be undone by a later reaction removal
        source = CASE WHEN public.team_checkin_acks.source = 'text'
                        OR EXCLUDED.source = 'text' THEN 'text' ELSE EXCLUDED.source END;

  RETURN jsonb_build_object('ok', true, 'action', 'recorded',
    'checkin_type', v_run.checkin_type, 'team_id', v_team_id);
END;
$function$;

-- A text message carries no reminder message id, so find the open run and hand
-- off to the one writer above. Never duplicates the ack logic.
CREATE OR REPLACE FUNCTION public.team_checkin_record_ack_from_text(p_agency_id uuid, p_telegram_user_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_message_id bigint;
BEGIN
  SELECT reminder_message_id INTO v_message_id
  FROM public.team_checkin_runs
  WHERE agency_id = p_agency_id
    AND checkin_date = (now() AT TIME ZONE 'America/Chicago')::date
    AND reminder_message_id IS NOT NULL
    AND compile_results_at IS NULL
  ORDER BY reminder_sent_at DESC
  LIMIT 1;

  IF v_message_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_open_checkin');
  END IF;

  RETURN public.team_checkin_record_ack(v_message_id, p_telegram_user_id, NULL, false, 'text');
END;
$function$;