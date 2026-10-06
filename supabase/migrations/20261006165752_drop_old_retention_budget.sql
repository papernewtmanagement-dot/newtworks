-- Peter 2026-10-06: delete the old standalone retention budget. Replaced by the team bonus pool split in three.
-- Callers checked before drop: no function, view, trigger, foreign key, cron job, automation recipe, or app/edge code reads either object.
DO $$
DECLARE v_hits text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_hits
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname <> 'compute_retention_budget_weekly'
    AND (pg_get_functiondef(p.oid) ILIKE '%compute_retention_budget_weekly%' OR pg_get_functiondef(p.oid) ILIKE '%retention_budget_schedule%');
  IF v_hits IS NOT NULL THEN RAISE EXCEPTION 'Still called by: %', v_hits; END IF;
END $$;

DROP FUNCTION public.compute_retention_budget_weekly(uuid, date);
DROP TABLE public.retention_budget_schedule;

DO $$
BEGIN
  IF to_regprocedure('public.compute_retention_budget_weekly(uuid,date)') IS NOT NULL
     OR to_regclass('public.retention_budget_schedule') IS NOT NULL THEN
    RAISE EXCEPTION 'Old retention budget still present';
  END IF;
END $$;
