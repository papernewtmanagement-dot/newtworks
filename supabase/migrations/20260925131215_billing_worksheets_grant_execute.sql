-- The Dewey page calls these as the signed-in login. New functions only get
-- postgres and service_role by default, so logins need the grant, the same as
-- rp_log_entry and kickoff_commits_mine.
GRANT EXECUTE ON FUNCTION public.billing_worksheet_save(text, text, text, jsonb, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.billing_worksheet_get(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.billing_worksheet_list(text, integer) TO authenticated;
