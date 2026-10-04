-- Earning Potential: draw the TENTATIVE retention raise track (Peter 2026-10-04).
-- Retention chart now runs on the same pay_scale ladder, x = weekly total points, and the
-- retention people's points sit at their track total. Pay is unchanged (track not live).
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('public.compute_role_earnings_projection(uuid,date)'::regprocedure)) <> 'd16b5fa562f4dbbedf12595862efea28'
  OR md5(pg_get_functiondef('public.earnings_curve_positions(uuid)'::regprocedure)) <> 'b106267ddd5243eb2ba7e424d5473f4e'
  OR md5(pg_get_functiondef('public.retention_raise_track(uuid,date)'::regprocedure)) <> 'ea68b39134a14c46d88f7261eebf9661' THEN
    RAISE EXCEPTION 'An Earning Potential function changed since it was read; re-read before replacing it';
  END IF;
END
$guard$;

DROP FUNCTION IF EXISTS public.earnings_raise_ladder(uuid);
CREATE FUNCTION public.earnings_raise_ladder(p_agency_id uuid, p_track text DEFAULT 'sales')
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- The published raise ladder, one copy. 'sales': thresholds are weekly sales points.
  -- 'retention' (TENTATIVE track, Peter 2026-10-04): thresholds are weekly total points
  -- (pay_scale.retention_points), tier 1 is starting pay, and the licence tiers name the
  -- licence that grants them without the points.
  SELECT jsonb_agg(jsonb_build_object(
           'tier', p.raise_tier,
           'hourly', p.base_hourly,
           'weekly', round(p.base_hourly * 40, 0),
           'annual', round(p.base_hourly * 2080, 0),
           'threshold', CASE WHEN p_track = 'retention' THEN COALESCE(p.retention_points, 0)
                             ELSE NULLIF(p.sales_points, 0) END,
           'lookback_quarters', p.lookback_quarters,
           'license', CASE WHEN p_track = 'retention'
                            AND (COALESCE(p.retention_requires_pc, false) OR COALESCE(p.retention_requires_lh, false))
                           THEN p.retention_requirement END
         ) ORDER BY p.raise_tier)
    FROM public.pay_scale p
   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
     AND (p_track <> 'retention' OR p.raise_tier >= 1);
