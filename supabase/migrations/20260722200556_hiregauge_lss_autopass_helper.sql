-- Helper function: encodes the LSS-under-25 pre-interview auto-pass tiered rule.
-- Returns jsonb with tier + status + auto-detected exceptions + manual-check exceptions.
-- Rule text lives in hiregauge_rules.rule_name='LSS-under-25 pre-interview auto-pass'.
CREATE OR REPLACE FUNCTION public._hiregauge_lss_autopass(
  p_lss_total numeric,
  p_reliability text,
  p_analytical numeric,
  p_target_role text,
  p_best_fit_role text
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_tier text;
  v_status text;
  v_auto_exc text[] := ARRAY[]::text[];
  v_manual_exc text[] := ARRAY[]::text[];
  v_effective_role text;
  v_reason text;
BEGIN
  -- Not applicable: LSS at/above threshold or missing
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

  -- Tier 1: LSS <= 15 AND reliability=low → compound invalidity, hard pass, no exceptions
  IF p_lss_total <= 15 AND p_reliability = 'low' THEN
    v_tier := 'tier1';
    v_status := 'auto_pass_no_exceptions';
    v_reason := 'LSS ' || p_lss_total || ' AND reliability=low → compound validity failure (see Validity-LSS-Compound rule).';

  -- Tier 2: LSS <= 15 AND reliability high/moderate → strong pass, requires heavy evidence
  ELSIF p_lss_total <= 15 THEN
    v_tier := 'tier2';
    v_status := 'strong_pass_heavy_evidence_required';
    v_manual_exc := array_append(v_manual_exc, 'reputable_degree_AND_prior_job_success_both_required');
    v_reason := 'LSS ' || p_lss_total || ' is deep below floor. Interview only with reputable-school degree AND documented similar-job success.';

  -- Tier 3: LSS 16-24 AND reliability=low → soft pass, no exceptions
  ELSIF p_reliability = 'low' THEN
    v_tier := 'tier3';
    v_status := 'auto_pass_no_exceptions';
    v_reason := 'LSS ' || p_lss_total || ' AND reliability=low → score signal contaminated.';

  -- Tier 4: LSS 16-24 AND reliability high/moderate → soft pass, check for exceptions
  ELSE
    v_tier := 'tier4';

    -- Auto-detected exception: CTS Analytical trait >= 70
    IF p_analytical IS NOT NULL AND p_analytical >= 70 THEN
      v_auto_exc := array_append(v_auto_exc, 'analytical_high');
    END IF;

    -- Auto-detected exception: retention/service role less LSS-sensitive
    IF v_effective_role LIKE 'retention%' THEN
      v_auto_exc := array_append(v_auto_exc, 'role_less_sensitive');
    END IF;

    -- Manual-check exceptions always listed for Tier 4
    v_manual_exc := ARRAY['reputable_degree', 'documented_prior_job_success', 'relevant_licensure_PC_LH_IPS_Series'];

    IF array_length(v_auto_exc, 1) IS NOT NULL AND array_length(v_auto_exc, 1) > 0 THEN
      v_status := 'exception_applies';
      v_reason := 'LSS ' || p_lss_total || ' with reliability=' || p_reliability || '. Auto-detected exceptions: ' || array_to_string(v_auto_exc, ', ') || '. Also verify manual exceptions at pre-screen.';
    ELSE
      v_status := 'soft_pass_check_manual_exceptions';
      v_reason := 'LSS ' || p_lss_total || ' with reliability=' || p_reliability || '. No auto-detected exceptions. Verify manual exceptions at pre-screen before interviewing.';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'status', v_status,
    'tier', v_tier,
    'reason', v_reason,
    'auto_exceptions', to_jsonb(v_auto_exc),
    'manual_check_exceptions', to_jsonb(v_manual_exc),
    'lss_total', p_lss_total,
    'reliability', p_reliability,
    'effective_role', v_effective_role
  );
END;
$$;

-- Smoke test on all 5 new candidates + Stephanie + Marie
SELECT candidate_name, lss_total_accuracy AS lss,
       public._hiregauge_lss_autopass(
         lss_total_accuracy::numeric,
         reliability,
         analytical::numeric,
         assessment_target_role,
         NULL  -- best_fit_role not needed for smoke test
       ) AS autopass
FROM public.hiring_candidates
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND candidate_name IN ('Allan Piedrabuena','Katie Barraco','Carla Sanders','Maximus Moody','Jason Villa','Stephanie Rogers','Marie Story (test)')
ORDER BY lss_total_accuracy;
