-- Peter directive 2026-07-17: Telegram bot check-ins should exclude
-- (a) fully unlicensed teammates (no P&C, no L&H, no IPS) — e.g. Cassie
-- (b) teammates approved off for the full day (partial_day='none')
--
-- Scope: work_checkin purpose only. Health check-ins untouched.
-- Companion migration switches three time-off functions from work_checkin
-- (semantic mismatch) to time_off_participant (their intended purpose).

CREATE OR REPLACE FUNCTION public.get_expected_teammates(p_agency_id uuid, p_purpose text, p_as_of_date date DEFAULT NULL::date)
 RETURNS TABLE(team_id uuid, first_name text, last_name text, nickname text, display_name text, category text, role text, role_level text, role_category text, email_sf text, email_personal text, start_date date)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_week_ending date;
  v_use_snapshot boolean := false;
  v_time_off_date date;
BEGIN
  IF p_as_of_date IS NOT NULL THEN
    v_week_ending := p_as_of_date + ((6 - EXTRACT(dow FROM p_as_of_date)::int + 7) % 7)::int;
    SELECT EXISTS (
      SELECT 1 
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE r.agency_id = p_agency_id AND r.week_ending_date = v_week_ending
        AND d.role_level IS NOT NULL   -- snapshot populated
    ) INTO v_use_snapshot;
  END IF;

  -- For work_checkin, use the target date (or today if unspecified) to check time-off
  v_time_off_date := COALESCE(p_as_of_date, (now() AT TIME ZONE 'America/Chicago')::date);

  IF v_use_snapshot THEN
    RETURN QUERY
    SELECT
      d.team_member_id AS team_id,
      d.first_name, d.last_name, d.nickname,
      COALESCE(NULLIF(d.nickname, ''), d.first_name) AS display_name,
      d.category, d.role, d.role_level, d.role_category,
      t.email_sf, t.email_personal, d.start_date
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    JOIN public.team t ON t.id = d.team_member_id
    WHERE r.agency_id       = p_agency_id
      AND r.week_ending_date = v_week_ending
      AND COALESCE(d.is_test_user, false) = false
      AND COALESCE(d.is_admin_backoffice, false) = false
      AND (d.archived_at IS NULL OR d.archived_at > p_as_of_date::timestamptz)
      AND (
        (p_purpose = 'work_checkin'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner'))
          AND COALESCE(t.tag_in_team_reminders, true) = true
          -- exclude fully unlicensed teammates
          AND NOT (COALESCE(t.license_pc, false) = false
                   AND COALESCE(t.license_lh, false) = false
                   AND COALESCE(t.license_ips, false) = false)
          -- exclude teammates with an approved full-day time-off covering the target date
          AND NOT EXISTS (
            SELECT 1 FROM public.time_off_requests tor
            WHERE tor.requester_team_id = t.id
              AND tor.agency_id = p_agency_id
              AND tor.status = 'approved'
              AND v_time_off_date BETWEEN tor.start_date AND tor.end_date
              AND COALESCE(tor.partial_day, 'none') = 'none'
          ))
        OR
        (p_purpose = 'health_checkin'
          AND (t.include_in_health_checkins = true OR
               (t.include_in_health_checkins IS NULL AND d.category = 'agency')))
        OR
        (p_purpose = 'compensation'
          AND d.category = 'agency'
          AND COALESCE(d.role_level, '') != 'Owner')
        OR
        (p_purpose = 'time_off_participant'
          AND d.category = 'agency'
          AND COALESCE(d.role_level, '') != 'Owner'
          AND d.is_active = true)
        OR
        (p_purpose = 'wtw_am_sales'
          AND d.role_level IN ('Account Manager', 'Unit Manager')
          AND d.role_category = 'Sales'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner')))
        OR
        (p_purpose = 'wtw_am_retention'
          AND d.role_level IN ('Account Manager', 'Unit Manager')
          AND d.role_category = 'Retention'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND d.category = 'agency' AND d.role != 'Owner')))
        OR
        (p_purpose = 'agency_am_um'
          AND d.category = 'agency'
          AND d.role_level IN ('Account Manager', 'Unit Manager'))
        OR
        (p_purpose = 'agency_active_all'
          AND d.category = 'agency'
          AND d.is_active = true)
      );
  ELSE
    RETURN QUERY
    SELECT
      t.id AS team_id, t.first_name, t.last_name, t.nickname,
      COALESCE(NULLIF(t.nickname, ''), t.first_name) AS display_name,
      t.category, t.role, t.role_level, t.role_category,
      t.email_sf, t.email_personal, t.start_date
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.is_test_user IS NOT TRUE
      AND t.is_admin_backoffice = false
      AND (
        p_as_of_date IS NULL AND t.archived_at IS NULL
        OR p_as_of_date IS NOT NULL AND (t.archived_at IS NULL OR t.archived_at > p_as_of_date::timestamptz)
      )
      AND (
        (p_purpose = 'work_checkin'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner'))
          AND COALESCE(t.tag_in_team_reminders, true) = true
          -- exclude fully unlicensed teammates
          AND NOT (COALESCE(t.license_pc, false) = false
                   AND COALESCE(t.license_lh, false) = false
                   AND COALESCE(t.license_ips, false) = false)
          -- exclude teammates with an approved full-day time-off covering the target date
          AND NOT EXISTS (
            SELECT 1 FROM public.time_off_requests tor
            WHERE tor.requester_team_id = t.id
              AND tor.agency_id = p_agency_id
              AND tor.status = 'approved'
              AND v_time_off_date BETWEEN tor.start_date AND tor.end_date
              AND COALESCE(tor.partial_day, 'none') = 'none'
          ))
        OR
        (p_purpose = 'health_checkin'
          AND (t.include_in_health_checkins = true OR
               (t.include_in_health_checkins IS NULL AND t.category = 'agency')))
        OR
        (p_purpose = 'compensation'
          AND t.category = 'agency'
          AND COALESCE(t.role_level, '') != 'Owner')
        OR
        (p_purpose = 'time_off_participant'
          AND t.category = 'agency'
          AND COALESCE(t.role_level, '') != 'Owner'
          AND t.is_active = true)
        OR
        (p_purpose = 'wtw_am_sales'
          AND t.role_level IN ('Account Manager', 'Unit Manager')
          AND t.role_category = 'Sales'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')))
        OR
        (p_purpose = 'wtw_am_retention'
          AND t.role_level IN ('Account Manager', 'Unit Manager')
          AND t.role_category = 'Retention'
          AND (t.include_in_team_checkins = true OR
               (t.include_in_team_checkins IS NULL AND t.category = 'agency' AND t.role != 'Owner')))
        OR
        (p_purpose = 'agency_am_um'
          AND t.category = 'agency'
          AND t.role_level IN ('Account Manager', 'Unit Manager'))
        OR
        (p_purpose = 'agency_active_all'
          AND t.category = 'agency'
          AND t.is_active = true)
      );
  END IF;
END;
$function$;

-- team_checkin_tag_missing: pass v_today explicitly so time-off filter uses correct date
CREATE OR REPLACE FUNCTION public.team_checkin_tag_missing(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_input_config jsonb; v_checkin_type text; v_local_time text; v_chat_id bigint;
  v_today date; v_text text; v_response jsonb; v_message_id bigint; v_missing record;
  v_missing_tags text := ''; v_missing_ids uuid[] := ARRAY[]::uuid[];
  v_missing_count int := 0; v_is_recovery boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_checkin_type := v_input_config->>'checkin_type';
  v_local_time := v_input_config->>'local_time';

  IF public.team_checkin_is_right_local_time(v_local_time)
     AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder') THEN
    v_is_recovery := false;
  ELSIF public.team_checkin_is_within_recovery_window(v_local_time)
        AND public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'reminder')
        AND NOT public.team_checkin_step_completed(p_agency_id, v_checkin_type, 'tag_missing') THEN
    v_is_recovery := true;
  ELSIF public.team_checkin_is_right_local_time(v_local_time) THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'Skipped: no reminder went out today, nothing to tag');
  ELSE
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('Skipped: wrong-DST cron fire (intended %s CT)', v_local_time));
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  PERFORM public.telegram_recover_checkins(v_today, v_checkin_type);

  SELECT setting_value::bigint INTO v_chat_id FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'telegram_team_group_chat_id';

  -- Pass v_today so get_expected_teammates can apply the time-off date filter.
  FOR v_missing IN
    SELECT et.team_id AS id, et.first_name
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin', v_today) et
    LEFT JOIN public.team_checkins tc ON tc.team_id = et.team_id AND tc.agency_id = p_agency_id
      AND tc.checkin_date = v_today AND tc.checkin_type = v_checkin_type
    WHERE tc.id IS NULL ORDER BY et.first_name
  LOOP
    v_missing_count := v_missing_count + 1;
    v_missing_ids := v_missing_ids || v_missing.id;
    v_missing_tags := v_missing_tags || v_missing.first_name || ' ';
  END LOOP;

  IF v_missing_count = 0 THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', format('%s tag-missing: silent (everyone already in)', v_checkin_type));
  END IF;

  v_text := '⏰ Still need numbers from: ' || trim(v_missing_tags);
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
    'output_summary', format('%s tag-missing%s: %s pending',
      v_checkin_type, CASE WHEN v_is_recovery THEN ' [RECOVERY]' ELSE '' END, v_missing_count));
END;
$function$;

