-- Migration: daily_call_activity_and_morning_block
-- Applied: 2026-07-08 (session pre-compact)
--
-- Creates the per-day, per-team-member call activity table + the morning
-- check-in render helper. Data source: eGain Daily Call Log HTML attachments,
-- parsed by the call-log-parser edge function.
--
-- Extension name format from eGain: "First_Last_VAXXXX" where VAXXXX is the
-- 6-char SF code that's also embedded in team.email_sf, e.g.
--   "Cassie_Alves_VAKFNO" -> matches email_sf ILIKE '%.vakfno@%'
-- so team_member_id can be resolved without a new column on team.
--
-- The "Not Applicable" bucket (unassigned queue) is stored with
-- team_member_id=NULL and surfaced separately in the morning render as
-- "Unattached: N abandoned, M voicemail".

CREATE TABLE IF NOT EXISTS public.daily_call_activity (
  id                             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                      uuid NOT NULL REFERENCES public.agencies(id),
  team_member_id                 uuid REFERENCES public.team(id),
  activity_date                  date NOT NULL,
  extension_raw                  text NOT NULL,
  inbound_calls_external         integer NOT NULL DEFAULT 0,
  inbound_talk_time_seconds      integer NOT NULL DEFAULT 0,
  inbound_calls_internal         integer NOT NULL DEFAULT 0,
  inbound_talk_time_internal_s   integer NOT NULL DEFAULT 0,
  answered_calls_external        integer NOT NULL DEFAULT 0,
  abandoned_calls_external       integer NOT NULL DEFAULT 0,
  transferred_calls_external     integer NOT NULL DEFAULT 0,
  voicemail_calls_external       integer NOT NULL DEFAULT 0,
  outbound_calls_external        integer NOT NULL DEFAULT 0,
  outbound_talk_time_seconds     integer NOT NULL DEFAULT 0,
  outbound_calls_internal        integer NOT NULL DEFAULT 0,
  outbound_talk_time_internal_s  integer NOT NULL DEFAULT 0,
  source_document_id             uuid REFERENCES public.documents(id),
  source_gmail_message_id        text,
  created_at                     timestamptz NOT NULL DEFAULT now(),
  updated_at                     timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_daily_call_activity_agency_ext_date
  ON public.daily_call_activity (agency_id, lower(extension_raw), activity_date);

CREATE INDEX IF NOT EXISTS idx_daily_call_activity_member_date
  ON public.daily_call_activity (agency_id, team_member_id, activity_date DESC)
  WHERE team_member_id IS NOT NULL;

ALTER TABLE public.daily_call_activity ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_all_daily_call_activity
  ON public.daily_call_activity FOR ALL TO anon USING (true) WITH CHECK (true);

CREATE POLICY authenticated_all_daily_call_activity
  ON public.daily_call_activity FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- Morning check-in render helper. Returns empty string when no data present.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.render_daily_calls_block(p_agency_id uuid, p_activity_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_out text := '';
  v_row record;
  v_total_in int := 0;
  v_total_out int := 0;
  v_total_answered int := 0;
  v_total_talk_seconds int := 0;
  v_row_count int := 0;
  v_na_in int := 0;
  v_na_abandoned int := 0;
  v_na_voicemail int := 0;
BEGIN
  FOR v_row IN
    SELECT
      t.first_name,
      dca.answered_calls_external,
      dca.inbound_calls_external,
      dca.outbound_calls_external,
      dca.inbound_talk_time_seconds + dca.outbound_talk_time_seconds AS talk_seconds
    FROM public.daily_call_activity dca
    JOIN public.team t ON t.id = dca.team_member_id
    WHERE dca.agency_id = p_agency_id
      AND dca.activity_date = p_activity_date
      AND dca.team_member_id IS NOT NULL
      AND t.is_admin_backoffice = false
    ORDER BY t.start_date NULLS LAST, t.first_name
  LOOP
    v_row_count := v_row_count + 1;
    v_total_in := v_total_in + v_row.inbound_calls_external;
    v_total_out := v_total_out + v_row.outbound_calls_external;
    v_total_answered := v_total_answered + v_row.answered_calls_external;
    v_total_talk_seconds := v_total_talk_seconds + v_row.talk_seconds;
    v_out := v_out
      || format(
        E'  %s: %s in (%s ans) / %s out — %s talk\n',
        v_row.first_name,
        v_row.inbound_calls_external,
        v_row.answered_calls_external,
        v_row.outbound_calls_external,
        CASE
          WHEN v_row.talk_seconds >= 3600
            THEN format('%sh %sm', v_row.talk_seconds / 3600, (v_row.talk_seconds % 3600) / 60)
          ELSE format('%sm', v_row.talk_seconds / 60)
        END
      );
  END LOOP;

  IF v_row_count = 0 THEN
    RETURN '';
  END IF;

  SELECT
    COALESCE(SUM(inbound_calls_external), 0),
    COALESCE(SUM(abandoned_calls_external), 0),
    COALESCE(SUM(voicemail_calls_external), 0)
  INTO v_na_in, v_na_abandoned, v_na_voicemail
  FROM public.daily_call_activity
  WHERE agency_id = p_agency_id
    AND activity_date = p_activity_date
    AND team_member_id IS NULL;

  v_out :=
    format(E'📞 Yesterday''s calls (%s):\n', to_char(p_activity_date, 'Mon DD'))
    || v_out
    || format(
      E'  Team: %s in / %s answered / %s out — %s talk\n',
      v_total_in, v_total_answered, v_total_out,
      CASE
        WHEN v_total_talk_seconds >= 3600
          THEN format('%sh %sm', v_total_talk_seconds / 3600, (v_total_talk_seconds % 3600) / 60)
        ELSE format('%sm', v_total_talk_seconds / 60)
      END
    );

  IF v_na_abandoned + v_na_voicemail > 0 THEN
    v_out := v_out
      || format(
        E'  Unattached: %s abandoned, %s voicemail%s\n',
        v_na_abandoned,
        v_na_voicemail,
        CASE WHEN v_na_in > 0 THEN format(' (of %s ringing)', v_na_in) ELSE '' END
      );
  END IF;

  RETURN v_out;
END;
$function$;
