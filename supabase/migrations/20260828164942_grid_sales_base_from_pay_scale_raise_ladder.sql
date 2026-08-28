-- Year-by-year grid base pay = the pay-scale raise ladder (one ladder
-- everywhere). Until now the sales rows of the year-by-year table pulled
-- base pay from earnings_projection_base_ladder (the old hire-band
-- ladder, $35,000-$40,000 for a Rock) while the Earning Potential chart
-- published base from public.pay_scale (the raise-tier ladder, $33,280
-- at 100 weekly points). Same candidate, two different base numbers.
-- This migration points the sales rows of the grid at pay_scale: each
-- projected year's weekly sales points are looked up on the same
-- 10-point rows the chart draws, raises are sticky year over year, and
-- the base handed to projected_team_bonus is that same ladder base — so
-- at matching points the table's bonus equals the chart's bonus to the
-- dollar. Retention and Life Specialist keep their existing base
-- ladders (the raise ladder is a sales ladder). Assumptions note gains
-- a sentence saying so.

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
-- pay_scale_bonus_mechanical_projection). All live inputs gathered once
-- by public.pay_scale_bonus_inputs — latest settled week, the same anchor
-- reseed_pay_scale uses. Runtime computation only, per core_principles
-- compensation_data_freshness (650).
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
  c_sales_ramp      numeric[] := ARRAY[0.55,0.85,1.00,1.05,1.10];
  c_ret_ramp        numeric[] := ARRAY[0.30,0.80,1.00,1.05,1.10];
  c_life_prem       numeric[] := ARRAY[47500,67500,97500,97500,97500];
  c_goals_wk        jsonb := '{"rock":10,"rock_n_roll":20,"rockstar":30,"rock_legend":40}'::jsonb;
