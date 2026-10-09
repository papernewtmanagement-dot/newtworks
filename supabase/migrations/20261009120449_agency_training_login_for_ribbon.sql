-- The row of values (training_login_email, training_login_password) is set in the live database only.
-- It is left out of this mirror because the repo is public.
ALTER TABLE public.agency ADD COLUMN IF NOT EXISTS training_login_email text;
ALTER TABLE public.agency ADD COLUMN IF NOT EXISTS training_login_password text;
CREATE OR REPLACE FUNCTION public.ribbon_training_login()
 RETURNS TABLE(email text, password text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT a.training_login_email, a.training_login_password
  FROM public.agency a
  WHERE a.id = (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() AND u.role <> 'family' LIMIT 1);
$function$;
REVOKE EXECUTE ON FUNCTION public.ribbon_training_login() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ribbon_training_login() TO authenticated;
