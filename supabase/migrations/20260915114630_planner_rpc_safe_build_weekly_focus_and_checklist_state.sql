-- 1. New backlog_state: 'checklist'.
-- Rows under a standing commitment. They stay in place and stay visible,
-- they just stop competing for a weekly slot. Not 'someday' - nothing is parked.
ALTER TABLE public.tasks DROP CONSTRAINT IF EXISTS tasks_backlog_state_check;
ALTER TABLE public.tasks ADD CONSTRAINT tasks_backlog_state_check
  CHECK (backlog_state = ANY (ARRAY['active'::text, 'someday'::text, 'checklist'::text]));

-- 2. build_weekly_focus rewritten set-based.
-- The CREATE TEMP TABLE version returns HTTP 400 through PostgREST even when it
-- runs clean in SQL, so the app could never have called it. Same selection rules,
-- same straddle, no temp table.
-- Also teaches the pool about standing commitments: a parent whose open children
-- are all 'checklist' is now treated as a leaf and competes on its own hours.
CREATE OR REPLACE FUNCTION public.build_weekly_focus(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_week_of date DEFAULT NULL::date,
  p_dry_run boolean DEFAULT true)
RETURNS TABLE(who text, rank integer, scheduled_day date, priority text,
              est_hours numeric, running_hours numeric, task_title text, task_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_today date := public.agency_today();
  v_week date; v_cap int; v_park_at int; v_stale int;
  w_imp numeric; v_maxshare numeric; v_protect int;
BEGIN
  v_week := COALESCE(p_week_of, v_today - EXTRACT(DOW FROM v_today)::int);

  SELECT importance_value INTO v_cap FROM task_scoring_rules WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='weekly_item_cap' AND is_active;
  SELECT importance_value INTO v_park_at FROM task_scoring_rules WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='rollover_park_after' AND is_active;
  SELECT importance_value INTO v_stale FROM task_scoring_rules WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='stale_park_days' AND is_active;
  SELECT importance_value INTO w_imp FROM task_scoring_rules WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='importance_weight' AND is_active;
  SELECT importance_value INTO v_protect FROM task_scoring_rules WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='park_protect_importance' AND is_active;
  SELECT hours_value INTO v_maxshare FROM task_scoring_rules WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='max_item_share' AND is_active;

  v_cap:=COALESCE(v_cap,7); v_park_at:=COALESCE(v_park_at,4); v_stale:=COALESCE(v_stale,120);
  w_imp:=COALESCE(w_imp,65)/100.0; v_maxshare:=COALESCE(v_maxshare,0.50); v_protect:=COALESCE(v_protect,70);

  IF NOT p_dry_run THEN
    UPDATE tasks SET weeks_carried=weeks_carried+1
      WHERE agency_id=p_agency_id AND status='open' AND in_weekly_focus AND week_of IS NOT NULL AND week_of < v_week;

    UPDATE tasks SET stuck_since=COALESCE(stuck_since,v_week)
      WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
        AND weeks_carried>=v_park_at AND COALESCE(importance,0)>=v_protect;

    UPDATE tasks SET backlog_state='someday', in_weekly_focus=false, scheduled_day=NULL, parked_at=now(),
      parked_reason='Scheduled '||weeks_carried||' weeks running and never started. Importance '||COALESCE(importance,0)||', below the '||v_protect||' protection floor.'
      WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
        AND weeks_carried>=v_park_at AND COALESCE(importance,0)<v_protect;

    UPDATE tasks SET backlog_state='someday', parked_at=now(),
      parked_reason='No deadline, never scheduled, untouched for over '||v_stale||' days. Importance '||COALESCE(importance,0)||', below the '||v_protect||' protection floor.'
      WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
        AND week_of IS NULL AND due_date IS NULL
        AND COALESCE(importance,0)<v_protect AND updated_at < now() - (v_stale||' days')::interval;

    UPDATE tasks SET in_weekly_focus=false, scheduled_day=NULL
      WHERE agency_id=p_agency_id AND in_weekly_focus;
  END IF;

  RETURN QUERY
  WITH cand AS (
    SELECT t.id, t.assigned_to, t.title, t.priority, t.estimated_hours, u.full_name,
           COALESCE((SELECT s.hours_value FROM task_scoring_rules s
                      WHERE s.agency_id=p_agency_id AND s.rule_kind='setting' AND s.is_active
                        AND s.match_pattern='weekly_hours_'||lower(split_part(u.full_name,' ',1))
                      LIMIT 1),5.00) AS budget,
           (t.importance*w_imp + t.urgency*(1-w_imp)) AS score
      FROM tasks t
      JOIN users u ON u.id=t.assigned_to AND u.role IN ('owner','manager') AND u.is_active
     WHERE t.agency_id=p_agency_id AND t.status='open' AND t.backlog_state='active'
       AND t.estimated_hours IS NOT NULL
       AND (t.task_type<>'epic'
            OR EXISTS (SELECT 1 FROM tasks c WHERE c.parent_task_id=t.id AND c.backlog_state='checklist'))
       AND NOT EXISTS (SELECT 1 FROM tasks c
                        WHERE c.parent_task_id=t.id AND c.status='open' AND c.backlog_state<>'checklist')
  ),
  fits AS (
    SELECT c.* FROM cand c WHERE c.estimated_hours <= c.budget * v_maxshare
  ),
  ranked AS (
    SELECT f.*,
           ROW_NUMBER() OVER (PARTITION BY f.assigned_to ORDER BY f.score DESC, f.estimated_hours ASC)::int AS rn,
           SUM(f.estimated_hours) OVER (PARTITION BY f.assigned_to
             ORDER BY f.score DESC, f.estimated_hours ASC
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS run_hours
      FROM fits f
  ),
  picked AS (
    SELECT r.*, (v_week + (((r.rn-1)%5)+1))::date AS day_slot
      FROM ranked r
     WHERE r.rn <= v_cap AND (r.run_hours - r.estimated_hours) < r.budget
  ),
  applied AS (
    UPDATE tasks t SET in_weekly_focus=true, week_of=v_week, scheduled_day=pk.day_slot
      FROM picked pk WHERE t.id=pk.id AND NOT p_dry_run
    RETURNING t.id
  )
  SELECT pk.full_name::text, pk.rn, pk.day_slot, pk.priority,
         pk.estimated_hours, ROUND(pk.run_hours,2), pk.title::text, pk.id
    FROM picked pk ORDER BY pk.full_name, pk.rn;
END; $function$;