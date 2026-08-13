-- Mirrors migration 20260806210932 (lockdown_rescope_anon_policies_to_authenticated),
-- which was applied live on 2026-08-06 but never mirrored to this repo. Found
-- 2026-08-13 while double-checking that the public assessment flow still works
-- after the v_hiring_candidates security_invoker fix, and separately confirming
-- the state of the anon-read grant on hiring_candidates that was flagged as a
-- loose thread earlier the same session.
--
-- What this migration actually did in production: closed the anon-readable
-- hiring_candidates exposure that migration 20260806190201 had opened earlier
-- the same evening (that one extended staff_hiring_candidates_select to
-- TO authenticated, anon USING (true), reasoning that the app "runs on the
-- plain anon key with no login" — a premise a later migration the same night,
-- 20260806193501/200816, established was wrong: the app has a full Supabase
-- Auth login gate, and the one legitimately anon-facing surface — the public
-- assessment flow — goes through the v1-assessment edge function on the
-- service role key, never through direct table reads). This migration dropped
-- anon from that policy, restoring authenticated-only, USING (true) — batch4
-- (20260807051312, mirrored) later tightened USING (true) to is_agency_admin()
-- on top of this, which is the state live today.
--
-- It also re-scoped three vestigial anon-facing policies on job_applications,
-- job_postings, and job_screener_questions to authenticated-only. Verified
-- 2026-08-13 this did not break the public careers page: careers-site (the
-- edge function serving /careers) reads those tables via SUPABASE_SERVICE_ROLE_KEY,
-- bypassing RLS entirely — no frontend code path reads them directly as anon.
--
-- Mirrored verbatim from supabase_migrations.schema_migrations.statements for
-- version 20260806210932. No changes applied here — the live database already
-- has this; this file only brings the repo mirror into sync so a fresh
-- `supabase db reset` from this repo reproduces the live security posture
-- instead of regressing to the anon-readable state that existed for a few
-- hours on 2026-08-06.
--
-- 1 of 4: hiring_candidates read — drop anon, keep authenticated, same USING.
ALTER POLICY staff_hiring_candidates_select ON public.hiring_candidates
  TO authenticated USING (true);
-- 2 of 4: vestigial careers-page anon insert. Re-scoped, NOT dropped.
ALTER POLICY ja_anon_insert ON public.job_applications
  TO authenticated WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
-- 3 of 4: vestigial public job board read.
ALTER POLICY jp_public_active ON public.job_postings
  TO authenticated USING ((is_active = true) AND (publish_to_careers_page = true));
-- 4 of 4: vestigial public screener read.
ALTER POLICY jsq_public_active ON public.job_screener_questions
  TO authenticated USING (is_active = true);
