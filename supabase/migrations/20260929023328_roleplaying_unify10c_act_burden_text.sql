-- roleplaying_unify10c_act_burden_text
-- The fight log names the burden when Prayer or Bible Study face it: "Zaboo rolls Prayer against 5 + 3 burden.
-- Rolled 80, needs 58." instead of "against 5 ... needs 58" with the 58 unexplained. Anchored patch on rpg_act,
-- which was last changed by anchors (unify10a); the md5 of its body is checked first.
DO $do$
DECLARE v_src text; v_n int; v_md5 text;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_act';
  IF v_src LIKE '%'' burden'' ELSE '''' END%' THEN RETURN; END IF;
  v_md5 := md5(v_src);
  IF v_md5 <> '01c39536fcf63a6e7263e8825a5cd16d' THEN RAISE EXCEPTION 'rpg_act body drifted (md5 %), patch by hand', v_md5; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, ''' rolls '' \|\| v_label \|\| '' against '' \|\| trim_scale\(v_diff\)', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor found % times', v_n; END IF;
  v_src := replace(v_src, ''' rolls '' || v_label || '' against '' || trim_scale(v_diff)',
                          ''' rolls '' || v_label || '' against '' || trim_scale(v_diff) || CASE WHEN v_discipline AND (v_first->>''difficulty'')::numeric > v_diff THEN '' + '' || trim_scale((v_first->>''difficulty'')::numeric - v_diff) || '' burden'' ELSE '''' END');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;