$function$;
REVOKE ALL ON FUNCTION public.earnings_raise_ladder(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.earnings_raise_ladder(uuid, text) TO service_role;

CREATE OR REPLACE FUNCTION public.retention_raise_track(p_agency_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS TABLE(team_member_id uuid, first_name text, role_level text, current_hourly numeric, title_increment numeric, current_tier integer, license_tier integer, next_tier integer, next_points integer, next_lookback_quarters integer, weeks_counted integer, avg_sales_points numeric, avg_retention_points numeric, avg_marketing_points numeric, avg_total_points numeric, points_to_go numeric, lapse_now numeric, lapse_prior numeric, lapse_check_passed boolean, earned_by text, would_be_tier integer, would_be_hourly numeric, ladder_live boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Retention raise track (TENTATIVE, Peter 2026-10-04). The one place the track is computed.
-- Live only when settings.retention_ladder_live = 'true'; until then it previews and
-- nothing reads it to change pay (team_raise_progress stays licence-only for retention).
-- Measure: weekly TOTAL points = sales points (raw) + net retention points + marketing points,
-- averaged over the NEXT tier's lookback_quarters, capped at the weeks Retention Points have
-- existed (settings.retention_points_go_live_week_end) and at weeks since hire, the same short
-- first window a new hire gets.
-- Steps: a held licence grants every tier its flags allow (automatic bump, no lapse check);
-- otherwise one tier per review when the total meets the next tier's retention_points and,
-- if settings.retention_ladder_lapse_check is on, the blended lapse rate at the last completed
-- week is no worse than 13 weeks earlier. Pay never steps down. Manager title rides on top.
DECLARE
  v_live boolean;
  v_check boolean;
  v_go_live date;
  v_last date;
  v_lapse_now numeric;
  v_lapse_prior numeric;
  v_gate_ok boolean;
  v_max_n integer;
  v_weeks jsonb := '[]'::jsonb;
  s record;
  v_hourly numeric;
  v_title numeric;
  v_cur integer;
  v_lic integer;
  v_nx_tier integer;
  v_nx_pts integer;
  v_nx_lb integer;
  v_n integer;
  v_sp numeric;
  v_rp numeric;
  v_mp numeric;
  v_total numeric;
  v_target integer;
  v_by text;
  v_target_rate numeric;
BEGIN
  PERFORM public.require_login('staff');

  SELECT COALESCE(MAX(st.setting_value) FILTER (WHERE st.setting_key = 'retention_ladder_live'), 'false') = 'true',
         COALESCE(MAX(st.setting_value) FILTER (WHERE st.setting_key = 'retention_ladder_lapse_check'), 'true') = 'true',
         (MAX(st.setting_value) FILTER (WHERE st.setting_key = 'retention_points_go_live_week_end'))::date
    INTO v_live, v_check, v_go_live
    FROM public.settings st
   WHERE st.agency_id = p_agency_id;

  -- Last completed Sunday-to-Saturday week on or before the as-of date.
  v_last := public.rp_week_end(p_as_of);
  IF v_last > p_as_of THEN v_last := v_last - 7; END IF;

  SELECT l.annualized_rate INTO v_lapse_now
    FROM public.compute_lapse_rate(p_agency_id, v_last) l WHERE l.line = 'blended';
  SELECT l.annualized_rate INTO v_lapse_prior
    FROM public.compute_lapse_rate(p_agency_id, v_last - 91) l WHERE l.line = 'blended';
  v_gate_ok := NOT v_check
               OR (v_lapse_now IS NOT NULL AND v_lapse_prior IS NOT NULL AND v_lapse_now <= v_lapse_prior);

  -- Weekly retention + marketing points per person, computed once for the widest window.
  v_max_n := 52;
  IF v_go_live IS NOT NULL THEN
    v_max_n := LEAST(v_max_n, ((v_last - v_go_live) / 7) + 1);
  END IF;

  IF v_max_n > 0 THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('wk', x.wk, 'tm', x.tm, 'rp', x.rp, 'mp', x.mp)), '[]'::jsonb)
      INTO v_weeks
      FROM (
        SELECT u.wk, u.tm, SUM(u.rp) AS rp, SUM(u.mp) AS mp
          FROM (
            SELECT (v_last - 7 * g.i) AS wk, w.team_member_id AS tm, w.net_points AS rp, 0::numeric AS mp
              FROM generate_series(0, v_max_n - 1) AS g(i)
             CROSS JOIN LATERAL public.compute_weekly_retention_points(p_agency_id, v_last - 7 * g.i) w
            UNION ALL
            SELECT m.week_end_date, m.team_member_id, 0::numeric, m.points
              FROM generate_series(0, v_max_n - 1) AS g(i)
             CROSS JOIN LATERAL public.marketing_points_weekly(p_agency_id, v_last - 7 * g.i) m
             WHERE m.week_end_date = v_last - 7 * g.i
          ) u
         GROUP BY u.wk, u.tm
      ) x;
  END IF;

  FOR s IN
    SELECT t.id, t.first_name, t.role_level, t.pay_type, t.pay_rate, t.hire_date,
           COALESCE(t.license_pc, false) AS has_pc, COALESCE(t.license_lh, false) AS has_lh
      FROM public.team t
     WHERE t.agency_id = p_agency_id AND t.category = 'agency'
       AND t.role_category = 'Retention'
       AND t.is_active = true AND t.archived_at IS NULL AND t.is_test_user IS NOT TRUE
       AND t.pay_rate IS NOT NULL
       -- Admins see every retention seat; anyone else only their own.
       AND (auth.role() IS NULL OR auth.role() = 'service_role'
            OR public.is_agency_admin() OR t.id = public.current_team_member_id())
     ORDER BY t.first_name
  LOOP
    v_hourly := CASE WHEN UPPER(COALESCE(s.pay_type, '')) = 'SALARY' THEN s.pay_rate / 40.0 ELSE s.pay_rate END;
    v_title := COALESCE((SELECT p.base_hourly FROM public.pay_scale p
                          WHERE p.agency_id = p_agency_id AND p.role_key = 'title_step'
                            AND p.title_label = s.role_level LIMIT 1), 0);

    SELECT p.raise_tier INTO v_cur
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.base_hourly <= (v_hourly - v_title)
     ORDER BY p.base_hourly DESC LIMIT 1;

    SELECT MAX(p.raise_tier) INTO v_lic
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.retention_requirement IS NOT NULL
       AND (s.has_pc OR NOT COALESCE(p.retention_requires_pc, false))
       AND (s.has_lh OR NOT COALESCE(p.retention_requires_lh, false));

    v_nx_tier := NULL; v_nx_pts := NULL; v_nx_lb := NULL;
    SELECT p.raise_tier, p.retention_points, p.lookback_quarters
      INTO v_nx_tier, v_nx_pts, v_nx_lb
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.raise_tier > GREATEST(COALESCE(v_cur, 0), COALESCE(v_lic, 0))
     ORDER BY p.raise_tier LIMIT 1;

    v_n := GREATEST(LEAST(COALESCE(v_nx_lb, 4) * 13, v_max_n), 0);
    IF s.hire_date IS NOT NULL THEN
      v_n := LEAST(v_n, GREATEST(((v_last - public.rp_week_end(s.hire_date)) / 7) + 1, 0));
    END IF;

    IF v_n > 0 THEN
      v_sp := COALESCE(public.team_member_sales_points_avg_nwk(s.id, v_n, v_last), 0);
      SELECT COALESCE(SUM((e->>'rp')::numeric), 0) / v_n,
             COALESCE(SUM((e->>'mp')::numeric), 0) / v_n
        INTO v_rp, v_mp
        FROM jsonb_array_elements(v_weeks) e
       WHERE (e->>'tm')::uuid = s.id
         AND (e->>'wk')::date > v_last - 7 * v_n;
      v_total := ROUND(v_sp + v_rp + v_mp, 2);
    ELSE
      v_sp := NULL; v_rp := NULL; v_mp := NULL; v_total := NULL;
    END IF;

    IF COALESCE(v_lic, 0) > COALESCE(v_cur, 0) THEN
      v_target := v_lic; v_by := 'license';
    ELSIF v_nx_pts IS NOT NULL AND v_total IS NOT NULL AND v_total >= v_nx_pts AND v_gate_ok THEN
      v_target := v_nx_tier; v_by := 'points';
    ELSE
      v_target := v_cur; v_by := NULL;
    END IF;

    SELECT p.base_hourly INTO v_target_rate
      FROM public.pay_scale p
     WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
       AND p.raise_tier = v_target;

    team_member_id := s.id;
    first_name := s.first_name;
    role_level := s.role_level;
    current_hourly := ROUND(v_hourly, 2);
    title_increment := v_title;
    current_tier := v_cur;
    license_tier := v_lic;
    next_tier := v_nx_tier;
    next_points := v_nx_pts;
    next_lookback_quarters := v_nx_lb;
    weeks_counted := v_n;
    avg_sales_points := ROUND(v_sp, 2);
    avg_retention_points := ROUND(v_rp, 2);
    avg_marketing_points := ROUND(v_mp, 2);
    avg_total_points := v_total;
    points_to_go := CASE WHEN v_nx_pts IS NULL OR v_total IS NULL THEN NULL
                         ELSE GREATEST(ROUND(v_nx_pts - v_total, 1), 0) END;
    lapse_now := ROUND(v_lapse_now * 100, 2);
    lapse_prior := ROUND(v_lapse_prior * 100, 2);
    lapse_check_passed := v_gate_ok;
    earned_by := v_by;
    would_be_tier := v_target;
    would_be_hourly := GREATEST(ROUND(v_hourly, 2), COALESCE(v_target_rate, 0) + v_title);
    ladder_live := v_live;
    RETURN NEXT;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_role_earnings_projection(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Earning potential by role / performer tier / year of employment, plus a
-- production curve per role. Sales curve reads public.pay_scale. Team
-- bonus for point-producing seats = mechanical seasoned-book projection
-- (public.projected_team_bonus; model record: migration
-- pay_scale_bonus_mechanical_projection). All live inputs gathered once by
-- public.pay_scale_bonus_inputs, all of them today's figures -- this is not
-- a forecast over time, it is what pay looks like at each production level
-- at the agency as it stands. Runtime computation only, per
-- core_principles compensation_data_freshness (650).
DECLARE
  v_inputs          jsonb;
  v_week            date;
  v_pool_annual     numeric;
  v_pool_wk_avg     numeric;
  v_sp_pools_annual numeric;
  v_ret_pool_annual numeric;
  v_rest_sp         numeric;
  v_team_wh         numeric;
  v_pool_basis      numeric;
  v_roles           jsonb := '[]'::jsonb;
  r_role            record;
  r_tier            record;
  v_years           jsonb;
  y                 int;
  v_base            numeric;
  v_step            text;
  v_sp_target       numeric;
  v_sp_ramp         numeric;
  v_sp_annual       numeric;
  v_commission      numeric;
  v_bonus           numeric;
  v_goals           numeric;
  v_extras          numeric;
  v_extras_note     text;
  v_wh              numeric;
  v_prem            numeric;
  v_q               numeric;
  v_unlicensed      boolean;
  v_base_candidate  numeric;
  v_base_sticky     numeric;
  v_ps_hourly       numeric;
  v_ps_tier         int;
  -- curve
  v_curve           jsonb;
  v_bands           jsonb;
  v_points          jsonb;
  v_ladder          jsonb;
  v_entry_base      numeric;
  v_x_max           numeric;
  v_x_kind          text;
  v_x_label         text;
  v_target          numeric;
  v_xs              numeric[];
  v_x               numeric;
  v_band_base       numeric;
  v_band_goals      numeric;
  i                 int;
  -- band pattern
  v_band_n          int;
  v_danger_w        numeric;
  v_top_start       numeric;
  v_sales_x_max     numeric;
  c_sales_ramp      numeric[] := ARRAY[0.55,0.85,1.00,1.05,1.10];
  c_ret_ramp        numeric[] := ARRAY[0.30,0.80,1.00,1.05,1.10];
  c_life_prem       numeric[] := ARRAY[47500,67500,97500,97500,97500];
BEGIN
  PERFORM public.require_login('staff');
  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  v_week            := (v_inputs->>'as_of_week')::date;
  v_pool_annual     := COALESCE((v_inputs->>'pool_today_annual')::numeric, 0);
  v_pool_wk_avg     := v_pool_annual / 52.0;
  v_sp_pools_annual := v_pool_annual * 2.0 / 3.0;
  v_ret_pool_annual := v_pool_annual / 3.0;
  v_rest_sp         := COALESCE((v_inputs->>'rest_sp')::numeric, 0);
  v_team_wh         := COALESCE((v_inputs->>'team_wh')::numeric, 0);
  v_pool_basis      := COALESCE((v_inputs->>'basis_annual')::numeric, 0);

  -- Where the band pattern runs out: top band start + (band count x Danger
  -- width). Danger D, Caution 2D, Good 3D, Great 4D, Elite 5D.
  SELECT COUNT(*) INTO v_band_n
    FROM public.pay_scale b
   WHERE b.agency_id = p_agency_id AND b.role_key = 'sales' AND b.band_starts_here;
  -- Danger's width is where the second band begins.
  SELECT b.sales_points INTO v_danger_w
    FROM public.pay_scale b
   WHERE b.agency_id = p_agency_id AND b.role_key = 'sales' AND b.band_starts_here
     AND b.sales_points > 0
   ORDER BY b.sales_points LIMIT 1;
  SELECT b.sales_points INTO v_top_start
    FROM public.pay_scale b
   WHERE b.agency_id = p_agency_id AND b.role_key = 'sales' AND b.band_starts_here
   ORDER BY b.sales_points DESC LIMIT 1;
  v_sales_x_max := COALESCE(v_top_start, 0) + COALESCE(v_band_n, 0) * COALESCE(v_danger_w, 0);
  IF NOT (v_sales_x_max > 0) THEN v_sales_x_max := 1000; END IF;

  FOR r_role IN
    SELECT DISTINCT l.role_key,
           CASE l.role_key WHEN 'sales' THEN 'Sales'
                           WHEN 'retention' THEN 'Retention'
                           WHEN 'life_specialist' THEN 'Life Specialist' END AS role_label,
           CASE l.role_key WHEN 'sales' THEN 10
                           WHEN 'retention' THEN 20
                           WHEN 'life_specialist' THEN 30 END AS ord
      FROM (VALUES ('sales'),('retention'),('life_specialist')) AS l(role_key)
     ORDER BY ord
  LOOP
    DECLARE v_tiers jsonb := '[]'::jsonb;
    BEGIN
      v_ladder := NULL;

      FOR r_tier IN
        SELECT t.tier_key, t.tier_label, t.applicant_pct, t.multiplier, t.descriptor,
               t.goals_weekly
          FROM public.pay_scale_performer_tiers(p_agency_id) t
      LOOP
        v_years := '[]'::jsonb;
        v_base_sticky := 0;

        FOR y IN 1..5 LOOP
          SELECT b.annual_base, b.step_label INTO v_base, v_step
            FROM public.pay_scale_role_base(p_agency_id, r_role.role_key,
                                            r_tier.tier_key, y) b;

          v_extras := 0; v_extras_note := NULL;
          v_commission := 0; v_sp_annual := 0;

          IF r_role.role_key = 'life_specialist' THEN
            v_wh   := 5;
            v_prem := c_life_prem[y] * r_tier.multiplier;
            v_q    := v_prem / 4.0;
            v_commission := 4.0 * (
                 LEAST(v_q, 10000) * 0.15
               + GREATEST(LEAST(v_q, 20000) - 10000, 0) * 0.22
               + GREATEST(v_q - 20000, 0) * 0.30
            );
            IF y = 1 THEN
              v_extras := 5000 + GREATEST(3000 - (v_commission / 4.0), 0);
              v_extras_note := 'Year one only: 5,000 signing bonus'
                || CASE WHEN (v_commission/4.0) < 3000
                        THEN ' plus first-quarter commission topped up to 3,000' ELSE '' END;
            END IF;
            v_bonus := CASE WHEN (v_team_wh + v_wh) > 0
                            THEN v_ret_pool_annual * (v_wh / (v_team_wh + v_wh)) ELSE 0 END;
          ELSE
            v_sp_target := CASE r_role.role_key WHEN 'sales' THEN 100 ELSE 50 END;
            v_sp_ramp   := CASE r_role.role_key WHEN 'sales' THEN c_sales_ramp[y] ELSE c_ret_ramp[y] END;
            v_wh        := CASE r_role.role_key WHEN 'sales' THEN 8 ELSE 15 END;
            v_unlicensed := (r_role.role_key = 'retention' AND v_base <= 16 * 2080);
            v_sp_annual  := CASE WHEN v_unlicensed THEN 0
                                 ELSE v_sp_target * v_sp_ramp * r_tier.multiplier * 52 END;
            v_commission := v_sp_annual;  -- one sales point = one dollar
            IF r_role.role_key = 'sales' THEN
              SELECT p.base_annual, p.base_hourly, p.raise_tier
                INTO v_base_candidate, v_ps_hourly, v_ps_tier
                FROM public.pay_scale p
               WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
                 AND p.sales_points = LEAST(1000, GREATEST(0,
                       floor((v_sp_annual / 52.0) / 10.0) * 10))::int;
              IF v_base_candidate IS NOT NULL AND v_base_candidate >= v_base_sticky THEN
                v_base_sticky := v_base_candidate;
                v_base := v_base_candidate;
                v_step := '$' || to_char(v_ps_hourly, 'FM990.00') || '/hr'
                       || CASE WHEN COALESCE(v_ps_tier, 0) > 0
                               THEN ' — raise tier ' || v_ps_tier
                               ELSE ' — starting rate' END;
              ELSIF v_base_candidate IS NOT NULL THEN
                v_base := v_base_sticky;
              END IF;
            END IF;
            v_bonus := public.projected_team_bonus(v_inputs, v_sp_annual / 52.0, v_wh, v_base);
          END IF;

          v_goals := COALESCE(r_tier.goals_weekly, 0) * 52
                     * CASE WHEN y = 1 THEN 0.5 ELSE 1 END;

          v_years := v_years || jsonb_build_object(
            'year', y,
            'base', round(v_base, 0),
            'step_label', v_step,
            'commission', round(v_commission, 0),
            'bonus_pool', round(v_bonus, 0),
            'goals_bonus', round(v_goals, 0),
            'extras', round(v_extras, 0),
            'extras_note', v_extras_note,
            'total', round(v_base + v_commission + v_bonus + v_goals + v_extras, 0)
          );
        END LOOP;

        v_tiers := v_tiers || jsonb_build_object(
          'tier_key', r_tier.tier_key,
          'tier_label', r_tier.tier_label,
          'applicant_pct', r_tier.applicant_pct,
          'multiplier', r_tier.multiplier,
          'descriptor', r_tier.descriptor,
          'years', v_years
        );
      END LOOP;

      v_curve := NULL;
      v_points := NULL;

      IF r_role.role_key = 'retention' THEN
        -- Retention track (TENTATIVE, Peter 2026-10-04): same scale as the sales ladder, but x is the
        -- weekly TOTAL of sales + retention + marketing points. Base follows pay_scale.retention_points
        -- (tier 1 is starting pay), licences are the automatic bump. Drawn so the track can be seen;
        -- pay does not change until settings.retention_ladder_live is turned on.
        SELECT jsonb_agg(jsonb_build_object(
                 'x', g.x,
                 'base', round(g.base, 0),
                 'commission', round(g.x * 52, 0),
                 'base_comm', round(g.base + g.x * 52, 0),
                 'bonus', round(g.bonus, 0),
                 'goals', 0,
                 'total', round(g.base + g.x * 52 + g.bonus, 0)
               ) ORDER BY g.x)
          INTO v_points
          FROM (SELECT p.sales_points AS x, rb.base,
                       public.projected_team_bonus(v_inputs, p.sales_points, 15, rb.base) AS bonus
                  FROM public.pay_scale p
                  CROSS JOIN LATERAL (
                    SELECT COALESCE(MAX(t.base_annual), 16 * 2080) AS base
                      FROM public.pay_scale t
                     WHERE t.agency_id = p_agency_id AND t.role_key = 'sales' AND t.tier_starts_here
                       AND t.raise_tier >= 1
                       AND (t.raise_tier = 1 OR t.retention_points <= p.sales_points)) rb
                 WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
                   AND p.sales_points <= v_sales_x_max) g;
        v_ladder := public.earnings_raise_ladder(p_agency_id, 'retention');
      END IF;

      IF r_role.role_key IN ('sales', 'retention') THEN
        IF r_role.role_key = 'sales' THEN
        SELECT jsonb_agg(jsonb_build_object(
                 'x', p.sales_points,
                 'base', round(p.base_annual, 0),
                 'commission', round(COALESCE(p.expected_commission_annual,0), 0),
                 'base_comm', round(p.base_annual + COALESCE(p.expected_commission_annual,0), 0),
                 'bonus', round(COALESCE(p.expected_team_bonus_annual,0)
                               + COALESCE(p.expected_goals_bonus_annual,0), 0),
                 'goals', round(COALESCE(p.expected_goals_bonus_annual,0), 0),
                 'total', round(p.base_annual + COALESCE(p.expected_commission_annual,0)
                                              + COALESCE(p.expected_team_bonus_annual,0)
                                              + COALESCE(p.expected_goals_bonus_annual,0), 0)
               ) ORDER BY p.sales_points)
          INTO v_points
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
           AND p.sales_points <= v_sales_x_max;

        -- The published raise ladder, with its real thresholds and the
        -- window each tier is measured over. One copy, in
        -- public.earnings_raise_ladder.
        v_ladder := public.earnings_raise_ladder(p_agency_id);
        END IF;

        IF v_points IS NOT NULL THEN
          SELECT jsonb_agg(jsonb_build_object(
                   'tier_key', lower(s.band),
                   'tier_label', s.band,
                   'from_x', s.fx,
                   'nickname', n.band_tier_label,
                   'applicant_pct', n.band_applicant_pct,
                   'traits', n.band_tier_traits
                 ) ORDER BY s.fx)
            INTO v_bands
            FROM (SELECT p.band, MIN(p.sales_points) AS fx
                    FROM public.pay_scale p
                   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales'
                     AND p.band IS NOT NULL AND p.sales_points <= v_sales_x_max
                   GROUP BY p.band) s
            LEFT JOIN public.pay_scale n
              ON n.agency_id = p_agency_id AND n.role_key = 'sales'
             AND n.sales_points = s.fx AND n.band_tier_key IS NOT NULL;

          SELECT p.base_annual INTO v_entry_base
            FROM public.pay_scale p
           WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.sales_points = 0;
          IF r_role.role_key = 'retention' THEN
            v_entry_base := (v_points->0->>'base')::numeric;
          END IF;

          v_curve := jsonb_build_object(
            'x_kind', CASE WHEN r_role.role_key = 'retention' THEN 'weekly_total_points' ELSE 'weekly_sales_points' END,
            'x_label', CASE WHEN r_role.role_key = 'retention' THEN 'Weekly total points (sales + retention + marketing)' ELSE 'Weekly sales points' END,
            'x_max', v_sales_x_max,
            'entry_base', round(COALESCE(v_entry_base, 0), 0),
            'source', 'pay_scale',
            'bands', COALESCE(v_bands, '[]'::jsonb),
            'points', v_points
          );
        END IF;
      END IF;

      IF v_curve IS NULL THEN
        IF r_role.role_key = 'life_specialist' THEN
          v_target := 97500; v_x_kind := 'annual_life_premium'; v_x_label := 'Annual life premium';
        ELSIF r_role.role_key = 'sales' THEN
          v_target := 100;   v_x_kind := 'weekly_sales_points'; v_x_label := 'Weekly sales points';
        ELSE
          v_target := 50;    v_x_kind := 'weekly_sales_points'; v_x_label := 'Weekly sales points';
        END IF;

        SELECT MIN(p.base_annual) INTO v_entry_base
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.tier_starts_here
           AND ((r_role.role_key = 'retention'
                 AND p.retention_reached_year IS NOT NULL
                 AND p.base_annual > 16 * 2080)
             OR (r_role.role_key = 'life_specialist'
                 AND p.life_specialist_reached_year IS NOT NULL));

        v_bands := '[]'::jsonb;
        FOR r_tier IN
          SELECT t.tier_key, t.tier_label, t.multiplier, t.goals_weekly,
                 (SELECT b.annual_base FROM public.pay_scale_role_base(
                    p_agency_id, r_role.role_key, t.tier_key, 5) b) AS steady_base
            FROM public.pay_scale_performer_tiers(p_agency_id) t
        LOOP
          v_bands := v_bands || jsonb_build_object(
            'tier_key', r_tier.tier_key,
            'tier_label', r_tier.tier_label,
            'from_x', round(v_target * r_tier.multiplier, 1),
            'base_annual', round(COALESCE(r_tier.steady_base, v_entry_base), 0),
            'goals_weekly', COALESCE(r_tier.goals_weekly, 0)
          );
        END LOOP;

        SELECT MAX((b->>'from_x')::numeric) * 1.06 INTO v_x_max
          FROM jsonb_array_elements(v_bands) b;
        v_x_max := COALESCE(v_x_max, v_target * 2);

        v_xs := ARRAY[]::numeric[];
        FOR i IN 0..120 LOOP
          v_xs := v_xs || round(v_x_max * i / 120.0, 2);
        END LOOP;

        v_points := '[]'::jsonb;
        FOREACH v_x IN ARRAY v_xs LOOP
          SELECT (b->>'base_annual')::numeric, (b->>'goals_weekly')::numeric
            INTO v_band_base, v_band_goals
            FROM jsonb_array_elements(v_bands) b
           WHERE (b->>'from_x')::numeric <= v_x
           ORDER BY (b->>'from_x')::numeric DESC
           LIMIT 1;
          IF v_band_base IS NULL THEN v_band_base := v_entry_base; v_band_goals := 0; END IF;

          IF r_role.role_key = 'life_specialist' THEN
            v_q := v_x / 4.0;
            v_commission := 4.0 * (
                 LEAST(v_q, 10000) * 0.15
               + GREATEST(LEAST(v_q, 20000) - 10000, 0) * 0.22
               + GREATEST(v_q - 20000, 0) * 0.30
            );
            v_bonus := CASE WHEN (v_team_wh + 5) > 0
                            THEN v_ret_pool_annual * (5 / (v_team_wh + 5)) ELSE 0 END;
          ELSE
            v_commission := v_x * 52;  -- one sales point = one dollar
            v_wh := CASE r_role.role_key WHEN 'sales' THEN 8 ELSE 15 END;
            v_bonus := public.projected_team_bonus(v_inputs, v_x, v_wh, v_band_base);
          END IF;

          v_points := v_points || jsonb_build_object(
            'x', v_x,
            'base', round(v_band_base, 0),
            'commission', round(v_commission, 0),
            'base_comm', round(v_band_base + v_commission, 0),
            'bonus', round(v_bonus, 0),
            'total', round(v_band_base + v_commission + v_bonus + (v_band_goals * 52), 0)
          );
        END LOOP;

        v_curve := jsonb_build_object(
          'x_kind', v_x_kind,
          'x_label', v_x_label,
          'x_max', round(v_x_max, 1),
          'entry_base', round(v_entry_base, 0),
          'source', 'computed',
          'bands', v_bands,
          'points', v_points
        );
      END IF;

      v_roles := v_roles || jsonb_build_object(
        'role_key', r_role.role_key,
        'role_label', r_role.role_label,
        'tiers', v_tiers,
        'curve', v_curve,
        'raise_ladder', v_ladder
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id,
    'as_of_week', v_week,
    'computed_at', now(),
    'roles', v_roles,
    'assumptions', jsonb_build_object(
      'pool_basis_annual', round(v_pool_basis,0),
      'weekly_bonus_pool', round(v_pool_wk_avg,2),
      'annual_sales_points_pools', round(v_sp_pools_annual,0),
      'annual_retention_pool', round(v_ret_pool_annual,0),
      'rest_of_team_weekly_sp', round(v_rest_sp,1),
      'team_weighted_hours_weekly', round(v_team_wh,1),
      'sales_points_target_weekly', jsonb_build_object('sales',100,'retention',50),
      'pool_pct_used', round(COALESCE((v_inputs->>'pool_pct')::numeric,0) * 100, 2),
      'note', 'One sales point equals one dollar of commission. Team bonus is a '
           || 'share of the bonus pool, projected mechanically from your '
           || 'production: the real commission rate curve turns your points into '
           || 'the premium behind them, that premium builds a book sized at the '
           || 'agency''s live retention, the book''s earnings grow the pool, and '
           || 'the cost of your seat comes out first. Two thirds of the pool '
           || 'follow sales points, one third follows retention hours. Every '
           || 'input is today''s — today''s share of agency earnings funding the '
           || 'pool, today''s book, today''s retention. This is not a forecast '
           || 'over time; it is what each production level pays at the agency as '
           || 'it stands. Numbers '
           || 'show the seasoned book — at today''s retention the book reaches '
           || 'about seventy percent of that by year three. Base pay in the '
           || 'year-by-year table follows the same raise ladder the chart '
           || 'draws: the rate steps up as weekly pace crosses each raise '
           || 'tier, and a raise never steps back down. The goals bonus is '
           || 'in the chart total, alongside the team bonus. The chart holds a '
           || 'steady production pace; '
           || 'years one and two typically run lower — see the year-by-year table.'
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.earnings_curve_positions(p_agency_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
SELECT public.require_login('staff');
  -- Production on the chart is the same average the raise review measures
  -- (team_raise_progress): the look-back window of the person's next step. A seat with
  -- no pace step ahead (retention climbs on licences, or the top of the ladder) shows
  -- the four-quarter average, the window every step from the fourth on uses, shortened
  -- to time since hire so a newer teammate is not averaged over weeks before they started.
  -- Pay carries the manager title money separately so the label can show ladder step
  -- plus title (Peter 2026-10-03: the old 13-week figure did not match the raise rule).
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'team_member_id',  s.id,
           'first_name',      s.first_name,
           'is_me',           s.id = public.current_team_member_id(),
           'role_key',        lower(s.role_category),
           'x',               s.avg_sp,
           'window_weeks',    s.window_wk,
           'y',               p.on_time_annual,
           'ytd_paid',        p.ytd_paid,
           'as_of_week',      p.week_ending_date,
           'current_hourly',  s.current_hourly,
           'step_hourly',     s.tier_hourly,
           'title_hourly',    s.title_increment,
           'title_label',     CASE WHEN COALESCE(s.title_increment,0) > 0 THEN s.role_level END,
           'next_hourly',     s.next_hourly,
           'next_step_hourly', s.next_hourly - COALESCE(s.title_increment, 0),
           'on_track',        COALESCE(s.on_track, false)
         ) ORDER BY s.first_name), '[]'::jsonb)
    FROM (
      SELECT t.id, t.first_name, t.role_category, t.role_level,
             rp.current_hourly, rp.tier_hourly, rp.title_increment, rp.next_hourly, rp.on_track,
             CASE WHEN lower(t.role_category) = 'retention'
                    THEN (SELECT r.weeks_counted FROM public.retention_raise_track(p_agency_id) r WHERE r.team_member_id = t.id)
                  WHEN rp.avg_weekly_sp IS NOT NULL THEN rp.lookback_quarters * 13
                  ELSE GREATEST(1, LEAST(52, COALESCE(rp.weeks_employed, 52))) END AS window_wk,
             CASE WHEN lower(t.role_category) = 'retention'
                  -- Retention chart's x is the retention track's weekly total points (2026-10-04).
                  THEN (SELECT r.avg_total_points FROM public.retention_raise_track(p_agency_id) r WHERE r.team_member_id = t.id)
             ELSE COALESCE(rp.avg_weekly_sp,
                      ROUND(public.team_member_sales_points_avg_nwk(
                        t.id, GREATEST(1, LEAST(52, COALESCE(rp.weeks_employed, 52)))), 2)) END AS avg_sp
        FROM public.team t
        LEFT JOIN public.team_raise_progress(p_agency_id) rp ON rp.team_member_id = t.id
       WHERE t.agency_id                  = p_agency_id
         AND t.category                   = 'agency'
         AND COALESCE(t.role_level, '')  <> 'Owner'
         AND t.is_active = true AND t.archived_at IS NULL
         AND t.is_test_user IS NOT TRUE
         AND lower(COALESCE(t.role_category, '')) IN ('sales', 'retention')
         AND (public.is_agency_admin()
              OR t.id = public.current_team_member_id())
    ) s
    LEFT JOIN public.team_on_time_annual_pay(p_agency_id) p
      ON p.team_member_id = s.id
   WHERE s.avg_sp IS NOT NULL;
$function$;

