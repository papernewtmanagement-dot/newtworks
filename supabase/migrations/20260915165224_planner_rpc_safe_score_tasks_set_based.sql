-- score_tasks rewritten set-based. No CREATE TEMP TABLE, so PostgREST can call it.
-- Behaviour is byte-for-byte the same as the temp-table version: same scoring maths,
-- same manual-source locks, same epic handling, same return counts.
-- The three separate UPDATEs are folded into ONE UPDATE because two data-modifying
-- CTEs touching the same row in one statement is undefined in Postgres.
-- Columns that must not change fall back to their own current value, which the
-- value-comparing tasks_set_updated_at trigger reads as "no change", so the
-- staleness clock still stays put on a planner-only write.
CREATE OR REPLACE FUNCTION public.score_tasks(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_force boolean DEFAULT false
)
RETURNS TABLE(rows_scored integer, priority_written integer, hours_written integer, locked_skipped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  w_imp numeric; b_crit numeric; b_high numeric; b_med numeric; pf_mult numeric; roll numeric;
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
  SELECT importance_value INTO roll   FROM task_scoring_rules
    WHERE agency_id=p_agency_id AND rule_kind='setting' AND match_pattern='rollover_urgency_bump' AND is_active;

  w_imp := COALESCE(w_imp,65)/100.0;
  b_crit := COALESCE(b_crit,80); b_high := COALESCE(b_high,60); b_med := COALESCE(b_med,35);
  pf_mult := COALESCE(pf_mult,1.00);
  roll := COALESCE(roll,12);

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
  ),
  sc AS (
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
             + (b.weeks_carried * roll)
           ))::smallint AS urgency,
           CASE WHEN b.task_type = 'epic' THEN NULL
                ELSE GREATEST(0.25, ROUND((COALESCE(kw.kw_hours, typ.type_hours, 1.5) * pf_mult) * 4, 0) / 4)
           END::numeric(5,2) AS est_hours
    FROM base b
    JOIN cat ON cat.id=b.id JOIN kw ON kw.id=b.id
    JOIN struct ON struct.id=b.id JOIN typ ON typ.id=b.id
  ),
  upd AS (
    UPDATE tasks t SET
      importance = s.importance,
      urgency    = s.urgency,
      scored_at  = now(),
      priority   = CASE WHEN s.priority_source = 'auto' THEN
                     CASE
                       WHEN (s.importance*w_imp + s.urgency*(1-w_imp)) >= b_crit THEN 'critical'
                       WHEN (s.importance*w_imp + s.urgency*(1-w_imp)) >= b_high THEN 'high'
                       WHEN (s.importance*w_imp + s.urgency*(1-w_imp)) >= b_med  THEN 'medium'
                       ELSE 'low' END
                   ELSE t.priority END,
      estimated_hours = CASE WHEN s.estimated_hours_source = 'auto' AND s.task_type <> 'epic'
                             THEN s.est_hours ELSE t.estimated_hours END
    FROM sc s
    WHERE t.id = s.id
    RETURNING s.priority_source AS ps, s.estimated_hours_source AS hs, s.task_type AS tt
  )
  SELECT count(*)::int,
         count(*) FILTER (WHERE ps = 'auto')::int,
         count(*) FILTER (WHERE hs = 'auto' AND tt <> 'epic')::int,
         count(*) FILTER (WHERE ps = 'manual' OR hs = 'manual')::int
    INTO v_scored, v_pri, v_hrs, v_lock
  FROM upd;

  RETURN QUERY SELECT v_scored, v_pri, v_hrs, v_lock;
END;
$function$;
