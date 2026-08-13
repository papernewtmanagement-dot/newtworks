-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 15:08:38 UTC (ledger name: calls_block_use_nickname_display) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709150838.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Use nickname over first_name in calls block for consistency with check-in status block
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
  v_total_talk_seconds int := 0;
  v_row_count int := 0;
  v_missed int := 0;
BEGIN
  FOR v_row IN
    SELECT
      COALESCE(t.nickname, t.first_name) AS display_name,
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
    v_total_talk_seconds := v_total_talk_seconds + v_row.talk_seconds;
    v_out := v_out
      || format(
        E'  %s: %s/%s/%s min\n',
        v_row.display_name,
        v_row.inbound_calls_external,
        v_row.outbound_calls_external,
        v_row.talk_seconds / 60
      );
  END LOOP;

  IF v_row_count = 0 THEN
    RETURN '';
  END IF;

  SELECT COALESCE(SUM(abandoned_calls_external), 0) + COALESCE(SUM(voicemail_calls_external), 0)
  INTO v_missed
  FROM public.daily_call_activity
  WHERE agency_id = p_agency_id
    AND activity_date = p_activity_date
    AND team_member_id IS NULL;

  v_out :=
    format(E'📞 Calls %s (in/out/time)\n', to_char(p_activity_date, 'Mon DD'))
    || v_out
    || format(
      E'  Team: %s/%s/%s min\n',
      v_total_in, v_total_out, v_total_talk_seconds / 60
    );

  IF v_missed > 0 THEN
    v_out := v_out || format(E'  Missed: %s\n', v_missed);
  END IF;

  RETURN v_out;
END;
$function$;
