CREATE OR REPLACE FUNCTION public.render_daily_calls_block(p_agency_id uuid, p_activity_date date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_out text := ''; v_row record; v_row_count int := 0; v_missed int := 0;
BEGIN
  FOR v_row IN
    SELECT COALESCE(t.nickname, t.first_name) AS display_name,
      dca.inbound_calls_external, dca.outbound_calls_external,
      dca.inbound_talk_time_seconds + dca.outbound_talk_time_seconds AS talk_seconds
    FROM public.daily_call_activity dca
    JOIN public.team t ON t.id = dca.team_member_id
    WHERE dca.agency_id = p_agency_id
      AND dca.activity_date = p_activity_date
      AND dca.team_member_id IS NOT NULL
      AND t.is_admin_backoffice = false
      -- 2026-10-05: only people on the team that day. John left 2026-09-01, but calls made
      -- from his old phone login on Oct 1 and 2 still matched to him by name.
      AND (t.end_date IS NULL OR t.end_date >= p_activity_date)
    ORDER BY public.role_level_rank(t.role_level), t.start_date NULLS LAST, t.first_name
  LOOP
    v_row_count := v_row_count + 1;
    v_out := v_out || format(E'• %s: %s/%s/%s min\n',
      v_row.display_name, v_row.inbound_calls_external,
      v_row.outbound_calls_external, v_row.talk_seconds / 60);
  END LOOP;

  IF v_row_count = 0 THEN RETURN ''; END IF;

  SELECT COALESCE(SUM(abandoned_calls_external), 0) + COALESCE(SUM(voicemail_calls_external), 0)
  INTO v_missed
  FROM public.daily_call_activity
  WHERE agency_id = p_agency_id AND activity_date = p_activity_date AND team_member_id IS NULL;

  v_out := E'📞 Calls (in/out/time)\n' || v_out;
  IF v_missed > 0 THEN v_out := v_out || format(E'• Missed: %s\n', v_missed); END IF;

  RETURN rtrim(v_out, E'\n');
END;
$function$;
