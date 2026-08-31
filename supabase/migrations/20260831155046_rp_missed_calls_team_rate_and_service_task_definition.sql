-- Retention Points: missed calls now count (team-level, abandoned calls), and the
-- standard service task gets a real definition.
--
-- Peter directive 2026-08-31:
--   1. "The call report's missed calls aren't being attributed to missed calls. Make sure they are."
--      Supersedes the 2026-08-31 v1 rule "desk-attributed calls only", under which every abandoned
--      call landed on the main-line row (team_member_id NULL) and missed % was permanently 0.
--   2. The standard service task was never defined. "Answering the phone and answering basic
--      questions" does not qualify — that is the call point.

-- ---------------------------------------------------------------------------
-- 1. compute_weekly_retention_points — team miss rate from abandoned calls
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.compute_weekly_retention_points(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, first_name text, role_category text, hours_in_office numeric, hour_points numeric, calls_answered integer, call_points numeric, missed_calls integer, missed_pct numeric, reduction_pct numeric, logged_points numeric, derived_points numeric, gross_points numeric, net_points numeric, detail jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- DESIGN RECORD (2026-08-31, Peter directive: make sure the call report's missed calls count).
--
-- A missed call is an ABANDONED inbound call: it rang, nobody picked up, the caller hung up.
-- Abandons can only happen while the phones are open, so they are a clean miss.
--
-- The eGain "Extension Activity" report puts every abandon on the "Not Applicable" (main line)
-- row because the system rings the whole group — per-desk abandons are always 0. So the miss
-- belongs to the team: the team's weekly missed % is applied to every roster member who worked
-- that week (any in-office hours or any answered call). No hours and no calls = no reduction.
--
-- VOICEMAIL calls are NOT counted. The report is daily totals with no time of day, so a
-- voicemail left after hours (nobody could answer) is indistinguishable from one left while we
-- were open. Counting them would have zeroed the whole team for week ending 2026-08-01
-- (51 voicemails, one Tuesday the phones rolled to voicemail). Revisit when the phone system
-- can timestamp voicemails.
--
-- Reduction curve unchanged: 0.08 × missed%² (handbook "Missed Calls Shrink Both").
DECLARE
  v_week_end date := public.rp_week_end(p_week_end_date);
  v_week_start date := public.rp_week_end(p_week_end_date) - 6;
  v_hour_val numeric; v_call_val numeric;
  v_team_answered integer := 0;
  v_team_missed integer := 0;
  v_team_missed_pct numeric := 0;
BEGIN
  SELECT points INTO v_hour_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='hour_in_office' AND is_active;
  SELECT points INTO v_call_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='call_answered' AND is_active;
  v_hour_val := COALESCE(v_hour_val, 0); v_call_val := COALESCE(v_call_val, 0);

  -- Team-wide phone numbers for the week: answered at any desk, abandoned anywhere (main line included).
  SELECT COALESCE(SUM(CASE WHEN d.team_member_id IS NOT NULL
                           THEN COALESCE(d.answered_calls_external,0) + COALESCE(d.transferred_calls_external,0)
                           ELSE 0 END),0)::integer,
         COALESCE(SUM(COALESCE(d.abandoned_calls_external,0)),0)::integer
    INTO v_team_answered, v_team_missed
  FROM public.daily_call_activity d
  WHERE d.agency_id = p_agency_id
    AND d.activity_date BETWEEN v_week_start AND v_week_end;

  v_team_missed_pct := CASE WHEN v_team_answered + v_team_missed > 0
                            THEN ROUND(100.0 * v_team_missed / (v_team_answered + v_team_missed), 2)
                            ELSE 0 END;

  RETURN QUERY
  WITH roster AS (
    SELECT t.id, t.first_name, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user,false) = false AND COALESCE(t.is_admin_backoffice,false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (t.end_date IS NULL OR t.end_date >= v_week_start)
  ),
  hrs AS (
    SELECT h.team_member_id AS tm, COALESCE(SUM(CASE WHEN h.location = 'in_office' THEN h.hours ELSE 0 END),0)::numeric AS in_office
    FROM public.get_weekly_cpr_hours(p_agency_id, v_week_end) h
    GROUP BY h.team_member_id
  ),
  calls AS (
    SELECT d.team_member_id AS tm,
           COALESCE(SUM(d.answered_calls_external),0) + COALESCE(SUM(d.transferred_calls_external),0) AS answered
    FROM public.daily_call_activity d
    WHERE d.agency_id = p_agency_id AND d.team_member_id IS NOT NULL
      AND d.activity_date BETWEEN v_week_start AND v_week_end
    GROUP BY d.team_member_id
  ),
  logged AS (
    SELECT l.team_member_id AS tm,
           COALESCE(SUM(CASE WHEN l.source = 'manual' THEN l.points ELSE 0 END),0) AS logged_pts,
           COALESCE(SUM(CASE WHEN l.source <> 'manual' THEN l.points ELSE 0 END),0) AS derived_pts,
           jsonb_object_agg(l.activity_key, l.cnt) FILTER (WHERE l.activity_key IS NOT NULL) AS by_key
    FROM (
      SELECT x.team_member_id, x.activity_key, x.source, SUM(x.points) AS points, COUNT(*) AS cnt
      FROM public.retention_activity_log x
      WHERE x.agency_id = p_agency_id AND x.status = 'credited' AND x.credited_week_end_date = v_week_end
      GROUP BY x.team_member_id, x.activity_key, x.source
    ) l
    GROUP BY l.team_member_id
  ),
  calc AS (
    SELECT r.id, r.first_name, r.role_category,
           ROUND(COALESCE(h.in_office,0), 2) AS hours_in_office,
           ROUND(COALESCE(h.in_office,0) * v_hour_val, 2) AS hour_points,
           COALESCE(c.answered,0)::int AS calls_answered,
           ROUND(COALESCE(c.answered,0) * v_call_val, 2) AS call_points,
           (COALESCE(h.in_office,0) > 0 OR COALESCE(c.answered,0) > 0) AS worked,
           COALESCE(lg.logged_pts,0) AS logged_points,
           COALESCE(lg.derived_pts,0) AS derived_points,
           COALESCE(lg.by_key,'{}'::jsonb) AS by_key
    FROM roster r
    LEFT JOIN hrs h ON h.tm = r.id
    LEFT JOIN calls c ON c.tm = r.id
    LEFT JOIN logged lg ON lg.tm = r.id
  ),
  red AS (
    SELECT k.*,
           CASE WHEN k.worked THEN v_team_missed ELSE 0 END AS missed_calls,
           CASE WHEN k.worked THEN v_team_missed_pct ELSE 0 END AS missed_pct,
           CASE WHEN k.worked THEN LEAST(100, ROUND(0.08 * v_team_missed_pct * v_team_missed_pct, 2)) ELSE 0 END AS reduction_pct,
           (k.hour_points + k.call_points + k.logged_points + k.derived_points) AS gross
    FROM calc k
  )
  SELECT k.id, k.first_name, k.role_category,
         k.hours_in_office, k.hour_points, k.calls_answered, k.call_points,
         k.missed_calls::integer, k.missed_pct, k.reduction_pct,
         k.logged_points, k.derived_points,
         ROUND(k.gross, 2) AS gross_points,
         ROUND(k.gross * (1 - k.reduction_pct/100.0), 2) AS net_points,
         jsonb_build_object(
           'week_end_date', v_week_end,
           'values', jsonb_build_object('hour_in_office', v_hour_val, 'call_answered', v_call_val),
           'counts_by_key', k.by_key,
           'worked_this_week', k.worked,
           'team_calls_answered', v_team_answered,
           'team_missed_calls', v_team_missed,
           'team_missed_pct', v_team_missed_pct,
           'formula', 'net = (hour_pts + call_pts + logged + derived) × (1 − 0.08 × missed%² / 100); missed% = team abandoned calls ÷ (team answered + abandoned), applied to everyone who worked the week; voicemails not counted'
         ) AS detail
  FROM red k
  ORDER BY k.first_name;
END $function$;

COMMENT ON FUNCTION public.compute_weekly_retention_points(uuid, date) IS
  'Weekly Retention Points per roster member. Missed % = team abandoned calls / (team answered + abandoned), applied to everyone who worked the week; voicemails not counted (no time-of-day in the phone report). Reduction = 0.08 × missed%².';

-- ---------------------------------------------------------------------------
-- 2. Standard service task — define it so it cannot be "answered the phone"
-- ---------------------------------------------------------------------------
UPDATE public.retention_point_values
SET description = 'A change you made and finished on the customer''s policy, account, or billing: added or removed a vehicle or driver, changed an address or coverage, took a payment, issued ID cards or proof of insurance, updated a lienholder or mortgagee, changed a beneficiary, processed a reinstatement. Answering a question, reading a due date or bill amount, taking a message, or transferring the call is not a service task — picking up already earned the call point.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task';
