CREATE OR REPLACE FUNCTION public.compute_role_earnings_projection(
  p_agency_id uuid,
  p_week_end_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
-- Earning potential by role / performer tier / year of employment.
-- Runtime computation only. Nothing here is stored as a "current" value,
-- per core_principles compensation_data_freshness (650).
-- See migration role_earnings_projection_tiers_and_function for the full
-- design record, including the O'Boyle & Aguinis (2012) power-law basis for
-- the tier multipliers.
DECLARE
  v_week            date;
  v_diag            jsonb;
  v_weekly_pool     numeric;
  v_team_wk_sp      numeric;
  v_team_wh         numeric;
  v_per_sp          numeric;   -- bonus dollars per sales point
  v_per_wh_wk       numeric;   -- bonus dollars per weighted retention hour, weekly
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
  -- year-of-employment ramps
  c_sales_ramp      numeric[] := ARRAY[0.55,0.85,1.00,1.05,1.10];
  c_ret_ramp        numeric[] := ARRAY[0.30,0.80,1.00,1.05,1.10];
  c_life_prem       numeric[] := ARRAY[47500,67500,97500,97500,97500];
  c_goals_wk        jsonb := '{"rock":10,"rock_n_roll":20,"rockstar":30,"rock_legend":40}'::jsonb;
BEGIN
  -- Latest week that actually has residual-pool data.
  SELECT COALESCE(p_week_end_date, MAX(r.week_ending_date))
    INTO v_week
    FROM public.weekly_cpr_reports r
   WHERE r.agency_id = p_agency_id
     AND EXISTS (SELECT 1 FROM public.weekly_cpr_team_detail d
                  WHERE d.weekly_cpr_report_id = r.id AND d.bonus IS NOT NULL);

  SELECT x.diagnostics INTO v_diag
    FROM public.compute_weekly_comp_residual_pool(p_agency_id, v_week) x
   LIMIT 1;

  v_weekly_pool := COALESCE((v_diag->'weekly_settlement'->>'weekly_bonus_pool')::numeric, 0);
  v_pool_basis  := COALESCE((v_diag->'envelope'->>'annual_basis')::numeric, 0);
  v_team_wk_sp  := NULLIF(COALESCE((v_diag->'team_totals'->>'qtd_sp_total')::numeric,0)
                          / NULLIF((v_diag->'quarter'->>'weeks_elapsed_qtd')::numeric,0), 0);
  v_team_wh     := NULLIF(COALESCE((v_diag->'team_totals'->>'wh_total')::numeric,0), 0);

  -- Two thirds of the pool follows sales points, one third follows weighted
  -- retention hours. Rates held at today's level; see design note on why.
  v_per_sp    := CASE WHEN v_team_wk_sp IS NULL THEN 0
                      ELSE (v_weekly_pool * 0.6667) / v_team_wk_sp END;
  v_per_wh_wk := CASE WHEN v_team_wh IS NULL THEN 0
                      ELSE (v_weekly_pool * 0.3333) / v_team_wh END;

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
              -- Year one recruiting package, never repeats.
              v_extras := 5000 + GREATEST(3000 - (v_commission / 4.0), 0);
              v_extras_note := 'Year one only: 5,000 signing bonus'
                || CASE WHEN (v_commission/4.0) < 3000
                        THEN ' plus first-quarter commission topped up to 3,000' ELSE '' END;
            END IF;
          ELSE
            v_sp_target := CASE r_role.role_key WHEN 'sales' THEN 100 ELSE 50 END;
            v_sp_ramp   := CASE r_role.role_key WHEN 'sales' THEN c_sales_ramp[y] ELSE c_ret_ramp[y] END;
            v_wh        := CASE r_role.role_key WHEN 'sales' THEN 8 ELSE 15 END;
            -- Unlicensed retention seats cannot quote or sell, so no sales points.
            v_unlicensed := (r_role.role_key = 'retention' AND v_base <= 16 * 2080);
            v_sp_annual  := CASE WHEN v_unlicensed THEN 0
                                 ELSE v_sp_target * v_sp_ramp * r_tier.multiplier * 52 END;
            v_commission := v_sp_annual;  -- one sales point = one dollar
          END IF;

          v_bonus := (v_sp_annual * v_per_sp) + (v_wh * v_per_wh_wk * 52);
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

      v_roles := v_roles || jsonb_build_object(
        'role_key', r_role.role_key,
        'role_label', r_role.role_label,
        'tiers', v_tiers
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
      'weekly_bonus_pool', round(v_weekly_pool,2),
      'bonus_dollars_per_sales_point', round(v_per_sp,4),
      'bonus_dollars_per_weighted_hour_weekly', round(v_per_wh_wk,4),
      'sales_points_target_weekly', jsonb_build_object('sales',100,'retention',50),
      'note', 'One sales point equals one dollar of commission. Bonus pool share '
           || 'rates are held at today''s level, which assumes the pool grows with '
           || 'production. Base pay steps come from the published pay bands. Tier '
           || 'multipliers follow a power-law performance curve (O''Boyle & Aguinis '
           || '2012), not an even spread.'
    )
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.compute_role_earnings_projection(uuid, date) TO authenticated;