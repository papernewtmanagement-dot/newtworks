-- ONE place that decides what production counts, and ONE place that turns it into
-- sales points. rp_week_scoreboard_for and get_sales_points_qtd both move onto it
-- in this migration. This is a cutover, not an addition.

CREATE OR REPLACE FUNCTION public.rp_reported_through()
RETURNS date
LANGUAGE sql IMMUTABLE
AS $fn$ SELECT '2026-09-12'::date $fn$;

COMMENT ON FUNCTION public.rp_reported_through() IS
'Last week end that reads from what was reported. Every week after it runs live. One place so the board and the sales-points resolver can never disagree about which weeks are live.';

-- Which production rows count, and how many apps each one is worth.
CREATE OR REPLACE FUNCTION public.production_rows_for(p_agency_id uuid, p_from date, p_through date)
RETURNS TABLE(tm uuid, id uuid, sale_id uuid, lob text, product_type text, premium numeric,
              policy_count integer, vehicle_count integer, units integer, issued_date date,
              customer_label text, type_label text, on_file_answer text, phone_last4 text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT s.team_member_id, p.id, s.id, p.line_of_business, p.product_type,
         COALESCE(p.issued_premium, p.premium),
         GREATEST(1, COALESCE(p.policy_count, 1)),
         p.vehicle_count,
         -- Auto counts one app per VEHICLE. Everything else counts policies.
         CASE WHEN p.line_of_business = 'auto'
              THEN GREATEST(1, COALESCE(p.vehicle_count, s.vehicle_count, p.policy_count, 1))
              ELSE GREATEST(1, COALESCE(p.policy_count, 1)) END,
         p.issued_date, s.customer_label, pt.label, s.on_file_answer, s.phone_last4
  FROM public.sales_log s
  JOIN public.sales_log_products p ON p.sales_log_id = s.id
  LEFT JOIN public.product_types pt
    ON pt.agency_id = s.agency_id AND pt.line_of_business = p.line_of_business AND pt.type_key = p.product_type
  WHERE s.agency_id = p_agency_id AND s.status = 'active' AND p.issued_date IS NOT NULL
    AND p.issued_date BETWEEN p_from AND p_through
    -- Peter 2026-09-14: charged back, even partially, means out of sales points.
    AND NOT EXISTS (SELECT 1 FROM public.cancelation_log cb
                     WHERE cb.matched_sale_product_id = p.id AND cb.status = 'active');
$fn$;

COMMENT ON FUNCTION public.production_rows_for(uuid, date, date) IS
'The eligible issued-production rows for a window, with auto apps counted per vehicle. The only definition of what counts toward sales points. Date basis is issued_date; premium basis is issued premium over written.';

-- Sales points from production, per person, for a window.
CREATE OR REPLACE FUNCTION public.production_sales_points_for(p_agency_id uuid, p_from date, p_through date)
RETURNS TABLE(team_member_id uuid, sp jsonb)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
  SELECT x.tm,
         public.compute_sp_from_production(
           COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.units END), 0),
           COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.units END), 0),
           COALESCE(SUM(CASE WHEN x.lob = 'life'   THEN x.premium END), 0),
           COALESCE(SUM(CASE WHEN x.lob = 'health' THEN x.premium END), 0),
           COALESCE(SUM(CASE WHEN x.lob = 'auto'   THEN x.premium END), 0),
           COALESCE(SUM(CASE WHEN x.lob = 'fire'   THEN x.premium END), 0))
  FROM public.production_rows_for(p_agency_id, p_from, p_through) x
  GROUP BY x.tm;
$fn$;

COMMENT ON FUNCTION public.production_sales_points_for(uuid, date, date) IS
'Sales points from production per person for a window. The ONLY place production is turned into sales points. rp_week_scoreboard_for and get_sales_points_qtd both call this. Returns no row for a person with no production - the caller decides what zero production means.';

