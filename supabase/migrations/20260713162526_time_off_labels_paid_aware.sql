-- Migration: post-approval display labels respect is_paid
-- Rule: time_off_* + is_paid=true → "PTO"; else generic "Time off". Applied 2026-07-13.
-- Mirrors what was applied via apply_migration.
--
-- 1) Helper: canonical human label for a request row (post-decision aware)
CREATE OR REPLACE FUNCTION public.time_off_display_label(p_request_type text, p_is_paid boolean)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_request_type
    WHEN 'time_off_full_day' THEN CASE WHEN p_is_paid IS TRUE THEN 'PTO' ELSE 'Time off' END
    WHEN 'time_off_half_day' THEN CASE WHEN p_is_paid IS TRUE THEN 'PTO (half day)' ELSE 'Time off (half day)' END
    WHEN 'sick'              THEN 'Sick'
    WHEN 'remote_day'        THEN 'Remote'
    WHEN 'remote_half_day'   THEN 'Remote (half day)'
    WHEN 'four_day_off_change' THEN '4-day schedule change'
    ELSE p_request_type
  END;
$function$;

-- 2) time_off_calendar_dispatch — v_type_label now routes through the paid-aware helper for
--    non-four_day_off_change types. Full body applied live; see pg_get_functiondef for current source.
--
-- 3) time_off_notification_dispatch — same. v_type_display variable used in all three email paths
--    (vote request, vote closed, decision). Vote requests fire pre-decision (is_paid IS NULL → generic).
--    Decision emails fire post-decision (is_paid set → paid-aware).
--
-- To view current function bodies:
--   SELECT pg_get_functiondef(p.oid) FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
--     AND p.proname IN ('time_off_calendar_dispatch','time_off_notification_dispatch');
--
-- Full bodies not inlined here to keep the migration file readable. Source of truth = live DB.
-- Future regeneration: refresh supabase/schema_snapshots/functions_YYYY-MM-DD.sql after major sprints.
