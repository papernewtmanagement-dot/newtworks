-- The time clock is for hourly people. Salaried teammates should not see it.
-- pay_type is not on team_directory on purpose (pay is sensitive), so this
-- returns only the viewer's own pay type and nothing else.
CREATE OR REPLACE FUNCTION public.my_pay_type()
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT t.pay_type FROM public.team t WHERE t.id = public.current_team_member_id();
$function$;

GRANT EXECUTE ON FUNCTION public.my_pay_type() TO authenticated, service_role;
