-- Production module: marketing point values with the review/referral split, prior-event scaling on
-- Retention Points (same shape as marketing), rp_week_scoreboard for the My Week tab, and the
-- 60-day backlog on To be issued (Peter 2026-09-11).

-- 1. Marketing point values live in a table now. Review $15 -> $10 here ($5 sits on Retention Points),
--    Referral Sold $30 -> $20 here ($10 on Retention Points), Referral Quoted stays $30 (no Retention earner).
--    Kickers unchanged: +0.15 per prior review, +0.30 per prior referral sold, 99 priors max, counted this calendar year.
CREATE TABLE IF NOT EXISTS public.marketing_point_values (
  agency_id      uuid NOT NULL,
  event_key      text NOT NULL,
  label          text NOT NULL,
  base_points    numeric NOT NULL DEFAULT 0,
  step_per_prior numeric NOT NULL DEFAULT 0,
  prior_cap      integer NOT NULL DEFAULT 0,
  description    text,
  sort_order     integer NOT NULL DEFAULT 0,
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, event_key)
);
ALTER TABLE public.marketing_point_values ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS marketing_point_values_read ON public.marketing_point_values;
CREATE POLICY marketing_point_values_read ON public.marketing_point_values FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);
GRANT SELECT ON public.marketing_point_values TO authenticated;

INSERT INTO public.marketing_point_values (agency_id, event_key, label, base_points, step_per_prior, prior_cap, description, sort_order)
SELECT a.agency_id, v.event_key, v.label, v.base_points, v.step_per_prior, v.prior_cap, v.description, v.sort_order
FROM (VALUES
  ('google_review',   'Google Review',   10.00, 0.15, 99, 'A customer left a Google review. $10 here plus $0.15 for every review you already had this year (99 max). The other $5 of the review is a Retention Point.', 10),
  ('referral_quoted', 'Referral Quoted', 30.00, 0.00,  0, 'A referral you sourced was quoted. $30 flat.', 20),
  ('referral_sold',   'Referral Sold',   20.00, 0.30, 99, 'A referral you sourced became a new household. $20 here plus $0.30 for every referral you already sold this year (99 max). The other $10 is a Retention Point.', 30)
) AS v(event_key, label, base_points, step_per_prior, prior_cap, description, sort_order)
CROSS JOIN (SELECT DISTINCT agency_id FROM public.retention_point_values) a
ON CONFLICT (agency_id, event_key) DO NOTHING;

-- 2. Retention Points scale like marketing points: every prior item of the same kind this calendar year
--    adds 1% of the item's value to the next one, 99 priors max (the 100th pays double). Hours, calls and
--    chargebacks do not scale: hours and calls would pass 99 in the first month and simply double for the year.
ALTER TABLE public.retention_point_values ADD COLUMN IF NOT EXISTS prior_step_pct numeric NOT NULL DEFAULT 1.0;
ALTER TABLE public.retention_point_values ADD COLUMN IF NOT EXISTS prior_cap integer NOT NULL DEFAULT 99;
UPDATE public.retention_point_values SET prior_step_pct = 0, prior_cap = 0
WHERE activity_key IN ('hour_in_office', 'call_answered', 'multiline_chargeback');

CREATE OR REPLACE FUNCTION public.rp_scale_points_by_prior()
RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $$
DECLARE v_pct numeric; v_cap integer; v_prior integer;
BEGIN
  IF NEW.points IS NULL OR NEW.points <= 0 THEN RETURN NEW; END IF;
  SELECT COALESCE(v.prior_step_pct, 0), COALESCE(v.prior_cap, 0) INTO v_pct, v_cap
  FROM public.retention_point_values v WHERE v.agency_id = NEW.agency_id AND v.activity_key = NEW.activity_key;
  IF NOT FOUND OR v_pct <= 0 OR v_cap <= 0 THEN RETURN NEW; END IF;
  SELECT count(*) INTO v_prior FROM public.retention_activity_log p
  WHERE p.agency_id = NEW.agency_id AND p.team_member_id = NEW.team_member_id AND p.activity_key = NEW.activity_key
    AND p.status <> 'voided' AND p.points > 0
    AND date_trunc('year', p.occurred_on) = date_trunc('year', NEW.occurred_on)
    AND p.occurred_on <= NEW.occurred_on;
  NEW.points := ROUND(NEW.points * (1 + (v_pct / 100.0) * LEAST(v_cap, v_prior)), 2);
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_rp_scale_points_by_prior ON public.retention_activity_log;
CREATE TRIGGER trg_rp_scale_points_by_prior BEFORE INSERT ON public.retention_activity_log
FOR EACH ROW EXECUTE FUNCTION public.rp_scale_points_by_prior();

