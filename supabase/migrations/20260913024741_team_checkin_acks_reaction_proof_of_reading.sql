-- Check-in acknowledgement by emoji reaction (Peter 2026-09-11).
-- The team no longer texts numbers; the numbers come from Production. Proof that
-- a teammate READ the check-in is now a reaction on the check-in message.
-- One row per person per check-in. The reaction lands on the REMINDER message
-- (8:25 / 12:00 / 17:00), which is what tag-missing then nags about at :15.
-- The reminder is deleted when the summary posts, so the ack is recorded here
-- first and survives the delete.

CREATE TABLE IF NOT EXISTS public.team_checkin_acks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  checkin_date date NOT NULL,
  checkin_type text NOT NULL,
  team_id uuid REFERENCES public.team(id) ON DELETE CASCADE,
  telegram_user_id bigint,
  message_id bigint,
  emoji text,
  reacted_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS team_checkin_acks_one_per_person
  ON public.team_checkin_acks (agency_id, checkin_date, checkin_type, team_id);

CREATE INDEX IF NOT EXISTS team_checkin_acks_message
  ON public.team_checkin_acks (message_id);

ALTER TABLE public.team_checkin_acks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS team_checkin_acks_read ON public.team_checkin_acks;
CREATE POLICY team_checkin_acks_read ON public.team_checkin_acks
  FOR SELECT USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

COMMENT ON TABLE public.team_checkin_acks IS
  'One row per teammate per check-in: they reacted to the check-in message, so they read it.';

-- Record (or clear) one reaction. Called from the telegram edge function when a
-- message_reaction update arrives. Matches the message to today''s or yesterday''s
-- check-in reminder; anything else is ignored.
CREATE OR REPLACE FUNCTION public.team_checkin_record_ack(
  p_message_id bigint,
  p_telegram_user_id bigint,
  p_emoji text,
  p_removed boolean DEFAULT false
) RETURNS jsonb
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
    DELETE FROM public.team_checkin_acks
    WHERE agency_id = v_run.agency_id AND checkin_date = v_run.checkin_date
      AND checkin_type = v_run.checkin_type AND team_id = v_team_id;
    RETURN jsonb_build_object('ok', true, 'action', 'cleared',
      'checkin_type', v_run.checkin_type, 'team_id', v_team_id);
  END IF;

  INSERT INTO public.team_checkin_acks (
    agency_id, checkin_date, checkin_type, team_id, telegram_user_id, message_id, emoji, reacted_at)
  VALUES (v_run.agency_id, v_run.checkin_date, v_run.checkin_type, v_team_id,
          p_telegram_user_id, p_message_id, p_emoji, now())
  ON CONFLICT (agency_id, checkin_date, checkin_type, team_id) DO UPDATE
    SET emoji = EXCLUDED.emoji, reacted_at = now(), message_id = EXCLUDED.message_id,
        telegram_user_id = EXCLUDED.telegram_user_id;

  RETURN jsonb_build_object('ok', true, 'action', 'recorded',
    'checkin_type', v_run.checkin_type, 'team_id', v_team_id);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.team_checkin_record_ack(bigint, bigint, text, boolean) TO anon, authenticated, service_role;

-- Who is expected on this check-in and has not reacted yet.
CREATE OR REPLACE FUNCTION public.team_checkin_missing_acks(
  p_agency_id uuid, p_checkin_date date, p_checkin_type text
) RETURNS TABLE(team_id uuid, first_name text)
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT et.team_id, et.first_name
  FROM public.get_expected_teammates(p_agency_id, 'work_checkin', p_checkin_date, p_checkin_type) et
  LEFT JOIN public.team_checkin_acks a
    ON a.agency_id = p_agency_id AND a.checkin_date = p_checkin_date
   AND a.checkin_type = p_checkin_type AND a.team_id = et.team_id
  WHERE a.id IS NULL
  ORDER BY et.first_name;
$function$;

GRANT EXECUTE ON FUNCTION public.team_checkin_missing_acks(uuid, date, text) TO anon, authenticated, service_role;
