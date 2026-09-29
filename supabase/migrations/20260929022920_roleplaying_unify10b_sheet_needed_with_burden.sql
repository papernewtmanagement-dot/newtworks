-- roleplaying_unify10b_sheet_needed_with_burden
-- The sheet's "needs" for Prayer and Bible Study includes the spiritual burden, the way rpg_roll charges it
-- (burden 6, Prayer 7 at difficulty 5: the sheet said 42, the roll needed 61). Anchored patch on rpg_sheet, which
-- was last changed by anchors (unify10a); the md5 of its body is checked first so a drifted function is not patched blind.
DO $do$
DECLARE v_src text; v_n int; v_md5 text;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src LIKE '%v_d.spirit_discipline%' THEN RETURN; END IF;
  v_md5 := md5(v_src);
  IF v_md5 <> 'c3cf592a54c4cfb417f284fe2878b473' THEN RAISE EXCEPTION 'rpg_sheet body drifted (md5 %), patch by hand', v_md5; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    v_nc := public\.rpg_needed\(v_v, v_diff\);\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor found % times', v_n; END IF;
  v_src := replace(v_src, E'    v_nc := public.rpg_needed(v_v, v_diff);\n',
                          E'    -- Prayer and Bible Study face the difficulty plus the spiritual burden, as rpg_roll charges it (burden 6: 5 becomes 11)\n    v_nc := public.rpg_needed(v_v, v_diff + CASE WHEN v_d.spirit_discipline THEN coalesce(v_c.spiritual_burden, 0) ELSE 0 END);\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;