-- Who is on the board for a week.
CREATE OR REPLACE FUNCTION public.rp_board_roster_for(p_agency_id uuid, p_week_end date)
RETURNS TABLE(team_member_id uuid, first_name text, role_category text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_week_end   date := public.rp_week_end(p_week_end);
  v_week_start date := public.rp_week_end(p_week_end) - 6;
BEGIN
  RETURN QUERY
  WITH contributors AS (
    -- Peter 2026-09-11: contributions never expire and employment does not gate
    -- them. Narrowed 2026-09-14: the window is THIS WEEK, not the quarter to date.
    SELECT s.team_member_id AS tm
    FROM public.sales_log s
    JOIN public.sales_log_products p ON p.sales_log_id = s.id
    WHERE s.agency_id = p_agency_id AND s.status = 'active'
      AND p.issued_date BETWEEN v_week_start AND v_week_end
    UNION
    SELECT s.team_member_id FROM public.sales_log s
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
      AND (l.week_end_date = v_week_end OR l.credited_week_end_date = v_week_end)
    UNION
    SELECT ap.team_member_id FROM public.appointment_log ap
    WHERE ap.agency_id = p_agency_id AND ap.status = 'active'
      AND (public.rp_week_end(ap.kept_on) = v_week_end OR public.rp_week_end(ap.sold_on) = v_week_end)
  )
  SELECT t.id, t.first_name, t.role_category
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND COALESCE(t.is_test_user, false) = false AND COALESCE(t.is_admin_backoffice, false) = false
    AND (t.role_level IS NULL OR t.role_level <> 'Owner') AND t.category = 'agency'
    AND (
      (t.is_active AND t.archived_at IS NULL
       AND (t.end_date IS NULL OR t.end_date >= v_week_start))
      OR t.id IN (SELECT c.tm FROM contributors c)
    );
END;
$fn$;

COMMENT ON FUNCTION public.rp_board_roster_for(uuid, date) IS
'Who appears on the week scoreboard: the active agency roster for that week, plus anyone who contributed during that week whenever they left. Extracted so the sales-points resolver can apply the same gate without calling the whole board.';

-- Move rp_week_scoreboard_for onto the shared functions, by line range with a
-- shape guard, so a 20k-character body is never retyped by hand.
DO $mig$
DECLARE
  src     text;
  lines   text[];
  n       int;
  newsrc  text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO src
  FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
  WHERE ns.nspname = 'public' AND p.proname = 'rp_week_scoreboard_for';

  lines := string_to_array(src, E'\n');
  n := array_length(lines, 1);

  IF btrim(lines[9])   <> 'c_reported_through constant date := ''2026-09-12'';'
     OR btrim(lines[90])  <> 'WITH contributors AS ('
     OR btrim(lines[137]) <> '),'
     OR btrim(lines[238]) <> 'prod AS ('
     OR btrim(lines[253]) <> '),'
     OR btrim(lines[254]) <> 'sp AS ('
     OR btrim(lines[271]) <> '),'
     OR lines[272] NOT LIKE '%compute_weekly_retention_points%'
  THEN
    RAISE EXCEPTION 'rp_week_scoreboard_for is not the expected shape. Another thread changed it. Re-read pg_proc before patching.';
  END IF;

  lines[9] := '  c_reported_through constant date := public.rp_reported_through();';

  newsrc :=
    array_to_string(lines[1:89], E'\n') || E'\n' ||
$blk$  WITH roster AS (
    SELECT r.team_member_id AS id, r.first_name, r.role_category
    FROM public.rp_board_roster_for(p_agency_id, v_week_end) r
  ),$blk$ || E'\n' ||
    array_to_string(lines[138:237], E'\n') || E'\n' ||
$blk$  prod AS (
    SELECT x.tm, x.id, x.sale_id, x.lob, x.product_type, x.premium, x.policy_count, x.vehicle_count,
           x.issued_date, x.customer_label, x.type_label, x.on_file_answer, x.phone_last4
    FROM public.production_rows_for(p_agency_id, v_cycle_start, v_week_end) x
  ),
  sp AS (
    SELECT r.id AS tm,
      COALESCE(cu.sp, public.compute_sp_from_production(0, 0, 0, 0, 0, 0)) AS cur,
      COALESCE(pv.sp, public.compute_sp_from_production(0, 0, 0, 0, 0, 0)) AS prev,
      (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'sale_id', x.sale_id, 'issued_on', x.issued_date, 'customer', x.customer_label, 'line', x.lob,
                                           'type', COALESCE(x.type_label, initcap(x.lob)), 'premium', x.premium, 'policies', x.policy_count, 'vehicles', x.vehicle_count, 'on_file_answer', x.on_file_answer, 'phone', x.phone_last4)
                        ORDER BY x.issued_date DESC, x.customer_label)
         FROM prod x WHERE x.tm = r.id AND x.issued_date >= v_week_start) AS items
    FROM roster r
    LEFT JOIN public.production_sales_points_for(p_agency_id, v_cycle_start, v_week_end) cu ON cu.team_member_id = r.id
    LEFT JOIN public.production_sales_points_for(p_agency_id, v_cycle_start, v_prev_end) pv ON pv.team_member_id = r.id
  ),$blk$ || E'\n' ||
    array_to_string(lines[272:n], E'\n');

  EXECUTE newsrc;
