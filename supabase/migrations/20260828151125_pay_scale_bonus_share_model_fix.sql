-- FIX: expected_team_bonus_annual was computed as a per-point rate
-- (2/3 of one week's residual pool ÷ team weekly Sales Points, ≈ $1.02
-- per point). That linearization breaks: past the team's own weekly
-- production it pays out more than the entire pool holds (at 1000 pts it
-- promised ~$53k from a ~$20k sales-side pool). Found 2026-08-28 after
-- Peter flagged the numbers.
--
-- The comp system actually distributes the bonus pool by SHARES, in three
-- equal thirds: 1/3 by rolling 13-week Sales Points share, 1/3 by rolling
-- 4-week Sales Points share, 1/3 by retention weighted-hours share
-- (op-rule "Team comp — residual-pool design"). At a steady production
-- pace the two Sales Points thirds carry the same share, so for the
-- published scale:
--
--   bonus(X) = SP_pools_annual × X / (X + rest_of_team_weekly_SP)
--            + retention_pool_annual × wh_seat / (team_wh + wh_seat)
--
-- with the pool held at this quarter's average weekly distribution
-- ((qtd bonuses already paid + this week's pool) / weeks elapsed), the
-- rest of the team at its current production, and a sales seat carrying
-- 8 weighted retention hours. The share saturates toward the pool total
-- and can never exceed it. Commission column is unchanged and verified:
-- 1 Sales Point = $1 of team commission (locked design principle),
-- annual = weekly points × 52.
-- Same share math applied to the year-by-year grid and the computed
-- curves (retention, life specialist) inside
-- compute_role_earnings_projection so the chart, table, and tier cards
-- agree at any production level.

CREATE OR REPLACE FUNCTION public.reseed_pay_scale(p_agency_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
-- Rebuilds the sales pay scale: 101 rows, 0-1000 weekly Sales Points by 10.
-- Ladder + research record: migration pay_scale_table_and_curve_from_table.
-- Bonus model (share of the pool, saturating): migration
-- pay_scale_bonus_share_model_fix. Re-running refreshes pool + team inputs
-- from compute_weekly_comp_residual_pool at the latest settled week.
DECLARE
  v_week            date;
  v_diag            jsonb;
  v_weeks           numeric;
  v_weekly_pool     numeric;
  v_pool_wk_avg     numeric;
  v_sp_pools_annual numeric;
  v_ret_pool_annual numeric;
  v_rest_sp         numeric;
  v_team_wh         numeric;
  v_bonus           numeric;
  v_x               integer;
  v_i               integer;
  v_tier            integer;
  v_hourly          numeric;
  v_next            integer;
  v_n               integer := 0;
  c_thresholds  integer[] := ARRAY[0,100,175,250,300,325,355,390,425,460,500,545,595];
  c_hourly      numeric[] := ARRAY[15,16,17,18,19,20,21,22,23,24,25,26,27];
  c_seat_wh     numeric   := 8;  -- weighted retention hours a sales seat carries
BEGIN
  SELECT MAX(r.week_ending_date) INTO v_week
    FROM public.weekly_cpr_reports r
   WHERE r.agency_id = p_agency_id
     AND EXISTS (SELECT 1 FROM public.weekly_cpr_team_detail d
                  WHERE d.weekly_cpr_report_id = r.id AND d.bonus IS NOT NULL);

  SELECT x.diagnostics INTO v_diag
    FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_week) x
   LIMIT 1;

  v_weeks       := NULLIF(COALESCE((v_diag->'quarter'->>'weeks_elapsed_qtd')::numeric, 0), 0);
  v_weekly_pool := COALESCE((v_diag->'weekly_settlement'->>'weekly_bonus_pool')::numeric, 0);
  -- Quarter-average weekly distribution: bonuses already paid this quarter
  -- plus this week's pool, over weeks elapsed. Steadier than one week's
  -- residual.
  v_pool_wk_avg := (COALESCE((v_diag->'qtd_subtractions'->>'qtd_bonus_paid_prior')::numeric, 0)
                    + v_weekly_pool) / COALESCE(v_weeks, 1);
  v_sp_pools_annual := v_pool_wk_avg * 52 * 2.0 / 3.0;  -- 13-wk + 4-wk thirds
  v_ret_pool_annual := v_pool_wk_avg * 52 / 3.0;        -- retention-hours third
  v_rest_sp := COALESCE((v_diag->'team_totals'->>'qtd_sp_total')::numeric, 0) / COALESCE(v_weeks, 1);
  v_team_wh := COALESCE((v_diag->'team_totals'->>'wh_total')::numeric, 0);

  DELETE FROM public.pay_scale WHERE agency_id = p_agency_id AND role_key = 'sales';

  FOR v_x IN SELECT generate_series(0, 1000, 10) LOOP
    v_tier := 0; v_hourly := c_hourly[1]; v_next := NULL;
    FOR v_i IN 1..array_length(c_thresholds, 1) LOOP
      IF v_x >= c_thresholds[v_i] THEN
        v_tier := v_i - 1;
        v_hourly := c_hourly[v_i];
        v_next := CASE WHEN v_i < array_length(c_thresholds, 1) THEN c_thresholds[v_i + 1] ELSE NULL END;
      END IF;
    END LOOP;

    v_bonus := CASE WHEN v_x > 0 AND (v_x + v_rest_sp) > 0
                    THEN v_sp_pools_annual * (v_x / (v_x + v_rest_sp)) ELSE 0 END
             + CASE WHEN (v_team_wh + c_seat_wh) > 0
                    THEN v_ret_pool_annual * (c_seat_wh / (v_team_wh + c_seat_wh)) ELSE 0 END;

    INSERT INTO public.pay_scale (
      agency_id, role_key, sales_points, band, raise_tier,
      base_hourly, base_annual, next_raise_at,
      expected_commission_annual, expected_team_bonus_annual, updated_at
    ) VALUES (
      p_agency_id, 'sales', v_x,
      public.compute_sales_points_rating(p_agency_id, v_x),
      v_tier,
      v_hourly,
      round(v_hourly * 2080, 0),
      v_next,
      round(v_x * 52.0, 0),   -- one sales point = one dollar of commission
      round(v_bonus, 0),
      now()
    );
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$function$;

CREATE OR REPLACE FUNCTION public.compute_role_earnings_projection(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Earning potential by role / performer tier / year of employment, plus a
-- production curve per role. Sales curve reads public.pay_scale; retention
-- and life specialist curves are computed until their scales are set.
-- Team bonus everywhere = share of the pool (three equal thirds: 13-wk SP,
-- 4-wk SP, retention hours), pool held at this quarter's average weekly
-- distribution — see migration pay_scale_bonus_share_model_fix. Runtime
-- computation only, per core_principles compensation_data_freshness (650).
DECLARE
  v_week            date;
  v_diag            jsonb;
  v_weeks           numeric;
  v_weekly_pool     numeric;
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
  v_sp_weekly       numeric;
  v_commission      numeric;
  v_bonus           numeric;
  v_goals           numeric;
  v_extras          numeric;
  v_extras_note     text;
  v_wh              numeric;
  v_prem            numeric;
  v_q               numeric;
  v_unlicensed      boolean;
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
  -- year-of-employment ramps
  c_sales_ramp      numeric[] := ARRAY[0.55,0.85,1.00,1.05,1.10];
  c_ret_ramp        numeric[] := ARRAY[0.30,0.80,1.00,1.05,1.10];
  c_life_prem       numeric[] := ARRAY[47500,67500,97500,97500,97500];
  c_goals_wk        jsonb := '{"rock":10,"rock_n_roll":20,"rockstar":30,"rock_legend":40}'::jsonb;
BEGIN
  SELECT COALESCE(p_week_end_date, MAX(r.week_ending_date))
    INTO v_week
    FROM public.weekly_cpr_reports r
   WHERE r.agency_id = p_agency_id
     AND EXISTS (SELECT 1 FROM public.weekly_cpr_team_detail d
                  WHERE d.weekly_cpr_report_id = r.id AND d.bonus IS NOT NULL);

  SELECT x.diagnostics INTO v_diag
    FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_week) x
   LIMIT 1;

  v_pool_basis  := COALESCE((v_diag->'envelope'->>'annual_basis')::numeric, 0);
  v_weeks       := NULLIF(COALESCE((v_diag->'quarter'->>'weeks_elapsed_qtd')::numeric, 0), 0);
  v_weekly_pool := COALESCE((v_diag->'weekly_settlement'->>'weekly_bonus_pool')::numeric, 0);
  v_pool_wk_avg := (COALESCE((v_diag->'qtd_subtractions'->>'qtd_bonus_paid_prior')::numeric, 0)
                    + v_weekly_pool) / COALESCE(v_weeks, 1);
  v_sp_pools_annual := v_pool_wk_avg * 52 * 2.0 / 3.0;
  v_ret_pool_annual := v_pool_wk_avg * 52 / 3.0;
  v_rest_sp := COALESCE((v_diag->'team_totals'->>'qtd_sp_total')::numeric, 0) / COALESCE(v_weeks, 1);
  v_team_wh := COALESCE((v_diag->'team_totals'->>'wh_total')::numeric, 0);

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
            -- Marginal quarterly tiers on Life premium: 15% / 22% / 30%.
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
          ELSE
            v_sp_target := CASE r_role.role_key WHEN 'sales' THEN 100 ELSE 50 END;
            v_sp_ramp   := CASE r_role.role_key WHEN 'sales' THEN c_sales_ramp[y] ELSE c_ret_ramp[y] END;
            v_wh        := CASE r_role.role_key WHEN 'sales' THEN 8 ELSE 15 END;
            v_unlicensed := (r_role.role_key = 'retention' AND v_base <= 16 * 2080);
            v_sp_annual  := CASE WHEN v_unlicensed THEN 0
                                 ELSE v_sp_target * v_sp_ramp * r_tier.multiplier * 52 END;
            v_commission := v_sp_annual;  -- one sales point = one dollar
          END IF;

          -- Bonus = share of the pool: SP thirds by points share alongside
          -- the rest of the team, retention third by weighted-hours share.
          v_sp_weekly := v_sp_annual / 52.0;
          v_bonus := CASE WHEN v_sp_weekly > 0 AND (v_sp_weekly + v_rest_sp) > 0
                          THEN v_sp_pools_annual * (v_sp_weekly / (v_sp_weekly + v_rest_sp)) ELSE 0 END
                   + CASE WHEN (v_team_wh + v_wh) > 0
                          THEN v_ret_pool_annual * (v_wh / (v_team_wh + v_wh)) ELSE 0 END;
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

      -- Sales: curve from the pay scale table
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

      -- Computed curve (retention, life specialist, and sales fallback)
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
            v_bonus := CASE WHEN v_x > 0 AND (v_x + v_rest_sp) > 0
                            THEN v_sp_pools_annual * (v_x / (v_x + v_rest_sp)) ELSE 0 END
                     + CASE WHEN (v_team_wh + v_wh) > 0
                            THEN v_ret_pool_annual * (v_wh / (v_team_wh + v_wh)) ELSE 0 END;
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
           || 'share of the bonus pool: two thirds follow sales points (your points '
           || 'alongside the rest of the team''s), one third follows retention hours. '
           || 'The pool and the team''s production are held at this quarter''s pace, '
           || 'so the pool does not grow as the book grows — the right side of the '
           || 'curve understates a growing agency. The sales chart reads the '
           || 'published pay scale; the goals bonus is not in the chart total. '
           || 'The chart holds a steady production pace; years one and two '
           || 'typically run lower — see the year-by-year table.'
    )
  );
END;
$function$;

SELECT public.reseed_pay_scale('126794dd-25ff-47d2-a436-724499733365');
