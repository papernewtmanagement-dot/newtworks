-- Migration: daily_call_activity_plain_unique
-- Applied: 2026-07-08
--
-- PostgREST upsert with onConflict='agency_id,extension_raw,activity_date'
-- cannot match an expression-based unique index (lower(extension_raw)).
-- Replace with a plain unique constraint. The parser already produces
-- normalized extension names, so case-preservation is fine.

DROP INDEX IF EXISTS public.ux_daily_call_activity_agency_ext_date;

ALTER TABLE public.daily_call_activity
  DROP CONSTRAINT IF EXISTS uq_daily_call_activity_agency_ext_date;

ALTER TABLE public.daily_call_activity
  ADD CONSTRAINT uq_daily_call_activity_agency_ext_date
  UNIQUE (agency_id, extension_raw, activity_date);