-- 3. The week scoreboard. Everyone sees everyone (Peter 2026-09-11). Marketing Points from marketing_point_values,
--    HH Quotes from quote_log, Sales Points from compute_sp_from_production on issued policies quarter to date
--    (this week = quarter total after this week minus after last week), Retention Points from
--    compute_weekly_retention_points, scorecards from rp_week_rollup. Items behind every number ride along.
CREATE OR REPLACE FUNCTION public.rp_week_scoreboard_for(p_agency_id uuid, p_week_end date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
DECLARE
  v_week_end   date := public.rp_week_end(p_week_end);
  v_week_start date := public.rp_week_end(p_week_end) - 6;
  v_prev_end   date := public.rp_week_end(p_week_end) - 7;
  v_cycle_start date;
  v_people jsonb;
  v_team jsonb;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);

  WITH roster AS (
    SELECT t.id, t.first_name, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id AND t.is_active AND t.archived_at IS NULL
      AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (t.end_date IS NULL OR t.end_date >= v_week_start)
  ),
  labels AS (SELECT v.activity_key, v.label FROM public.retention_point_values v WHERE v.agency_id = p_agency_id),
  mv AS (SELECT m.event_key, m.label, m.base_points, m.step_per_prior, m.prior_cap FROM public.marketing_point_values m WHERE m.agency_id = p_agency_id AND m.is_active),
  m_rev AS (
    SELECT l.team_member_id AS tm, 'google_review'::text AS event_key, l.occurred_on AS on_date, l.customer_label AS customer, l.id,
      (SELECT count(*) FROM public.retention_activity_log p
        WHERE p.agency_id = p_agency_id AND p.team_member_id = l.team_member_id AND p.activity_key = 'google_review' AND p.status = 'credited'
          AND date_trunc('year', p.occurred_on) = date_trunc('year', l.occurred_on)
          AND (p.occurred_on < l.occurred_on OR (p.occurred_on = l.occurred_on AND p.created_at < l.created_at)))::int AS prior
    FROM public.retention_activity_log l
    WHERE l.agency_id = p_agency_id AND l.activity_key = 'google_review' AND l.status = 'credited' AND l.week_end_date = v_week_end
  ),
  m_rq AS (
    SELECT COALESCE(q.sourced_by_team_member_id, q.team_member_id) AS tm, 'referral_quoted'::text AS event_key, q.quote_date AS on_date, q.customer_label AS customer, q.id, 0::int AS prior
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.marketing_source = 'referral' AND q.week_end_date = v_week_end
  ),
  m_rs AS (
    SELECT COALESCE(s.sourced_by_team_member_id, s.team_member_id) AS tm, 'referral_sold'::text AS event_key, s.submitted_date AS on_date, s.customer_label AS customer, s.id,
      (SELECT count(*) FROM public.sales_log p
        WHERE p.agency_id = p_agency_id
          AND COALESCE(p.sourced_by_team_member_id, p.team_member_id) = COALESCE(s.sourced_by_team_member_id, s.team_member_id)
          AND p.status = 'active' AND p.marketing_source = 'referral' AND p.household_status IN ('new', 'winback')
          AND date_trunc('year', p.submitted_date) = date_trunc('year', s.submitted_date)
          AND (p.submitted_date < s.submitted_date OR (p.submitted_date = s.submitted_date AND p.created_at < s.created_at)))::int AS prior
    FROM public.sales_log s
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND s.marketing_source = 'referral'
      AND s.household_status IN ('new', 'winback') AND s.week_end_date = v_week_end
  ),
  m_ev AS (SELECT * FROM m_rev UNION ALL SELECT * FROM m_rq UNION ALL SELECT * FROM m_rs),
  m_priced AS (
    SELECT e.tm, e.event_key, e.on_date, e.customer, e.id, e.prior, mv.label,
           ROUND(mv.base_points + mv.step_per_prior * LEAST(mv.prior_cap, e.prior), 2) AS points
    FROM m_ev e JOIN mv ON mv.event_key = e.event_key
  ),
  m_agg AS (
    SELECT tm, SUM(points) AS points,
           jsonb_agg(jsonb_build_object('id', id, 'kind', event_key, 'label', label, 'on_date', on_date, 'customer', customer, 'nth', prior + 1, 'points', points)
                     ORDER BY on_date DESC, customer) AS items
    FROM m_priced GROUP BY tm
  ),
  q_rows AS (
    SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.products_discussed, q.marketing_source, q.relationship_type,
           (SELECT string_agg(COALESCE(pt.label, initcap(qp.line_of_business)), ', ' ORDER BY qp.created_at)
              FROM public.quote_log_products qp
              LEFT JOIN public.product_types pt ON pt.agency_id = qp.agency_id AND pt.line_of_business = qp.line_of_business AND pt.type_key = qp.product_type
             WHERE qp.quote_log_id = q.id) AS types
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.week_end_date = v_week_end
  ),
  q_agg AS (
    SELECT tm, count(*)::int AS n,
           jsonb_agg(jsonb_build_object('id', id, 'on_date', quote_date, 'customer', customer_label, 'products', products_discussed, 'types', types,
                                        'source', marketing_source, 'relationship', relationship_type)
                     ORDER BY quote_date DESC, customer_label) AS items
    FROM q_rows GROUP BY tm
  ),
  prod AS (
    SELECT s.team_member_id AS tm, p.id, s.id AS sale_id, p.line_of_business AS lob, p.product_type, p.premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count, p.vehicle_count, p.issued_date, s.customer_label, pt.label AS type_label
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    LEFT JOIN public.product_types pt ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end
  ),
  sp AS (
    SELECT r.id AS tm,
      (SELECT public.compute_sp_from_production(
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.policy_count END), 0), COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.policy_count END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0))
         FROM prod x WHERE x.tm = r.id) AS cur,
      (SELECT public.compute_sp_from_production(
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.policy_count END), 0), COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.policy_count END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0))
         FROM prod x WHERE x.tm = r.id AND x.issued_date <= v_prev_end) AS prev,
      (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'issued_on', x.issued_date, 'customer', x.customer_label, 'line', x.lob,
                                           'type', COALESCE(x.type_label, initcap(x.lob)), 'premium', x.premium, 'policies', x.policy_count, 'vehicles', x.vehicle_count)
                        ORDER BY x.issued_date DESC, x.customer_label)
         FROM prod x WHERE x.tm = r.id AND x.issued_date >= v_week_start) AS items
    FROM roster r
  ),
  rp AS (SELECT * FROM public.compute_weekly_retention_points(p_agency_id, v_week_end)),
  rp_items AS (
    SELECT l.team_member_id AS tm,
           jsonb_agg(jsonb_build_object('id', l.id, 'on_date', l.occurred_on, 'customer', l.customer_label, 'activity_key', l.activity_key,
                                        'label', COALESCE(lb.label, l.activity_key), 'points', l.points, 'source', l.source,
                                        'clears_on', CASE WHEN l.credited_week_end_date <> v_week_end THEN l.credit_available_on END,
                                        'note', COALESCE(CASE WHEN l.save_reason IS NOT NULL THEN initcap(l.save_line) || ': ' || l.save_reason END, l.note))
                     ORDER BY l.occurred_on DESC, l.created_at DESC) AS items
    FROM public.retention_activity_log l LEFT JOIN labels lb ON lb.activity_key = l.activity_key
    WHERE l.agency_id = p_agency_id AND l.status = 'credited' AND (l.week_end_date = v_week_end OR l.credited_week_end_date = v_week_end)
    GROUP BY l.team_member_id
  ),
  conv AS (SELECT * FROM public.rp_week_rollup(v_week_end, NULL)),
  people AS (
    SELECT r.id, r.first_name, r.role_category,
      jsonb_build_object('points', COALESCE(m.points, 0), 'items', COALESCE(m.items, '[]'::jsonb)) AS marketing,
      jsonb_build_object('count', COALESCE(q.n, 0), 'items', COALESCE(q.items, '[]'::jsonb)) AS quotes,
      jsonb_build_object(
        'points', ROUND(COALESCE((s.cur->'commission'->>'total_commission')::numeric, 0) - COALESCE((s.prev->'commission'->>'total_commission')::numeric, 0), 2),
        'qtd_points', COALESCE((s.cur->'commission'->>'total_commission')::numeric, 0),
        'pc_rate', (s.cur->'rates'->>'pc_rate_capped')::numeric, 'lh_rate', (s.cur->'rates'->>'lh_rate_capped')::numeric,
        'items', COALESCE(s.items, '[]'::jsonb)) AS sales,
      jsonb_build_object('hours_in_office', COALESCE(p.hours_in_office, 0), 'hour_points', COALESCE(p.hour_points, 0),
        'calls_answered', COALESCE(p.calls_answered, 0), 'call_points', COALESCE(p.call_points, 0),
        'missed_pct', COALESCE(p.missed_pct, 0), 'reduction_pct', COALESCE(p.reduction_pct, 0),
        'logged_points', COALESCE(p.logged_points, 0), 'derived_points', COALESCE(p.derived_points, 0),
        'gross', COALESCE(p.gross_points, 0), 'net', COALESCE(p.net_points, 0), 'items', COALESCE(ri.items, '[]'::jsonb)) AS retention,
      jsonb_build_object('scorecards', COALESCE(c.scorecards, 0), 'avg', c.scorecard_avg, 'pivots', COALESCE(c.pivots, 0)) AS conversations
    FROM roster r
    LEFT JOIN m_agg m ON m.tm = r.id
    LEFT JOIN q_agg q ON q.tm = r.id
    LEFT JOIN sp s ON s.tm = r.id
    LEFT JOIN rp p ON p.team_member_id = r.id
    LEFT JOIN rp_items ri ON ri.tm = r.id
    LEFT JOIN conv c ON c.team_member_id = r.id
  )
  SELECT jsonb_agg(jsonb_build_object('team_member_id', id, 'first_name', first_name, 'role_category', role_category,
                                      'marketing', marketing, 'quotes', quotes, 'sales', sales, 'retention', retention, 'conversations', conversations)
                   ORDER BY first_name),
         jsonb_build_object(
           'marketing',       COALESCE(SUM((marketing->>'points')::numeric), 0),
           'quotes',          COALESCE(SUM((quotes->>'count')::int), 0),
           'sales',           COALESCE(SUM((sales->>'points')::numeric), 0),
           'retention_net',   COALESCE(SUM((retention->>'net')::numeric), 0),
           'retention_gross', COALESCE(SUM((retention->>'gross')::numeric), 0),
           'missed_pct',      COALESCE(MAX((retention->>'missed_pct')::numeric), 0))
  INTO v_people, v_team
  FROM people;

  RETURN jsonb_build_object('ok', true, 'week_end', v_week_end, 'week_start', v_week_start, 'cycle_start', v_cycle_start,
                            'team', COALESCE(v_team, '{}'::jsonb), 'people', COALESCE(v_people, '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.rp_week_scoreboard(p_week_end date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $$
  SELECT CASE WHEN auth.uid() IS NULL THEN jsonb_build_object('ok', false, 'error', 'Sign in first.')
              ELSE public.rp_week_scoreboard_for((SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1), p_week_end) END;
$$;
REVOKE ALL ON FUNCTION public.rp_week_scoreboard_for(uuid, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rp_week_scoreboard(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rp_week_scoreboard(date) TO authenticated;

-- 4. To be issued: anything submitted more than 60 days ago and never marked is treated as issued a week after
--    submission (Peter 2026-09-11). 18 backfill rows.
UPDATE public.sales_log_products p SET issued_date = s.submitted_date + 7
FROM public.sales_log s
WHERE s.id = p.sales_log_id AND s.status = 'active' AND p.issued_date IS NULL
  AND s.submitted_date < (public.rp_today_central() - 60);
