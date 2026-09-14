CREATE OR REPLACE FUNCTION public.build_weekly_focus(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  p_week_of date DEFAULT NULL,
  p_dry_run boolean DEFAULT true
)
RETURNS TABLE (
  who text, rank int, scheduled_day date, priority text,
  est_hours numeric, running_hours numeric, task_title text, task_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_week date; v_cap int; v_park_at int; v_stale int;
  w_imp numeric; v_maxshare numeric; v_protect int;
BEGIN
  v_week := COALESCE(p_week_of, CURRENT_DATE + ((7 - EXTRACT(DOW FROM CURRENT_DATE)::int) % 7));

  SELECT importance_value INTO v_cap     FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='weekly_item_cap' AND is_active;
  SELECT importance_value INTO v_park_at FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='rollover_park_after' AND is_active;
  SELECT importance_value INTO v_stale   FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='stale_park_days' AND is_active;
  SELECT importance_value INTO w_imp     FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='importance_weight' AND is_active;
  SELECT importance_value INTO v_protect FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='park_protect_importance' AND is_active;
  SELECT hours_value      INTO v_maxshare FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='max_item_share' AND is_active;

  v_cap := COALESCE(v_cap,7); v_park_at := COALESCE(v_park_at,4);
  v_stale := COALESCE(v_stale,120); w_imp := COALESCE(w_imp,65)/100.0;
  v_maxshare := COALESCE(v_maxshare,0.50); v_protect := COALESCE(v_protect,70);

  IF NOT p_dry_run THEN
    UPDATE tasks SET weeks_carried = weeks_carried + 1
     WHERE agency_id=p_agency_id AND status='open'
       AND in_weekly_focus AND week_of IS NOT NULL AND week_of < v_week;

    -- Important work that keeps rolling is NOT parked. It is surfaced.
    -- Repeated rollover on something that matters means it is too big or blocked.
    UPDATE tasks SET stuck_since = COALESCE(stuck_since, v_week)
     WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
       AND weeks_carried >= v_park_at AND COALESCE(importance,0) >= v_protect;

    -- Only unimportant rollovers park, and only with a written reason.
    UPDATE tasks
       SET backlog_state='someday', in_weekly_focus=false, scheduled_day=NULL,
           parked_at=now(),
           parked_reason='Scheduled '||weeks_carried||' weeks running and never started. Importance '
                         ||COALESCE(importance,0)||', below the '||v_protect||' protection floor.'
     WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
       AND weeks_carried >= v_park_at AND COALESCE(importance,0) < v_protect;

    -- Same protection on the age rule. An important task on the back burner stays put.
    UPDATE tasks
       SET backlog_state='someday', parked_at=now(),
           parked_reason='No deadline, never scheduled, untouched for over '||v_stale||' days. Importance '
                         ||COALESCE(importance,0)||', below the '||v_protect||' protection floor.'
     WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
       AND week_of IS NULL AND due_date IS NULL
       AND COALESCE(importance,0) < v_protect
       AND updated_at < now() - (v_stale || ' days')::interval;

    UPDATE tasks SET in_weekly_focus=false, scheduled_day=NULL
     WHERE agency_id=p_agency_id AND in_weekly_focus;
  END IF;

  RETURN QUERY
  WITH budget AS (
    SELECT u.id AS uid, u.full_name,
           COALESCE((SELECT r.hours_value FROM task_scoring_rules r
                      WHERE r.agency_id=p_agency_id AND r.rule_kind='setting' AND r.is_active
                        AND r.match_pattern = 'weekly_hours_' || lower(split_part(u.full_name,' ',1))
                      LIMIT 1), 5.00) AS hours_budget
    FROM users u WHERE u.role IN ('owner','manager') AND u.is_active
  ),
  pool AS (
    SELECT t.id, t.assigned_to, t.title, t.priority, t.estimated_hours,
           (t.importance * w_imp + t.urgency * (1-w_imp)) AS score
    FROM tasks t
    WHERE t.agency_id=p_agency_id AND t.status='open'
      AND t.backlog_state='active' AND t.task_type <> 'epic'
      AND t.assigned_to IS NOT NULL AND t.estimated_hours IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM tasks c WHERE c.parent_task_id=t.id AND c.status='open')
  ),
  fits AS (
    SELECT p.*, b.full_name, b.hours_budget
    FROM pool p JOIN budget b ON b.uid = p.assigned_to
    WHERE p.estimated_hours <= b.hours_budget * v_maxshare
  ),
  ranked AS (
    SELECT f.full_name, f.id, f.title, f.priority, f.estimated_hours, f.hours_budget,
           ROW_NUMBER() OVER (PARTITION BY f.assigned_to ORDER BY f.score DESC, f.estimated_hours ASC)::int AS rn,
           SUM(f.estimated_hours) OVER (PARTITION BY f.assigned_to
             ORDER BY f.score DESC, f.estimated_hours ASC
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS run_hours
    FROM fits f
  ),
  picked AS (
    SELECT r.*, (v_week + (((r.rn - 1) % 5) + 1))::date AS day_slot
    FROM ranked r
    WHERE r.rn <= v_cap AND (r.run_hours - r.estimated_hours) < r.hours_budget
  ),
  applied AS (
    UPDATE tasks t SET in_weekly_focus = true, week_of = v_week, scheduled_day = pk.day_slot
      FROM picked pk WHERE t.id = pk.id AND NOT p_dry_run
    RETURNING t.id)
  SELECT pk.full_name::text, pk.rn, pk.day_slot, pk.priority,
         pk.estimated_hours, ROUND(pk.run_hours,2), pk.title::text, pk.id
  FROM picked pk ORDER BY pk.full_name, pk.rn;
END;
$fn$;

-- The cluster sheet. One decision per cluster instead of one per task.
CREATE OR REPLACE FUNCTION public.review_backlog_clusters(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'
)
RETURNS TABLE (
  cluster text, items int, hours numeric, top_importance int,
  oldest date, last_human_touch date, owner text
)
LANGUAGE sql STABLE
AS $fn$
  SELECT COALESCE(left(p.title,60), '(no parent) — '||COALESCE(t.task_category,'uncategorized')) AS cluster,
         count(*)::int,
         ROUND(SUM(t.estimated_hours),1),
         MAX(t.importance)::int,
         MIN(t.created_at)::date,
         MAX(t.updated_at)::date,
         COALESCE(string_agg(DISTINCT split_part(u.full_name,' ',1), '/'), 'unassigned')
  FROM tasks t
  LEFT JOIN tasks p ON p.id = t.parent_task_id
  LEFT JOIN users u ON u.id = t.assigned_to
  WHERE t.agency_id = p_agency_id AND t.status='open'
    AND t.backlog_state='active' AND t.task_type <> 'epic'
  GROUP BY 1
  ORDER BY count(*) DESC;
$fn$;