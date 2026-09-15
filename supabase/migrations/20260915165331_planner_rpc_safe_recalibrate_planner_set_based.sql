-- recalibrate_planner rewritten set-based. No CREATE TEMP TABLE, so PostgREST can call it.
-- Two fixes carried in the same rewrite:
--   1. The week bucket was Monday-anchored (date_trunc('week', ...)). The agency runs
--      Sunday to Saturday on every week-bounded number, so a closure on Sunday was
--      landing in the previous week's bucket. Now anchored on Sunday.
--   2. The note column said "Applied." even on a dry run. It now tells the truth.
CREATE OR REPLACE FUNCTION public.recalibrate_planner(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_weeks integer DEFAULT 8,
  p_apply boolean DEFAULT false
)
RETURNS TABLE(who text, weeks_measured integer, avg_hours_finished numeric, current_budget numeric,
              suggested_budget numeric, carry_rate numeric, note text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_carry numeric; v_mult numeric;
BEGIN
  SELECT ROUND(AVG(weeks_carried),2) INTO v_carry
    FROM tasks WHERE agency_id=p_agency_id AND status='open' AND week_of IS NOT NULL;
  v_carry := COALESCE(v_carry,0);

  -- Every extra carried week means the estimates were light. Nudge the multiplier, cap the move.
  v_mult := LEAST(2.00, GREATEST(0.60, 1.00 + (v_carry * 0.15)));

  IF p_apply THEN
    WITH done AS (
      SELECT t.assigned_to, u.full_name,
             (date_trunc('week', t.completed_at + interval '1 day')::date - 1) AS wk,
             SUM(COALESCE(t.estimated_hours,0)) AS hrs
        FROM tasks t JOIN users u ON u.id=t.assigned_to
       WHERE t.agency_id=p_agency_id AND t.status IN ('closed','completed')
         AND t.completed_at >= CURRENT_DATE - (p_weeks*7)
       GROUP BY 1,2,3
    ),
    cal AS (
      SELECT full_name, assigned_to, count(*)::int AS wks, ROUND(AVG(hrs),2) AS avg_hrs
        FROM done GROUP BY 1,2
    )
    UPDATE task_scoring_rules s
       SET hours_value = c.avg_hrs, updated_at = now(),
           notes = 'Recalibrated '||CURRENT_DATE||' from '||c.wks||' weeks of real closures.'
      FROM cal c
     WHERE s.agency_id=p_agency_id AND s.rule_kind='setting'
       AND s.match_pattern = 'weekly_hours_'||lower(split_part(c.full_name,' ',1))
       AND c.wks >= 4;

    UPDATE task_scoring_rules SET hours_value=v_mult, updated_at=now()
     WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='planning_multiplier';
  END IF;

  RETURN QUERY
  WITH done AS (
    SELECT t.assigned_to, u.full_name,
           (date_trunc('week', t.completed_at + interval '1 day')::date - 1) AS wk,
           SUM(COALESCE(t.estimated_hours,0)) AS hrs
      FROM tasks t JOIN users u ON u.id=t.assigned_to
     WHERE t.agency_id=p_agency_id AND t.status IN ('closed','completed')
       AND t.completed_at >= CURRENT_DATE - (p_weeks*7)
     GROUP BY 1,2,3
  ),
  cal AS (
    SELECT full_name, assigned_to, count(*)::int AS wks, ROUND(AVG(hrs),2) AS avg_hrs
      FROM done GROUP BY 1,2
  )
  SELECT c.full_name::text, c.wks, c.avg_hrs,
         COALESCE((SELECT s.hours_value FROM task_scoring_rules s
                    WHERE s.agency_id=p_agency_id AND s.rule_kind='setting'
                      AND s.match_pattern='weekly_hours_'||lower(split_part(c.full_name,' ',1))),0),
         c.avg_hrs, v_carry,
         CASE WHEN c.wks < 4 THEN 'Not enough data yet. Needs 4 weeks of closures; has '||c.wks||'.'
              WHEN p_apply   THEN 'Applied.'
              ELSE 'Suggested only. Re-run with apply turned on to write it.' END::text
  FROM cal c ORDER BY c.full_name;
END; $function$;
