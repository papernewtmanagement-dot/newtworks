CREATE OR REPLACE FUNCTION public.rp_week_scoreboard_for(p_agency_id uuid, p_week_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  -- Last week that reads from what was reported. Everything after runs live.
  c_reported_through constant date := public.rp_reported_through(p_agency_id);
  v_week_end   date := public.rp_week_end(p_week_end);
  v_week_start date := public.rp_week_end(p_week_end) - 6;
  v_prev_end   date := public.rp_week_end(p_week_end) - 7;
  v_cycle_start date;
  -- First week end in scope that is computed rather than read from what was reported.
  v_live_from  date;
  v_people jsonb;
  v_team jsonb;
BEGIN
  SELECT c.cycle_start INTO v_cycle_start FROM public.current_cycle_info(p_agency_id, v_week_end) c;
  v_cycle_start := COALESCE(v_cycle_start, date_trunc('quarter', v_week_end)::date);
  v_live_from := GREATEST(v_cycle_start, c_reported_through + 1);

  IF v_week_end <= c_reported_through AND v_week_end < public.rp_live_capture_from(p_agency_id) THEN
    WITH mk AS (
      SELECT m.team_member_id AS tm,
             SUM(m.points) FILTER (WHERE m.week_end_date = v_week_end) AS points,
             SUM(m.points) AS qtd
      FROM public.marketing_points m
      WHERE m.agency_id = p_agency_id
        AND m.week_end_date BETWEEN v_cycle_start AND v_week_end
      GROUP BY m.team_member_id
    ),
    sp_rows AS (
      SELECT d.team_member_id AS tm, r.week_ending_date AS wk, d.sales_points AS pts
      FROM public.weekly_cpr_team_detail d
      JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
      WHERE d.agency_id = p_agency_id
        AND r.week_ending_date BETWEEN v_cycle_start AND v_week_end
        AND d.sales_points IS NOT NULL
    ),
    -- One definition of the week's growth, shared with the live branch.
    sp AS (
      SELECT g.team_member_id AS tm, g.qtd, g.prev, g.growth
      FROM public.rp_sales_week_growth(p_agency_id, v_week_end) g
    ),
    roster AS (
      SELECT t.id, t.first_name, t.role_category
      FROM public.team t
      WHERE t.agency_id = p_agency_id
        AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
        AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
        AND (
          (t.is_active AND t.archived_at IS NULL AND (t.end_date IS NULL OR t.end_date >= v_week_start))
          OR t.id IN (SELECT tm FROM mk WHERE COALESCE(points, 0) <> 0)
          OR t.id IN (SELECT tm FROM sp WHERE COALESCE(growth, 0) <> 0)
        )
    ),
    conv AS (SELECT * FROM public.rp_week_rollup(v_week_end, NULL)),
    people AS (
      SELECT r.id, r.first_name, r.role_category,
        jsonb_build_object('points', COALESCE(m.points, 0), 'qtd_points', COALESCE(m.qtd, 0),
          'qtd_mix', NULL::jsonb, 'qtd_reported', NULL::numeric, 'items', '[]'::jsonb) AS marketing,
        jsonb_build_object(
          'points', COALESCE(s.growth, 0),
          'qtd_points', COALESCE(s.qtd, 0),
          'pc_rate', NULL::numeric, 'lh_rate', NULL::numeric,
          'pc_points', NULL::numeric, 'lh_points', NULL::numeric,
          'pc_premium', NULL::numeric, 'lh_premium', NULL::numeric,
          'tiers', NULL::jsonb, 'units', NULL::jsonb, 'rates', NULL::jsonb,
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
             'marketing_qtd', COALESCE(SUM((marketing->>'qtd_points')::numeric), 0),
             'sales',     COALESCE(SUM((sales->>'points')::numeric), 0))
    INTO v_people, v_team
    FROM people;

    RETURN jsonb_build_object('ok', true, 'week_end', v_week_end, 'week_start', v_week_start, 'cycle_start', v_cycle_start,
                              'mode', 'reported',
                              'show', jsonb_build_object('marketing', true, 'sales', true, 'quotes', false, 'retention', false),
                              'team', COALESCE(v_team, '{}'::jsonb), 'people', COALESCE(v_people, '[]'::jsonb));
  END IF;

  WITH roster AS (
    SELECT r.team_member_id AS id, r.first_name, r.role_category
    FROM public.rp_board_roster_for(p_agency_id, v_week_end) r
  ),
  labels AS (SELECT v.activity_key, v.label FROM public.retention_point_values v WHERE v.agency_id = p_agency_id),
  m_priced AS (SELECT * FROM public.marketing_events_priced(p_agency_id, v_cycle_start, v_week_end)),
  -- Weeks before the live cutover were reported, not computed, so the
  -- quarter-to-date total picks those up from what was reported.
  m_reported AS (
    SELECT m.team_member_id AS tm, SUM(m.points) AS points
    FROM public.marketing_points m
    WHERE m.agency_id = p_agency_id
      AND m.week_end_date BETWEEN v_cycle_start AND LEAST(c_reported_through, v_week_end)
    GROUP BY m.team_member_id
  ),
  -- A locked week pays what was frozen on lock, so its weekly marketing number reads that.
  m_week_frozen AS (
    SELECT m.team_member_id AS tm, SUM(m.points) AS points
    FROM public.marketing_points m
    WHERE m.agency_id = p_agency_id AND m.week_end_date = v_week_end
    GROUP BY m.team_member_id
  ),
  -- One pricing pass, two totals: this week, and the quarter so far.
  m_agg AS (
    SELECT tm,
           SUM(points) FILTER (WHERE wk = v_week_end) AS points,
           SUM(points) FILTER (WHERE wk >= v_live_from) AS qtd_live,
           -- What our own prices account for inside the already-reported weeks.
           SUM(points) FILTER (WHERE wk < v_live_from) AS priced_reported,
           jsonb_agg(jsonb_build_object('id', id, 'kind', event_key, 'label', label, 'on_date', on_date, 'customer', customer, 'nth', prior + 1, 'points', points)
                     ORDER BY on_date DESC, customer, id) FILTER (WHERE wk = v_week_end) AS items
    FROM m_priced GROUP BY tm
  ),
  m_qtd AS (
    SELECT COALESCE(a.tm, rp.tm) AS tm,
           COALESCE(a.qtd_live, 0) + COALESCE(rp.points, 0) AS qtd
    FROM m_agg a FULL JOIN m_reported rp ON rp.tm = a.tm
  ),
  -- Quarter-to-date build-up: one row per kind of event, over the whole cycle.
  m_mix AS (
    SELECT z.tm, jsonb_agg(jsonb_build_object('kind', z.event_key, 'label', z.label, 'n', z.n, 'points', z.pts)
                          ORDER BY z.pts DESC, z.label) AS mix
    FROM (SELECT tm, event_key, label, count(*)::int AS n, ROUND(SUM(points), 2) AS pts
          FROM m_priced GROUP BY tm, event_key, label) z
    GROUP BY z.tm
  ),
  q_rows AS (
    SELECT q.team_member_id AS tm, q.id, q.created_at, q.quote_date, q.customer_label, q.phone_last4, q.products_discussed, q.marketing_source, q.relationship_type,
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
                                        'source', marketing_source, 'relationship', relationship_type, 'dup', dup, 'phone', phone_last4,
                                        'can_change', public.rp_entry_can_change(tm, created_at))
                     ORDER BY quote_date DESC, customer_label, id) AS items
    FROM q_rows GROUP BY tm
  ),
  prod AS (
    SELECT x.tm, x.id, x.sale_id, x.lob, x.product_type, x.premium, x.policy_count, x.vehicle_count,
           x.issued_date, x.customer_label, x.type_label, x.on_file_answer, x.phone_last4
    FROM public.production_rows_for(p_agency_id, v_cycle_start, v_week_end) x
  ),
  sp AS (
    SELECT r.id AS tm,
      COALESCE(cu.sp, public.compute_sp_from_production(0, 0, 0, 0, 0, 0)) AS cur,
      -- Last week's quarter-to-date as REPORTED, not recomputed (Peter 2026-09-16).
      COALESCE(g.growth, 0) AS week_growth, g.qtd AS week_qtd,
      (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'issued_on', x.issued_date, 'customer', x.customer_label, 'line', x.lob,
                                           'type', COALESCE(x.type_label, initcap(x.lob)), 'premium', x.premium, 'policies', x.policy_count, 'vehicles', x.vehicle_count, 'on_file_answer', x.on_file_answer, 'phone', x.phone_last4)
                        ORDER BY x.issued_date DESC, x.customer_label, x.id)
         FROM prod x WHERE x.tm = r.id AND x.issued_date >= v_week_start) AS items
    FROM roster r
    LEFT JOIN public.production_sales_points_for(p_agency_id, v_cycle_start, v_week_end) cu ON cu.team_member_id = r.id
    LEFT JOIN public.rp_sales_week_growth(p_agency_id, v_week_end) g ON g.team_member_id = r.id
  ),
  rp AS (SELECT * FROM public.compute_weekly_retention_points(p_agency_id, v_week_end)),
  rp_items AS (
    SELECT l.team_member_id AS tm,
           jsonb_agg(jsonb_build_object('id', l.id, 'on_date', l.occurred_on, 'customer', l.customer_label, 'activity_key', l.activity_key,
                                        'label', COALESCE(lb.label, l.activity_key), 'points', l.points, 'source', l.source,
                                        'clears_on', CASE WHEN l.credited_week_end_date <> v_week_end THEN l.credit_available_on END,
                                        'note', COALESCE(CASE WHEN l.save_reason IS NOT NULL THEN initcap(l.save_line) || ': ' || l.save_reason END, l.note))
                     ORDER BY l.occurred_on DESC, l.created_at DESC, l.id) AS items
    FROM public.retention_activity_now l LEFT JOIN labels lb ON lb.activity_key = l.activity_key
    WHERE l.agency_id = p_agency_id AND l.status = 'credited' AND (l.week_end_date = v_week_end OR l.credited_week_end_date = v_week_end)
    GROUP BY l.team_member_id
  ),
  conv AS (SELECT * FROM public.rp_week_rollup(v_week_end, NULL)),
  people AS (
    SELECT r.id, r.first_name, r.role_category,
      jsonb_build_object('points', CASE WHEN v_week_end <= c_reported_through THEN COALESCE(mw.points, 0) ELSE COALESCE(m.points, 0) END, 'qtd_points', COALESCE(mq.qtd, 0),
        'qtd_mix', COALESCE(mx.mix, '[]'::jsonb),
        'qtd_reported', ROUND(COALESCE(mr.points, 0) - COALESCE(m.priced_reported, 0), 2),
        'items', COALESCE(m.items, '[]'::jsonb)) AS marketing,
      jsonb_build_object('count', COALESCE(q.n, 0), 'items', COALESCE(q.items, '[]'::jsonb)) AS quotes,
      jsonb_build_object(
        'points', COALESCE(s.week_growth, 0),
        'qtd_points', COALESCE(s.week_qtd, (s.cur->'commission'->>'total_commission')::numeric, 0),
        'pc_rate', (s.cur->'rates'->>'pc_rate_capped')::numeric, 'lh_rate', (s.cur->'rates'->>'lh_rate_capped')::numeric,
        'pc_points', COALESCE((s.cur->'commission'->>'pc_commission')::numeric, 0),
        'lh_points', COALESCE((s.cur->'commission'->>'lh_commission')::numeric, 0),
        'pc_premium', COALESCE((s.cur->'commission'->>'pc_premium_base')::numeric, 0),
        'lh_premium', COALESCE((s.cur->'commission'->>'lh_premium_base')::numeric, 0),
        'tiers', COALESCE(s.cur->'tiers', '{}'::jsonb),
        'units', COALESCE(s.cur->'units', '{}'::jsonb),
        'rates', COALESCE(s.cur->'rates', '{}'::jsonb), 'life', COALESCE(s.cur->'life', '{}'::jsonb),
        'items', COALESCE(s.items, '[]'::jsonb)) AS sales,
      jsonb_build_object('hours_in_office', COALESCE(p.hours_in_office, 0), 'hour_points', COALESCE(p.hour_points, 0),
        'calls_answered', COALESCE(p.calls_answered, 0), 'call_points', COALESCE(p.call_points, 0),
        'missed_pct', COALESCE(p.missed_pct, 0), 'reduction_pct', COALESCE(p.reduction_pct, 0),
        'logged_points', COALESCE(p.logged_points, 0), 'derived_points', COALESCE(p.derived_points, 0),
        'gross', COALESCE(p.gross_points, 0), 'net', COALESCE(p.net_points, 0), 'items', COALESCE(ri.items, '[]'::jsonb)) AS retention,
      jsonb_build_object('scorecards', COALESCE(c.scorecards, 0), 'avg', c.scorecard_avg, 'pivots', COALESCE(c.pivots, 0)) AS conversations
    FROM roster r
    LEFT JOIN m_agg m ON m.tm = r.id
    LEFT JOIN m_qtd mq ON mq.tm = r.id
    LEFT JOIN m_mix mx ON mx.tm = r.id
    LEFT JOIN m_reported mr ON mr.tm = r.id
    LEFT JOIN m_week_frozen mw ON mw.tm = r.id
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
           'marketing_qtd',   COALESCE(SUM((marketing->>'qtd_points')::numeric), 0),
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
END $function$

