-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-13 14:33:06 UTC (ledger name: update_hiregauge_rules_autonomy_imputation) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260813143306.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Resume scoring revamp: Autonomy — opportunity-relative instruction + insufficient-evidence imputation
-- Approved spec: session_note "2026-08-12 — Resume scoring revamp: approved spec
-- (signal-level weights + LE anchors + autonomy imputation)"
-- Citation: Mael 1991, Personnel Psychology 44 — biodata equal-access item principle.

UPDATE public.hiregauge_rules
SET
  description = description
    || E'\n\nOPPORTUNITY-RELATIVE (added 2026-08-12): Judge self-initiated activity against the opportunity window the candidate actually had. Initiative inside a short career (self-taught tools, voluntary duties, early side work) counts fully — do not require a decade of accumulation.'
    || E'\n\nINSUFFICIENT EVIDENCE (added 2026-08-12): Total work history under ~2 years consisting of a single first job with no realistic window for self-initiated activity → score 45 (pinned population median at 2026-08-12 calibration, n=273, mean 43.8) with reason ''insufficient tenure to assess — neutral imputation''. Do NOT score low for absence of opportunity (Mael 1991 equal-access principle). Do NOT omit the signal (omission silently reweights the other signals).',
  updated_at = now()
WHERE id = '1feb76f5-b774-470d-b35e-c2e9623a5ca5';
