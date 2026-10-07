-- Peter 2026-10-06: team bonus pool basis moves to the book from week ending 2026-10-10 (Q4 2026).
-- Basis = P&C book x (pc_base_rate + on-time SMVC) + life book premium x 10% + on-time Scorecard.
-- No statement commissions, no applied-SMVC strip, no health. Weeks before 2026-10-10 keep the old math.
CREATE OR REPLACE FUNCTION public.compute_pool_basis_and_envelope(p_agency_id uuid, p_week_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  c_book_basis_from   CONSTANT date := '2026-10-10';   -- Peter 2026-10-06
  c_life_rate         CONSTANT numeric := 0.10;         -- Peter 2026-10-06: 10% of total life premium
  v_year              int  := EXTRACT(YEAR FROM p_week_end_date)::int;
  v_book_mode         boolean := p_week_end_date >= c_book_basis_from;
  v_smvc_rate_pc      numeric;
  v_pc_base_rate      numeric;
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
  v_pc_base_dollars   numeric;
  v_life_premium      numeric;
  v_life_snap_date    date;
  v_life_dollars      numeric;
  v_smvc_result       jsonb;
  v_smvc_anchor_date  date;
  v_book_snap_date    date;
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
  SELECT smvc_rate_pc, COALESCE(pc_base_rate, 0.08) INTO v_smvc_rate_pc, v_pc_base_rate FROM public.agency WHERE id = p_agency_id;
  v_strip_factor := 8.0 / (8.0 + (v_smvc_rate_pc * 100.0));

  SELECT
    COALESCE(SUM(CASE WHEN comp_category IN ('auto_new','auto_renewal','fire_new','fire_renewal') THEN amount END), 0),
    COALESCE(SUM(CASE WHEN comp_category IN ('life_new','life_renewal','health_new','health_renewal') THEN amount END), 0),
    MAX(period_month)
  INTO v_pc_gross_ytd, v_lh_ytd, v_max_period_month
  FROM public.comp_recap
  WHERE agency_id = p_agency_id
    AND period_year = v_year
    AND (period_year || '-' || LPAD(period_month::text, 2, '0') || '-01')::date <= p_week_end_date;

  v_comp_anchor_date := public.get_comp_recap_anchor_date(p_agency_id, p_week_end_date);

  SELECT MAX(NULLIF(substring(d.file_name FROM '^\d{2}_\d{2}_(\d{2})'), '')::int)
  INTO v_latest_stmt_day
  FROM public.comp_recap cr
  JOIN public.documents d ON d.id = cr.source_document_id
  WHERE cr.agency_id = p_agency_id AND cr.period_year = v_year AND cr.period_month = v_max_period_month
    AND d.file_name ~ '^\d{2}_\d{2}_\d{2}';

  v_anchor_source := CASE WHEN v_latest_stmt_day IS NULL OR v_latest_stmt_day < 20
      THEN 'first_half_statement → pay period end = 15th'
    ELSE 'second_half_statement → pay period end = last day' END;

  v_days_elapsed_comp := (v_comp_anchor_date - make_date(v_year, 1, 1))::int + 1;
  v_annualization_comp := 365.0 / v_days_elapsed_comp::numeric;
  v_pc_gross_annual    := v_pc_gross_ytd * v_annualization_comp;
  v_pc_stripped_annual := v_pc_gross_annual * v_strip_factor;
  v_lh_annual          := v_lh_ytd * v_annualization_comp;

  v_smvc_result      := public.compute_agency_on_time_smvc(p_agency_id, p_week_end_date);
  v_on_time_smvc_pct := NULLIF(v_smvc_result->>'on_time_smvc_pct','')::numeric;
  v_on_time_smvc_dol := COALESCE(NULLIF(v_smvc_result->>'on_time_smvc_dollars','')::numeric, 0);
  v_pc_book_premium  := COALESCE(NULLIF(v_smvc_result->>'pc_book_premium','')::numeric, 0);
  v_smvc_anchor_date := NULLIF(v_smvc_result->>'effective_as_of','')::date;
  v_book_snap_date   := NULLIF(v_smvc_result->>'book_snapshot_date','')::date;

  v_scorecard := public.compute_scorecard_bonus(p_agency_id,
    COALESCE(NULLIF(v_smvc_result->>'snapshot_date','')::date, p_week_end_date));
  v_on_time_scc_dol := COALESCE(NULLIF(v_scorecard->>'bonus_projected','')::numeric, 0);

  SELECT s.life_premium, s.snapshot_date INTO v_life_premium, v_life_snap_date
  FROM public.agency_snapshot s
  WHERE s.agency_id = p_agency_id AND s.snapshot_date <= p_week_end_date AND s.life_premium IS NOT NULL
  ORDER BY s.snapshot_date DESC LIMIT 1;
  v_pc_base_dollars := v_pc_book_premium * v_pc_base_rate;
  v_life_dollars    := COALESCE(v_life_premium, 0) * c_life_rate;

  IF v_book_mode THEN
    v_total_basis := v_pc_base_dollars + v_on_time_smvc_dol + v_life_dollars + v_on_time_scc_dol;
  ELSE
    v_total_basis := v_pc_stripped_annual + v_lh_annual + v_on_time_smvc_dol + v_on_time_scc_dol;
  END IF;

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
      'basis_method',              CASE WHEN v_book_mode THEN 'book' ELSE 'statements' END,
      'pc_base_rate',              v_pc_base_rate,
      'pc_base_dollars',           ROUND(v_pc_base_dollars, 2),
      'life_premium',              v_life_premium,
      'life_snapshot_date',        v_life_snap_date,
      'life_rate',                 c_life_rate,
      'life_dollars',              ROUND(v_life_dollars, 2),
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
      'smvc_fs_anchor_date',       NULLIF(v_smvc_result->>'fs_effective_as_of','')::date,
      'book_snapshot_date',        v_book_snap_date
    ),
    'schedule', jsonb_build_object(
      'pool_pct', v_pool_pct, 'phase', v_pool_pct_row.phase,
      'basis_regime', v_pool_pct_row.basis_regime, 'plan_note', v_pool_pct_row.plan_note),
    'envelope', jsonb_build_object(
      'annual_dollars', ROUND(v_annual_envelope, 2),
      'weekly_dollars', ROUND(v_weekly_envelope, 2)),
    'computed_at', now()
  );
