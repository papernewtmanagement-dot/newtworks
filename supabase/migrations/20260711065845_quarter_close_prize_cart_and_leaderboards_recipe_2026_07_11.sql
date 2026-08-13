-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-11 06:58:45 UTC (ledger name: quarter_close_prize_cart_and_leaderboards_recipe_2026_07_11) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260711065845.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Function invoked by the quarter-close automation. Runs at Q close 23:59 CT.
-- Idempotent: safe to re-run within a quarter.
CREATE OR REPLACE FUNCTION public.quarter_close_prize_cart_and_leaderboards(
  p_agency_id uuid,
  p_quarter_ending_date date
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_next_q_end          date;
  v_carried             int := 0;
  v_scorecard_annual    numeric := 0;
  v_next_budget         numeric := 0;
  v_pool_result         jsonb;
  v_mvp_id              uuid;
  v_mvp_sp              numeric;
  v_mvp_row_exists      boolean;
  v_result              jsonb;
BEGIN
  -- Determine next quarter end (next quarter's last Saturday, approx via +90 days & align)
  v_next_q_end := p_quarter_ending_date + INTERVAL '13 weeks';

  -- 1. Carry unwon prize_cart rows into next quarter
  WITH carried AS (
    INSERT INTO public.prize_cart (
      agency_id, quarter_ending_date, display_order,
      prize_description, prize_url, prize_value
    )
    SELECT agency_id, v_next_q_end, display_order,
           prize_description, prize_url, prize_value
    FROM public.prize_cart
    WHERE agency_id = p_agency_id
      AND quarter_ending_date = p_quarter_ending_date
      AND winner_team_member_id IS NULL
    RETURNING 1
  )
  SELECT COUNT(*) INTO v_carried FROM carried;

  -- 2. Compute next-quarter prize budget = 1% x on-time Scorecard annual
  v_pool_result := public.compute_pool_basis_and_envelope(p_agency_id, v_next_q_end);
  v_scorecard_annual := COALESCE((v_pool_result->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_next_budget := ROUND(v_scorecard_annual * 0.01, 2);

  INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
  VALUES (p_agency_id, v_next_q_end, v_next_budget,
          '1% × on-time Scorecard ($' || v_scorecard_annual::text || ' → $' || v_next_budget::text || ')')
  ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE
    SET budget_dollars = EXCLUDED.budget_dollars,
        formula_note   = EXCLUDED.formula_note;

  -- 3. Snapshot week's MVP into mvp_history if team won and no MVP recorded yet
  SELECT id INTO v_mvp_id FROM public.mvp_history
    WHERE agency_id = p_agency_id AND week_ending_date = p_quarter_ending_date;
  v_mvp_row_exists := v_mvp_id IS NOT NULL;

  IF NOT v_mvp_row_exists THEN
    SELECT d.team_member_id, MAX(d.sales_points) INTO v_mvp_id, v_mvp_sp
    FROM public.weekly_cpr_reports r
    JOIN public.weekly_cpr_team_detail d ON d.weekly_cpr_report_id = r.id
    WHERE r.agency_id = p_agency_id
      AND r.week_ending_date = p_quarter_ending_date
      AND r.won_the_week = true
    GROUP BY d.team_member_id
    ORDER BY MAX(d.sales_points) DESC NULLS LAST
    LIMIT 1;

    IF v_mvp_id IS NOT NULL AND COALESCE(v_mvp_sp, 0) > 0 THEN
      INSERT INTO public.mvp_history (agency_id, week_ending_date, team_member_id, sales_points_earned, prize_draws)
      VALUES (p_agency_id, p_quarter_ending_date, v_mvp_id, v_mvp_sp, 3);
    END IF;
  END IF;

  -- 4. Placeholder for leaderboard audit — full crossing-detection to be built out later.
  --    For now record that quarter-close ran.
  v_result := jsonb_build_object(
    'quarter_ending_date',        p_quarter_ending_date,
    'next_quarter_ending_date',   v_next_q_end,
    'prizes_carried',             v_carried,
    'next_quarter_budget_dollars', v_next_budget,
    'mvp_recorded',               (v_mvp_id IS NOT NULL AND NOT v_mvp_row_exists),
    'ran_at',                     now()
  );

  RETURN v_result;
END;
$$;

-- Register the recipe.
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  internal_handler, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'Quarter Close — prize cart carry + budget + MVP snapshot',
  'Runs at Q-close Saturday 23:59 CT. Carries unwon prize_cart rows to next quarter; computes 1% x on-time Scorecard for next-quarter prize budget; snapshots winning week MVP.',
  'cron',
  -- Q close Saturdays 2026-2027: Oct 3 2026, Jan 2 2027, Apr 3 2027, Jul 3 2027, Oct 2 2027.
  -- Use "last Sat before quarter boundary" pattern: 59 23 * * 6 with date guard in handler.
  '59 4 * * 0',
  'quarter_close_prize_cart_and_leaderboards_dispatcher',
  false  -- start inactive; will activate after wiring dispatcher
)
ON CONFLICT DO NOTHING;
