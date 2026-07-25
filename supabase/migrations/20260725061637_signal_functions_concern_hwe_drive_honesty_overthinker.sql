-- Signal function library: derived-from-traits 0-100 scores that role_fit functions consume like competencies
CREATE OR REPLACE FUNCTION public.assessment_signal_concern(ta hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $$
BEGIN
  RETURN jsonb_build_object(
    'adjusted', COALESCE(ROUND(GREATEST(0, LEAST(100, ta.compassion))), 0)::int,
    'signal', 'concern', 'source_rule', 'CF-Concern',
    'notes', 'Direct from Compassion trait. Rule threshold: 40+ passes.'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.assessment_signal_hwe(ta hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $$
DECLARE dm_ratio numeric; is_ratio numeric; mha_proxy numeric; mha_ratio numeric; score numeric;
BEGIN
  dm_ratio := COALESCE(ta.deadline_motivation, 0) / 55.0;
  is_ratio := COALESCE(ta.independent_spirit, 0) / 60.0;
  mha_proxy := (COALESCE(ta.recognition_drive, 0) + COALESCE(ta.assertiveness, 0)) / 2.0;
  mha_ratio := mha_proxy / 50.0;
  score := LEAST(dm_ratio, is_ratio, mha_ratio) * 100;
  RETURN jsonb_build_object(
    'adjusted', ROUND(GREATEST(0, LEAST(100, score)))::int,
    'signal', 'hwe', 'source_rule', 'CF-HWE',
    'notes', 'Composite of DM/55, IS/60, (RD+AS)/2/50 - MIN of three normalized ratios (character-floor logic).'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.assessment_signal_drive_engine(ta hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $$
DECLARE d int; r int; a int; i int; arr int[]; top2 numeric; floor_count int; score numeric;
BEGIN
  d := COALESCE(ta.deadline_motivation, 0);
  r := COALESCE(ta.recognition_drive, 0);
  a := COALESCE(ta.assertiveness, 0);
  i := COALESCE(ta.independent_spirit, 0);
  arr := ARRAY[d, r, a, i];
  SELECT AVG(v) INTO top2 FROM (SELECT unnest(arr) v ORDER BY v DESC LIMIT 2) sub;
  floor_count := (CASE WHEN d < 25 THEN 1 ELSE 0 END) 
               + (CASE WHEN r < 25 THEN 1 ELSE 0 END)
               + (CASE WHEN a < 25 THEN 1 ELSE 0 END)
               + (CASE WHEN i < 25 THEN 1 ELSE 0 END);
  score := top2 - (floor_count * 10);
  RETURN jsonb_build_object(
    'adjusted', ROUND(GREATEST(0, LEAST(100, score)))::int,
    'signal', 'drive_engine', 'source_rule', 'drive-engine-composite',
    'notes', 'Top-2 avg of (DM,RD,AS,IS) minus 10 per floor trait (<25).'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.assessment_signal_honesty(ta hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $$
DECLARE bo_comp numeric; rd_comp numeric; rel_bonus numeric; score numeric;
BEGIN
  bo_comp := COALESCE(ta.belief_in_others, 0);
  rd_comp := 100 - COALESCE(ta.recognition_drive, 0);
  rel_bonus := CASE ta.reliability WHEN 'high' THEN 100 WHEN 'moderate' THEN 60 WHEN 'low' THEN 20 ELSE 40 END;
  score := bo_comp * 0.4 + rd_comp * 0.3 + rel_bonus * 0.3;
  RETURN jsonb_build_object(
    'adjusted', ROUND(GREATEST(0, LEAST(100, score)))::int,
    'signal', 'honesty', 'source_rule', 'CF-Honesty',
    'notes', 'BO*0.4 + (100-RD)*0.3 + reliability_bonus*0.3.'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.assessment_signal_overthinker_penalty(ta hiring_candidates)
 RETURNS jsonb LANGUAGE plpgsql STABLE
AS $$
DECLARE an int; is_ int; score numeric;
BEGIN
  an := COALESCE(ta.analytical, 0);
  is_ := COALESCE(ta.independent_spirit, 0);
  IF an >= 60 AND is_ < 50 THEN
    score := (an - 60) * 2 + (50 - is_) * 2;
  ELSE
    score := 0;
  END IF;
  RETURN jsonb_build_object(
    'adjusted', ROUND(GREATEST(0, LEAST(100, score)))::int,
    'signal', 'overthinker_penalty', 'source_rule', 'Overthinker/Non-Executor',
    'notes', 'Zero if AN<60 OR IS>=50. Otherwise (AN-60)*2 + (50-IS)*2.'
  );
END;
$$;
