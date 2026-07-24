-- Refresh stale meta.adjusted_source label in 7 role_fit fns post-3D atomic rename.
-- Doc-only change: string label inside output meta. No scoring logic touched.
-- 'cts_competency_*_v2 (direct, phase_3c1)' -> 'cts_competency_* (canonical, phase_3d)'

DO $meta_refresh$
DECLARE
  r record;
  transformed_defs jsonb := '{}'::jsonb;
  v_count int;
BEGIN
  FOR r IN
    SELECT proname,
           replace(pg_get_functiondef(oid),
                   'cts_competency_*_v2 (direct, phase_3c1)',
                   'cts_competency_* (canonical, phase_3d)') AS new_def
    FROM pg_proc
    WHERE pronamespace='public'::regnamespace
      AND proname IN (
        'assessment_role_fit_sales_outbound','assessment_role_fit_sales_inbound',
        'assessment_role_fit_sales_in_book','assessment_role_fit_retention_reception',
        'assessment_role_fit_retention_escalation','assessment_role_fit_retention_support',
        'assessment_role_fit_aspirant'
      )
  LOOP
    transformed_defs := transformed_defs || jsonb_build_object(r.proname, r.new_def);
  END LOOP;

  SELECT count(*) INTO v_count FROM jsonb_object_keys(transformed_defs);
  IF v_count <> 7 THEN
    RAISE EXCEPTION 'Meta refresh: expected 7 role_fit defs, captured %', v_count;
  END IF;

  FOR r IN SELECT key, value FROM jsonb_each_text(transformed_defs) LOOP
    EXECUTE r.value;
  END LOOP;
END;
$meta_refresh$;
