-- telegram_recover_checkins posted to the edge function's recoverCheckins action,
-- which re-read typed quote/sales numbers out of old group messages. Production
-- is the source now. The edge handler went in telegram v26; this is the caller.
DROP FUNCTION IF EXISTS public.telegram_recover_checkins(date, text);

-- The reminder told the team only a reaction counts. A text reply counts too now,
-- so the line has to say so or it is telling them something untrue.
CREATE OR REPLACE FUNCTION public.team_checkin_reminder_ack_line()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT '👍 React when you have read this — or just reply.';
$function$;

COMMENT ON FUNCTION public.team_checkin_reminder_ack_line() IS
  'One place for the acknowledgment line on midday and end-of-day reminders. Peter copy.';