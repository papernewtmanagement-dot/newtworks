-- Remove the freeze guard from write_weekly_comp_v2.
-- Reason: CPR page banner is derived-display state and must always reflect
-- current truth (won_the_week + MVP). Freeze-on-send blocked Save + page-load
-- recompute after auto-send, causing the banner to lag reality.
-- Historical weeks (before current calendar quarter) stay read-only at the
-- frontend gate (isHistoricalWeek in CPRDetail.jsx) - no server-side lock needed.
-- Companion op-rule updated: "CPR data model - snapshot, freeze, dates, source columns".

DO $mig$
DECLARE
  v_def text;
  v_guard_start int;
  v_guard_end int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p
  WHERE p.pronamespace='public'::regnamespace AND p.proname='write_weekly_comp_v2';

  v_guard_start := position(E'  -- FREEZE GUARD:' IN v_def);
  IF v_guard_start = 0 THEN RAISE EXCEPTION 'freeze guard header not found'; END IF;

  v_guard_end := position(E'  v_prefill_result := public.prefill_weekly_cpr_form' IN v_def);
  IF v_guard_end = 0 OR v_guard_end <= v_guard_start THEN
    RAISE EXCEPTION 'end sentinel not found (got %)', v_guard_end;
  END IF;

  v_def := substring(v_def FROM 1 FOR v_guard_start - 1)
        || substring(v_def FROM v_guard_end);

  IF position('FREEZE GUARD' IN v_def) <> 0 THEN
    RAISE EXCEPTION 'guard still present after edit';
  END IF;

  EXECUTE v_def;
END $mig$;

DO $verify$
BEGIN
  IF position('FREEZE GUARD' IN pg_get_functiondef('public.write_weekly_comp_v2(uuid,date)'::regprocedure)) <> 0 THEN
    RAISE EXCEPTION 'FREEZE GUARD still present after migration';
  END IF;
END $verify$;