END
$mig$;

-- Move the resolver onto the same two functions. It no longer calls the board.
CREATE OR REPLACE FUNCTION public.get_sales_points_qtd(p_agency_id uuid, p_week_end date)
RETURNS TABLE(team_id uuid, sales_points numeric, source text)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v_week_end date;
  v_cycle_start date;
  v_live boolean;
BEGIN
  SELECT c.week_ending_saturday, c.cycle_start INTO v_week_end, v_cycle_start
  FROM public.current_cycle_info(p_agency_id, p_week_end) c;

  v_live := v_week_end > public.rp_reported_through();

  RETURN QUERY
  WITH frozen AS (
    -- Only the row for this exact week. A sent week keeps the number the team was
    -- paid on, whatever lands in the production log afterwards.
    SELECT d.team_member_id AS tm, d.sales_points_frozen AS pts
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = v_week_end
      AND d.sales_points_frozen IS NOT NULL
  ),
  production AS (
    -- Same roster gate and same calculation the scoreboard uses, without loading
    -- the scoreboard. Someone on the board with no production reads 0 from
    -- production, not a fall-through to an older override.
    SELECT r.team_member_id AS tm,
           COALESCE((ps.sp->'commission'->>'total_commission')::numeric, 0) AS pts
    FROM public.rp_board_roster_for(p_agency_id, v_week_end) r
    LEFT JOIN public.production_sales_points_for(p_agency_id, v_cycle_start, v_week_end) ps
      ON ps.team_member_id = r.team_member_id
    WHERE v_live
  ),
  override AS (
    SELECT DISTINCT ON (d.team_member_id)
      d.team_member_id AS tm, d.sales_points AS pts
    FROM public.weekly_cpr_team_detail d
    JOIN public.weekly_cpr_reports r ON r.id = d.weekly_cpr_report_id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date BETWEEN v_cycle_start AND v_week_end
      AND d.sales_points IS NOT NULL
    ORDER BY d.team_member_id, r.week_ending_date DESC
  ),
  reported AS (
    SELECT DISTINCT ON (tc.team_id)
      tc.team_id AS tm, tc.sales_points_quarter AS pts
    FROM public.team_checkins tc
    WHERE tc.agency_id = p_agency_id
      AND tc.checkin_date BETWEEN v_cycle_start AND v_week_end
      AND tc.sales_points_quarter IS NOT NULL
    ORDER BY tc.team_id, tc.checkin_date DESC, tc.received_at DESC
  ),
  everyone AS (
    SELECT tm FROM frozen
    UNION SELECT tm FROM production
    UNION SELECT tm FROM override
    UNION SELECT tm FROM reported
  )
  SELECT e.tm,
         COALESCE(f.pts, pr.pts, o.pts, rp.pts, 0)::numeric,
         CASE WHEN f.pts  IS NOT NULL THEN 'frozen'
              WHEN pr.pts IS NOT NULL THEN 'production'
              WHEN o.pts  IS NOT NULL THEN 'cpr_override'
              WHEN rp.pts IS NOT NULL THEN 'self_reported'
              ELSE 'none' END
  FROM everyone e
  LEFT JOIN frozen f ON f.tm = e.tm
  LEFT JOIN production pr ON pr.tm = e.tm
  LEFT JOIN override o ON o.tm = e.tm
  LEFT JOIN reported rp ON rp.tm = e.tm;
END;
$fn$;

COMMENT ON FUNCTION public.get_sales_points_qtd(uuid, date) IS
'THE sales points function. Precedence per person: this week frozen figure, then production on live weeks, then Peter typed cpr_override carried forward, then self-reported check-in. Production comes from production_sales_points_for gated by rp_board_roster_for - the same two functions the scoreboard uses.';
