DROP FUNCTION public.hiregauge_composite_recommendation(uuid);
DROP FUNCTION public.hiregauge_evaluate_candidate(uuid);
DROP FUNCTION public._hiregauge_get_trait_value(hiring_candidates, text);

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS overall_score,
  DROP COLUMN IF EXISTS assessment_date;
