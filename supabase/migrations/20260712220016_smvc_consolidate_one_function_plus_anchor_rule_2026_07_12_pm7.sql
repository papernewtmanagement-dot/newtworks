-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-12 22:00:16 UTC (ledger name: smvc_consolidate_one_function_plus_anchor_rule_2026_07_12_pm7) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260712220016.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- 2026-07-12 pm7 — Peter directives:
--   1) ONE on-time SMVC compute function. Any place calculating on-time SMVC
--      must go through it. Was: 3 callers, 2 different FS credits sources,
--      2 different anchor rules, produced 2.53% vs 2.822% on same page.
--   2) Anchor rule for annualizing YTD gross:
--      Latest comp statement day < 20 (first-half issue) → anchor = 15th of MM
--      Latest comp statement day >= 20 (second-half issue) → anchor = last of MM
--      SF pay periods end on 15th and last day only.
-- ============================================================================

-- (1) Canonical SMVC helper. All three callers below now use this.
CREATE OR REPLACE FUNCTION public.compute_agency_on_time_smvc(
  p_agency_id uuid,
  p_as_of_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_program_year     int := EXTRACT(YEAR FROM p_as_of_date)::int;
  v_snap             record;
  v_book             record;
  v_effective_as_of  date;
  v_pc_production    numeric;
  v_auto_gain        numeric;
  v_fire_gain        numeric;
  v_fs_credits       numeric;
  v_ips_activity     numeric;
  v_pc_book_premium  numeric;
  v_smvc             jsonb;
  v_on_time_smvc_pct numeric;
  v_on_time_smvc_dol numeric;
  v_smvc_dollar_diff numeric;
  v_applied_smvc     numeric;
BEGIN
  -- Latest snapshot with YTD data (production + gain inputs)
  SELECT * INTO v_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_as_of_date
    AND auto_new_ytd IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF v_snap.id IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'as_of_date', p_as_of_date,
      'on_time_smvc_pct', NULL, 'on_time_smvc_dollars', 0,
      'pc_book_premium', 0, 'note', 'no agency_snapshot with YTD data',
      'computed_at', now()
    );
  END IF;

  v_pc_production   := COALESCE(v_snap.auto_new_ytd, 0) + COALESCE(v_snap.fire_new_ytd, 0);
  v_auto_gain       := COALESCE(v_snap.auto_new_ytd, 0) - COALESCE(v_snap.auto_lost_ytd, 0);
  v_fire_gain       := COALESCE(v_snap.fire_new_ytd, 0) - COALESCE(v_snap.fire_lost_ytd, 0);
  -- FS credits: life commissions from comp_recap (matches section 11).
  -- Was previously (in two callers): agency_snapshot.life_paid_for_premium_ytd — WRONG.
  v_fs_credits      := public.compute_fs_commissions_ytd(p_agency_id, p_as_of_date);
  v_ips_activity    := COALESCE(v_snap.ips_new_money_ytd, 0);
  v_effective_as_of := LEAST(p_as_of_date, v_snap.snapshot_date);

  v_smvc := public.compute_on_time_smvc_with_better_of(
    p_agency_id, v_program_year,
    v_pc_production, v_auto_gain, v_fire_gain,
    v_fs_credits, v_ips_activity, v_effective_as_of
  );
  v_on_time_smvc_pct := NULLIF(v_smvc->>'applied_smvc_decimal', '')::numeric;

  -- Book premium for on-time SMVC $ conversion
  SELECT snapshot_date, auto_premium, fire_premium INTO v_book
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_as_of_date
    AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;
  v_pc_book_premium := COALESCE(v_book.auto_premium, 0) + COALESCE(v_book.fire_premium, 0);
  v_on_time_smvc_dol := COALESCE(v_on_time_smvc_pct, 0) * v_pc_book_premium;

  SELECT smvc_rate_pc INTO v_applied_smvc FROM public.agency WHERE id = p_agency_id;
  IF v_on_time_smvc_pct IS NOT NULL AND v_applied_smvc IS NOT NULL AND v_pc_book_premium IS NOT NULL THEN
    v_smvc_dollar_diff := (v_on_time_smvc_pct - v_applied_smvc) * v_pc_book_premium;
  END IF;

  RETURN jsonb_build_object(
    'agency_id',            p_agency_id,
    'as_of_date',           p_as_of_date,
    'effective_as_of',      v_effective_as_of,
    'snapshot_date',        v_snap.snapshot_date,
    'book_snapshot_date',   v_book.snapshot_date,
    'on_time_smvc_pct',     v_on_time_smvc_pct,
    'on_time_smvc_dollars', ROUND(v_on_time_smvc_dol, 2),
    'pc_book_premium',      v_pc_book_premium,
    'applied_smvc_rate',    v_applied_smvc,
    'smvc_dollar_diff',     v_smvc_dollar_diff,
    'fs_credits_ytd',       v_fs_credits,
    'bands_complete',       COALESCE((v_smvc->>'bands_complete')::boolean, false),
    'computed_breakdown',   v_smvc,
    'computed_at',          now()
  );
