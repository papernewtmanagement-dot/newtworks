-- Marketing points for weeks after the last locked week were priced live on the
-- scoreboard (rp_week_scoreboard_for) but payroll, the marketing bonus and the
-- quarter-to-date views read only marketing_points, which has no rows for live
-- weeks. Week ending 2026-09-19 showed 0 on the CPR payroll while the scoreboard
-- showed Cassandra 10.30. One pricing function, one weekly reader, every caller
-- moved onto them, and the live figures freeze into marketing_points at lock.

-- 1. The one place a marketing event is priced. Lifted verbatim from the live
--    branch of rp_week_scoreboard_for (m_rev, m_rq, m_rs, m_ak, m_as, m_priced).
CREATE OR REPLACE FUNCTION public.marketing_events_priced(p_agency_id uuid, p_cycle_start date, p_through date)
 RETURNS TABLE(tm uuid, event_key text, on_date date, customer text, id uuid, prior integer, label text, wk date, points numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH mv AS (SELECT m.event_key, m.label, m.base_points, m.step_per_prior, m.prior_cap FROM public.marketing_point_values m WHERE m.agency_id = p_agency_id AND m.is_active),
  m_rev AS (
    SELECT l.team_member_id AS tm, 'google_review'::text AS event_key, l.occurred_on AS on_date, l.customer_label AS customer, l.id,
      (SELECT count(*) FROM public.retention_activity_now p
        WHERE p.agency_id = p_agency_id AND p.team_member_id = l.team_member_id AND p.activity_key = 'google_review' AND p.status = 'credited'
          AND p.occurred_on >= p_cycle_start
          AND (p.occurred_on < l.occurred_on OR (p.occurred_on = l.occurred_on AND (p.created_at < l.created_at OR (p.created_at = l.created_at AND p.id < l.id)))))::int AS prior
    FROM public.retention_activity_now l
    WHERE l.agency_id = p_agency_id AND l.activity_key = 'google_review' AND l.status = 'credited'
      AND l.week_end_date BETWEEN p_cycle_start AND p_through
  ),
  m_rq AS (
    SELECT COALESCE(q.sourced_by_team_member_id, q.team_member_id) AS tm, 'referral_quoted'::text AS event_key, q.quote_date AS on_date, q.customer_label AS customer, q.id, 0::int AS prior
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.marketing_source = 'referral'
      AND q.week_end_date BETWEEN p_cycle_start AND p_through
  ),
  m_rs AS (
    SELECT s.team_member_id AS tm, 'referral_sold'::text AS event_key, s.submitted_date AS on_date, s.customer_label AS customer, s.id,
      (SELECT count(*) FROM public.sales_log p
        WHERE p.agency_id = p_agency_id
          AND p.team_member_id = s.team_member_id
          AND p.status = 'active' AND p.marketing_source = 'referral' AND p.household_status IN ('new', 'winback')
          AND p.submitted_date >= p_cycle_start
          AND (p.submitted_date < s.submitted_date OR (p.submitted_date = s.submitted_date AND (p.created_at < s.created_at OR (p.created_at = s.created_at AND p.id < s.id)))))::int AS prior
    FROM public.sales_log s
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND s.marketing_source = 'referral'
      AND s.household_status IN ('new', 'winback')
      AND s.week_end_date BETWEEN p_cycle_start AND p_through
  ),
  m_ak AS (
    SELECT ap.team_member_id AS tm, 'appointment_kept'::text AS event_key, ap.kept_on AS on_date, ap.customer_label AS customer, ap.id, 0::int AS prior
    FROM public.appointment_log ap
    WHERE ap.agency_id = p_agency_id AND ap.status = 'active'
      AND ap.escalated_to_team_member_id IS NOT NULL
      AND ap.escalated_to_team_member_id <> ap.team_member_id
      AND ap.sold_on IS NULL
      AND ap.kept_on IS NOT NULL AND public.rp_week_end(ap.kept_on) BETWEEN p_cycle_start AND p_through
  ),
  m_as AS (
    SELECT ap.team_member_id AS tm, 'appointment_sold'::text AS event_key, ap.sold_on AS on_date, ap.customer_label AS customer, ap.id,
      (SELECT count(*) FROM public.appointment_log q
        WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.team_member_id = ap.team_member_id
          AND q.escalated_to_team_member_id IS NOT NULL AND q.escalated_to_team_member_id <> q.team_member_id
          AND q.sold_on IS NOT NULL AND q.sold_on >= p_cycle_start
          AND (q.sold_on < ap.sold_on OR (q.sold_on = ap.sold_on AND (q.created_at < ap.created_at OR (q.created_at = ap.created_at AND q.id < ap.id)))))::int AS prior
    FROM public.appointment_log ap
    WHERE ap.agency_id = p_agency_id AND ap.status = 'active'
      AND ap.escalated_to_team_member_id IS NOT NULL
      AND ap.escalated_to_team_member_id <> ap.team_member_id
      AND ap.sold_on IS NOT NULL AND public.rp_week_end(ap.sold_on) BETWEEN p_cycle_start AND p_through
  ),
  m_ev AS (SELECT * FROM m_rev UNION ALL SELECT * FROM m_rq UNION ALL SELECT * FROM m_rs UNION ALL SELECT * FROM m_ak UNION ALL SELECT * FROM m_as)
  SELECT e.tm, e.event_key, e.on_date, e.customer, e.id, e.prior, mv.label,
         public.rp_week_end(e.on_date) AS wk,
         ROUND(mv.base_points + mv.step_per_prior * LEAST(mv.prior_cap, e.prior), 2) AS points
  FROM m_ev e JOIN mv ON mv.event_key = e.event_key
$function$;

-- 2. The one weekly reader. Locked weeks come from marketing_points (what was
--    reported and paid); weeks after the last lock are priced live.
CREATE OR REPLACE FUNCTION public.marketing_points_weekly(p_agency_id uuid, p_week_end date)
 RETURNS TABLE(team_member_id uuid, week_end_date date, points numeric, is_live boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_week_end date := public.rp_week_end(p_week_end);
  v_rt date := public.rp_reported_through(p_agency_id);
  v_cycle_start date;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);
  RETURN QUERY
  SELECT m.team_member_id, m.week_end_date, SUM(m.points)::numeric, false
  FROM public.marketing_points m
  WHERE m.agency_id = p_agency_id
    AND m.week_end_date BETWEEN v_cycle_start AND LEAST(v_rt, v_week_end)
  GROUP BY m.team_member_id, m.week_end_date
  UNION ALL
  SELECT e.tm, e.wk, SUM(e.points)::numeric, true
  FROM public.marketing_events_priced(p_agency_id, v_cycle_start, v_week_end) e
  WHERE e.wk > v_rt AND e.wk BETWEEN v_cycle_start AND v_week_end
  GROUP BY e.tm, e.wk;
END
$function$;

GRANT EXECUTE ON FUNCTION public.marketing_events_priced(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.marketing_points_weekly(uuid, date) TO authenticated;

-- 3. Scoreboard live branch prices through the shared function.
DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.rp_week_scoreboard_for(uuid,date)'::regprocedure);
  v_start int; v_end int;
  c_start text := '  mv AS (SELECT m.event_key';
  c_end   text := E'    FROM m_ev e JOIN mv ON mv.event_key = e.event_key\n  ),';
BEGIN
  v_start := strpos(v_def, c_start);
  v_end := strpos(v_def, c_end);
  IF v_start = 0 OR v_end = 0 OR v_end < v_start THEN RAISE EXCEPTION 'rp_week_scoreboard_for anchors not found'; END IF;
  v_def := substr(v_def, 1, v_start - 1)
        || E'  m_priced AS (SELECT * FROM public.marketing_events_priced(p_agency_id, v_cycle_start, v_week_end)),'
        || substr(v_def, v_end + length(c_end));
  EXECUTE v_def;
END $mig$;

-- 4. Marketing bonus reads the weekly reader.
DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.compute_weekly_marketing_bonus(uuid,date)'::regprocedure);
  o1 text := E'  SELECT COALESCE(SUM(points), 0) INTO v_total_points_qtd\n  FROM public.marketing_points\n  WHERE agency_id = p_agency_id\n    AND week_end_date >= v_quarter_start AND week_end_date <= v_week_end;';
  n1 text := E'  SELECT COALESCE(SUM(w.points), 0) INTO v_total_points_qtd\n  FROM public.marketing_points_weekly(p_agency_id, v_week_end) w;';
  o2 text := E'    SELECT team_member_id, SUM(points) AS points_qtd,\n           COALESCE(SUM(CASE WHEN week_end_date = v_week_end THEN points END), 0) AS points_this_week\n    FROM public.marketing_points\n    WHERE agency_id = p_agency_id AND week_end_date >= v_quarter_start AND week_end_date <= v_week_end\n    GROUP BY team_member_id';
  n2 text := E'    SELECT w.team_member_id, SUM(w.points) AS points_qtd,\n           COALESCE(SUM(CASE WHEN w.week_end_date = v_week_end THEN w.points END), 0) AS points_this_week\n    FROM public.marketing_points_weekly(p_agency_id, v_week_end) w\n    GROUP BY w.team_member_id';
BEGIN
  IF strpos(v_def, o1) = 0 OR strpos(v_def, o2) = 0 THEN RAISE EXCEPTION 'compute_weekly_marketing_bonus anchors not found'; END IF;
  EXECUTE replace(replace(v_def, o1, n1), o2, n2);
END $mig$;

-- 5. Payroll tab reads the weekly reader.
DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.team_payroll_week(uuid,date)'::regprocedure);
  o text := E'    LEFT JOIN public.marketing_points mp\n      ON mp.agency_id = p_agency_id\n     AND mp.team_member_id = d.team_member_id\n     AND mp.week_end_date = v_week_end';
  n text := E'    LEFT JOIN public.marketing_points_weekly(p_agency_id, v_week_end) mp\n      ON mp.team_member_id = d.team_member_id\n     AND mp.week_end_date = v_week_end';
BEGIN
  IF strpos(v_def, o) = 0 THEN RAISE EXCEPTION 'team_payroll_week anchor not found'; END IF;
  EXECUTE replace(v_def, o, n);
END $mig$;

-- 6. Quarter-to-date view reads the weekly reader.
DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.team_quarter_to_date(uuid,date)'::regprocedure);
  o text := E'    SELECT m.team_member_id AS tm, SUM(m.points) AS pts\n    FROM public.marketing_points m\n    WHERE m.agency_id = p_agency_id AND m.week_end_date BETWEEN v_cycle_start AND v_week_end\n    GROUP BY m.team_member_id';
  n text := E'    SELECT m.team_member_id AS tm, SUM(m.points) AS pts\n    FROM public.marketing_points_weekly(p_agency_id, v_week_end) m\n    GROUP BY m.team_member_id';
BEGIN
  IF strpos(v_def, o) = 0 THEN RAISE EXCEPTION 'team_quarter_to_date anchor not found'; END IF;
  EXECUTE replace(v_def, o, n);
END $mig$;

-- 7. At lock, freeze every live week up to the locked one into marketing_points,
--    BEFORE the lock row lands (the lock is what flips a week from live to reported).
DO $mig$
DECLARE
  v_def text := pg_get_functiondef('public.tg_lock_week_on_payroll_paid()'::regprocedure);
  o text := E'    INSERT INTO public.weekly_pool_lock (';
  n text := E'    -- Freeze live marketing points for every unlocked week through this one\n'
         || E'    -- before the lock lands; after it, those weeks read from marketing_points.\n'
         || E'    IF NOT EXISTS (SELECT 1 FROM public.weekly_pool_lock l0 WHERE l0.agency_id = r.agency_id AND l0.week_end_date = r.wk) THEN\n'
         || E'      INSERT INTO public.marketing_points (agency_id, team_member_id, week_end_date, points, notes, source, updated_at)\n'
         || E'      SELECT r.agency_id, w.team_member_id, w.week_end_date, w.points, NULL, ''frozen_on_lock'', now()\n'
         || E'      FROM public.marketing_points_weekly(r.agency_id, r.wk) w\n'
         || E'      WHERE w.is_live AND w.points > 0\n'
         || E'      ON CONFLICT (agency_id, team_member_id, week_end_date)\n'
         || E'      DO UPDATE SET points = EXCLUDED.points, source = EXCLUDED.source, updated_at = now();\n'
         || E'    END IF;\n\n'
         || E'    INSERT INTO public.weekly_pool_lock (';
BEGIN
  IF strpos(v_def, o) = 0 THEN RAISE EXCEPTION 'tg_lock_week_on_payroll_paid anchor not found'; END IF;
  EXECUTE replace(v_def, o, n);
END $mig$;
