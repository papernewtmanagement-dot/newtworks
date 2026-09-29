-- Pipeline board shows the CTS best-role fit after the assessment score (Peter 2026-09-28).
-- Display only: forwards to cts_role_fit, the single CTS fit function. Stores nothing,
-- feeds no score, verdict or gate.
CREATE OR REPLACE FUNCTION public.cts_best_fit(hc hiring_candidates)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT (public.cts_role_fit(hc.cts_result)->>'best_fit')::int;
$function$;
