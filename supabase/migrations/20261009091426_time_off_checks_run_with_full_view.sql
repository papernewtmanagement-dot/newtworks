-- Time-off checks were running under the requester's own row-level view.
-- Staff see only their own team row and none of pay_scale, so coverage counted
-- a team of 1 (always RED -> every staff request flagged case-by-case, never voted)
-- and the eligibility reason printed a 0+ requirement.
ALTER FUNCTION public.time_off_check_coverage(uuid,date,date,uuid,text,uuid) SECURITY DEFINER SET search_path = public;
ALTER FUNCTION public.time_off_check_eligibility(uuid) SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION public.time_off_check_coverage(uuid,date,date,uuid,text,uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.time_off_check_eligibility(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.time_off_check_coverage(uuid,date,date,uuid,text,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.time_off_check_eligibility(uuid) TO authenticated, service_role;
