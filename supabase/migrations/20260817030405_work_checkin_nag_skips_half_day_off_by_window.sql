-- Peter directive 2026-08-16: the WtW work-checkin nag (team_checkin_tag_missing)
-- should not tag someone who is scheduled off during that specific reminder window.
-- Full-day off already skipped all three nags. This extends it to half-days, mapped
-- to the reminder window that falls inside the off time:
--   morning-off  -> skip morning (8:25) AND midday (12:00) nags (they're not back by noon)
--   afternoon-off -> skip only the EOD (5:00) nag
-- Nothing else changes: WtW requirements, quote/SP totals, and team summaries all read
-- from the separate 'work_display' / totals paths, untouched by this.

CREATE OR REPLACE FUNCTION public.get_expected_teammates(
  p_agency_id uuid,
  p_purpose text,
  p_as_of_date date DEFAULT NULL::date,
  p_checkin_type text DEFAULT NULL::text
)
 RETURNS TABLE(team_id uuid, first_name text, last_name text, nickname text, display_name text, category text, role text, role_level text, role_category text, email_sf text, email_personal text, start_date date)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_today_ct      date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_week_ending   date;
  v_use_snapshot  boolean := false;
  v_time_off_date date := COALESCE(p_as_of_date, (now() AT TIME ZONE 'America/Chicago')::date);
BEGIN
  IF p_as_of_date IS NOT NULL THEN
    v_week_ending := p_as_of_date + ((6 - EXTRACT(dow FROM p_as_of_date)::int + 7) % 7)::int;
    IF v_week_ending < v_today_ct THEN
      SELECT EXISTS (
        SELECT 1
        FROM public.weekly_cpr_team_detail d
        JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
        WHERE r.agency_id = p_agency_id
          AND r.week_ending_date = v_week_ending
          AND d.role_level IS NOT NULL
      ) INTO v_use_snapshot;
    END IF;
  END IF;

  RETURN QUERY
  WITH roster AS (
    SELECT
      d.team_member_id                                   AS team_id,
      d.first_name, d.last_name, d.nickname,
      d.category, d.role, d.role_level, d.role_category,
      d.start_date,
      d.is_active, d.archived_at,
      (COALESCE(d.is_test_user, false) OR COALESCE(t.is_test_user, false))                 AS is_test_user,
      (COALESCE(d.is_admin_backoffice, false) OR COALESCE(t.is_admin_backoffice, false))   AS is_admin_backoffice,
      t.email_sf, t.email_personal,
      t.include_in_team_checkins, t.tag_in_team_reminders, t.include_in_health_checkins,
      t.license_pc, t.license_lh, t.license_ips
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r  ON r.id = d.weekly_cpr_report_id
    JOIN public.team t                ON t.id = d.team_member_id
    WHERE v_use_snapshot
      AND r.agency_id       = p_agency_id
      AND r.week_ending_date = v_week_ending

    UNION ALL

    SELECT
      t.id AS team_id,
      t.first_name, t.last_name, t.nickname,
      t.category, t.role, t.role_level, t.role_category,
      t.start_date,
      t.is_active, t.archived_at, t.is_test_user, t.is_admin_backoffice,
      t.email_sf, t.email_personal,
      t.include_in_team_checkins, t.tag_in_team_reminders, t.include_in_health_checkins,
      t.license_pc, t.license_lh, t.license_ips
    FROM public.team t
    WHERE NOT v_use_snapshot
      AND t.agency_id = p_agency_id
  )
  SELECT
    r.team_id,
    r.first_name, r.last_name, r.nickname,
    COALESCE(NULLIF(r.nickname,''), r.first_name)::text AS display_name,
    r.category, r.role, r.role_level, r.role_category,
    r.email_sf, r.email_personal,
    r.start_date
  FROM roster r
  WHERE r.is_test_user IS NOT TRUE
    AND COALESCE(r.is_admin_backoffice, false) = false
    AND (r.archived_at IS NULL
         OR (p_as_of_date IS NOT NULL AND r.archived_at > p_as_of_date::timestamptz))
    AND (
      -- work_checkin: nag list. Requires an active license and excludes teammates whose
      -- approved time off covers the specific reminder window (full day always; half-day
      -- mapped by p_checkin_type -- morning-off covers morning+midday, afternoon-off covers eod).
      (p_purpose = 'work_checkin'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner'))
        AND COALESCE(r.tag_in_team_reminders, true) = true
        AND (COALESCE(r.license_pc, false)
             OR COALESCE(r.license_lh, false)
             OR COALESCE(r.license_ips, false))
        AND NOT EXISTS (
          SELECT 1 FROM public.time_off_requests tor
          WHERE tor.requester_team_id = r.team_id
            AND tor.agency_id         = p_agency_id
            AND tor.status            = 'approved'
            AND v_time_off_date BETWEEN tor.start_date AND tor.end_date
            AND (
              COALESCE(tor.partial_day, 'none') = 'none'
              OR (p_checkin_type IN ('morning', 'midday') AND tor.partial_day = 'morning')
              OR (p_checkin_type = 'eod' AND tor.partial_day = 'afternoon')
            )
        ))
      OR
      (p_purpose = 'work_display'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner'))
        AND (COALESCE(r.license_pc, false)
             OR COALESCE(r.license_lh, false)
             OR COALESCE(r.license_ips, false)))
      OR
      (p_purpose = 'health_checkin'
        AND (r.include_in_health_checkins = true OR
             (r.include_in_health_checkins IS NULL AND r.category = 'agency')))
      OR
      (p_purpose = 'compensation'
        AND r.category = 'agency'
        AND COALESCE(r.role_level, '') != 'Owner')
      OR
      (p_purpose = 'time_off_participant'
        AND r.category = 'agency'
        AND COALESCE(r.role_level, '') != 'Owner'
        AND r.is_active = true)
      OR
      (p_purpose = 'wtw_am_sales'
        AND r.role_level IN ('Account Manager', 'Unit Manager')
        AND r.role_category = 'Sales'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner')))
      OR
      (p_purpose = 'wtw_am_retention'
        AND r.role_level IN ('Account Manager', 'Unit Manager')
        AND r.role_category = 'Retention'
        AND (r.include_in_team_checkins = true OR
             (r.include_in_team_checkins IS NULL AND r.category = 'agency' AND r.role != 'Owner')))
      OR
      (p_purpose = 'agency_am_um'
        AND r.category = 'agency'
        AND r.role_level IN ('Account Manager', 'Unit Manager'))
      OR
      (p_purpose = 'agency_active_all'
        AND r.category = 'agency'
        AND r.is_active = true)
    );
END;
$function$;

-- Pass the firing reminder's checkin_type through so the half-day window mapping above
-- has something to match against.
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

  -- Pass v_today AND v_checkin_type so get_expected_teammates can apply both the
  -- time-off date filter and the half-day reminder-window mapping.
  FOR v_missing IN
    SELECT et.team_id AS id, et.first_name
    FROM public.get_expected_teammates(p_agency_id, 'work_checkin', v_today, v_checkin_type) et
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

-- Postgres treats adding a trailing parameter as a new overload, not a replace.
-- Drop the stale 3-arg version so every call resolves to the one function above
-- (3-arg callers get p_checkin_type=NULL via the default, which is correct for them).
DROP FUNCTION IF EXISTS public.get_expected_teammates(uuid, text, date);
