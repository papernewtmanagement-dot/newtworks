REVOKE ALL ON FUNCTION public.checkin_refresh_commits(uuid, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.checkin_refresh_commits(uuid, date) TO service_role;
