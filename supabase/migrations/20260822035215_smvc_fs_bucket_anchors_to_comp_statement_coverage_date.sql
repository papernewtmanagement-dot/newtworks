-- ============================================================================
-- BUG FIX 2026-08-22 (Peter): the FS-credits bucket inside the on-time SMVC
-- calculation was annualized against the WEEKLY SNAPSHOT date, even though its
-- data comes from comp_recap (commission statements), which cover a different
-- period.
--
-- All commission statements ARE processed. The newest available statement
-- simply covers through an earlier date than "today" (e.g. the 26_08_11
-- statement covers the pay period ending 08/15, while the weekly snapshot is
-- 08/22). Dividing statement data by days-through-08/22 understates the
-- projection, and it decays a little further every week until the next
-- statement lands.
--
-- This is the same principle already locked in by migration 20260702191843:
-- "each data source annualizes against ITS OWN latest-data date." It was
-- applied to the P&C / L&H basis lines but never to the FS bucket inside SMVC
-- after migration 20260712220016 rewired FS credits from agency_snapshot to
-- comp_recap.
--
-- Fix: derive the comp-statement coverage date FROM THE DATABASE and use it for
-- the FS bucket only. Gain buckets (auto/fire/ips) still anchor to the weekly
-- snapshot, because that is their source.
--
-- The coverage-date logic is extracted into one helper so it cannot drift
-- between the two functions that need it.
-- ============================================================================

-- (1) Canonical comp-statement coverage date. Single copy.
--     Rule (Peter 2026-07-12 pm7), unchanged, just relocated:
--       latest statement day < 20  -> first-half issue  -> coverage ends MM/15
--       latest statement day >= 20 -> second-half issue -> coverage ends last of MM
CREATE OR REPLACE FUNCTION public.get_comp_recap_anchor_date(
  p_agency_id uuid,
  p_as_of_date date
) RETURNS date
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_year             int := EXTRACT(YEAR FROM p_as_of_date)::int;
  v_max_period_month int;
  v_latest_stmt_day  int;
BEGIN
  SELECT MAX(period_month) INTO v_max_period_month
  FROM public.comp_recap
  WHERE agency_id = p_agency_id
    AND period_year = v_year
    AND (period_year || '-' || LPAD(period_month::text, 2, '0') || '-01')::date <= p_as_of_date;

  IF v_max_period_month IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT MAX(NULLIF(substring(d.file_name FROM '^\d{2}_\d{2}_(\d{2})'), '')::int)
  INTO v_latest_stmt_day
  FROM public.comp_recap cr
  JOIN public.documents d ON d.id = cr.source_document_id
  WHERE cr.agency_id = p_agency_id
    AND cr.period_year = v_year
    AND cr.period_month = v_max_period_month
    AND d.file_name ~ '^\d{2}_\d{2}_\d{2}';

  IF v_latest_stmt_day IS NULL OR v_latest_stmt_day < 20 THEN
    RETURN make_date(v_year, v_max_period_month, 15);
  ELSE
    RETURN (make_date(v_year, v_max_period_month, 1) + INTERVAL '1 month - 1 day')::date;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.get_comp_recap_anchor_date(uuid, date) IS
'Returns the date through which processed commission-statement data actually covers, derived from the newest statement filename for the latest loaded month. Anchor rule locked by Peter 2026-07-12 pm7. Single source of truth - callers must not re-derive this inline.';


