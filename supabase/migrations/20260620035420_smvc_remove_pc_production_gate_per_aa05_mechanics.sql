-- Per AA05 mechanics core principle: "NO COMBINED GATE — SMVC operates as
-- four individual scoring metrics. There is no combined Auto+Fire P&C
-- Production Minimum that gates all four buckets together."
--
-- Previous implementation gated all per-bucket scoring on a pc_production_gate
-- band lookup. That gate is removed. pc_production_actual is still accepted
-- as a parameter for backward compatibility but is informational only.

CREATE OR REPLACE FUNCTION public.compute_on_time_smvc(
  p_agency_id uuid,
  p_program_year integer,
  p_pc_production_actual numeric,
  p_auto_pif_gain numeric,
  p_fire_pif_gain numeric,
  p_fs_credits numeric,
  p_ips_activity numeric
) RETURNS jsonb
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
  -- NO COMBINED GATE per AA05 mechanics core principle.
  -- Score each bucket independently; pc_production_actual is reported but unused.
  FOR rec IN
    SELECT bucket_name, min_threshold, max_threshold, percent_available
    FROM public.smvc_band_config
    WHERE agency_id = p_agency_id
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

  -- Bands incomplete only if a per-bucket band is missing
  IF v_auto_smvc IS NULL OR v_fire_smvc IS NULL OR v_fs_smvc IS NULL OR v_ips_smvc IS NULL THEN
    v_bands_complete := false;
  END IF;

  -- Sum buckets (pct units: 1.00 = 1.00%). Cap program total at 3.00%.
  v_calculated_pct := COALESCE(v_auto_smvc,0)
                    + COALESCE(v_fire_smvc,0)
                    + COALESCE(v_fs_smvc,0)
                    + COALESCE(v_ips_smvc,0);

  RETURN jsonb_build_object(
    'program_year',            p_program_year,
    'gate_passed',             true,    -- legacy field; gate removed per AA05 principle
    'gate_min',                NULL,    -- legacy field; gate removed per AA05 principle
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
