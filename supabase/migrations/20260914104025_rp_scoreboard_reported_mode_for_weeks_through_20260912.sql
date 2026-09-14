-- Peter ruling 2026-09-14. Weeks ending on or before 2026-09-12 show MARKETING and
-- SALES only, and both come from what was REPORTED, not from a production calculation,
-- because the capture module is still under construction. QUOTES and RETENTION must not
-- show at all for those weeks. Weeks ending 2026-09-19 and later run the live calculation
-- exactly as before.
--
-- Reported sources, both verified live 2026-09-14:
--   marketing -> public.marketing_points.points for that week_end_date (one row per person
--                per week, already weekly not cumulative; compute_weekly_marketing_bonus
--                sums them for quarter to date).
--   sales     -> public.weekly_cpr_team_detail.sales_points, the quarter-to-date figure
--                Peter types on the CPR each week. Weekly points = this week's figure minus
--                the most recent earlier figure inside the same cycle.
-- public.producer_production was NOT used: it is monthly, per line of business, covers only
-- two or three people and stops at June 2026, so it cannot produce a per-person weekly number.
CREATE OR REPLACE FUNCTION public.rp_week_scoreboard_for(p_agency_id uuid, p_week_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  -- Last week that reads from what was reported. Everything after runs live.
  c_reported_through constant date := '2026-09-12';
  v_week_end   date := public.rp_week_end(p_week_end);
  v_week_start date := public.rp_week_end(p_week_end) - 6;
  v_prev_end   date := public.rp_week_end(p_week_end) - 7;
  v_cycle_start date;
  v_people jsonb;
  v_team jsonb;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);

  IF v_week_end <= c_reported_through THEN
    WITH mk AS (
      SELECT m.team_member_id AS tm, m.points
      FROM public.marketing_points m
      WHERE m.agency_id = p_agency_id AND m.week_end_date = v_week_end
    ),
    sp_rows AS (
      SELECT d.team_member_id AS tm, r.week_ending_date AS wk, d.sales_points AS pts
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE d.agency_id = p_agency_id
        AND r.week_ending_date BETWEEN v_cycle_start AND v_week_end
        AND d.sales_points IS NOT NULL
    ),
    sp AS (
      SELECT tm,
        (SELECT x.pts FROM sp_rows x WHERE x.tm = s.tm AND x.wk <= v_week_end ORDER BY x.wk DESC LIMIT 1) AS qtd,
        COALESCE((SELECT x.pts FROM sp_rows x WHERE x.tm = s.tm AND x.wk <= v_prev_end ORDER BY x.wk DESC LIMIT 1), 0) AS prev
      FROM (SELECT DISTINCT tm FROM sp_rows) s
    ),
    roster AS (
      SELECT t.id, t.first_name, t.role_category
      FROM public.team t
      WHERE t.agency_id = p_agency_id
        AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
        AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
        AND (
          (t.is_active AND t.archived_at IS NULL AND (t.end_date IS NULL OR t.end_date >= v_week_start))
          OR t.id IN (SELECT tm FROM mk) OR t.id IN (SELECT tm FROM sp)
        )
    ),
    conv AS (SELECT * FROM public.rp_week_rollup(v_week_end, NULL)),
    people AS (
      SELECT r.id, r.first_name, r.role_category,
        jsonb_build_object('points', COALESCE(m.points, 0), 'items', '[]'::jsonb) AS marketing,
        jsonb_build_object(
          'points', ROUND(COALESCE(s.qtd, 0) - COALESCE(s.prev, 0), 2),
          'qtd_points', COALESCE(s.qtd, 0),
          'pc_rate', NULL::numeric, 'lh_rate', NULL::numeric,
          'items', '[]'::jsonb) AS sales,
        jsonb_build_object('scorecards', COALESCE(c.scorecards, 0), 'avg', c.scorecard_avg, 'pivots', COALESCE(c.pivots, 0)) AS conversations
      FROM roster r
      LEFT JOIN mk m ON m.tm = r.id
      LEFT JOIN sp s ON s.tm = r.id
      LEFT JOIN conv c ON c.team_member_id = r.id
    )
    SELECT jsonb_agg(jsonb_build_object('team_member_id', id, 'first_name', first_name, 'role_category', role_category,
                                        'marketing', marketing, 'sales', sales, 'conversations', conversations)
                     ORDER BY first_name),
           jsonb_build_object(
             'marketing', COALESCE(SUM((marketing->>'points')::numeric), 0),
             'sales',     COALESCE(SUM((sales->>'points')::numeric), 0))
    INTO v_people, v_team
    FROM people;

    RETURN jsonb_build_object('ok', true, 'week_end', v_week_end, 'week_start', v_week_start, 'cycle_start', v_cycle_start,
                              'mode', 'reported',
                              'show', jsonb_build_object('marketing', true, 'sales', true, 'quotes', false, 'retention', false),
                              'team', COALESCE(v_team, '{}'::jsonb), 'people', COALESCE(v_people, '[]'::jsonb));
  END IF;

  WITH contributors AS (
    -- Peter 2026-09-11: contributions never expire and employment does not gate
    -- them. Anyone with activity inside the window stays on the board, whenever
    -- they left. Same shape rp_rollup_for already uses.
    -- This is the CONTRIBUTIONS half only. Requirements and targets are the other
    -- half and are untouched -- those still prorate in the leaving week and then
    -- zero out, via get_wtw_am_seat_weights. Do not merge the two.
    SELECT s.team_member_id AS tm
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    WHERE s.agency_id = p_agency_id AND s.status = 'active'
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end
    UNION
    SELECT COALESCE(s.sourced_by_team_member_id, s.team_member_id)
    FROM public.sales_log s
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND s.week_end_date = v_week_end
    UNION
    SELECT q.team_member_id FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.week_end_date = v_week_end
    UNION
    SELECT COALESCE(q.sourced_by_team_member_id, q.team_member_id) FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.week_end_date = v_week_end
    UNION
    SELECT l.team_member_id FROM public.retention_activity_log l
    WHERE l.agency_id = p_agency_id AND l.status = 'credited'
      AND (l.week_end_date = v_week_end OR l.credited_week_end_date = v_week_end
           OR (l.activity_key = 'google_review' AND l.occurred_on BETWEEN v_cycle_start AND v_week_end))
  ),
  roster AS (
    SELECT t.id, t.first_name, t.role_category
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
      AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
      AND (
        (t.is_active AND t.archived_at IS NULL
         AND (t.end_date IS NULL OR t.end_date >= v_week_start))
        OR t.id IN (SELECT tm FROM contributors)
      )
  ),
  labels AS (SELECT v.activity_key, v.label FROM public.retention_point_values v WHERE v.agency_id = p_agency_id),
  mv AS (SELECT m.event_key, m.label, m.base_points, m.step_per_prior, m.prior_cap FROM public.marketing_point_values m WHERE m.agency_id = p_agency_id AND m.is_active),
  m_rev AS (
    SELECT l.team_member_id AS tm, 'google_review'::text AS event_key, l.occurred_on AS on_date, l.customer_label AS customer, l.id,
      (SELECT count(*) FROM public.retention_activity_log p
        WHERE p.agency_id = p_agency_id AND p.team_member_id = l.team_member_id AND p.activity_key = 'google_review' AND p.status = 'credited'
          AND p.occurred_on >= v_cycle_start
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
          AND p.submitted_date >= v_cycle_start
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
    SELECT q.team_member_id AS tm, q.id, q.quote_date, q.customer_label, q.phone_last4, q.products_discussed, q.marketing_source, q.relationship_type,
           EXISTS (SELECT 1 FROM public.quote_log x WHERE x.agency_id = q.agency_id AND x.status = 'active' AND x.customer_label = q.customer_label AND x.week_end_date = q.week_end_date AND (x.phone_last4 IS NULL OR q.phone_last4 IS NULL OR x.phone_last4 = q.phone_last4)
                     AND (x.quote_date < q.quote_date OR (x.quote_date = q.quote_date AND x.created_at < q.created_at))) AS dup,
           (SELECT string_agg(COALESCE(pt.label, initcap(qp.line_of_business)), ', ' ORDER BY qp.created_at)
              FROM public.quote_log_products qp
              LEFT JOIN public.product_types pt ON pt.agency_id = qp.agency_id AND pt.line_of_business = qp.line_of_business AND pt.type_key = qp.product_type
             WHERE qp.quote_log_id = q.id) AS types
    FROM public.quote_log q
    WHERE q.agency_id = p_agency_id AND q.status = 'active' AND q.week_end_date = v_week_end
  ),
  q_agg AS (
    SELECT tm, count(DISTINCT customer_label || COALESCE(phone_last4, ''))::int AS n,
           jsonb_agg(jsonb_build_object('id', id, 'on_date', quote_date, 'customer', customer_label, 'products', products_discussed, 'types', types,
                                        'source', marketing_source, 'relationship', relationship_type, 'dup', dup, 'phone', phone_last4)
                     ORDER BY quote_date DESC, customer_label) AS items
    FROM q_rows GROUP BY tm
  ),
  prod AS (
    SELECT s.team_member_id AS tm, p.id, s.id AS sale_id, p.line_of_business AS lob, p.product_type, COALESCE(p.issued_premium, p.premium) AS premium,
           GREATEST(1, COALESCE(p.policy_count, 1)) AS policy_count, p.vehicle_count, p.issued_date, s.customer_label, pt.label AS type_label, s.on_file_answer, s.phone_last4,
           -- Auto counts one app per VEHICLE. Everything else counts policies.
           CASE WHEN p.line_of_business = 'auto'
                THEN GREATEST(1, COALESCE(p.vehicle_count, s.vehicle_count, p.policy_count, 1))
                ELSE GREATEST(1, COALESCE(p.policy_count, 1)) END AS units
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    LEFT JOIN public.product_types pt ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
    WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
      AND p.issued_date BETWEEN v_cycle_start AND v_week_end
  ),
  sp AS (
    SELECT r.id AS tm,
      (SELECT public.compute_sp_from_production(
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.units END), 0), COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.units END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0))
         FROM prod x WHERE x.tm = r.id) AS cur,
      (SELECT public.compute_sp_from_production(
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.units END), 0), COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.units END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'life' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
          COALESCE(SUM(CASE WHEN x.lob = 'auto' THEN x.premium END), 0),     COALESCE(SUM(CASE WHEN x.lob = 'fire' THEN x.premium END), 0))
         FROM prod x WHERE x.tm = r.id AND x.issued_date <= v_prev_end) AS prev,
      (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'issued_on', x.issued_date, 'customer', x.customer_label, 'line', x.lob,
                                           'type', COALESCE(x.type_label, initcap(x.lob)), 'premium', x.premium, 'policies', x.policy_count, 'vehicles', x.vehicle_count, 'on_file_answer', x.on_file_answer, 'phone', x.phone_last4)
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
                            'mode', 'live',
                            'show', jsonb_build_object('marketing', true, 'sales', true, 'quotes', true, 'retention', true),
                            'team', COALESCE(v_team, '{}'::jsonb), 'people', COALESCE(v_people, '[]'::jsonb));
END $function$;