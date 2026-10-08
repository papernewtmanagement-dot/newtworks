-- Biggest gap to the next raise (Peter 2026-10-07, revised same night). Sales seats for now.
-- 1. Tier imbalance: one more sale a month (3 a quarter) on each tiered line (auto, fire, life),
--    at the person's average premium on that line (agency average if they have none),
--    repriced through compute_sp_from_production. The line that adds the most is the gap.
-- 2. Own best: last finished quarter swapped for the person's best finished quarter on the
--    line where that adds the most.
-- Pace and next step come from team_raise_progress (prorated), the same average the dot shows.
CREATE OR REPLACE FUNCTION public.raise_gap_scenario(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_extra CONSTANT integer := 3;   -- one more sale a month
  v_out jsonb := '[]'::jsonb;
  r record;
  v_cs date;
  v_q record;
  v_qs jsonb;
  v_u jsonb;
  v_base jsonb;
  v_scen jsonb;
  v_sc jsonb;
  v_res jsonb;
  v_sp_base numeric;
  v_sp numeric;
  v_line text;
  v_lift numeric;
  v_avg numeric;
  v_apps numeric;
  v_prem numeric;
  v_agency_avg jsonb := '{}'::jsonb;
  v_imb jsonb;
  v_best jsonb;
  v_new_x numeric;
  v_tier integer;
  v_tier_rate numeric;
  v_hire date;
  v_n integer;
  i integer;
BEGIN
  PERFORM public.require_login('staff');
  SELECT c.cycle_start INTO v_cs FROM public.current_cycle_info(p_agency_id, p_as_of) c;

  -- Agency average premium per sale on each line, last four finished quarters.
  SELECT jsonb_object_agg(l.line, ROUND(l.prem / NULLIF(l.apps, 0), 2)) INTO v_agency_avg
    FROM (
      SELECT x.line, SUM((ps.sp->'units'->>(x.line || '_apps'))::numeric) AS apps,
                     SUM((ps.sp->'units'->>(x.line || '_premium'))::numeric) AS prem
        FROM generate_series(1, 4) g(k)
       CROSS JOIN LATERAL public.current_cycle_info(p_agency_id, v_cs - 1 - 91 * (g.k - 1)) c
       CROSS JOIN LATERAL public.production_sales_points_for(p_agency_id, c.cycle_start, c.cycle_end) ps
       CROSS JOIN (VALUES ('auto'), ('fire'), ('life')) x(line)
       GROUP BY x.line
    ) l;

  FOR r IN SELECT * FROM public.team_raise_progress(p_agency_id, p_as_of, true) rp
            WHERE rp.role_category = 'Sales' AND NOT rp.at_top AND rp.avg_weekly_sp IS NOT NULL
              AND (public.is_agency_admin() OR rp.team_member_id = public.current_team_member_id())
  LOOP
    SELECT t.hire_date INTO v_hire FROM public.team t WHERE t.id = r.team_member_id;

    -- Finished quarters the person worked in full, newest first, up to four.
    v_qs := '[]'::jsonb;
    FOR i IN 1..4 LOOP
      SELECT * INTO v_q FROM public.current_cycle_info(p_agency_id, v_cs - 1 - 91 * (i - 1));
      EXIT WHEN v_hire IS NOT NULL AND v_q.cycle_start < v_hire;
      SELECT ps.sp->'units' INTO v_u
        FROM public.production_sales_points_for(p_agency_id, v_q.cycle_start, v_q.cycle_end) ps
       WHERE ps.team_member_id = r.team_member_id;
      v_qs := v_qs || jsonb_build_array(COALESCE(v_u, '{}'::jsonb) || jsonb_build_object('quarter', v_q.quarter_label));
    END LOOP;
    CONTINUE WHEN jsonb_array_length(v_qs) < 1;

    v_base := v_qs->0;
    v_sp_base := (public.compute_sp_from_production(
                   (v_base->>'auto_apps')::numeric, (v_base->>'fire_apps')::numeric,
                   (v_base->>'life_premium')::numeric, (v_base->>'health_premium')::numeric,
                   (v_base->>'auto_premium')::numeric, (v_base->>'fire_premium')::numeric)
                 ->'commission'->>'total_commission')::numeric;

    -- Build every candidate quarter, then price them all the same way.
    v_scen := '[]'::jsonb;
    FOREACH v_line IN ARRAY ARRAY['auto', 'fire', 'life'] LOOP
      SELECT SUM((q->>(v_line || '_apps'))::numeric), SUM((q->>(v_line || '_premium'))::numeric)
        INTO v_apps, v_prem FROM jsonb_array_elements(v_qs) q;
      v_avg := COALESCE(ROUND(v_prem / NULLIF(v_apps, 0), 2), (v_agency_avg->>v_line)::numeric, 0);
      v_scen := v_scen || jsonb_build_array(jsonb_build_object(
        'kind', 'imbalance', 'line', v_line, 'avg_premium', v_avg,
        'q', v_base || jsonb_build_object(
               v_line || '_apps',    COALESCE((v_base->>(v_line || '_apps'))::numeric, 0) + c_extra,
               v_line || '_premium', COALESCE((v_base->>(v_line || '_premium'))::numeric, 0) + c_extra * v_avg)));
      IF jsonb_array_length(v_qs) >= 2 THEN
        SELECT q INTO v_u FROM jsonb_array_elements(v_qs) q
         ORDER BY CASE WHEN v_line = 'life' THEN (q->>'life_premium')::numeric
                       ELSE (q->>(v_line || '_apps'))::numeric END DESC NULLS LAST
         LIMIT 1;
        v_scen := v_scen || jsonb_build_array(jsonb_build_object(
          'kind', 'best', 'line', v_line, 'best_quarter', v_u->>'quarter',
          'best_value', CASE WHEN v_line = 'life' THEN (v_u->>'life_premium')::numeric ELSE (v_u->>(v_line || '_apps'))::numeric END,
          'q', v_base || jsonb_build_object(
                 v_line || '_apps',    v_u->(v_line || '_apps'),
                 v_line || '_premium', v_u->(v_line || '_premium'))));
      END IF;
    END LOOP;

    v_imb := NULL; v_best := NULL;
    FOR v_sc IN SELECT * FROM jsonb_array_elements(v_scen) LOOP
      v_sp := (public.compute_sp_from_production(
                 (v_sc->'q'->>'auto_apps')::numeric, (v_sc->'q'->>'fire_apps')::numeric,
                 (v_sc->'q'->>'life_premium')::numeric, (v_sc->'q'->>'health_premium')::numeric,
                 (v_sc->'q'->>'auto_premium')::numeric, (v_sc->'q'->>'fire_premium')::numeric)
               ->'commission'->>'total_commission')::numeric;
      v_lift := ROUND((v_sp - v_sp_base) / 13.0, 1);
      CONTINUE WHEN v_lift < 1;
      v_new_x := ROUND(r.avg_weekly_sp + v_lift, 1);
      SELECT p.raise_tier, p.base_hourly INTO v_tier, v_tier_rate
        FROM public.pay_scale p
       WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
         AND p.sales_points <= v_new_x
       ORDER BY p.raise_tier DESC LIMIT 1;
      -- Weeks at the new pace until the next step's window average clears its bar,
      -- each new week replacing one at the current average.
      v_n := r.lookback_quarters * 13;
      v_res := (v_sc - 'q') || jsonb_build_object(
        'line_label',     CASE v_sc->>'line' WHEN 'auto' THEN 'Auto' WHEN 'fire' THEN 'Fire' ELSE 'Life' END,
        'last_quarter',   v_base->>'quarter',
        'last_value',     CASE WHEN v_sc->>'line' = 'life' THEN COALESCE((v_base->>'life_premium')::numeric, 0)
                               ELSE COALESCE((v_base->>((v_sc->>'line') || '_apps'))::numeric, 0) END,
        'extra_sales',    c_extra,
        'lift_weekly',    v_lift,
        'x',              v_new_x,
        'reached_tier',   GREATEST(v_tier, COALESCE(r.current_tier, 0)),
        'reached_hourly', GREATEST(COALESCE(v_tier_rate, 0) + COALESCE(r.title_increment, 0), r.current_hourly),
        'weeks_to_next',  CASE WHEN r.next_threshold IS NOT NULL AND v_new_x > r.next_threshold
                                    AND r.avg_weekly_sp < r.next_threshold
                               THEN CEIL((r.next_threshold - r.avg_weekly_sp) * v_n / (v_new_x - r.avg_weekly_sp))::int END);
      IF v_sc->>'kind' = 'imbalance' AND (v_imb IS NULL OR v_lift > (v_imb->>'lift_weekly')::numeric) THEN v_imb := v_res; END IF;
      IF v_sc->>'kind' = 'best' AND (v_best IS NULL OR v_lift > (v_best->>'lift_weekly')::numeric) THEN v_best := v_res; END IF;
    END LOOP;
    CONTINUE WHEN v_imb IS NULL AND v_best IS NULL;

    v_out := v_out || jsonb_build_array(COALESCE(v_imb, v_best) || jsonb_build_object(
      'team_member_id', r.team_member_id,
      'current_hourly', r.current_hourly,
      'next_tier',      r.next_tier,
      'best',           CASE WHEN v_imb IS NOT NULL THEN v_best END));
  END LOOP;
  RETURN v_out;
END;
$function$;

