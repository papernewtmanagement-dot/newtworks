-- The database clock is UTC. At 8pm Sunday in San Antonio it is already Monday in UTC,
-- so a Sunday-evening run computed the wrong week and dated every due-date check a day early.
CREATE OR REPLACE FUNCTION public.agency_today()
RETURNS date LANGUAGE sql STABLE AS
$fn$ SELECT (now() AT TIME ZONE 'America/Chicago')::date $fn$;

COMMENT ON FUNCTION public.agency_today IS
  'Today in San Antonio. Use instead of CURRENT_DATE anywhere a calendar day matters, because the database runs on UTC and rolls over six hours early.';

CREATE OR REPLACE FUNCTION public.score_tasks(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365',
  p_force boolean DEFAULT false
)
RETURNS TABLE (rows_scored int, priority_written int, hours_written int, locked_skipped int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $fn$
DECLARE
  w_imp numeric; b_crit numeric; b_high numeric; b_med numeric; pf_mult numeric;
  v_today date := public.agency_today();
  v_scored int := 0; v_pri int := 0; v_hrs int := 0; v_lock int := 0;
BEGIN
  SELECT importance_value INTO w_imp  FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='importance_weight' AND is_active;
  SELECT importance_value INTO b_crit FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='band_critical' AND is_active;
  SELECT importance_value INTO b_high FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='band_high' AND is_active;
  SELECT importance_value INTO b_med  FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='band_medium' AND is_active;
  SELECT hours_value      INTO pf_mult FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='planning_multiplier' AND is_active;

  w_imp := COALESCE(w_imp,65)/100.0;
  b_crit := COALESCE(b_crit,80); b_high := COALESCE(b_high,60); b_med := COALESCE(b_med,35);
  pf_mult := COALESCE(pf_mult,1.00);

  CREATE TEMP TABLE _sc ON COMMIT DROP AS
  WITH base AS (
    SELECT t.id, t.task_type, t.task_category, t.due_date, t.weeks_carried,
           t.priority_source, t.estimated_hours_source, t.parent_task_id,
           lower(coalesce(t.title,'') || ' ' || coalesce(t.description,'')) AS hay
    FROM tasks t
    WHERE t.agency_id = p_agency_id AND t.status = 'open' AND t.backlog_state = 'active'
      AND (p_force OR t.scored_at IS NULL OR t.updated_at > t.scored_at)
  ),
  cat AS (
    SELECT b.id, COALESCE(
      (SELECT r.importance_value FROM task_scoring_rules r
        WHERE r.agency_id=p_agency_id AND r.rule_kind='category_weight'
          AND r.is_active AND r.match_category = b.task_category LIMIT 1),
      (SELECT r.importance_value FROM task_scoring_rules r
        WHERE r.agency_id=p_agency_id AND r.rule_kind='category_weight'
          AND r.is_active AND r.match_category IS NULL LIMIT 1), 50)::numeric AS cat_imp
    FROM base b
  ),
  kw AS (
    SELECT b.id,
           COALESCE(SUM(r.importance_bump),0)::numeric AS imp_bump,
           COALESCE(SUM(r.urgency_bump),0)::numeric    AS urg_bump,
           (ARRAY_AGG(r.hours_value ORDER BY r.priority, r.hours_value)
              FILTER (WHERE r.hours_value IS NOT NULL))[1] AS kw_hours
    FROM base b
    LEFT JOIN task_scoring_rules r
      ON r.agency_id = p_agency_id AND r.rule_kind='keyword' AND r.is_active AND b.hay ~ r.match_pattern
    GROUP BY b.id
  ),
  struct AS (
    SELECT b.id, EXISTS (SELECT 1 FROM tasks c WHERE c.parent_task_id=b.id AND c.status='open') AS has_kids
    FROM base b
  ),
  typ AS (
    SELECT b.id, (SELECT r.hours_value FROM task_scoring_rules r
                   WHERE r.agency_id=p_agency_id AND r.rule_kind='type_hours'
                     AND r.is_active AND r.match_pattern = b.task_type LIMIT 1) AS type_hours
    FROM base b
  )
  SELECT b.id, b.task_type, b.priority_source, b.estimated_hours_source,
         GREATEST(0, LEAST(100, cat.cat_imp + kw.imp_bump
           + CASE WHEN struct.has_kids THEN 8 ELSE 0 END))::smallint AS importance,
         GREATEST(0, LEAST(100,
           CASE
             WHEN b.due_date IS NULL THEN 25
             WHEN b.due_date <= v_today      THEN 100
             WHEN b.due_date <= v_today + 3  THEN 90
             WHEN b.due_date <= v_today + 7  THEN 75
             WHEN b.due_date <= v_today + 14 THEN 60
             WHEN b.due_date <= v_today + 30 THEN 40
             ELSE 20 END
           + kw.urg_bump
           + (b.weeks_carried * COALESCE(
               (SELECT r.importance_value FROM task_scoring_rules r
                 WHERE r.agency_id=p_agency_id AND r.rule_kind='setting'
                   AND r.match_pattern='rollover_urgency_bump' AND r.is_active LIMIT 1), 12))
         ))::smallint AS urgency,
         CASE WHEN b.task_type = 'epic' THEN NULL
              ELSE GREATEST(0.25, ROUND((COALESCE(kw.kw_hours, typ.type_hours, 1.5) * pf_mult) * 4, 0) / 4)
         END::numeric(5,2) AS est_hours
  FROM base b
  JOIN cat ON cat.id=b.id JOIN kw ON kw.id=b.id
  JOIN struct ON struct.id=b.id JOIN typ ON typ.id=b.id;

  SELECT count(*) INTO v_scored FROM _sc;
  SELECT count(*) INTO v_lock FROM _sc WHERE priority_source='manual' OR estimated_hours_source='manual';

  UPDATE tasks t SET importance=s.importance, urgency=s.urgency, scored_at=now()
    FROM _sc s WHERE t.id = s.id;

  WITH upd AS (
    UPDATE tasks t SET priority = CASE
        WHEN (s.importance*w_imp + s.urgency*(1-w_imp)) >= b_crit THEN 'critical'
        WHEN (s.importance*w_imp + s.urgency*(1-w_imp)) >= b_high THEN 'high'
        WHEN (s.importance*w_imp + s.urgency*(1-w_imp)) >= b_med  THEN 'medium'
        ELSE 'low' END
      FROM _sc s WHERE t.id = s.id AND s.priority_source = 'auto'
    RETURNING 1)
  SELECT count(*) INTO v_pri FROM upd;

  WITH upd2 AS (
    UPDATE tasks t SET estimated_hours = s.est_hours
      FROM _sc s WHERE t.id = s.id AND s.estimated_hours_source='auto' AND s.task_type <> 'epic'
    RETURNING 1)
  SELECT count(*) INTO v_hrs FROM upd2;

  RETURN QUERY SELECT v_scored, v_pri, v_hrs, v_lock;
END;
$fn$;