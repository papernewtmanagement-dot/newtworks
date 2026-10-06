-- Test point "Cassanie" (owner only), appended to earnings_curve_positions with:
--   ORDER BY s.first_name), '[]'::jsonb) || public.earnings_test_point(p_agency_id)
CREATE OR REPLACE FUNCTION public.earnings_test_point(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- TEST POINT "Cassanie" (Peter 2026-10-05). Not a person; owner-only; drawn on the Retention chart.
-- Combined window total = Stephanie + Cassandra total points (sales + net retention + marketing)
-- since Retention Points began (the retention track's window), spread per week.
-- Plus 5 Online Reviews and 2 Referrals Sold every week at the stacking rule in force for a
-- quarter ahead (step and cap from retention_point_values, after the kicker date).
-- One full quarter = 13 weeks of that pace. x = weekly pace, y = Retention curve at that x.
DECLARE
  v_wk integer; v_sum numeric; v_base numeric;
  v_rev numeric; v_ref numeric; v_step numeric; v_cap numeric;
  v_rev_wk numeric; v_ref_wk numeric; v_x numeric; v_y numeric; v_quarter numeric;
  v_pts jsonb; a jsonb; b jsonb;
BEGIN
  PERFORM public.require_login('staff');
  IF NOT (auth.role() IS NULL OR auth.role() = 'service_role' OR public.is_agency_admin()) THEN RETURN '[]'::jsonb; END IF;

  SELECT MAX(r.weeks_counted), SUM(r.avg_total_points * r.weeks_counted)
    INTO v_wk, v_sum
    FROM public.retention_raise_track(p_agency_id) r
   WHERE r.first_name IN ('Stephanie', 'Cassandra');
  IF COALESCE(v_wk, 0) = 0 THEN RETURN '[]'::jsonb; END IF;
  v_base := v_sum / v_wk;

  SELECT MAX(points) FILTER (WHERE activity_key = 'google_review'),
         MAX(points) FILTER (WHERE activity_key = 'referral_sold'),
         MAX(prior_step_pct) FILTER (WHERE activity_key = 'google_review'),
         MAX(prior_cap) FILTER (WHERE activity_key = 'google_review')
    INTO v_rev, v_ref, v_step, v_cap
    FROM public.retention_point_values WHERE agency_id = p_agency_id;

  -- n items in a week: each earlier same-kind item adds step%, capped at cap x step%.
  SELECT 5 * v_rev + v_rev * SUM(LEAST(i * v_step, v_cap * v_step) / 100.0) FILTER (WHERE i < 5)
    INTO v_rev_wk FROM generate_series(0, 4) i;
  SELECT 2 * v_ref + v_ref * SUM(LEAST(i * v_step, v_cap * v_step) / 100.0) FILTER (WHERE i < 2)
    INTO v_ref_wk FROM generate_series(0, 1) i;

  v_x := ROUND(v_base + v_rev_wk + v_ref_wk, 2);
  v_quarter := ROUND(v_x * 13, 0);

  SELECT rp->'curve'->'points' INTO v_pts
    FROM jsonb_array_elements(public.compute_role_earnings_projection(p_agency_id, CURRENT_DATE)->'roles') rp
   WHERE rp->>'role_key' = 'retention' LIMIT 1;
  IF v_pts IS NULL THEN RETURN '[]'::jsonb; END IF;

  SELECT e INTO a FROM jsonb_array_elements(v_pts) e WHERE (e->>'x')::numeric <= v_x ORDER BY (e->>'x')::numeric DESC LIMIT 1;
  SELECT e INTO b FROM jsonb_array_elements(v_pts) e WHERE (e->>'x')::numeric >= v_x ORDER BY (e->>'x')::numeric ASC LIMIT 1;
  IF a IS NULL OR b IS NULL THEN RETURN '[]'::jsonb; END IF;
  v_y := CASE WHEN (b->>'x')::numeric = (a->>'x')::numeric THEN (a->>'total')::numeric
              ELSE (a->>'total')::numeric + ((b->>'total')::numeric - (a->>'total')::numeric)
                    * (v_x - (a->>'x')::numeric) / ((b->>'x')::numeric - (a->>'x')::numeric) END;

  RETURN jsonb_build_array(jsonb_build_object(
    'team_member_id', NULL, 'first_name', 'Cassanie', 'is_me', false, 'is_test', true,
    'role_key', 'retention', 'x', v_x, 'window_weeks', 13, 'y', ROUND(v_y, 0),
    'quarter_points', v_quarter, 'combined_base_weekly', ROUND(v_base, 2),
    'reviews_weekly_points', ROUND(v_rev_wk, 2), 'referrals_weekly_points', ROUND(v_ref_wk, 2),
    'on_track', false));
END $function$;
