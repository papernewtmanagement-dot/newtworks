-- 20260722_lss_autopass_reads_structured_data
--
-- Rewrites _hiregauge_lss_autopass to detect the three previously-manual-check
-- exceptions (reputable degree, prior similar-job success, relevant licensure)
-- from structured columns instead of a hardcoded list of "please verify"
-- exception names.
--
-- New signature adds three jsonb params. Since the arity changes, we drop the
-- old function first per op-rule "Function-signature changes".

BEGIN;

DROP FUNCTION IF EXISTS public._hiregauge_lss_autopass(numeric, text, numeric, text, text);

CREATE OR REPLACE FUNCTION public._hiregauge_lss_autopass(
  p_lss_total numeric,
  p_reliability text,
  p_analytical numeric,
  p_target_role text,
  p_best_fit_role text,
  p_licenses jsonb,
  p_education jsonb,
  p_prior_role jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $function$
DECLARE
  v_tier text;
  v_status text;
  v_auto_exc text[] := ARRAY[]::text[];
  v_effective_role text;
  v_reason text;
  v_license_held boolean := false;
  v_reputable_degree boolean := false;
  v_prior_job_success boolean := false;
  v_institution text;
  v_edu_level text;
  v_relevance text;
BEGIN
  IF p_lss_total IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'not_scored',
      'tier', null,
      'reason', 'LSS not yet scored',
      'auto_exceptions', '[]'::jsonb,
      'manual_check_exceptions', '[]'::jsonb
    );
  END IF;
  IF p_lss_total >= 25 THEN
    RETURN jsonb_build_object(
      'status', 'not_applicable',
      'tier', null,
      'reason', 'LSS total ' || p_lss_total || ' is at or above the 25 threshold',
      'auto_exceptions', '[]'::jsonb,
      'manual_check_exceptions', '[]'::jsonb
    );
  END IF;

  v_effective_role := COALESCE(p_target_role, p_best_fit_role);

  -- Detect license held (any of the tracked licenses = true)
  IF p_licenses IS NOT NULL THEN
    v_license_held := COALESCE((p_licenses->>'pc')::boolean, false)
                   OR COALESCE((p_licenses->>'lh')::boolean, false)
                   OR COALESCE((p_licenses->>'ips')::boolean, false)
                   OR COALESCE((p_licenses->>'series_6')::boolean, false)
                   OR COALESCE((p_licenses->>'series_63')::boolean, false)
                   OR COALESCE((p_licenses->>'series_7')::boolean, false)
                   OR COALESCE((p_licenses->>'series_24')::boolean, false);
  END IF;

  -- Detect reputable degree: bachelors+ AND institution named (non-empty)
  IF p_education IS NOT NULL THEN
    v_edu_level := p_education->>'highest_completed';
    v_institution := NULLIF(TRIM(COALESCE(p_education->>'institution', '')), '');
    v_reputable_degree := v_edu_level IN ('bachelors','masters','doctorate')
                          AND v_institution IS NOT NULL;
  END IF;

  -- Detect prior similar-job success: insurance-direct or adjacent AND success signals present
  IF p_prior_role IS NOT NULL THEN
    v_relevance := p_prior_role->>'highest_relevance';
    v_prior_job_success := v_relevance IN ('insurance_direct','insurance_adjacent')
                           AND jsonb_typeof(p_prior_role->'success_signals') = 'array'
                           AND jsonb_array_length(p_prior_role->'success_signals') > 0;
  END IF;

  -- Tier 1: LSS <= 15 AND reliability=low → compound invalidity, hard fail, no exceptions honored
  IF p_lss_total <= 15 AND p_reliability = 'low' THEN
    v_tier := 'tier1';
    v_status := 'auto_pass_no_exceptions';
    v_reason := 'LSS ' || p_lss_total || ' AND reliability=low → compound validity failure (Validity-LSS-Compound rule). Framework declines regardless of qualifications.';

  -- Tier 2: LSS <= 15 AND reliability high/moderate → strong pass unless BOTH heavy-evidence exceptions present
  ELSIF p_lss_total <= 15 THEN
    v_tier := 'tier2';
    IF v_reputable_degree THEN v_auto_exc := array_append(v_auto_exc, 'reputable_degree'); END IF;
    IF v_prior_job_success THEN v_auto_exc := array_append(v_auto_exc, 'prior_similar_role_success'); END IF;
    IF v_reputable_degree AND v_prior_job_success THEN
      v_status := 'exception_applies';
      v_reason := 'LSS ' || p_lss_total || ' is deep below floor. Heavy-evidence exceptions BOTH satisfied: reputable degree (' || COALESCE(v_institution,'unknown') || ') AND prior similar-role success (' || v_relevance || '). Interview justified.';
    ELSE
      v_status := 'auto_pass_heavy_evidence_missing';
      v_reason := 'LSS ' || p_lss_total || ' is deep below floor. Tier 2 requires BOTH reputable degree AND documented prior similar-role success. Found: degree=' || COALESCE(v_reputable_degree::text,'null') || ', prior_role=' || COALESCE(v_prior_job_success::text,'null') || '. Framework declines.';
    END IF;

  -- Tier 3: LSS 16-24 AND reliability=low → score signal contaminated, no exceptions
  ELSIF p_reliability = 'low' THEN
    v_tier := 'tier3';
    v_status := 'auto_pass_no_exceptions';
    v_reason := 'LSS ' || p_lss_total || ' AND reliability=low → score signal contaminated. Framework declines regardless of qualifications.';

  -- Tier 4: LSS 16-24 AND reliability high/moderate → check for any exception
  ELSE
    v_tier := 'tier4';

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
      v_reason := 'LSS ' || p_lss_total || ' with reliability=' || p_reliability || '. Exceptions found: ' || array_to_string(v_auto_exc, ', ') || '. Interview justified.';
    ELSE
      v_status := 'auto_pass';
      v_reason := 'LSS ' || p_lss_total || ' with reliability=' || p_reliability || '. No exceptions found in structured data. Framework declines.';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', v_status,
    'tier', v_tier,
    'reason', v_reason,
    'auto_exceptions', to_jsonb(v_auto_exc),
    'manual_check_exceptions', '[]'::jsonb,
    'lss_total', p_lss_total,
    'reliability', p_reliability,
    'effective_role', v_effective_role,
    'detected', jsonb_build_object(
      'license_held', v_license_held,
      'reputable_degree', v_reputable_degree,
      'prior_job_success', v_prior_job_success,
      'edu_level', v_edu_level,
      'institution', v_institution,
      'relevance', v_relevance
    )
  );
END;
$function$;

COMMIT;
