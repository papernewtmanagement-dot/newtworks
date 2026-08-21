-- 1. Band config table (annual SF-published thresholds per bucket)
CREATE TABLE IF NOT EXISTS public.smvc_band_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  program_year integer NOT NULL,
  bucket_name text NOT NULL CHECK (bucket_name IN ('auto_pif_gain','fire_pif_gain','fs_credits','ips_activity','pc_production_gate')),
  min_threshold numeric,
  max_threshold numeric,
  percent_available numeric NOT NULL,
  is_gate boolean NOT NULL DEFAULT false,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(agency_id, program_year, bucket_name)
);

ALTER TABLE public.smvc_band_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS smvc_band_config_all ON public.smvc_band_config;
CREATE POLICY smvc_band_config_all ON public.smvc_band_config FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS smvc_band_config_lookup_idx ON public.smvc_band_config(agency_id, program_year, bucket_name);

-- 2. Per-bucket scoring function (pure math, single linear interpolation per locked mechanics)
CREATE OR REPLACE FUNCTION public.smvc_bucket_score(
  p_actual numeric,
  p_min numeric,
  p_max numeric,
  p_pct_available numeric
) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_min IS NULL OR p_max IS NULL OR p_pct_available IS NULL THEN
    RETURN NULL;  -- bands not configured; signal incomplete
  END IF;
  IF p_actual IS NULL THEN
    RETURN 0;  -- no production = 0% earned
  END IF;
  IF p_max = p_min THEN
    RETURN 0;
  END IF;
  -- Floor at 0, cap at percent_available
  RETURN LEAST(
    p_pct_available,
    GREATEST(0, ((p_actual - p_min) / (p_max - p_min)) * p_pct_available)
  );
END;
$$;

