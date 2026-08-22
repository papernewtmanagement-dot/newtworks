-- Part 1: reliability + LSS helpers
CREATE OR REPLACE FUNCTION public._cts_apply_reliability_confidence(p_score integer, p_reliability text)
 RETURNS integer LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_score IS NULL THEN NULL
    WHEN p_score >= 50 THEN GREATEST(0, LEAST(100, ROUND(50 + (p_score - 50) * public._cts_reliability_confidence(p_reliability))::int))
    ELSE p_score
  END;
$function$;

CREATE OR REPLACE FUNCTION public._cts_lss_apply_v4(p_base numeric, p_acc_wt numeric, p_spd_wt numeric, p_acc_signal numeric, p_spd_signal numeric, p_rel_factor numeric, p_has_lss boolean)
 RETURNS integer LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_lin_signal numeric := 0;
  v_lss_delta numeric := 0;
  v_pre_rel numeric;
BEGIN
  IF p_base IS NULL THEN RETURN NULL; END IF;
  IF p_has_lss THEN
    v_lin_signal := (COALESCE(p_acc_wt, 0) * p_acc_signal + COALESCE(p_spd_wt, 0) * p_spd_signal) / 2.0;
    v_lss_delta := 15.0 * v_lin_signal;
    IF v_lin_signal < 0 THEN
      v_lss_delta := v_lss_delta - 20.0 * v_lin_signal * v_lin_signal;
    END IF;
  END IF;
  v_pre_rel := GREATEST(0, LEAST(100, ROUND(p_base + v_lss_delta)));
  IF v_pre_rel >= 50 THEN
    RETURN GREATEST(0, LEAST(100, ROUND(50 + (v_pre_rel - 50) * COALESCE(p_rel_factor, 1.0))))::int;
  ELSE
    RETURN GREATEST(0, LEAST(100, v_pre_rel))::int;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._cts_lss_delta_v4(p_acc_wt numeric, p_spd_wt numeric, p_acc_signal numeric, p_spd_signal numeric, p_has_lss boolean)
 RETURNS numeric LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_lin_signal numeric;
  v_delta numeric;
BEGIN
  IF NOT p_has_lss THEN RETURN 0; END IF;
  v_lin_signal := (COALESCE(p_acc_wt, 0) * p_acc_signal + COALESCE(p_spd_wt, 0) * p_spd_signal) / 2.0;
  v_delta := 15.0 * v_lin_signal;
  IF v_lin_signal < 0 THEN
    v_delta := v_delta - 20.0 * v_lin_signal * v_lin_signal;
  END IF;
  RETURN ROUND(v_delta, 2);
END;
$function$;

-- Part 2: simplified LSS auto-pass helper (2-bucket, 3-outcome)
CREATE OR REPLACE FUNCTION public._hiregauge_lss_autopass(
  p_lss_total numeric, p_reliability text, p_analytical numeric,
  p_target_role text, p_best_fit_role text,
  p_licenses jsonb, p_education jsonb, p_prior_role jsonb
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_status text; v_reason text; v_effective_role text;
  v_auto_exc text[] := ARRAY[]::text[];
  v_license_held boolean := false;
  v_reputable_degree boolean := false;
  v_prior_job_success boolean := false;
  v_institution text; v_edu_level text; v_relevance text;
  v_is_very_weak boolean := false;
BEGIN
  IF p_lss_total IS NULL THEN
    RETURN jsonb_build_object('status','not_scored','reason','LSS not yet scored','auto_exceptions','[]'::jsonb);
  END IF;
  IF p_lss_total >= 25 THEN
    RETURN jsonb_build_object('status','not_applicable','reason','LSS total '||p_lss_total||' is at or above the 25 threshold','auto_exceptions','[]'::jsonb);
  END IF;

  v_effective_role := COALESCE(p_target_role, p_best_fit_role);

  IF p_licenses IS NOT NULL THEN
    v_license_held := COALESCE((p_licenses->>'pc')::boolean, false)
                   OR COALESCE((p_licenses->>'lh')::boolean, false)
                   OR COALESCE((p_licenses->>'ips')::boolean, false)
                   OR COALESCE((p_licenses->>'series_6')::boolean, false)
                   OR COALESCE((p_licenses->>'series_63')::boolean, false)
                   OR COALESCE((p_licenses->>'series_7')::boolean, false)
                   OR COALESCE((p_licenses->>'series_24')::boolean, false);
  END IF;
  IF p_education IS NOT NULL THEN
    v_edu_level := p_education->>'highest_completed';
    v_institution := NULLIF(TRIM(COALESCE(p_education->>'institution', '')), '');
    v_reputable_degree := v_edu_level IN ('bachelors','masters','doctorate') AND v_institution IS NOT NULL;
  END IF;
  IF p_prior_role IS NOT NULL THEN
    v_relevance := p_prior_role->>'highest_relevance';
    v_prior_job_success := v_relevance IN ('insurance_direct','insurance_adjacent')
                           AND jsonb_typeof(p_prior_role->'success_signals') = 'array'
                           AND jsonb_array_length(p_prior_role->'success_signals') > 0;
  END IF;

  v_is_very_weak := p_lss_total <= 15 OR (p_lss_total <= 24 AND p_reliability = 'low');

  IF v_is_very_weak THEN
    IF v_reputable_degree THEN v_auto_exc := array_append(v_auto_exc, 'reputable_degree'); END IF;
    IF v_prior_job_success THEN v_auto_exc := array_append(v_auto_exc, 'prior_similar_role_success'); END IF;
    IF v_reputable_degree AND v_prior_job_success THEN
      v_status := 'exception_applies';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Very weak bucket but heavy-evidence exceptions BOTH satisfied.';
    ELSE
      v_status := 'decline_lss';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Very weak bucket requires BOTH reputable degree AND prior insurance-role success. Not met.';
    END IF;
  ELSE
    IF v_license_held THEN v_auto_exc := array_append(v_auto_exc, 'license_held'); END IF;
    IF v_reputable_degree THEN v_auto_exc := array_append(v_auto_exc, 'reputable_degree'); END IF;
    IF v_prior_job_success THEN v_auto_exc := array_append(v_auto_exc, 'prior_similar_role_success'); END IF;
    IF p_analytical IS NOT NULL AND p_analytical >= 70 THEN
      v_auto_exc := array_append(v_auto_exc, 'analytical_high');
    END IF;
    IF v_effective_role LIKE 'retention%' THEN
      v_auto_exc := array_append(v_auto_exc, 'role_less_sensitive');
    END IF;

    IF array_length(v_auto_exc, 1) IS NOT NULL AND array_length(v_auto_exc, 1) > 0 THEN
      v_status := 'exception_applies';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Weak bucket, exceptions found: '||array_to_string(v_auto_exc, ', ')||'. Framework verdict stands.';
    ELSE
      v_status := 'flag_lss_manual';
      v_reason := 'LSS '||p_lss_total||' with reliability='||p_reliability||'. Weak bucket, no exceptions found. Human review before pre-screen.';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', v_status, 'reason', v_reason,
    'auto_exceptions', to_jsonb(v_auto_exc),
    'lss_total', p_lss_total, 'reliability', p_reliability, 'effective_role', v_effective_role,
    'bucket', CASE WHEN v_is_very_weak THEN 'very_weak' ELSE 'weak' END,
    'detected', jsonb_build_object(
      'license_held', v_license_held,
      'reputable_degree', v_reputable_degree,
      'prior_job_success', v_prior_job_success,
      'edu_level', v_edu_level, 'institution', v_institution, 'relevance', v_relevance
    )
  );
END;
$function$;
