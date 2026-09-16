-- Same order everywhere: role level first, tenure inside a role level, first name
-- only to break a tie (Peter 2026-09-15).
CREATE OR REPLACE FUNCTION public.render_daily_calls_block(p_agency_id uuid, p_activity_date date)
 RETURNS text LANGUAGE plpgsql STABLE AS $function$
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

  v_out := format(E'📞 Calls %s (in/out/time)\n', to_char(p_activity_date, 'Mon DD')) || v_out;
  IF v_missed > 0 THEN v_out := v_out || format(E'• Missed: %s\n', v_missed); END IF;

  RETURN rtrim(v_out, E'\n');
END;
$function$;

CREATE OR REPLACE FUNCTION public.daily_commits_for_day(p_agency_id uuid, p_date date)
 RETURNS TABLE(team_id uuid, first_name text, display_name text, commit_text text, hit boolean)
 LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $function$
  WITH roster AS (
    SELECT e.team_id, e.first_name::text AS first_name, e.display_name::text AS display_name,
           e.start_date, e.role_level::text AS role_level
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin', p_date, NULL) e
    UNION
    SELECT t.id, t.first_name::text, COALESCE(NULLIF(t.nickname, ''), t.first_name)::text,
           t.start_date, t.role_level::text
    FROM public.daily_commits c
    JOIN public.team t ON t.id = c.team_member_id
    WHERE c.agency_id = p_agency_id AND c.commit_date = p_date
      AND t.archived_at IS NULL AND COALESCE(t.is_test_user, false) = false
  )
  SELECT r.team_id, r.first_name, r.display_name, c.commit_text, c.hit
  FROM roster r
  LEFT JOIN public.daily_commits c
    ON c.team_member_id = r.team_id AND c.agency_id = p_agency_id AND c.commit_date = p_date
  ORDER BY public.role_level_rank(r.role_level), r.start_date NULLS LAST, r.first_name;
$function$;

CREATE OR REPLACE FUNCTION public.team_checkin_missing_acks(p_agency_id uuid, p_checkin_date date, p_checkin_type text)
 RETURNS TABLE(team_id uuid, first_name text)
 LANGUAGE sql STABLE SET search_path TO 'public', 'pg_temp' AS $function$
  SELECT et.team_id, et.first_name
  FROM public.get_expected_teammates(p_agency_id, 'work_checkin', p_checkin_date, p_checkin_type) et
  LEFT JOIN public.team_checkin_acks a
    ON a.agency_id = p_agency_id AND a.checkin_date = p_checkin_date
   AND a.checkin_type = p_checkin_type AND a.team_id = et.team_id
  WHERE a.id IS NULL
  ORDER BY public.role_level_rank(et.role_level), et.start_date NULLS LAST, et.first_name;
$function$;
