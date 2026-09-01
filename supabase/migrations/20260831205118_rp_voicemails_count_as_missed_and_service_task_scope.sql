-- Peter directive 2026-08-31: voicemails count as missed calls.
--
-- Supersedes the abandoned-only rule applied earlier today. The Telegram daily block
-- (render_daily_calls_block) has always summed abandoned + voicemail into its "Missed"
-- line, so the pay calculation was contradicting the number the team reads every morning.
-- One definition now: a missed call is an inbound call nobody picked up — the caller hung
-- up (abandoned) or left a message (voicemail).
--
-- NOT changed here: the reduction curve is still 0.08 x missed%^2, the handbook's locked
-- value. It was set against the abandoned-only rate, which ran about 4% a week. With
-- voicemails in, the rate runs 7-38%, so the same curve now bites far harder (see the
-- weekly table in the 2026-08-31 build record). Recalibration is Peter's call.
CREATE OR REPLACE FUNCTION public.compute_weekly_retention_points(p_agency_id uuid, p_week_end_date date)
 RETURNS TABLE(team_member_id uuid, first_name text, role_category text, hours_in_office numeric, hour_points numeric, calls_answered integer, call_points numeric, missed_calls integer, missed_pct numeric, reduction_pct numeric, logged_points numeric, derived_points numeric, gross_points numeric, net_points numeric, detail jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- DESIGN RECORD (2026-08-31).
--
-- A missed call is an inbound call nobody picked up: the caller hung up (abandoned) or
-- left a message (voicemail). Same definition the Telegram daily block uses.
--
-- The eGain "Extension Activity" report puts both on the "Not Applicable" (main line) row
-- because the system rings the whole group -- per-desk abandons and voicemails are always
-- 0. So the miss belongs to the team: the team's weekly missed % is applied to every
-- roster member who worked that week (any in-office hours or any answered call). No hours
-- and no calls = no reduction.
--
-- Known limitation: the report is daily totals with no time of day, so a voicemail left
-- after hours counts the same as one left while the phones were open. Week ending
-- 2026-08-01 took 51 voicemails (27 in one day) and lands at 38% missed.
--
-- Reduction curve: 0.08 x missed%^2, capped at 100 (handbook "Missed Calls Shrink Both").
DECLARE
  v_week_end date := public.rp_week_end(p_week_end_date);
  v_week_start date := public.rp_week_end(p_week_end_date) - 6;
  v_hour_val numeric; v_call_val numeric;
  v_team_answered integer := 0;
  v_team_missed integer := 0;
  v_team_abandoned integer := 0;
  v_team_voicemail integer := 0;
  v_team_missed_pct numeric := 0;
BEGIN
  SELECT points INTO v_hour_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='hour_in_office' AND is_active;
  SELECT points INTO v_call_val FROM public.retention_point_values WHERE agency_id=p_agency_id AND activity_key='call_answered' AND is_active;
  v_hour_val := COALESCE(v_hour_val, 0); v_call_val := COALESCE(v_call_val, 0);

  SELECT COALESCE(SUM(CASE WHEN d.team_member_id IS NOT NULL
                           THEN COALESCE(d.answered_calls_external,0) + COALESCE(d.transferred_calls_external,0)
                           ELSE 0 END),0)::integer,
         COALESCE(SUM(COALESCE(d.abandoned_calls_external,0)),0)::integer,
         COALESCE(SUM(COALESCE(d.voicemail_calls_external,0)),0)::integer
    INTO v_team_answered, v_team_abandoned, v_team_voicemail
  FROM public.daily_call_activity d
  WHERE d.agency_id = p_agency_id
    AND d.activity_date BETWEEN v_week_start AND v_week_end;

  v_team_missed := v_team_abandoned + v_team_voicemail;
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
           'team_abandoned_calls', v_team_abandoned,
           'team_voicemail_calls', v_team_voicemail,
           'team_missed_pct', v_team_missed_pct,
           'formula', 'net = (hour_pts + call_pts + logged + derived) x (1 - 0.08 x missed%^2 / 100); missed% = team abandoned + voicemail calls / (team answered + those), applied to everyone who worked the week'
         ) AS detail
  FROM red k
  ORDER BY k.first_name;
END $function$;

COMMENT ON FUNCTION public.compute_weekly_retention_points(uuid, date) IS
  'Weekly Retention Points per roster member. Missed % = team (abandoned + voicemail) / (answered + those), applied to everyone who worked the week. Same missed definition as the Telegram daily block. Reduction = 0.08 x missed%^2, capped at 100.';

-- Service task scope: added and replaced vehicles are sales, not service tasks.
-- A reinstatement after a cancellation is a cancellation saved (7.50), not a 2.00 task.
UPDATE public.retention_point_values
SET description = 'A change you made and finished on the customer''s policy, account, or billing: added or removed a driver, removed a vehicle, changed an address or coverage, took a payment, issued ID cards or proof of insurance, updated a lienholder or mortgagee, changed a beneficiary. Added and replaced vehicles are sales — log those in the sales log, not here. Getting a cancelled policy reinstated is a cancellation saved, which is worth more — log it there. Answering a question, reading a due date or bill amount, taking a message, or transferring the call is not a service task — picking up already earned the call point.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND activity_key = 'service_task';