END;
$function$;

-- Re-solve the pool percent at the switch (Peter 2026-10-06): week ending 2026-10-10 keeps the same
-- envelope dollars it had under the old basis (44.33299% x $532,426.76 = $236,040.70/yr), then the
-- Phase 1 step-down is redrawn as a straight line to its 40.00% target on 2027-12-25.
-- Weeks before 2026-10-10 and all of Phase 3 (2028-01-01 on) are untouched.
SELECT set_config('request.jwt.claims','{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_old_pct CONSTANT numeric := 44.33299;
  v_old_basis CONSTANT numeric := 532426.76;
  v_new_basis numeric; v_p0 numeric; v_n int;
BEGIN
  v_new_basis := (public.compute_pool_basis_and_envelope(v_agency, '2026-10-10')->'basis'->>'total_basis_annual')::numeric;
  IF v_new_basis IS NULL OR v_new_basis <= 0 THEN RAISE EXCEPTION 'new basis missing'; END IF;
  v_p0 := ROUND(v_old_pct * v_old_basis / v_new_basis, 5);
  SELECT COUNT(*) - 1 INTO v_n FROM public.team_comp_pool_schedule
   WHERE agency_id = v_agency AND week_end_date BETWEEN '2026-10-10' AND '2027-12-25';
  IF v_n <> 63 THEN RAISE EXCEPTION 'expected 64 Phase 1 weeks from 2026-10-10, found %', v_n + 1; END IF;
  WITH w AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY week_end_date) - 1 AS i
    FROM public.team_comp_pool_schedule
    WHERE agency_id = v_agency AND week_end_date BETWEEN '2026-10-10' AND '2027-12-25')
  UPDATE public.team_comp_pool_schedule s
     SET pool_pct = ROUND(v_p0 + (40.00000 - v_p0) * w.i / v_n, 5),
         plan_note = CASE WHEN w.i = 0 THEN format('Book basis switch (Peter 2026-10-06): %s%% re-solved so the envelope matches the old basis this week (44.33299%% x $532,426.76 = $236,040.70/yr; new basis $%s). Straight line to 40.00%% at 2027-12-25.', v_p0, v_new_basis) ELSE s.plan_note END,
         updated_at = now()
    FROM w WHERE s.id = w.id;
  IF (SELECT pool_pct FROM public.team_comp_pool_schedule WHERE agency_id = v_agency AND week_end_date = '2027-12-25') <> 40.00000 THEN
    RAISE EXCEPTION 'Phase 1 end target missed';
  END IF;
END $$;

