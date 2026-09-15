-- Peter 2026-09-15: shorten the react line on the team check-in messages.
CREATE OR REPLACE FUNCTION public.team_checkin_reminder_ack_line()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT '👍 React when you read this';
$function$;
