-- Master composite. Runs all six careless-response methods (a-f) and
-- combines the flag count into a three-band verdict, per Peter's spec:
-- 0-1 fires = high, 2 fires = medium, 3+ fires = low. reliability_detail is
-- a JSONB object with each method's fired flag + diagnostic detail string,
-- so a low/medium verdict is auditable rather than a bare label.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_reliability_composite(
  p_candidate_id uuid
)
RETURNS TABLE(reliability text, fired_count int, reliability_detail jsonb)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  r_fast RECORD;
  r_slow RECORD;
  r_straight RECORD;
  r_retest RECORD;
  r_evenodd RECORD;
  r_bogus RECORD;
  v_fired_count int;
  v_detail jsonb;
BEGIN
  SELECT * INTO r_fast FROM public.hiregauge_v2_careless_response_time_fast(p_candidate_id);
  SELECT * INTO r_slow FROM public.hiregauge_v2_careless_disengagement_slow(p_candidate_id);
  SELECT * INTO r_straight FROM public.hiregauge_v2_careless_straightlining(p_candidate_id);
  SELECT * INTO r_retest FROM public.hiregauge_v2_careless_retest_divergence(p_candidate_id);
  SELECT * INTO r_evenodd FROM public.hiregauge_v2_careless_evenodd_consistency(p_candidate_id);
  SELECT * INTO r_bogus FROM public.hiregauge_v2_careless_bogus_items(p_candidate_id);

  v_fired_count :=
    (r_fast.fired)::int + (r_slow.fired)::int + (r_straight.fired)::int +
    (r_retest.fired)::int + (r_evenodd.fired)::int + (r_bogus.fired)::int;

  v_detail := jsonb_build_object(
    'response_time_fast',     jsonb_build_object('fired', r_fast.fired,     'detail', r_fast.detail),
    'disengagement_slow',     jsonb_build_object('fired', r_slow.fired,     'detail', r_slow.detail),
    'straightlining',         jsonb_build_object('fired', r_straight.fired, 'detail', r_straight.detail),
    'retest_divergence',      jsonb_build_object('fired', r_retest.fired,   'detail', r_retest.detail),
    'evenodd_consistency',    jsonb_build_object('fired', r_evenodd.fired,  'detail', r_evenodd.detail),
    'bogus_items',            jsonb_build_object('fired', r_bogus.fired,    'detail', r_bogus.detail),
    'computed_at',            now()
  );

  RETURN QUERY SELECT
    CASE
      WHEN v_fired_count <= 1 THEN 'high'
      WHEN v_fired_count = 2 THEN 'medium'
      ELSE 'low'
    END,
    v_fired_count,
    v_detail;
END;
$function$;

-- Write-back wrapper, mirrors apply_newtworks_v1_lss_to_candidate's pattern:
-- computes the composite and stamps it onto the candidate row. Called from
-- v1-assessment's handleFinalizeV2 on completion, same as v1's finalize path.
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_reliability_to_candidate(
  p_candidate_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_row RECORD;
BEGIN
  SELECT * INTO v_row FROM public.hiregauge_v2_reliability_composite(p_candidate_id);

  UPDATE public.hiring_candidates
  SET reliability = v_row.reliability,
      reliability_detail = v_row.reliability_detail
  WHERE id = p_candidate_id;
END;
$function$;
