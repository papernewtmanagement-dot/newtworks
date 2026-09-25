-- Roleplaying step 5d: in a multi-attack action (Multiattack: 2 × Claw, 1 × Bite) a later attack aimed at someone
-- who went down earlier in the same action moves to a random target still standing, or the action stops when no
-- one is. In-place edit of rpg_act at one anchor.
DO $do$
DECLARE v_src text; v_anchor text := 'v_tid := (v_step->>''t'')::uuid;';
BEGIN
  v_src := pg_get_functiondef('public.rpg_act'::regproc);
  IF position('still standing' IN v_src) > 0 THEN RETURN; END IF;
  IF (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor) <> 1 THEN RAISE EXCEPTION 'rpg_act anchor not unique'; END IF;
  EXECUTE replace(v_src, v_anchor, v_anchor || E'\n'
    || '      -- a later attack of the same action at someone already down goes to a target still standing, or stops' || E'\n'
    || '      IF v_kind = ''action'' AND jsonb_array_length(v_plan) > 1 AND (public.rpg_participant_vitality(v_tid)->>''left'')::integer <= 0 THEN' || E'\n'
    || '        SELECT p.id INTO v_tid FROM public.rpg_session_participants p' || E'\n'
    || '         WHERE p.id = ANY (v_targets) AND (public.rpg_participant_vitality(p.id)->>''left'')::integer > 0 ORDER BY random() LIMIT 1;' || E'\n'
    || '        EXIT WHEN v_tid IS NULL;' || E'\n'
    || '      END IF;');
END $do$;
DO $do$
BEGIN
  IF position('still standing' IN pg_get_functiondef('public.rpg_act'::regproc)) = 0 THEN RAISE EXCEPTION 'edit did not land'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_act(uuid, uuid[], text, uuid, text, numeric, integer, text)', 'EXECUTE') THEN RAISE EXCEPTION 'rpg_act lost its grant'; END IF;
END $do$;
