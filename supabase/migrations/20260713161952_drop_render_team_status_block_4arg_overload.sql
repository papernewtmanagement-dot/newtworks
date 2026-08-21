
-- Fix critical latent bug from migration 20260713135000: adding the 5-arg
-- signature with DEFAULT NULL created an overloading collision. The old
-- 4-arg signature was still present, so 4-arg calls (from
-- team_checkin_compile_results, which handles midday + EOD compiles) now
-- fail with "function is not unique" at runtime.
--
-- Fix: drop the old 4-arg signature. The 5-arg signature's default handles
-- 4-arg call sites naturally (v_wtw_date := COALESCE(NULL, p_as_of_date)
-- = p_as_of_date = today, which is what those callers want).
--
-- No compile has fired yet today (only the morning reminder), so no
-- production impact yet. Midday compile fires next at ~12:30 CT.

DROP FUNCTION IF EXISTS public.render_team_status_block(
  p_agency_id uuid,
  p_as_of_date date,
  p_fresh_type text,
  p_header_label text
);

