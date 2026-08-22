CREATE OR REPLACE FUNCTION public.assessment_intelligence_composite(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $function$
  SELECT public.hiregauge_lss_delta_v2(c.*)
  FROM public.hiring_candidates c
  WHERE c.id = p_assessment_id;
$function$;
