-- ============================================================================
-- prefill_weekly_cpr_form(p_agency_id, p_week_ending_date) RETURNS jsonb
-- ============================================================================
-- Idempotent prefill. Ensures one weekly_cpr_team_detail row per active
-- agency-category non-Owner team member for the given week, and fills any
-- NULL fields from programmatic sources:
--   - carryover     ← previous week's `owed` for that team member
--   - {day}_hours   ← SUM(EXTRACT(EPOCH FROM clock_out_at - clock_in_at))/3600
--                     from time_clock_entries for that team member / day
--                     (America/Chicago calendar day)
--   - {day}_location ← MAX(work_location) across that day's entries
-- NEVER overwrites existing non-NULL values. Safe to call repeatedly.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.prefill_weekly_cpr_form(
  p_agency_id uuid,
  p_week_ending_date date
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $func$
DECLARE
  v_report_id          uuid;
  v_prev_week          date := p_week_ending_date - 7;
  v_prev_report_id     uuid;
  v_week_start         date := p_week_ending_date - 6;  -- Sunday of week
  v_inserted_count     int := 0;
  v_filled_carryover   int := 0;
  v_filled_hours       int := 0;
  m                    record;
BEGIN
  -- Ensure the report row exists; create if missing
  SELECT id INTO v_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = p_week_ending_date;

  IF v_report_id IS NULL THEN
    INSERT INTO public.weekly_cpr_reports (agency_id, week_ending_date)
    VALUES (p_agency_id, p_week_ending_date)
    RETURNING id INTO v_report_id;
  END IF;

  -- Find previous week's report (for carryover lookup)
  SELECT id INTO v_prev_report_id
  FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_prev_week;

  -- For each active non-Owner agency-category team member:
  FOR m IN
    SELECT t.id, t.first_name, t.last_name
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.category = 'agency'
      AND t.is_active = true
      AND t.archived_at IS NULL
      AND COALESCE(t.role_level, '') <> 'Owner'
    ORDER BY t.hire_date, t.last_name
  LOOP
    -- Ensure detail row exists (defaults: checklist booleans true, ints 0)
    INSERT INTO public.weekly_cpr_team_detail (
      agency_id, weekly_cpr_report_id, team_member_id,
      carryover, missed, cost, total, paid, owed,
      cpr_reply_done, wrapup_done, inbox_done,
      shareds_done, texts_done, deposits_done, appts_done, tasks_done, cases_done,
      no_fu_task_done, new_opps_done, no_onboarding_done, no_phone_done, bad_data_done
    )
    VALUES (
      p_agency_id, v_report_id, m.id,
      0, 0, 0, 0, 0, 0,
      true, true, true,
      true, true, true, true, true, true,
      true, true, true, true, true
    )
    ON CONFLICT (weekly_cpr_report_id, team_member_id) DO NOTHING;

    -- Backfill carryover from previous week's owed (only if current carryover is 0/null)
    IF v_prev_report_id IS NOT NULL THEN
      UPDATE public.weekly_cpr_team_detail d
      SET carryover = pd.owed
      FROM public.weekly_cpr_team_detail pd
      WHERE d.weekly_cpr_report_id = v_report_id
        AND d.team_member_id = m.id
        AND pd.weekly_cpr_report_id = v_prev_report_id
        AND pd.team_member_id = m.id
        AND pd.owed IS NOT NULL
        AND pd.owed > 0
        AND (d.carryover IS NULL OR d.carryover = 0);
      IF FOUND THEN v_filled_carryover := v_filled_carryover + 1; END IF;
    END IF;

    -- Backfill hours + location for each weekday from time_clock_entries
    -- (only fills NULL columns; never overwrites)
    -- Mon = v_week_start + 1, Tue = +2, Wed = +3, Thu = +4, Fri = +5
    -- (v_week_start is Sunday)
    WITH day_aggs AS (
      SELECT
        DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago') AS work_date,
        ROUND( SUM( EXTRACT(EPOCH FROM (tce.clock_out_at - tce.clock_in_at)) ) / 3600.0, 2 )::numeric AS hours,
        MAX(tce.work_location) AS location
      FROM public.time_clock_entries tce
      WHERE tce.agency_id = p_agency_id
        AND tce.team_member_id = m.id
        AND tce.clock_in_at  >= (v_week_start::timestamp AT TIME ZONE 'America/Chicago')
        AND tce.clock_in_at  <  ((p_week_ending_date + 1)::timestamp AT TIME ZONE 'America/Chicago')
        AND tce.clock_out_at IS NOT NULL
      GROUP BY DATE(tce.clock_in_at AT TIME ZONE 'America/Chicago')
    )
    UPDATE public.weekly_cpr_team_detail d
    SET
      mon_hours    = CASE WHEN d.mon_hours    IS NULL THEN (SELECT hours    FROM day_aggs WHERE work_date = v_week_start + 1) ELSE d.mon_hours END,
      mon_location = CASE WHEN d.mon_location IS NULL THEN (SELECT location FROM day_aggs WHERE work_date = v_week_start + 1) ELSE d.mon_location END,
      tue_hours    = CASE WHEN d.tue_hours    IS NULL THEN (SELECT hours    FROM day_aggs WHERE work_date = v_week_start + 2) ELSE d.tue_hours END,
      tue_location = CASE WHEN d.tue_location IS NULL THEN (SELECT location FROM day_aggs WHERE work_date = v_week_start + 2) ELSE d.tue_location END,
      wed_hours    = CASE WHEN d.wed_hours    IS NULL THEN (SELECT hours    FROM day_aggs WHERE work_date = v_week_start + 3) ELSE d.wed_hours END,
      wed_location = CASE WHEN d.wed_location IS NULL THEN (SELECT location FROM day_aggs WHERE work_date = v_week_start + 3) ELSE d.wed_location END,
      thu_hours    = CASE WHEN d.thu_hours    IS NULL THEN (SELECT hours    FROM day_aggs WHERE work_date = v_week_start + 4) ELSE d.thu_hours END,
      thu_location = CASE WHEN d.thu_location IS NULL THEN (SELECT location FROM day_aggs WHERE work_date = v_week_start + 4) ELSE d.thu_location END,
      fri_hours    = CASE WHEN d.fri_hours    IS NULL THEN (SELECT hours    FROM day_aggs WHERE work_date = v_week_start + 5) ELSE d.fri_hours END,
      fri_location = CASE WHEN d.fri_location IS NULL THEN (SELECT location FROM day_aggs WHERE work_date = v_week_start + 5) ELSE d.fri_location END
    WHERE d.weekly_cpr_report_id = v_report_id
      AND d.team_member_id = m.id;
    IF FOUND THEN v_filled_hours := v_filled_hours + 1; END IF;

    v_inserted_count := v_inserted_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'report_id', v_report_id,
    'team_members_processed', v_inserted_count,
    'carryover_filled_count', v_filled_carryover,
    'hours_rows_filled_count', v_filled_hours,
    'prev_report_found', v_prev_report_id IS NOT NULL
  );
END;
$func$;

COMMENT ON FUNCTION public.prefill_weekly_cpr_form(uuid, date) IS
  'Idempotent prefill for the Weekly CPR form. Creates weekly_cpr_team_detail rows for the team if missing; backfills NULL/zero carryover from prior week''s owed; backfills NULL day-hours/location from time_clock_entries. Safe to call multiple times — never overwrites existing non-NULL values.';

GRANT EXECUTE ON FUNCTION public.prefill_weekly_cpr_form(uuid, date) TO authenticated, anon;