BEGIN
  v_inputs := public.pay_scale_bonus_inputs(p_agency_id);

  v_week            := (v_inputs->>'as_of_week')::date;
  v_pool_annual     := COALESCE((v_inputs->>'pool_today_annual')::numeric, 0);
  v_pool_wk_avg     := v_pool_annual / 52.0;
  v_sp_pools_annual := v_pool_annual * 2.0 / 3.0;
  v_ret_pool_annual := v_pool_annual / 3.0;
  v_rest_sp         := COALESCE((v_inputs->>'rest_sp')::numeric, 0);
  v_team_wh         := COALESCE((v_inputs->>'team_wh')::numeric, 0);
  v_pool_basis      := COALESCE((v_inputs->>'basis_annual')::numeric, 0);

  FOR r_role IN
    SELECT DISTINCT l.role_key,
           CASE l.role_key WHEN 'sales' THEN 'Sales'
                           WHEN 'retention' THEN 'Retention'
                           WHEN 'life_specialist' THEN 'Life Specialist' END AS role_label,
           CASE l.role_key WHEN 'sales' THEN 10
                           WHEN 'retention' THEN 20
                           WHEN 'life_specialist' THEN 30 END AS ord
      FROM public.earnings_projection_base_ladder l
     WHERE l.agency_id = p_agency_id
     ORDER BY ord
  LOOP
    DECLARE v_tiers jsonb := '[]'::jsonb;
    BEGIN
      FOR r_tier IN
        SELECT t.tier_key, t.tier_label, t.applicant_pct, t.multiplier, t.descriptor
          FROM public.earnings_projection_tiers t
         WHERE t.agency_id = p_agency_id AND t.is_active
         ORDER BY t.sort_order
      LOOP
        v_years := '[]'::jsonb;
        v_base_sticky := 0;

        FOR y IN 1..5 LOOP
          SELECT l.annual_base, l.step_label INTO v_base, v_step
            FROM public.earnings_projection_base_ladder l
           WHERE l.agency_id = p_agency_id
             AND l.role_key = r_role.role_key
             AND l.tier_key = r_tier.tier_key
             AND l.year_num = y;

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
            -- Life Specialist: today's retention-hours slice (production
            -- enters as premium, not points).
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
              -- Base from the same pay-scale raise ladder the chart
              -- publishes: look up the row at this year's weekly points
              -- (floored to the 10-point grid). Raises are sticky — the
              -- base never steps back down in a later year.
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
                v_base := v_base_sticky;  -- keep the higher earlier raise
              END IF;
            END IF;
            -- Mechanical seasoned-book bonus, same function the pay scale
            -- seeds from.
            v_bonus := public.projected_team_bonus(v_inputs, v_sp_annual / 52.0, v_wh, v_base);
          END IF;

          v_goals := (c_goals_wk->>r_tier.tier_key)::numeric * 52
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

      IF r_role.role_key = 'sales' THEN
        SELECT jsonb_agg(jsonb_build_object(
                 'x', p.sales_points,
                 'base', round(p.base_annual, 0),
                 'total', round(p.base_annual + COALESCE(p.expected_commission_annual,0)
                                              + COALESCE(p.expected_team_bonus_annual,0), 0)
               ) ORDER BY p.sales_points)
          INTO v_points
          FROM public.pay_scale p
         WHERE p.agency_id = p_agency_id AND p.role_key = 'sales';

        IF v_points IS NOT NULL THEN
          SELECT jsonb_agg(jsonb_build_object(
                   'tier_key', lower(s.band),
                   'tier_label', s.band,
                   'from_x', s.fx
                 ) ORDER BY s.fx)
            INTO v_bands
            FROM (SELECT p.band, MIN(p.sales_points) AS fx
                    FROM public.pay_scale p
                   WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.band IS NOT NULL
                   GROUP BY p.band) s;

          SELECT p.base_annual INTO v_entry_base
            FROM public.pay_scale p
           WHERE p.agency_id = p_agency_id AND p.role_key = 'sales' AND p.sales_points = 0;

          v_curve := jsonb_build_object(
            'x_kind', 'weekly_sales_points',
            'x_label', 'Weekly sales points',
            'x_max', 1000,
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

        SELECT MIN(l.annual_base) INTO v_entry_base
          FROM public.earnings_projection_base_ladder l
         WHERE l.agency_id = p_agency_id AND l.role_key = r_role.role_key
           AND NOT (r_role.role_key = 'retention' AND l.annual_base <= 16 * 2080);

        v_bands := '[]'::jsonb;
        FOR r_tier IN
          SELECT t.tier_key, t.tier_label, t.multiplier,
                 (SELECT l.annual_base FROM public.earnings_projection_base_ladder l
                   WHERE l.agency_id = p_agency_id AND l.role_key = r_role.role_key
                     AND l.tier_key = t.tier_key AND l.year_num = 5) AS steady_base
            FROM public.earnings_projection_tiers t
           WHERE t.agency_id = p_agency_id AND t.is_active
           ORDER BY t.sort_order
        LOOP
          v_bands := v_bands || jsonb_build_object(
            'tier_key', r_tier.tier_key,
            'tier_label', r_tier.tier_label,
            'from_x', round(v_target * r_tier.multiplier, 1),
            'base_annual', round(COALESCE(r_tier.steady_base, v_entry_base), 0),
            'goals_weekly', (c_goals_wk->>r_tier.tier_key)::numeric
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
        'curve', v_curve
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
      'note', 'One sales point equals one dollar of commission. Team bonus is a '
           || 'share of the bonus pool, projected mechanically from your '
           || 'production: the real commission rate curve turns your points into '
           || 'the premium behind them, that premium builds a book sized at the '
           || 'agency''s live retention, the book''s earnings grow the pool, and '
           || 'the cost of your seat comes out first. Two thirds of the pool '
           || 'follow sales points, one third follows retention hours. Numbers '
           || 'show the seasoned book — at today''s retention the book reaches '
           || 'about seventy percent of that by year three. Base pay in the '
           || 'year-by-year table follows the same raise ladder the chart '
           || 'draws: the rate steps up as weekly pace crosses each raise '
           || 'tier, and a raise never steps back down. The goals bonus is '
           || 'not in the chart total. The chart holds a steady production pace; '
           || 'years one and two typically run lower — see the year-by-year table.'
    )
  );
END;
$function$;
