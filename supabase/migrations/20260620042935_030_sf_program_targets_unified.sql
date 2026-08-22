-- Migration 030: Unify scorecard_tracking + smvc_band_config into sf_program_targets
-- Locked with Peter 2026-06-20

-- 1. Create unified table
CREATE TABLE IF NOT EXISTS public.sf_program_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  program text NOT NULL,
  program_year integer NOT NULL,
  period text NOT NULL DEFAULT 'annual',
  bucket_name text NOT NULL,
  min_target numeric,
  max_target numeric,
  percent_available numeric,
  is_gate boolean DEFAULT false,
  notes text,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT sf_program_targets_unique UNIQUE (agency_id, program, program_year, period, bucket_name)
);

CREATE INDEX IF NOT EXISTS idx_sf_program_targets_lookup
  ON public.sf_program_targets (agency_id, program, program_year);

COMMENT ON TABLE public.sf_program_targets IS 'Unified State Farm program targets — Scorecard bands, SMVC bands, Honor Club gates, Ambassador tiers, Champions Circle thresholds. Replaces scorecard_tracking + smvc_band_config (dropped 2026-06-20).';
COMMENT ON COLUMN public.sf_program_targets.program IS 'Which SF program: scorecard, smvc, honor_club, ambassador, champions_circle, etc.';
COMMENT ON COLUMN public.sf_program_targets.bucket_name IS 'Per-program bucket identifier (e.g., auto_pif_production, fs_credits, ips_activity).';
COMMENT ON COLUMN public.sf_program_targets.min_target IS 'Lower band threshold.';
COMMENT ON COLUMN public.sf_program_targets.max_target IS 'Upper band threshold.';
COMMENT ON COLUMN public.sf_program_targets.percent_available IS 'SMVC-specific: bucket weight (e.g., 1.00, 1.75, 0.25). NULL for non-SMVC entries.';
COMMENT ON COLUMN public.sf_program_targets.is_gate IS 'TRUE if entry is a binary gate (Honor Club gates); FALSE if scoring bucket.';

-- 2. RLS policies (mirror old tables: anon+auth read; auth write)
ALTER TABLE public.sf_program_targets ENABLE ROW LEVEL SECURITY;

CREATE POLICY sf_program_targets_anon_read ON public.sf_program_targets
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY sf_program_targets_auth_all ON public.sf_program_targets
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 3. Migrate scorecard_tracking rows
INSERT INTO public.sf_program_targets (
  agency_id, program, program_year, period, bucket_name,
  min_target, max_target, is_gate, notes
)
SELECT
  agency_id,
  CASE WHEN metric_name LIKE 'honor_club_%' THEN 'honor_club' ELSE 'scorecard' END,
  program_year,
  COALESCE(period, 'annual'),
  metric_name,
  min_target,
  max_target,
  CASE WHEN metric_name LIKE 'honor_club_%' THEN true ELSE false END,
  notes
FROM public.scorecard_tracking
ON CONFLICT (agency_id, program, program_year, period, bucket_name) DO NOTHING;

-- 4. Migrate smvc_band_config rows
INSERT INTO public.sf_program_targets (
  agency_id, program, program_year, period, bucket_name,
  min_target, max_target, percent_available, is_gate, notes
)
SELECT
  agency_id, 'smvc', program_year, 'annual', bucket_name,
  min_threshold, max_threshold, percent_available, is_gate, notes
FROM public.smvc_band_config
ON CONFLICT (agency_id, program, program_year, period, bucket_name) DO NOTHING;

-- 5. Rewrite compute_on_time_smvc to read from sf_program_targets
CREATE OR REPLACE FUNCTION public.compute_on_time_smvc(
  p_agency_id uuid, p_program_year integer, p_pc_production_actual numeric,
  p_auto_pif_gain numeric, p_fire_pif_gain numeric,
  p_fs_credits numeric, p_ips_activity numeric
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
  rec record;
BEGIN
  FOR rec IN
    SELECT bucket_name, min_target AS min_threshold, max_target AS max_threshold, percent_available
    FROM public.sf_program_targets
    WHERE agency_id = p_agency_id
      AND program = 'smvc'
      AND program_year = p_program_year
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

  IF v_auto_smvc IS NULL OR v_fire_smvc IS NULL OR v_fs_smvc IS NULL OR v_ips_smvc IS NULL THEN
    v_bands_complete := false;
  END IF;

  v_calculated_pct := COALESCE(v_auto_smvc,0)
                    + COALESCE(v_fire_smvc,0)
                    + COALESCE(v_fs_smvc,0)
                    + COALESCE(v_ips_smvc,0);

  RETURN jsonb_build_object(
    'program_year',            p_program_year,
    'gate_passed',             true,
    'gate_min',                NULL,
    'pc_production_actual',    p_pc_production_actual,
    'buckets', jsonb_build_object(
      'auto_pif_gain', jsonb_build_object('actual', p_auto_pif_gain, 'earned_pct', v_auto_smvc),
      'fire_pif_gain', jsonb_build_object('actual', p_fire_pif_gain, 'earned_pct', v_fire_smvc),
      'fs_credits',    jsonb_build_object('actual', p_fs_credits,    'earned_pct', v_fs_smvc),
      'ips_activity',  jsonb_build_object('actual', p_ips_activity,  'earned_pct', v_ips_smvc)
    ),
    'calculated_smvc_pct',     v_calculated_pct,
    'calculated_smvc_decimal', v_calculated_pct / 100.0,
    'capped_smvc_decimal',     LEAST(0.03, v_calculated_pct / 100.0),
    'bands_complete',          v_bands_complete,
    'computed_at',             now()
  );
END;
$function$;

-- 6. Drop old tables
DROP TABLE public.scorecard_tracking;
DROP TABLE public.smvc_band_config;