END;
$$;

-- (2) get_cpr_section_11 — call the canonical helper
CREATE OR REPLACE FUNCTION public.get_cpr_section_11(p_agency_id uuid, p_week_ending_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_program_year      int := EXTRACT(YEAR FROM p_week_ending_date)::int;
  v_smvc_result       jsonb;
  v_snap              record;
  v_smvc_on_time      numeric; v_smvc_applied numeric;
  v_smvc_dollar_diff  numeric; v_pc_premium   numeric;
  v_fs_credits        numeric;
  v_effective_as_of   date;
  v_scorecard         jsonb;  v_sc_on_time     numeric;
  v_sc_last_year      numeric; v_sc_dollar_diff numeric;
  v_cycle             record;
  v_curr_q_end        date;
  v_prize_cart_budget numeric; v_wtq_trip_budget numeric;
  v_wtq_scaling       numeric := 1.0;
BEGIN
  v_smvc_result := public.compute_agency_on_time_smvc(p_agency_id, p_week_ending_date);

  v_smvc_on_time     := NULLIF(v_smvc_result->>'on_time_smvc_pct','')::numeric;
  v_smvc_applied     := NULLIF(v_smvc_result->>'applied_smvc_rate','')::numeric;
  v_smvc_dollar_diff := NULLIF(v_smvc_result->>'smvc_dollar_diff','')::numeric;
  v_pc_premium       := NULLIF(v_smvc_result->>'pc_book_premium','')::numeric;
  v_fs_credits       := NULLIF(v_smvc_result->>'fs_credits_ytd','')::numeric;
  v_effective_as_of  := NULLIF(v_smvc_result->>'effective_as_of','')::date;

  -- Snapshot_date for output (production values live on this snapshot but we don't emit them here)
  SELECT * INTO v_snap FROM public.agency_snapshot
  WHERE agency_id = p_agency_id AND snapshot_date <= p_week_ending_date AND cadence='weekly'
  ORDER BY snapshot_date DESC LIMIT 1;

  v_scorecard    := public.compute_scorecard_bonus(p_agency_id, p_week_ending_date);
  v_sc_on_time   := NULLIF(v_scorecard->>'bonus_projected','')::numeric;
  v_sc_last_year := NULLIF(v_scorecard->>'last_year_bonus','')::numeric;
  IF v_sc_on_time IS NOT NULL AND v_sc_last_year IS NOT NULL THEN
    v_sc_dollar_diff := v_sc_on_time - v_sc_last_year;
  END IF;

  SELECT * INTO v_cycle FROM public.current_cycle_info(p_agency_id, p_week_ending_date);
  v_curr_q_end := v_cycle.cycle_end;

  IF v_sc_on_time IS NOT NULL THEN
    v_prize_cart_budget := 0.01 * v_sc_on_time;
    v_wtq_trip_budget   := 0.01 * v_sc_on_time * v_wtq_scaling;
  END IF;

  RETURN jsonb_build_object(
    'program_year', v_program_year, 'week_ending_date', p_week_ending_date,
    'snapshot_date', v_snap.snapshot_date,
    'effective_as_of_date', v_effective_as_of,
    'smvc', jsonb_build_object(
      'on_time', v_smvc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_smvc_applied, 'applied', v_smvc_applied,
      'dollar_diff', v_smvc_dollar_diff,
      'fs_commissions_ytd', v_fs_credits,
      'bands_complete', COALESCE((v_smvc_result->>'bands_complete')::boolean, false),
      'pc_premium_basis', v_pc_premium,
      'computed_breakdown', v_smvc_result->'computed_breakdown'),
    'scorecard_bonus', jsonb_build_object(
      'on_time', v_sc_on_time, 'last_wk', NULL, 'last_q', NULL,
      'last_year', v_sc_last_year, 'dollar_diff', v_sc_dollar_diff,
      'bonus_ytd', (v_scorecard->>'bonus_ytd')::numeric,
      'bonus_rate', (v_scorecard->>'bonus_rate')::numeric,
      'total_points', (v_scorecard->>'total_points')::numeric,
      'computed_breakdown', v_scorecard),
    'prize_cart_budget', jsonb_build_object(
      'value', v_prize_cart_budget,
      'formula', '1% × current OT Scorecard projection',
      'curr_q_end', v_curr_q_end,
      'curr_q_scorecard', v_sc_on_time,
      'note', CASE WHEN v_prize_cart_budget IS NULL THEN 'no Scorecard projection available' ELSE NULL END),
    'wtq_trip_budget', jsonb_build_object(
      'value', v_wtq_trip_budget,
      'formula', '1% × current OT Scorecard projection × (winner/leader scaling)',
      'curr_q_end', v_curr_q_end,
      'curr_q_scorecard', v_sc_on_time,
      'scaling', v_wtq_scaling,
      'note', CASE WHEN v_wtq_trip_budget IS NULL THEN 'no Scorecard projection available'
                   WHEN v_wtq_scaling = 1.0 THEN 'mid-cycle — scaling defaults to 1.0 until winner ≠ leader is recorded at cycle close'
                   ELSE NULL END),
    'computed_at', now());
END;
$$;

-- (3) compute_pool_basis_and_envelope — canonical SMVC + Peter's anchor rule
CREATE OR REPLACE FUNCTION public.compute_pool_basis_and_envelope(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_year              int  := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_smvc_rate_pc      numeric;
  v_strip_factor      numeric;

  v_pc_gross_ytd      numeric;
  v_lh_ytd            numeric;
  v_max_period_month  int;
  v_latest_stmt_day   int;
  v_comp_anchor_date  date;
  v_days_elapsed_comp int;
  v_annualization_comp numeric;
  v_anchor_source     text;

  v_pc_gross_annual   numeric;
  v_pc_stripped_annual numeric;
  v_lh_annual         numeric;

  v_smvc_result       jsonb;
  v_smvc_anchor_date  date;
  v_book_snap_date    date;
  v_smvc_breakdown    jsonb;
  v_on_time_smvc_pct  numeric;
  v_pc_book_premium   numeric;
  v_on_time_smvc_dol  numeric;

  v_scorecard         jsonb;
  v_on_time_scc_dol   numeric;

  v_total_basis       numeric;
  v_pool_pct_row      record;
  v_pool_pct          numeric;
  v_weekly_envelope   numeric;
  v_annual_envelope   numeric;
BEGIN
  SELECT smvc_rate_pc INTO v_smvc_rate_pc FROM public.agency WHERE id = p_agency_id;
  v_strip_factor := 8.0 / (8.0 + (v_smvc_rate_pc * 100.0));

  -- comp_recap YTD sums + latest period_month
  SELECT
    COALESCE(SUM(CASE WHEN comp_category IN ('auto_new','auto_renewal','fire_new','fire_renewal') THEN amount END), 0),
    COALESCE(SUM(CASE WHEN comp_category IN ('life_new','life_renewal','health_new','health_renewal') THEN amount END), 0),
    MAX(period_month)
  INTO v_pc_gross_ytd, v_lh_ytd, v_max_period_month
  FROM public.comp_recap
  WHERE agency_id = p_agency_id
    AND period_year = v_year
    AND (period_year || '-' || LPAD(period_month::text, 2, '0') || '-01')::date <= p_week_end_date;

  -- Peter's anchor rule (2026-07-12 pm7):
  -- Look at latest statement day (from filename YY_MM_DD) for MAX(period_month).
  -- Day < 20  → first-half statement (~10th) → pay period ended 15th of MM → anchor = MM/15
  -- Day >= 20 → second-half statement (~25th) → pay period ended last day of MM → anchor = last day of MM
  SELECT MAX(NULLIF(substring(d.file_name FROM '^\d{2}_\d{2}_(\d{2})'), '')::int)
  INTO v_latest_stmt_day
  FROM public.comp_recap cr
  JOIN public.documents d ON d.id = cr.source_document_id
  WHERE cr.agency_id = p_agency_id
    AND cr.period_year = v_year
    AND cr.period_month = v_max_period_month
    AND d.file_name ~ '^\d{2}_\d{2}_\d{2}';

  IF v_latest_stmt_day IS NULL OR v_latest_stmt_day < 20 THEN
    v_comp_anchor_date := make_date(v_year, v_max_period_month, 15);
    v_anchor_source    := 'first_half_statement → pay period end = 15th';
  ELSE
    v_comp_anchor_date := (make_date(v_year, v_max_period_month, 1) + INTERVAL '1 month - 1 day')::date;
    v_anchor_source    := 'second_half_statement → pay period end = last day';
  END IF;

  v_days_elapsed_comp := (v_comp_anchor_date - make_date(v_year, 1, 1))::int + 1;
  v_annualization_comp := 365.0 / v_days_elapsed_comp::numeric;

  v_pc_gross_annual    := v_pc_gross_ytd * v_annualization_comp;
  v_pc_stripped_annual := v_pc_gross_annual * v_strip_factor;
  v_lh_annual          := v_lh_ytd * v_annualization_comp;

  -- Canonical SMVC compute
  v_smvc_result      := public.compute_agency_on_time_smvc(p_agency_id, p_week_end_date);
  v_smvc_breakdown   := v_smvc_result->'computed_breakdown';
  v_on_time_smvc_pct := NULLIF(v_smvc_result->>'on_time_smvc_pct','')::numeric;
  v_on_time_smvc_dol := COALESCE(NULLIF(v_smvc_result->>'on_time_smvc_dollars','')::numeric, 0);
  v_pc_book_premium  := COALESCE(NULLIF(v_smvc_result->>'pc_book_premium','')::numeric, 0);
  v_smvc_anchor_date := NULLIF(v_smvc_result->>'effective_as_of','')::date;
  v_book_snap_date   := NULLIF(v_smvc_result->>'book_snapshot_date','')::date;

  -- Scorecard anchors against snapshot date (unchanged behavior)
  v_scorecard := public.compute_scorecard_bonus(
    p_agency_id,
    COALESCE(NULLIF(v_smvc_result->>'snapshot_date','')::date, p_week_end_date)
  );
  v_on_time_scc_dol := COALESCE(NULLIF(v_scorecard->>'bonus_projected','')::numeric, 0);

  v_total_basis := v_pc_stripped_annual + v_lh_annual + v_on_time_smvc_dol + v_on_time_scc_dol;

  SELECT pool_pct, phase, basis_regime, plan_note INTO v_pool_pct_row
  FROM public.team_comp_pool_schedule
  WHERE agency_id = p_agency_id AND week_end_date = p_week_end_date LIMIT 1;

  v_pool_pct        := v_pool_pct_row.pool_pct;
  v_annual_envelope := (v_pool_pct / 100.0) * v_total_basis;
  v_weekly_envelope := v_annual_envelope / 52.0;

  RETURN jsonb_build_object(
    'agency_id',     p_agency_id,
    'week_end_date', p_week_end_date,
    'basis', jsonb_build_object(
      'pc_gross_ytd',              ROUND(v_pc_gross_ytd, 2),
      'pc_gross_annualized',       ROUND(v_pc_gross_annual, 2),
      'strip_factor',              ROUND(v_strip_factor, 5),
      'pc_stripped_annualized',    ROUND(v_pc_stripped_annual, 2),
      'lh_ytd',                    ROUND(v_lh_ytd, 2),
      'lh_annualized',             ROUND(v_lh_annual, 2),
      'pc_book_premium',           v_pc_book_premium,
      'on_time_smvc_pct',          v_on_time_smvc_pct,
      'on_time_smvc_dollars',      ROUND(v_on_time_smvc_dol, 2),
      'on_time_scorecard_dollars', ROUND(v_on_time_scc_dol, 2),
      'total_basis_annual',        ROUND(v_total_basis, 2),
      'smvc_rate_pc_applied',      v_smvc_rate_pc,
      'comp_anchor_date',          v_comp_anchor_date,
      'comp_anchor_source',        v_anchor_source,
      'comp_latest_statement_day', v_latest_stmt_day,
      'comp_days_elapsed',         v_days_elapsed_comp,
      'comp_annualization',        ROUND(v_annualization_comp, 5),
      'smvc_anchor_date',          v_smvc_anchor_date,
      'book_snapshot_date',        v_book_snap_date
    ),
    'schedule', jsonb_build_object(
      'pool_pct',      v_pool_pct,
      'phase',         v_pool_pct_row.phase,
      'basis_regime',  v_pool_pct_row.basis_regime,
      'plan_note',     v_pool_pct_row.plan_note
    ),
    'envelope', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_envelope, 2),
      'weekly_dollars', ROUND(v_weekly_envelope, 2)
    ),
    'computed_at', now()
  );
END;
$$;

-- (4) compute_retention_budget_weekly — canonical SMVC
CREATE OR REPLACE FUNCTION public.compute_retention_budget_weekly(p_agency_id uuid, p_week_ending_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_scheduled_multiplier numeric;
  v_phase                text;
  v_smvc_result          jsonb;
  v_on_time_smvc         numeric;
  v_bands_complete       boolean;
  v_smvc_source          text;
  v_days_elapsed         int;
  v_book_snap            record;
  v_auto_premium         numeric;
  v_fire_premium         numeric;
  v_life_premium         numeric;
  v_total_premium        numeric;
  v_combined_rate        numeric;
  v_budget               numeric;
  v_note                 text;
BEGIN
  SELECT multiplier, phase INTO v_scheduled_multiplier, v_phase
  FROM public.retention_budget_schedule
  WHERE agency_id = p_agency_id AND week_end_date = p_week_ending_date
  LIMIT 1;

  IF v_scheduled_multiplier IS NULL THEN
    RETURN jsonb_build_object(
      'agency_id', p_agency_id, 'week_ending_date', p_week_ending_date,
      'budget', NULL, 'note', 'no retention_budget_schedule row for this week',
      'computed_at', now()
    );
  END IF;

  v_smvc_result    := public.compute_agency_on_time_smvc(p_agency_id, p_week_ending_date);
  v_on_time_smvc   := NULLIF(v_smvc_result->>'on_time_smvc_pct','')::numeric;
  v_bands_complete := COALESCE((v_smvc_result->>'bands_complete')::boolean, false);
  v_smvc_source    := (v_smvc_result->'computed_breakdown')->>'better_of_source';
  v_days_elapsed   := NULLIF((v_smvc_result->'computed_breakdown')->>'days_elapsed','')::int;

  SELECT auto_premium, fire_premium, life_premium INTO v_book_snap
  FROM public.agency_snapshot
  WHERE agency_id = p_agency_id
    AND snapshot_date <= p_week_ending_date
    AND auto_premium IS NOT NULL
  ORDER BY snapshot_date DESC LIMIT 1;

  IF FOUND THEN
    v_auto_premium := COALESCE(v_book_snap.auto_premium, 0);
    v_fire_premium := COALESCE(v_book_snap.fire_premium, 0);
    v_life_premium := COALESCE(v_book_snap.life_premium, 0);
    v_total_premium := v_auto_premium + v_fire_premium + v_life_premium;
  END IF;

  IF v_on_time_smvc IS NOT NULL AND v_total_premium IS NOT NULL THEN
    v_combined_rate := v_scheduled_multiplier + (0.21::numeric * v_on_time_smvc);
    v_budget        := v_combined_rate * v_total_premium;
  ELSE
    v_note := CASE WHEN v_on_time_smvc IS NULL  THEN 'missing on_time_SMVC inputs'
                   WHEN v_total_premium IS NULL THEN 'missing premium snapshot'
                   ELSE 'missing inputs' END;
  END IF;

  RETURN jsonb_build_object(
    'agency_id', p_agency_id, 'week_ending_date', p_week_ending_date,
    'budget', v_budget, 'phase', v_phase,
    'inputs', jsonb_build_object(
      'scheduled_multiplier', v_scheduled_multiplier,
      'on_time_smvc',         v_on_time_smvc,
      'on_time_smvc_source',  v_smvc_source,
      'days_elapsed',         v_days_elapsed,
      'bands_complete',       v_bands_complete,
      'auto_premium',         v_auto_premium,
      'fire_premium',         v_fire_premium,
      'life_premium',         v_life_premium,
      'total_premium',        v_total_premium,
      'combined_rate',        v_combined_rate
    ),
    'note', v_note, 'computed_at', now()
  );
END;
$$;
