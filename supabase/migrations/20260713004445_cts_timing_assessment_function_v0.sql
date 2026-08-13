-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-13 00:44:45 UTC (ledger name: cts_timing_assessment_function_v0) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260713004445.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Independent wall-clock timing flag for candidate assessments.
-- Sits alongside HireGauge RI/DIS validity indicator, does not replace it.
-- Thresholds v0 calibrated from n=6 Phase 1 team + 6 external moderate-RI cohort (2026-07-12).
-- Known clean performers (Tommy, John, Stephanie) all totaled 34-37 min.
-- Known problematic outcomes (Jason 17-week failure at 50 min, Cassandra hard-ceiling at 114 min) both flagged.
-- No exemption for founder/admin roles — timing is one facet, taken alongside overall picture.

CREATE OR REPLACE FUNCTION public.cts_timing_assessment(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_cts_s int; v_lss_s int; v_vct_s int; v_total_s int;
  v_cts_min int; v_lss_min int; v_vct_min int; v_total_min int;
  v_cts_flag text; v_lss_flag text; v_vct_flag text; v_total_flag text; v_overall text;
  v_reasons jsonb := '[]'::jsonb;
BEGIN
  SELECT cts_wall_duration_seconds, lss_wall_duration_seconds, vct_wall_duration_seconds
    INTO v_cts_s, v_lss_s, v_vct_s
  FROM public.team_assessments
  WHERE id = p_assessment_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('overall_flag','no_data','reason','assessment not found');
  END IF;

  v_total_s   := COALESCE(v_cts_s,0) + COALESCE(v_lss_s,0) + COALESCE(v_vct_s,0);
  v_cts_min   := v_cts_s / 60;
  v_lss_min   := v_lss_s / 60;
  v_vct_min   := v_vct_s / 60;
  v_total_min := v_total_s / 60;

  v_cts_flag := CASE WHEN v_cts_s IS NULL THEN 'no_data'
                     WHEN v_cts_min > 35 THEN 'red'
                     WHEN v_cts_min > 20 THEN 'yellow'
                     ELSE 'green' END;

  v_lss_flag := CASE WHEN v_lss_s IS NULL THEN 'no_data'
                     WHEN v_lss_min > 30 THEN 'red'
                     WHEN v_lss_min > 22 THEN 'yellow'
                     ELSE 'green' END;

  v_vct_flag := CASE WHEN v_vct_s IS NULL THEN 'no_data'
                     WHEN v_vct_min >= 9 THEN 'red'
                     WHEN v_vct_min > 5 THEN 'yellow'
                     ELSE 'green' END;

  v_total_flag := CASE WHEN v_total_s = 0 THEN 'no_data'
                       WHEN v_total_min > 65 THEN 'red'
                       WHEN v_total_min > 45 THEN 'yellow'
                       ELSE 'green' END;

  v_overall := CASE
    WHEN 'red'    = ANY(ARRAY[v_cts_flag, v_lss_flag, v_vct_flag, v_total_flag]) THEN 'red'
    WHEN 'yellow' = ANY(ARRAY[v_cts_flag, v_lss_flag, v_vct_flag, v_total_flag]) THEN 'yellow'
    WHEN 'no_data' = ALL(ARRAY[v_cts_flag, v_lss_flag, v_vct_flag, v_total_flag]) THEN 'no_data'
    ELSE 'green'
  END;

  IF v_total_flag = 'red'    THEN v_reasons := v_reasons || jsonb_build_array(format('Total %s min (>65 red)', v_total_min));
  ELSIF v_total_flag='yellow' THEN v_reasons := v_reasons || jsonb_build_array(format('Total %s min (46-65 yellow)', v_total_min));
  END IF;

  IF v_lss_flag = 'red'    THEN v_reasons := v_reasons || jsonb_build_array(format('LSS %s min (>30 red)', v_lss_min));
  ELSIF v_lss_flag='yellow' THEN v_reasons := v_reasons || jsonb_build_array(format('LSS %s min (23-30 yellow)', v_lss_min));
  END IF;

  IF v_vct_flag = 'red'    THEN v_reasons := v_reasons || jsonb_build_array(format('VCT %s min (≥9 red)', v_vct_min));
  ELSIF v_vct_flag='yellow' THEN v_reasons := v_reasons || jsonb_build_array(format('VCT %s min (6-8 yellow)', v_vct_min));
  END IF;

  IF v_cts_flag = 'red'    THEN v_reasons := v_reasons || jsonb_build_array(format('CTS %s min (>35 red)', v_cts_min));
  ELSIF v_cts_flag='yellow' THEN v_reasons := v_reasons || jsonb_build_array(format('CTS %s min (21-35 yellow)', v_cts_min));
  END IF;

  RETURN jsonb_build_object(
    'overall_flag', v_overall,
    'total_min',    v_total_min, 'total_flag', v_total_flag,
    'lss_min',      v_lss_min,   'lss_flag',   v_lss_flag,
    'vct_min',      v_vct_min,   'vct_flag',   v_vct_flag,
    'cts_min',      v_cts_min,   'cts_flag',   v_cts_flag,
    'reasons',      v_reasons,
    'thresholds_version', 'v0_2026_07_12'
  );
END;
$$;

COMMENT ON FUNCTION public.cts_timing_assessment(uuid) IS
  'Wall-clock timing flag calibrated 2026-07-12 from n=6 Phase 1 team + moderate-RI externals. Returns overall_flag (red|yellow|green|no_data) plus per-section reasons. Independent facet — read alongside HireGauge RI/DIS, not as replacement.';
