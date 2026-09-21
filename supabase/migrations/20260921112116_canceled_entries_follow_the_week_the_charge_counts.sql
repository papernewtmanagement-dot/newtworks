-- A chargeback counts in the sales points of the week the cancelation was
-- recorded (production_rows_for). The Canceled entry for it now sits in that
-- same week, so the log never shows a charge on a week whose points did not
-- take it. Everything else a cancelation can do keeps the CPR-week rule.
DO $mig$
DECLARE d text; a int; b int;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO d;
  a := position('  -- ---------- Cancelations: every one logged, and what it did to the points ----------' IN d);
  b := position('  issues_all AS (SELECT * FROM issues UNION ALL SELECT * FROM cxl),' IN d);
  IF a = 0 OR b = 0 OR b < a THEN RAISE EXCEPTION 'cxl block not found'; END IF;
  d := substr(d, 1, a - 1) || $blk$  -- ---------- Cancelations: every one logged, and what it did to the points ----------
  cxl_src AS (
    SELECT ci.txid, ci.changed_at, ci.changed_by_team_member_id, ci.changed_by_label, ci.subject AS snap_subject,
           ci.changed_fields, c.id AS cxl_id, to_jsonb(c) AS cxl_row, c.canceled_on, c.already_charged_back,
           c.team_member_id AS logged_for, c.phone_last4 AS cxl_phone,
           c.policy_line, c.product_type AS cxl_type, c.premium AS cxl_premium,
           (c.created_at AT TIME ZONE 'America/Chicago')::date AS recorded_on,
           p.id AS pid, p.line_of_business, p.product_type, p.vehicle_count, p.issued_date, p.issued_premium, p.premium,
           s.id AS sid, s.team_member_id AS sale_owner, s.phone_last4 AS sale_phone,
           pt.label AS type_label,
           CASE WHEN p.id IS NULL THEN 'outside_window'
                WHEN COALESCE(c.already_charged_back, false) THEN 'already_charged_back'
                WHEN s.id IS NULL OR p.issued_date IS NULL THEN 'not_counted'
                WHEN floor((((c.created_at AT TIME ZONE 'America/Chicago')::date) - b.anchor) / 91.0)
                     > floor((p.issued_date - b.anchor) / 91.0) THEN 'charged_back'
                ELSE 'removed' END AS effect
      FROM public.change_log ci
      CROSS JOIN gate g
      CROSS JOIN bounds b
      JOIN public.cancelation_log c ON c.id = ci.row_id
      LEFT JOIN public.sales_log_products p ON p.id = c.matched_sale_product_id
      LEFT JOIN public.sales_log s ON s.id = p.sales_log_id AND s.status = 'active'
      LEFT JOIN public.product_types pt
        ON pt.agency_id = c.agency_id
       AND pt.line_of_business = COALESCE(p.line_of_business, c.policy_line)
       AND pt.type_key = COALESCE(p.product_type, c.product_type)
     WHERE g.ok
       AND ci.agency_id = p_agency_id
       AND ci.table_name = 'cancelation_log' AND lower(ci.action) = 'insert'
       AND COALESCE(ci.via, '') <> 'automation'
       AND c.status = 'active'
       AND ci.changed_at >= b.t0 - interval '7 days' AND ci.changed_at < b.t1 + interval '14 days'
  ),
  cxl AS (
    SELECT x.txid, x.changed_at, 'canceled'::text AS kind, 'canceled'::text AS what, 'Policy'::text AS item,
           public.change_current_subject('cancelation_log', x.cxl_id, x.cxl_row, x.snap_subject) AS subject,
           x.changed_by_team_member_id AS actor_id, COALESCE(x.changed_by_label, 'Unknown') AS who,
           COALESCE(x.sale_owner, x.logged_for) AS owner_id, x.changed_fields, '[]'::jsonb AS changes,
           1 AS row_count, NULL::text AS spot_note,
           jsonb_build_object(
             'line_of_business', COALESCE(x.line_of_business, x.policy_line),
             'product', COALESCE(x.type_label, initcap(replace(COALESCE(x.product_type, x.cxl_type), '_', ' '))),
             'vehicles', x.vehicle_count,
             'issued_date', x.issued_date,
             'issued_premium', COALESCE(x.issued_premium, x.premium, x.cxl_premium),
             'submitted_premium', x.premium,
             'difference', NULL,
             'canceled_on', x.canceled_on,
             'recorded_on', x.recorded_on,
             'charge', CASE WHEN x.effect IN ('charged_back', 'removed') THEN COALESCE(x.issued_premium, x.premium) ELSE 0 END,
             'effect', x.effect) AS policy,
           COALESCE(x.cxl_phone, x.sale_phone) AS phone
      FROM cxl_src x, bounds b
     WHERE CASE WHEN NOT p_by_cpr_week
                  THEN x.changed_at >= b.t0 AND x.changed_at < b.t1
                WHEN x.effect = 'charged_back'
                  -- the charge counts in the week it was recorded
                  THEN public.rp_week_end(x.recorded_on) BETWEEN p_start AND p_end
                ELSE public.cpr_week_for(p_agency_id, x.changed_at) BETWEEN p_start AND p_end END
  ),
$blk$ || substr(d, b);
  EXECUTE d;
END $mig$;
