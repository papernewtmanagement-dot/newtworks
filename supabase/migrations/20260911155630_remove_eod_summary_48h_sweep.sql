-- Peter 2026-09-10: Friday's EOD summary stays up over the weekend so the team can
-- reflect on it. Sweep removed. Monday's kickoff still tries to delete it, but
-- Telegram's 48-hour limit refuses, so it simply stays as one extra message. Same
-- after a holiday gap. Accepted by Peter.
SELECT cron.unschedule('team_checkin_stale_eod_sweep')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'team_checkin_stale_eod_sweep');
DROP FUNCTION IF EXISTS public.team_checkin_sweep_stale_eod_summaries();