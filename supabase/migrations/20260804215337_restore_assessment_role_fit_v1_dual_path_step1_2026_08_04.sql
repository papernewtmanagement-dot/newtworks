-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-04 21:53:37 UTC (ledger name: restore_assessment_role_fit_v1_dual_path_step1_2026_08_04) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260804215337.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- STEP 1 of restoring dual-path assessment scoring (Peter's original standing
-- instruction: the old assessment and the new assessment must BOTH remain
-- scoreable). Migration 20260803192428 ("newtworks_competency_step7_retire_
-- orphaned_role_fit_v1") DROPPED all seven public.assessment_role_fit_* functions
-- instead of leaving them alongside the new public.newtworks_role_fit_* set.
-- 53 candidates hold old-instrument trait data and 0 hold new-instrument facet
-- data, so every one of them stopped scoring on the assessment layer.
--
-- This replays the last known-good definitions byte-for-byte out of
-- supabase_migrations.schema_migrations rather than re-deriving them. The
-- weights in these bodies are the product of weeks of calibration
-- (role_fit v3.5-v3.9 tuning, coordinated SI/SO calibration, LSS 2d work) and
-- must not be re-derived from scratch. Source statements verified beforehand to
-- contain exactly 7 CREATE OR REPLACE FUNCTION and zero DROP / ALTER TABLE /
-- INSERT / UPDATE / DELETE, so the replay is purely additive.
--
--   20260801024234 -> assessment_role_fit_sales_outbound
--   20260801024623 -> assessment_role_fit_sales_inbound,
--                     assessment_role_fit_sales_in_book,
--                     assessment_role_fit_retention_escalation
--   20260801025035 -> assessment_role_fit_retention_reception,
--                     assessment_role_fit_retention_support,
--                     assessment_role_fit_aspirant
DO $restore$
DECLARE
  v_stmt text;
  v_version text;
  v_restored int := 0;
BEGIN
  FOR v_version, v_stmt IN
    SELECT m.version, st.stmt
    FROM supabase_migrations.schema_migrations m
    CROSS JOIN LATERAL unnest(m.statements) AS st(stmt)
    WHERE m.version IN ('20260801024234','20260801024623','20260801025035')
      AND st.stmt ILIKE '%FUNCTION public.assessment_role_fit_%'
    ORDER BY m.version
  LOOP
    EXECUTE v_stmt;
    v_restored := v_restored + 1;
    RAISE NOTICE 'replayed migration statement from %', v_version;
  END LOOP;

  IF v_restored <> 3 THEN
    RAISE EXCEPTION 'expected 3 source statements, replayed %', v_restored;
  END IF;
END
$restore$;

-- Verify all seven are back before this migration is allowed to commit.
DO $verify$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname LIKE 'assessment_role_fit_%';
  IF v_n <> 7 THEN
    RAISE EXCEPTION 'expected 7 assessment_role_fit_* functions after restore, found %', v_n;
  END IF;
END
$verify$;
