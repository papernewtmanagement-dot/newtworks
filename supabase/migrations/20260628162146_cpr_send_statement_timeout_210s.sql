-- Raise statement_timeout on the CPR auto-send functions to 210s so the
-- in-function 180s Composio wait (150s poll + 30s recovery sweep) actually
-- fits. Default cron statement_timeout is 120s — killed the 2026-06-28
-- 6 AM CT fire mid-poll on a slow-Composio day. Also kills the EXCEPTION
-- handler, so no Telegram alert. This SET clause applies only when these
-- functions run.
ALTER FUNCTION public.try_send_weekly_cpr_recap()
  SET statement_timeout = '210000';

ALTER FUNCTION public.send_weekly_cpr_recap(uuid, date)
  SET statement_timeout = '210000';
