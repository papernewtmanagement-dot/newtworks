-- prior_quarter_closes existed only to loop over current_cycle_info. Peter directive
-- 2026-08-28: a function that exists only to call the core function should not exist --
-- its caller calls the core function instead. CPRDetail.jsx now does exactly that
-- (commit d779ebad, deploy dpl_FyV34Fk4aRySFoZgH5bRWce91LXm READY). No SQL function
-- referenced it; verified caller-free before dropping.

DO $guard$
DECLARE v_callers int;
BEGIN
  SELECT count(*) INTO v_callers
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname <> 'prior_quarter_closes'
    AND pg_get_functiondef(p.oid) ILIKE '%prior_quarter_closes%';

  IF v_callers > 0 THEN
    RAISE EXCEPTION 'prior_quarter_closes still has % SQL caller(s) — not dropping', v_callers;
  END IF;
END
$guard$;

DROP FUNCTION IF EXISTS public.prior_quarter_closes(uuid, date, integer);
