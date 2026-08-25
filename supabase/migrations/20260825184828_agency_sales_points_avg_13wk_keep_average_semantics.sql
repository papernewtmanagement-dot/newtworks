-- Keep the agency figure an AVERAGE PER PERSON per week, which is what it has
-- always meant and what the band thresholds compare against (they are per-person
-- targets). The prior revision in 20260824234100 briefly summed the team, which
-- silently changed the unit. Restoring average semantics.
CREATE OR REPLACE FUNCTION public.agency_sales_points_avg_13wk(p_agency_id uuid, p_end_date date DEFAULT CURRENT_DATE)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  SELECT ROUND(AVG(public.team_member_sales_points_avg_nwk(t.id, 13, p_end_date)), 2)
  FROM public.team t
  WHERE t.agency_id = p_agency_id
    AND t.is_active
    AND COALESCE(t.is_test_user, false) = false
    AND COALESCE(t.is_admin_backoffice, false) = false;
$function$;
