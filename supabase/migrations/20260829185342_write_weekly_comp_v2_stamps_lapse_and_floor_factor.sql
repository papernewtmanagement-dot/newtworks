-- write_weekly_comp_v2 now freezes the retention-floor inputs onto the weekly CPR row:
--   agency_lapse_auto_at_write / agency_lapse_fire_at_write  (our own lapse rate at write time)
--   retention_floor_factor                                   (NULL when no territory median entered)
-- Peter 2026-08-28: these must freeze with the week so they cannot drift.
-- Side benefit: this is what starts building the history of our own lapse rate
-- that the improvement kicker will need.
DO $mig$
DECLARE
  v_def text;
  a_declare CONSTANT text := '  v_report_id      uuid;';
  a_update  CONSTANT text :=
'  UPDATE public.weekly_cpr_reports' || chr(10) ||
'  SET wtw_requirements_adjustment_quotes = COALESCE((v_wtw_adj->''team''->>''quotes_under'')::int, 0),' || chr(10) ||
'      wtw_requirements_adjustment = COALESCE((v_wtw_adj->''team''->>''dollars'')::numeric, 0),' || chr(10) ||
'      updated_at = now()' || chr(10) ||
'  WHERE id = v_report_id;';
  n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid = p.pronamespace
  WHERE nsp.nspname = 'public' AND p.proname = 'write_weekly_comp_v2';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'write_weekly_comp_v2 not found';
  END IF;

  IF position('v_floor_diag' in v_def) > 0 THEN
    RAISE EXCEPTION 'already patched - floor stamping is present; refusing to double-apply';
  END IF;

  n := (length(v_def) - length(replace(v_def, a_declare, ''))) / length(a_declare);
  IF n <> 1 THEN RAISE EXCEPTION 'declare anchor matched % times, expected 1', n; END IF;

  n := (length(v_def) - length(replace(v_def, a_update, ''))) / length(a_update);
  IF n <> 1 THEN RAISE EXCEPTION 'update anchor matched % times, expected 1', n; END IF;

  v_def := replace(v_def, a_declare, a_declare || chr(10) || '  v_floor_diag     jsonb;');

  v_def := replace(v_def, a_update,
'  v_floor_diag := public.compute_retention_floor_factor(p_agency_id, p_week_end_date);' || chr(10) ||
chr(10) ||
'  UPDATE public.weekly_cpr_reports' || chr(10) ||
'  SET wtw_requirements_adjustment_quotes = COALESCE((v_wtw_adj->''team''->>''quotes_under'')::int, 0),' || chr(10) ||
'      wtw_requirements_adjustment = COALESCE((v_wtw_adj->''team''->>''dollars'')::numeric, 0),' || chr(10) ||
'      agency_lapse_auto_at_write = ROUND(NULLIF(v_floor_diag->>''our_auto'','''')::numeric, 6),' || chr(10) ||
'      agency_lapse_fire_at_write = ROUND(NULLIF(v_floor_diag->>''our_fire'','''')::numeric, 6),' || chr(10) ||
'      retention_floor_factor = NULLIF(v_floor_diag->>''factor'','''')::numeric,' || chr(10) ||
'      updated_at = now()' || chr(10) ||
'  WHERE id = v_report_id;');

  EXECUTE v_def;
END
$mig$;
