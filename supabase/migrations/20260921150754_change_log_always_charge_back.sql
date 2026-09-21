DO $mig$
DECLARE d text; d2 text;
BEGIN
  d := pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure);
  d2 := regexp_replace(d,
    'WHEN floor\(\(public\.cancel_counts_on\(c\.agency_id, c\.created_at\) - b\.anchor\) / 91\.0\)\s*> floor\(\(p\.issued_date - b\.anchor\) / 91\.0\) THEN ''charged_back''\s*ELSE ''removed'' END AS effect',
    'ELSE ''charged_back'' END AS effect');
  IF d2 = d THEN RAISE EXCEPTION 'shape changed'; END IF;
  EXECUTE d2;
END
$mig$;
