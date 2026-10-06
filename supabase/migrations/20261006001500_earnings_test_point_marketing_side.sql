-- Cassanie test point now counts the marketing half of reviews and referrals (quoted and sold).
CREATE OR REPLACE FUNCTION public.earnings_test_point(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- TEST POINT "Cassanie" (Peter 2026-10-05). Not a person; admin-only; drawn on the Retention chart.
-- Combined base = Stephanie + Cassandra total points (sales + net retention + marketing) since
-- Retention Points began (the retention track's window), per week.
-- Plus, every week for one 13-week quarter: 5 Online Reviews and 2 referrals quoted AND sold.
--   Retention side (weekly stack): review and Referral Sold values from retention_point_values.
--   Marketing side (quarterly stack): Online Review, Referral Quoted, Referral Sold from
--   marketing_point_values, climbing per prior item in the quarter up to prior_cap.
-- x = quarter total / 13 (weekly pace), y = Retention curve at that x.
DECLARE
  v_wk integer; v_sum numeric; v_base numeric;
  v_rev numeric; v_ref numeric; v_step numeric; v_cap numeric;
  v_rev_wk numeric; v_ref_wk numeric;
  v_m_rev numeric; v_m_refq numeric; v_m_refs numeric;
  v_q_total numeric; v_x numeric; v_y numeric;
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

  -- Retention side, stacking within the week.
  SELECT MAX(points) FILTER (WHERE activity_key = 'google_review'),
         MAX(points) FILTER (WHERE activity_key = 'referral_sold'),
         MAX(prior_step_pct) FILTER (WHERE activity_key = 'google_review'),
         MAX(prior_cap) FILTER (WHERE activity_key = 'google_review')
    INTO v_rev, v_ref, v_step, v_cap
    FROM public.retention_point_values WHERE agency_id = p_agency_id;
  SELECT 5 * v_rev + v_rev * SUM(LEAST(i * v_step, v_cap * v_step) / 100.0)
    INTO v_rev_wk FROM generate_series(0, 4) i;
  SELECT 2 * v_ref + v_ref * SUM(LEAST(i * v_step, v_cap * v_step) / 100.0)
    INTO v_ref_wk FROM generate_series(0, 1) i;

  -- Marketing side, stacking within the quarter: 65 reviews, 26 referrals quoted, 26 sold.
  SELECT SUM(m.base_points + m.step_per_prior * LEAST(k, m.prior_cap)) INTO v_m_rev
    FROM public.marketing_point_values m CROSS JOIN generate_series(0, 64) k
   WHERE m.agency_id = p_agency_id AND m.event_key = 'google_review' AND m.is_active;
  SELECT SUM(m.base_points + m.step_per_prior * LEAST(k, m.prior_cap)) INTO v_m_refq
    FROM public.marketing_point_values m CROSS JOIN generate_series(0, 25) k
   WHERE m.agency_id = p_agency_id AND m.event_key = 'referral_quoted' AND m.is_active;
  SELECT SUM(m.base_points + m.step_per_prior * LEAST(k, m.prior_cap)) INTO v_m_refs
    FROM public.marketing_point_values m CROSS JOIN generate_series(0, 25) k
   WHERE m.agency_id = p_agency_id AND m.event_key = 'referral_sold' AND m.is_active;

  v_q_total := 13 * (v_base + v_rev_wk + v_ref_wk)
             + COALESCE(v_m_rev, 0) + COALESCE(v_m_refq, 0) + COALESCE(v_m_refs, 0);
  v_x := ROUND(v_q_total / 13, 2);

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
    'quarter_points', ROUND(v_q_total, 0), 'combined_base_weekly', ROUND(v_base, 2),
    'retention_reviews_weekly', ROUND(v_rev_wk, 2), 'retention_referrals_weekly', ROUND(v_ref_wk, 2),
    'marketing_reviews_weekly', ROUND(v_m_rev / 13, 2),
    'marketing_referrals_quoted_weekly', ROUND(v_m_refq / 13, 2),
    'marketing_referrals_sold_weekly', ROUND(v_m_refs / 13, 2),
    'on_track', false));
END $function$;
