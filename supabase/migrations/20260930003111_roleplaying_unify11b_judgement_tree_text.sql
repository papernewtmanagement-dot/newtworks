-- roleplaying_unify11b_judgement_tree_text
-- Defect in unify11a, found in the rolled-back Torch test: rpg_judgement read the target record in its message even
-- when the harm was a tree (no target), and plpgsql refuses an unassigned record ("record v_t is not assigned yet").
-- The target's name now lives in a text variable that stays null for a tree. Whole body: the function is mine and
-- was not anchor-patched.
CREATE OR REPLACE FUNCTION public.rpg_judgement(p_actor_id uuid, p_target_id uuid, p_harmed_tree boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- Judging Gaze's watch. An effect on the actor that carries "on_harm" (Judged) turns into that block (Condemned:
-- exposed to its source, clear 'fight' so nothing takes it off) when the actor harms an innocent: a target on the good
-- side (rpg_sheet_values side) who has not attacked anyone in this fight (has_attacked), or forest ground set alight
-- (a tree). Returns the log tail, or null. Internal: rpg_act (every hostile roll) and rpg_act_square (a Torch).
DECLARE v_a record; v_t record; v_tname text; v_e jsonb; v_new jsonb; v_round integer; v_innocent boolean := coalesce(p_harmed_tree, false);
BEGIN
  SELECT * INTO v_a FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT e INTO v_e FROM jsonb_array_elements(v_a.effects) e WHERE jsonb_typeof(e->'on_harm') = 'object' LIMIT 1;
  IF v_e IS NULL THEN RETURN NULL; END IF;
  IF NOT v_innocent AND p_target_id IS NOT NULL THEN
    SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = p_target_id;
    v_innocent := FOUND AND v_t.character_id IS NOT NULL AND NOT v_t.has_attacked AND (public.rpg_sheet_values(v_t.character_id)->>'side') = 'good';
    IF v_innocent THEN v_tname := v_t.name; END IF;
  END IF;
  IF NOT v_innocent THEN RETURN NULL; END IF;
  SELECT round INTO v_round FROM public.rpg_sessions WHERE id = v_a.session_id;
  v_new := (v_e->'on_harm') || jsonb_build_object('source', v_e->>'source', 'source_id', v_e->>'source_id', 'round', v_round);
  UPDATE public.rpg_session_participants p
     SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE z->>'name' NOT IN (v_e->>'name', v_new->>'name'))
                   || jsonb_build_array(v_new)
   WHERE p.id = p_actor_id;
  RETURN ' ' || v_a.name || CASE WHEN v_tname IS NULL THEN ' harms the forest' ELSE ' strikes at an innocent, ' || v_tname || ',' END
         || ' under the ' || coalesce(v_e->>'source', 'gaze') || ' and is ' || (v_new->>'name') || ' for the rest of the fight.';
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_judgement(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_judgement(uuid, uuid, boolean) TO service_role;

