-- Correction to the kicker arithmetic.
-- Peter's example: ours 50% -> 49% is treated as 48%, not 47%.
-- The doubled improvement is measured from where we WERE, not from where we landed:
--   effective = prior - (2 x improvement)  ==  ours - improvement
--   50 - (2 x 1) = 48   and   49 - 1 = 48   (same number)
-- Holding at 49% the following week means improvement 0, so it is treated as 49%.
DO $mig$
DECLARE
  v_def text;
  a_eff CONSTANT text :=
'  v_eff_auto := GREATEST(0.0001, v_our_auto - (2 * v_imp_auto));' || chr(10) ||
'  v_eff_fire := GREATEST(0.0001, v_our_fire - (2 * v_imp_fire));';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname='public' AND p.proname='compute_retention_floor_factor';

  n := (length(v_def) - length(replace(v_def, a_eff, ''))) / length(a_eff);
  IF n <> 1 THEN RAISE EXCEPTION 'effective-rate anchor matched % times', n; END IF;

  v_def := replace(v_def, a_eff,
'  -- doubled improvement measured from the PRIOR rate: prior - 2*imp, which equals ours - imp' || chr(10) ||
'  v_eff_auto := GREATEST(0.0001, v_our_auto - v_imp_auto);' || chr(10) ||
'  v_eff_fire := GREATEST(0.0001, v_our_fire - v_imp_fire);');

  EXECUTE v_def;
END
$mig$;