-- (2) compute_on_time_smvc: FS bucket gets its own annualization date.
--     New trailing param, defaults NULL -> falls back to p_as_of_date, so any
--     caller not passing it behaves exactly as before.
CREATE OR REPLACE FUNCTION public.compute_on_time_smvc(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric,
  p_as_of_date date DEFAULT CURRENT_DATE,
  p_fs_as_of_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_auto_smvc numeric;
  v_fire_smvc numeric;
  v_fs_smvc numeric;
  v_ips_smvc numeric;
  v_calculated_pct numeric;
  v_bands_complete boolean := true;
  v_days_elapsed int;
  v_days_in_year int;
  v_annualization_factor numeric;
  v_fs_as_of date;
  v_fs_days_elapsed int;
  v_fs_annualization_factor numeric;
  v_auto_on_time numeric;
  v_fire_on_time numeric;
  v_fs_on_time numeric;
  v_ips_on_time numeric;
  rec record;
BEGIN
  v_days_in_year := (make_date(p_program_year + 1, 1, 1) - make_date(p_program_year, 1, 1))::int;

  -- Snapshot-sourced buckets (auto gain, fire gain, ips) annualize on p_as_of_date
  v_days_elapsed := (p_as_of_date - make_date(p_program_year, 1, 1))::int + 1;
  IF v_days_elapsed <= 0 THEN
    v_annualization_factor := 1.0;
  ELSIF v_days_elapsed >= v_days_in_year THEN
    v_annualization_factor := 1.0;
  ELSE
    v_annualization_factor := v_days_in_year::numeric / v_days_elapsed::numeric;
  END IF;

  -- Statement-sourced bucket (fs_credits) annualizes on its own coverage date
  v_fs_as_of := COALESCE(p_fs_as_of_date, p_as_of_date);
  v_fs_days_elapsed := (v_fs_as_of - make_date(p_program_year, 1, 1))::int + 1;
  IF v_fs_days_elapsed <= 0 THEN
    v_fs_annualization_factor := 1.0;
  ELSIF v_fs_days_elapsed >= v_days_in_year THEN
    v_fs_annualization_factor := 1.0;
  ELSE
    v_fs_annualization_factor := v_days_in_year::numeric / v_fs_days_elapsed::numeric;
  END IF;

  v_auto_on_time := COALESCE(p_auto_pif_gain, 0) * v_annualization_factor;
  v_fire_on_time := COALESCE(p_fire_pif_gain, 0) * v_annualization_factor;
  v_fs_on_time   := COALESCE(p_fs_credits, 0)   * v_fs_annualization_factor;
  v_ips_on_time  := COALESCE(p_ips_activity, 0) * v_annualization_factor;

  FOR rec IN
    SELECT bucket_name, min_target AS min_threshold, max_target AS max_threshold, percent_available
    FROM public.sf_program_targets
    WHERE agency_id = p_agency_id
      AND program = 'smvc'
      AND program_year = p_program_year
      AND bucket_name IN ('auto_pif_gain','fire_pif_gain','fs_credits','ips_activity')
  LOOP
    IF rec.bucket_name = 'auto_pif_gain' THEN
      v_auto_smvc := public.smvc_bucket_score(v_auto_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    ELSIF rec.bucket_name = 'fire_pif_gain' THEN
      v_fire_smvc := public.smvc_bucket_score(v_fire_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    ELSIF rec.bucket_name = 'fs_credits' THEN
      v_fs_smvc := public.smvc_bucket_score(v_fs_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    ELSIF rec.bucket_name = 'ips_activity' THEN
      v_ips_smvc := public.smvc_bucket_score(v_ips_on_time, rec.min_threshold, rec.max_threshold, rec.percent_available);
    END IF;
  END LOOP;

  IF v_auto_smvc IS NULL OR v_fire_smvc IS NULL OR v_fs_smvc IS NULL OR v_ips_smvc IS NULL THEN
    v_bands_complete := false;
  END IF;

  v_calculated_pct := COALESCE(v_auto_smvc,0)
                    + COALESCE(v_fire_smvc,0)
                    + COALESCE(v_fs_smvc,0)
                    + COALESCE(v_ips_smvc,0);

  RETURN jsonb_build_object(
    'program_year',            p_program_year,
    'as_of_date',              p_as_of_date,
    'days_elapsed',            v_days_elapsed,
    'days_in_year',            v_days_in_year,
    'annualization_factor',    v_annualization_factor,
    'fs_as_of_date',           v_fs_as_of,
    'fs_days_elapsed',         v_fs_days_elapsed,
    'fs_annualization_factor', v_fs_annualization_factor,
    'gate_passed',             true,
    'gate_min',                NULL,
    'pc_production_actual',    p_pc_production_actual,
    'buckets', jsonb_build_object(
      'auto_pif_gain', jsonb_build_object('ytd', p_auto_pif_gain, 'on_time', v_auto_on_time, 'earned_pct', v_auto_smvc),
      'fire_pif_gain', jsonb_build_object('ytd', p_fire_pif_gain, 'on_time', v_fire_on_time, 'earned_pct', v_fire_smvc),
      'fs_credits',    jsonb_build_object('ytd', p_fs_credits,    'on_time', v_fs_on_time,   'earned_pct', v_fs_smvc, 'as_of', v_fs_as_of),
      'ips_activity',  jsonb_build_object('ytd', p_ips_activity,  'on_time', v_ips_on_time,  'earned_pct', v_ips_smvc)
    ),
    'calculated_smvc_pct',     v_calculated_pct,
    'calculated_smvc_decimal', v_calculated_pct / 100.0,
    'capped_smvc_decimal',     LEAST(0.03, v_calculated_pct / 100.0),
    'bands_complete',          v_bands_complete,
    'computed_at',             now()
  );
END;
$function$;


-- (3) better_of wrapper: pass the FS date through.
CREATE OR REPLACE FUNCTION public.compute_on_time_smvc_with_better_of(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric,
  p_as_of_date date DEFAULT CURRENT_DATE,
  p_fs_as_of_date date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_current jsonb;
  v_current_rate numeric;
  v_prior1 numeric;
  v_prior2 numeric;
  v_priors_used int := 0;
  v_avg_rate numeric;
  v_better_of_rate numeric;
  v_better_of_source text;
BEGIN
  v_current := public.compute_on_time_smvc(
    p_agency_id, p_program_year,
    p_pc_production_actual, p_auto_pif_gain, p_fire_pif_gain, p_fs_credits, p_ips_activity,
    p_as_of_date, p_fs_as_of_date
  );
  v_current_rate := (v_current->>'capped_smvc_decimal')::numeric;

  SELECT smvc_rate_pc_prior_year, smvc_rate_pc_2_years_prior
    INTO v_prior1, v_prior2
  FROM public.agency
  WHERE id = p_agency_id;

  v_priors_used := (CASE WHEN v_prior1 IS NOT NULL THEN 1 ELSE 0 END)
                 + (CASE WHEN v_prior2 IS NOT NULL THEN 1 ELSE 0 END);

  IF v_priors_used >= 2 THEN
    v_avg_rate := (v_current_rate + v_prior1 + v_prior2) / 3.0;
  ELSIF v_priors_used = 1 THEN
    v_avg_rate := (v_current_rate + COALESCE(v_prior1, v_prior2)) / 2.0;
  ELSE
    v_avg_rate := v_current_rate;
  END IF;

  IF v_current_rate >= v_avg_rate THEN
    v_better_of_rate := LEAST(0.03, v_current_rate);
    v_better_of_source := 'current_year';
  ELSE
    v_better_of_rate := LEAST(0.03, v_avg_rate);
    v_better_of_source := 'rolling_average';
  END IF;

  RETURN v_current || jsonb_build_object(
    'prior_year_smvc',     v_prior1,
    'prior_2_year_smvc',   v_prior2,
    'priors_used_in_avg',  v_priors_used,
    'rolling_avg_smvc',    v_avg_rate,
    'applied_smvc_decimal', v_better_of_rate,
    'better_of_source',    v_better_of_source
  );
END;
$function$;


-- (4) compute_agency_on_time_smvc: look up the statement coverage date and use it.
CREATE OR REPLACE FUNCTION public.compute_agency_on_time_smvc(
  p_agency_id uuid,
  p_as_of_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_program_year     int := EXTRACT(YEAR FROM p_as_of_date)::int;
  v_snap             record;
  v_book             record;
  v_effective_as_of  date;
  v_fs_as_of         date;
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
  v_fs_credits      := public.compute_fs_commissions_ytd(p_agency_id, p_as_of_date);
  v_ips_activity    := COALESCE(v_snap.ips_new_money_ytd, 0);

  -- Gain/ips buckets come from the weekly snapshot -> anchor to the snapshot date.
  v_effective_as_of := LEAST(p_as_of_date, v_snap.snapshot_date);

  -- FS credits come from processed commission statements -> anchor to the date
  -- those statements actually cover. Falls back to the snapshot anchor if no
  -- statements are loaded for the year yet.
  v_fs_as_of := COALESCE(
    public.get_comp_recap_anchor_date(p_agency_id, p_as_of_date),
    v_effective_as_of
  );

  v_smvc := public.compute_on_time_smvc_with_better_of(
    p_agency_id, v_program_year,
    v_pc_production, v_auto_gain, v_fire_gain,
    v_fs_credits, v_ips_activity,
    v_effective_as_of, v_fs_as_of
  );
  v_on_time_smvc_pct := NULLIF(v_smvc->>'applied_smvc_decimal', '')::numeric;

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
    'fs_effective_as_of',   v_fs_as_of,
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
$function$;


-- (5) compute_pool_basis_and_envelope: use the shared helper instead of its own
--     inline copy of the anchor rule. Behavior identical; one copy now.
CREATE OR REPLACE FUNCTION public.compute_pool_basis_and_envelope(p_agency_id uuid, p_week_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
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

  SELECT
    COALESCE(SUM(CASE WHEN comp_category IN ('auto_new','auto_renewal','fire_new','fire_renewal') THEN amount END), 0),
    COALESCE(SUM(CASE WHEN comp_category IN ('life_new','life_renewal','health_new','health_renewal') THEN amount END), 0),
    MAX(period_month)
  INTO v_pc_gross_ytd, v_lh_ytd, v_max_period_month
  FROM public.comp_recap
  WHERE agency_id = p_agency_id
    AND period_year = v_year
    AND (period_year || '-' || LPAD(period_month::text, 2, '0') || '-01')::date <= p_week_end_date;

  -- Anchor rule now lives in one place: get_comp_recap_anchor_date.
  v_comp_anchor_date := public.get_comp_recap_anchor_date(p_agency_id, p_week_end_date);

  SELECT MAX(NULLIF(substring(d.file_name FROM '^\d{2}_\d{2}_(\d{2})'), '')::int)
  INTO v_latest_stmt_day
  FROM public.comp_recap cr
  JOIN public.documents d ON d.id = cr.source_document_id
  WHERE cr.agency_id = p_agency_id
    AND cr.period_year = v_year
    AND cr.period_month = v_max_period_month
    AND d.file_name ~ '^\d{2}_\d{2}_\d{2}';

  v_anchor_source := CASE
    WHEN v_latest_stmt_day IS NULL OR v_latest_stmt_day < 20
      THEN 'first_half_statement → pay period end = 15th'
    ELSE 'second_half_statement → pay period end = last day'
  END;

  v_days_elapsed_comp := (v_comp_anchor_date - make_date(v_year, 1, 1))::int + 1;
  v_annualization_comp := 365.0 / v_days_elapsed_comp::numeric;

  v_pc_gross_annual    := v_pc_gross_ytd * v_annualization_comp;
  v_pc_stripped_annual := v_pc_gross_annual * v_strip_factor;
  v_lh_annual          := v_lh_ytd * v_annualization_comp;

  v_smvc_result      := public.compute_agency_on_time_smvc(p_agency_id, p_week_end_date);
  v_smvc_breakdown   := v_smvc_result->'computed_breakdown';
  v_on_time_smvc_pct := NULLIF(v_smvc_result->>'on_time_smvc_pct','')::numeric;
  v_on_time_smvc_dol := COALESCE(NULLIF(v_smvc_result->>'on_time_smvc_dollars','')::numeric, 0);
  v_pc_book_premium  := COALESCE(NULLIF(v_smvc_result->>'pc_book_premium','')::numeric, 0);
  v_smvc_anchor_date := NULLIF(v_smvc_result->>'effective_as_of','')::date;
  v_book_snap_date   := NULLIF(v_smvc_result->>'book_snapshot_date','')::date;

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
      'smvc_fs_anchor_date',       NULLIF(v_smvc_result->>'fs_effective_as_of','')::date,
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
$function$;