-- 3. Main runtime function: computes current-year on-time SMVC from live inputs
CREATE OR REPLACE FUNCTION public.compute_on_time_smvc(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_gate_min numeric;
  v_gate_passed boolean := false;
  v_auto_smvc numeric;
  v_fire_smvc numeric;
  v_fs_smvc numeric;
  v_ips_smvc numeric;
  v_calculated_pct numeric;
  v_bands_complete boolean := true;
  rec record;
BEGIN
  -- Gate threshold
  SELECT min_threshold INTO v_gate_min
  FROM public.smvc_band_config
  WHERE agency_id = p_agency_id AND program_year = p_program_year AND bucket_name = 'pc_production_gate';

  IF v_gate_min IS NULL THEN v_bands_complete := false; END IF;

  v_gate_passed := (p_pc_production_actual IS NOT NULL AND v_gate_min IS NOT NULL AND p_pc_production_actual >= v_gate_min);

  IF v_gate_passed THEN
    -- Per-bucket scoring
    FOR rec IN
      SELECT bucket_name, min_threshold, max_threshold, percent_available
      FROM public.smvc_band_config
      WHERE agency_id = p_agency_id AND program_year = p_program_year
        AND bucket_name IN ('auto_pif_gain','fire_pif_gain','fs_credits','ips_activity')
    LOOP
      IF rec.bucket_name = 'auto_pif_gain' THEN
        v_auto_smvc := public.smvc_bucket_score(p_auto_pif_gain, rec.min_threshold, rec.max_threshold, rec.percent_available);
      ELSIF rec.bucket_name = 'fire_pif_gain' THEN
        v_fire_smvc := public.smvc_bucket_score(p_fire_pif_gain, rec.min_threshold, rec.max_threshold, rec.percent_available);
      ELSIF rec.bucket_name = 'fs_credits' THEN
        v_fs_smvc := public.smvc_bucket_score(p_fs_credits, rec.min_threshold, rec.max_threshold, rec.percent_available);
      ELSIF rec.bucket_name = 'ips_activity' THEN
        v_ips_smvc := public.smvc_bucket_score(p_ips_activity, rec.min_threshold, rec.max_threshold, rec.percent_available);
      END IF;
    END LOOP;

    -- Mark bands incomplete if any bucket band is unset
    IF v_auto_smvc IS NULL OR v_fire_smvc IS NULL OR v_fs_smvc IS NULL OR v_ips_smvc IS NULL THEN
      v_bands_complete := false;
    END IF;
  END IF;

  -- Sum buckets (pct units: 1.00 = 1.00%). Cap program total at 3.00%.
  v_calculated_pct := COALESCE(v_auto_smvc,0) + COALESCE(v_fire_smvc,0) + COALESCE(v_fs_smvc,0) + COALESCE(v_ips_smvc,0);

  RETURN jsonb_build_object(
    'program_year', p_program_year,
    'gate_passed', v_gate_passed,
    'gate_min', v_gate_min,
    'pc_production_actual', p_pc_production_actual,
    'buckets', jsonb_build_object(
      'auto_pif_gain',  jsonb_build_object('actual', p_auto_pif_gain,  'earned_pct', v_auto_smvc),
      'fire_pif_gain',  jsonb_build_object('actual', p_fire_pif_gain,  'earned_pct', v_fire_smvc),
      'fs_credits',     jsonb_build_object('actual', p_fs_credits,     'earned_pct', v_fs_smvc),
      'ips_activity',   jsonb_build_object('actual', p_ips_activity,   'earned_pct', v_ips_smvc)
    ),
    'calculated_smvc_pct',     v_calculated_pct,
    'calculated_smvc_decimal', v_calculated_pct / 100.0,
    'capped_smvc_decimal',     LEAST(0.03, v_calculated_pct / 100.0),
    'bands_complete', v_bands_complete,
    'computed_at', now()
  );
END;
$$;

-- 4. Better Of wrapper — applies SF's 3-year rolling-average rule
CREATE OR REPLACE FUNCTION public.compute_on_time_smvc_with_better_of(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
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
  v_current := public.compute_on_time_smvc(p_agency_id, p_program_year, p_pc_production_actual, p_auto_pif_gain, p_fire_pif_gain, p_fs_credits, p_ips_activity);
  v_current_rate := (v_current->>'capped_smvc_decimal')::numeric;

  -- Pull final earned rate per prior year from smvc_history (most recent row per year)
  SELECT
    MAX(CASE WHEN yr = p_program_year - 1 THEN this_period_smvc END),
    MAX(CASE WHEN yr = p_program_year - 2 THEN this_period_smvc END)
  INTO v_prior1, v_prior2
  FROM (
    SELECT DISTINCT ON (EXTRACT(YEAR FROM as_of_date)::int)
      EXTRACT(YEAR FROM as_of_date)::int as yr,
      this_period_smvc
    FROM public.smvc_history
    WHERE agency_id = p_agency_id
      AND EXTRACT(YEAR FROM as_of_date)::int IN (p_program_year - 1, p_program_year - 2)
    ORDER BY EXTRACT(YEAR FROM as_of_date)::int, as_of_date DESC
  ) priors;

  v_priors_used := (CASE WHEN v_prior1 IS NOT NULL THEN 1 ELSE 0 END)
                 + (CASE WHEN v_prior2 IS NOT NULL THEN 1 ELSE 0 END);

  IF v_priors_used >= 2 THEN
    v_avg_rate := (v_current_rate + v_prior1 + v_prior2) / 3.0;
  ELSIF v_priors_used = 1 THEN
    v_avg_rate := (v_current_rate + COALESCE(v_prior1, v_prior2)) / 2.0;
  ELSE
    v_avg_rate := v_current_rate;  -- no priors, no averaging
  END IF;

  IF v_current_rate >= v_avg_rate THEN
    v_better_of_rate := LEAST(0.03, v_current_rate);
    v_better_of_source := 'current_year';
  ELSE
    v_better_of_rate := LEAST(0.03, v_avg_rate);
    v_better_of_source := 'rolling_average';
  END IF;

  RETURN v_current || jsonb_build_object(
    'prior_year_smvc',    v_prior1,
    'prior_2_year_smvc',  v_prior2,
    'priors_used_in_avg', v_priors_used,
    'rolling_avg_smvc',   v_avg_rate,
    'applied_smvc_decimal', v_better_of_rate,
    'better_of_source',   v_better_of_source
  );
END;
$$;

-- 5. Seed 2026 band config with placeholders flagged AWAITING_PETER for any unknown values.
-- Locked percent_available values come from sf_compensation 2026 AA05 mechanics row.
INSERT INTO public.smvc_band_config (agency_id, program_year, bucket_name, min_threshold, max_threshold, percent_available, is_gate, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 2026, 'pc_production_gate', NULL, NULL, 0,    true,  'AWAITING_PETER: P&C Production Minimum (Auto PIF + Fire PIF combined annual target). Capture from corporate OT dashboard Jan 2026 publication.'),
  ('126794dd-25ff-47d2-a436-724499733365', 2026, 'auto_pif_gain',      NULL, NULL, 1.00, false, 'AWAITING_PETER: SMVC Auto PIF Gain bands Min/Max. Per 2026-06-15 session note Auto bands are exact in Peter''s 3/31 OT dashboard image but not yet captured numerically.'),
  ('126794dd-25ff-47d2-a436-724499733365', 2026, 'fire_pif_gain',      NULL, NULL, 1.00, false, 'AWAITING_PETER: SMVC Fire PIF Gain bands Min/Max.'),
  ('126794dd-25ff-47d2-a436-724499733365', 2026, 'fs_credits',         NULL, NULL, 1.75, false, 'AWAITING_PETER: SMVC FS Credits bands Min/Max. 2026-06-15 session note approximations were $8,800 / $40,000 / $89,000 — confirm against fresh OT read.'),
  ('126794dd-25ff-47d2-a436-724499733365', 2026, 'ips_activity',       NULL, NULL, 0.25, false, 'AWAITING_PETER: SMVC IPS bands Min/Max. 2026-06-15 session note had Max approximately $1,998.')
ON CONFLICT (agency_id, program_year, bucket_name) DO NOTHING;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.smvc_band_config TO anon, authenticated;
