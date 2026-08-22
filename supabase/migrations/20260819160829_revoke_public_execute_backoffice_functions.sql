-- Close anonymous access to back-office functions without touching the bots.
--
-- Every function below is SECURITY DEFINER (runs with full privileges and skips
-- row security) AND had EXECUTE granted to PUBLIC, which includes anon -- the
-- unauthenticated role any visitor gets. So they were callable with no login.
--
-- Verified before revoking: all 24 already hold an explicit service_role grant
-- (how edge functions and the automation runner call them), and the ones the
-- browser calls also hold an explicit authenticated grant. Revoking PUBLIC
-- removes anon and nothing else -- REVOKE ... FROM PUBLIC does not touch
-- role-specific grants.
--
-- DELIBERATELY NOT INCLUDED: compute_v1_assessment_token and
-- verify_v1_assessment_token. Job candidates open assessment links while logged
-- out, so anon EXECUTE there may be load-bearing by design. GitHub code search
-- returned zero hits for all three names tested (including one that certainly
-- has a caller), so the search index is unreliable here and absence of hits is
-- not evidence. Those two stay open until the candidate-facing page is read
-- directly.

REVOKE EXECUTE ON FUNCTION public.approve_time_clock_edit(uuid, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cash_register_gl_writer(uuid, boolean, date, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.chatbot_read_sql(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.claim_mvp_prize(uuid, date, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.comp_gl_writer(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.comp_gl_writer(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.composio_send_email(uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.paper_newt_send_message(bigint, text, text, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.payroll_gl_writer(uuid, boolean, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.payroll_gl_writer(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.payroll_weekly_nag(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.pfa_record_customer_deposit(text, text, text, numeric, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.pfa_resend_close_telegram(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.pfa_send_reconciliation(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.pfa_void_deposit(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.prune_automation_run_log() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.prune_session_notes() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.run_cash_register_gl_writer(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.send_mvp_prize_win_telegram(uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.send_signature_email(uuid, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.send_v1_assessment_invitations(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.statement_gl_writer(uuid, uuid, date, date, boolean, uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.statement_gl_writer_recipe(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.time_off_send_email(uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.try_send_weekly_cpr_recap() FROM PUBLIC;
