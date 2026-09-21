-- An issue entry's line: a correction says only the part that moved, and an
-- issue with no issued premium yet says so instead of "at blank".
DO $mig$
DECLARE v_def text; v_new text; v_old text; v_rep text;
BEGIN
  SELECT pg_get_functiondef('public.production_changes_for_range(uuid,date,date,boolean)'::regprocedure) INTO v_def;
  v_old := $o$                ELSE 'issued ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') ||
                  COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium'), '') ||$o$;
  v_rep := $n$                WHEN 'corrected' THEN concat_ws(', ',
                  CASE WHEN i.policy -> 'was_issued_date' IS DISTINCT FROM i.policy -> 'issued_date'
                       THEN 'issued date ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'was_issued_date')
                            || ' → ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') END,
                  CASE WHEN (i.policy ->> 'was_issued_premium')::numeric IS DISTINCT FROM (i.policy ->> 'issued_premium')::numeric
                       THEN 'issued premium ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'was_issued_premium')
                            || ' → ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium') END) ||
                  CASE WHEN (i.policy ->> 'difference') IS NULL THEN ''
                       WHEN (i.policy ->> 'difference')::numeric = 0 THEN ', same as submitted'
                       WHEN (i.policy ->> 'difference')::numeric > 0 THEN ', ' ||
                         public.change_value_text(p_agency_id, 'premium', i.policy -> 'difference') || ' more than submitted'
                       ELSE ', ' || public.change_value_text(p_agency_id, 'premium', to_jsonb(-(i.policy ->> 'difference')::numeric)) || ' less than submitted'
                  END
                ELSE 'issued ' || public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'issued_date') ||
                  COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'issued_premium'), ', no issued premium yet') ||$n$;
  IF position(v_old IN v_def) = 0 THEN RAISE EXCEPTION 'issue line block not found; not patching blind'; END IF;
  v_new := replace(v_def, v_old, v_rep);
  -- the old "(was ...)" tail on corrections is now said in full above
  v_old := $o$                  CASE WHEN i.what = 'corrected' THEN ' (was ' ||
                    public.change_value_text(p_agency_id, 'issued_date', i.policy -> 'was_issued_date') ||
                    COALESCE(' at ' || public.change_value_text(p_agency_id, 'issued_premium', i.policy -> 'was_issued_premium'), '') || ')'
                  ELSE '' END$o$;
  IF position(v_old IN v_new) = 0 THEN RAISE EXCEPTION 'correction tail not found; not patching blind'; END IF;
  v_new := replace(v_new, v_old, $n$                  ''$n$);
  EXECUTE v_new;
END $mig$;
