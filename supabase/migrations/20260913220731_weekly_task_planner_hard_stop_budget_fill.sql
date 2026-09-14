-- Peter ruling 2026-09-13: hard stop at the budget. An item that would overshoot is
-- skipped and the next one that fits takes the slot. No straddling the line.
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
  r record; v_person uuid; v_used numeric; v_n int;
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

    UPDATE tasks SET stuck_since = COALESCE(stuck_since, v_week)
     WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
       AND weeks_carried >= v_park_at AND COALESCE(importance,0) >= v_protect;

    UPDATE tasks
       SET backlog_state='someday', in_weekly_focus=false, scheduled_day=NULL,
           parked_at=now(),
           parked_reason='Scheduled '||weeks_carried||' weeks running and never started. Importance '
                         ||COALESCE(importance,0)||', below the '||v_protect||' protection floor.'
     WHERE agency_id=p_agency_id AND status='open' AND backlog_state='active'
       AND weeks_carried >= v_park_at AND COALESCE(importance,0) < v_protect;

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

  CREATE TEMP TABLE _pick (
    uid uuid, who text, rank int, day_slot date, priority text,
    est numeric, used numeric, title text, tid uuid
  ) ON COMMIT DROP;

  v_person := NULL; v_used := 0; v_n := 0;

  FOR r IN
    SELECT t.id, t.assigned_to, t.title, t.priority, t.estimated_hours,
           u.full_name,
           COALESCE((SELECT s.hours_value FROM task_scoring_rules s
                      WHERE s.agency_id=p_agency_id AND s.rule_kind='setting' AND s.is_active
                        AND s.match_pattern='weekly_hours_'||lower(split_part(u.full_name,' ',1))
                      LIMIT 1), 5.00) AS budget,
           (t.importance * w_imp + t.urgency * (1-w_imp)) AS score
      FROM tasks t
      JOIN users u ON u.id = t.assigned_to AND u.role IN ('owner','manager') AND u.is_active
     WHERE t.agency_id=p_agency_id AND t.status='open'
       AND t.backlog_state='active' AND t.task_type <> 'epic'
       AND t.estimated_hours IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM tasks c WHERE c.parent_task_id=t.id AND c.status='open')
     ORDER BY t.assigned_to,
              (t.importance * w_imp + t.urgency * (1-w_imp)) DESC,
              t.estimated_hours ASC
  LOOP
    IF v_person IS DISTINCT FROM r.assigned_to THEN
      v_person := r.assigned_to; v_used := 0; v_n := 0;
    END IF;

    CONTINUE WHEN v_n >= v_cap;                              -- item cap reached
    CONTINUE WHEN r.estimated_hours > r.budget * v_maxshare; -- too big for a week, needs splitting
    CONTINUE WHEN v_used + r.estimated_hours > r.budget;     -- hard stop: skip it, keep looking

    v_n := v_n + 1;
    v_used := v_used + r.estimated_hours;

    INSERT INTO _pick VALUES (
      r.assigned_to, r.full_name, v_n,
      (v_week + (((v_n - 1) % 5) + 1))::date,
      r.priority, r.estimated_hours, v_used, r.title, r.id);
  END LOOP;

  IF NOT p_dry_run THEN
    UPDATE tasks t
       SET in_weekly_focus = true, week_of = v_week, scheduled_day = pk.day_slot
      FROM _pick pk WHERE t.id = pk.tid;
  END IF;

  RETURN QUERY
    SELECT pk.who, pk.rank, pk.day_slot, pk.priority, pk.est, pk.used, pk.title, pk.tid
    FROM _pick pk ORDER BY pk.who, pk.rank;
END;
$fn$;