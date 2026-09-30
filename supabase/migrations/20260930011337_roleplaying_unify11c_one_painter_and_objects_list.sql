-- roleplaying_unify11c_one_painter_and_objects_list
-- Peter 2026-09-30 "1A": the board painter is one function. rpg_set_square(session, x, y, penalty) and rpg_set_ground
-- (forest, fire) are DROPPED (Peter's yes) and one rpg_set_square(session, x, y, penalty, forest, burning) replaces
-- them, still through the one writer of a square (rpg_square_set). Also for the Objects tab: rpg_item_row(item) is
-- the one row of an item (rpg_sheet's items list reads it now), and rpg_object_list() gives the game master every
-- object card with how one is made, its actions, and every item made from it.

-- 1. One painter. Nothing in the database calls the two old functions; the page did, and moves with this change.
DO $do$
DECLARE v_callers text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_callers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname NOT IN ('rpg_set_square', 'rpg_set_ground')
     AND (pg_get_functiondef(p.oid) LIKE '%rpg_set_square(%' OR pg_get_functiondef(p.oid) LIKE '%rpg_set_ground(%');
  IF v_callers IS NOT NULL THEN RAISE EXCEPTION 'rpg_set_square / rpg_set_ground still called by: %', v_callers; END IF;
END $do$;

DROP FUNCTION IF EXISTS public.rpg_set_square(uuid, integer, integer, integer);
DROP FUNCTION IF EXISTS public.rpg_set_ground(uuid, integer, integer, boolean, boolean);

CREATE OR REPLACE FUNCTION public.rpg_set_square(p_session_id uuid, p_x integer, p_y integer, p_penalty integer DEFAULT NULL::integer, p_forest boolean DEFAULT NULL::boolean, p_burning boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- The game master paints one square, each part given replacing that part: the movement penalty 0 to 9 (briars at 2:
-- stepping in costs 3), forest on or off, fire on (the square burns for burn_rounds rounds and burns a creature
-- waiting there under a rule fire ends: rpg_ignite, with a log line) or out. All of it goes through the one writer of
-- a square (rpg_square_set).
DECLARE v_s record; v_text text := '';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master shapes the ground'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_penalty IS NOT NULL AND p_penalty NOT BETWEEN 0 AND 9 THEN RAISE EXCEPTION 'a movement penalty is 0 to 9'; END IF;
  IF p_penalty IS NOT NULL OR p_forest IS NOT NULL THEN PERFORM public.rpg_square_set(p_session_id, p_x, p_y, p_penalty, p_forest, NULL); END IF;
  IF p_burning IS TRUE THEN
    v_text := public.rpg_ignite(p_session_id, p_x, p_y);
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'effect', 'info', 'The game master sets ' || public.rpg_square_name(p_x, p_y) || ' alight.' || v_text);
  ELSIF p_burning IS FALSE THEN
    PERFORM public.rpg_square_set(p_session_id, p_x, p_y, NULL, NULL, 0);
  END IF;
  RETURN jsonb_build_object('ok', true, 'text', v_text);
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_set_square(uuid, integer, integer, integer, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_set_square(uuid, integer, integer, integer, boolean, boolean) TO authenticated, service_role;

-- 2. One row of an item, for the sheet and the Objects tab alike.
CREATE OR REPLACE FUNCTION public.rpg_item_row(p_item_id uuid)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- One item as the pages show it: what the player gave it (name, the stat it adds to and by how much, uses, equipped,
-- notes, held or worn) and what its own object says (rpg_object_state: the card, the skill that swings it, life and
-- life left, broken, the Integrity it turns aside, its Weight, its Strength, Agility and Toughness), plus who holds
-- it. The one writer of this row: rpg_sheet's items list and rpg_object_list read it. Internal.
SELECT jsonb_build_object('id', i.id, 'name', i.name, 'stat_key', i.stat_key, 'stat_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = i.stat_key),
         'bonus', i.bonus, 'uses_left', i.uses_left, 'equipped', i.equipped, 'notes', i.notes, 'worn', i.worn, 'object_id', i.object_id,
         'owner_id', i.character_id, 'owner', (SELECT c.name FROM public.rpg_characters c WHERE c.id = i.character_id),
         'card_id', s->>'card_id', 'card', s->>'card', 'weapon_key', s->>'weapon_key', 'weapon_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = s->>'weapon_key'),
         'life', s->'pv', 'life_left', s->'left', 'broken', s->'broken', 'integrity', s->'ig', 'weight', s->'wt',
         'strength', s->'st', 'agility', s->'ag', 'toughness', s->'to')
  FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
 WHERE i.id = p_item_id;
$function$;
REVOKE ALL ON FUNCTION public.rpg_item_row(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_item_row(uuid) TO service_role;

-- 3. The Objects tab.
CREATE OR REPLACE FUNCTION public.rpg_object_list()
 RETURNS jsonb
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- The Objects tab, game master only: every object card (the cards under Object: Dagger, Sword, Cloak, Torch, ...)
-- with how one is made from it and the actions it carries (both from rpg_creature_card, as the creature cards show
-- them), and every item made from it (rpg_item_row: who holds it, life left, uses). Cards in their sort order, items
-- by owner then name.
DECLARE v_out jsonb := '[]'::jsonb; v_c record; v_card jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master sees the objects list'; END IF;
  FOR v_c IN SELECT c.* FROM public.rpg_creatures c
              WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.key <> 'object' AND public.rpg_is_object_card(c.id)
              ORDER BY c.sort_order, c.name LOOP
    v_card := public.rpg_creature_card(v_c.id);
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'id', v_c.id, 'key', v_c.key, 'name', v_c.name, 'color', v_c.color, 'worn', v_c.worn,
      'weapon_key', v_c.weapon_key, 'weapon_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = v_c.weapon_key),
      'template', v_card->'template', 'actions', v_card->'actions',
      'items', (SELECT coalesce(jsonb_agg(public.rpg_item_row(i.id) ORDER BY o.name, i.name), '[]'::jsonb)
                  FROM public.rpg_items i JOIN public.rpg_characters b ON b.id = i.object_id JOIN public.rpg_characters o ON o.id = i.character_id
                 WHERE b.template_id = v_c.id)));
  END LOOP;
  RETURN v_out;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_object_list() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_object_list() TO authenticated, service_role;

-- 4. Anchored patches.
CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text; v_src text;
BEGIN
  -- rpg_sheet: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src NOT LIKE '%rpg_item_row%' THEN
    IF md5(v_src) <> '7fc9ca38b6ffca3d01110e43c43240b9' THEN RAISE EXCEPTION 'rpg_sheet body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_sheet(uuid,numeric)'::regprocedure);
    v := pg_temp.rep(v, $a$  SELECT coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'stat_key', i.stat_key,
           'stat_name', v_names->>i.stat_key, 'bonus', i.bonus, 'uses_left', i.uses_left, 'equipped', i.equipped, 'notes', i.notes,
           'worn', i.worn, 'object_id', i.object_id, 'card', s->>'card', 'weapon_key', s->>'weapon_key', 'weapon_name', v_names->>(s->>'weapon_key'),
           'life', s->'pv', 'life_left', s->'left', 'broken', s->'broken', 'integrity', s->'ig', 'weight', s->'wt',
           'strength', s->'st', 'agility', s->'ag', 'toughness', s->'to')
           ORDER BY i.sort_order, i.created_at), '[]'::jsonb)
    INTO v_items FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s WHERE i.character_id = p_character_id;$a$,
$b$  -- each item's row comes from rpg_item_row, the one writer of it (the Objects tab reads the same rows)
  SELECT coalesce(jsonb_agg(public.rpg_item_row(i.id) ORDER BY i.sort_order, i.created_at), '[]'::jsonb)
    INTO v_items FROM public.rpg_items i WHERE i.character_id = p_character_id;$b$, 'sheet items');
    EXECUTE v;
  END IF;

  -- rpg_square_set: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_square_set';
  IF v_src NOT LIKE '%rpg_set_square (the game master painting)%' THEN
    IF md5(v_src) <> '8e3be5c6496abbcfabd38d274ec6ad81' THEN RAISE EXCEPTION 'rpg_square_set body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_square_set(uuid,integer,integer,integer,boolean,integer)'::regprocedure);
    v := pg_temp.rep(v, $a$-- left is dropped. Internal: rpg_set_square and rpg_set_ground (the game master painting), rpg_act_square (Briar
-- Shift) and rpg_ignite (fire).$a$,
$b$-- left is dropped. Internal: rpg_set_square (the game master painting), rpg_act_square (Briar Shift) and rpg_ignite
-- (fire).$b$, 'square_set comment');
    EXECUTE v;
  END IF;

  -- rpg_ignite: patched by anchors; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_ignite';
  IF v_src NOT LIKE '%rpg_set_square (fire by hand)%' THEN
    IF md5(v_src) <> '000a24c92e633a32f8581741643665b9' THEN RAISE EXCEPTION 'rpg_ignite body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_ignite(uuid,integer,integer)'::regprocedure);
    v := pg_temp.rep(v, $a$-- (rpg_burn_out: a Sunk Bramblemaw). Returns the log tail. Internal: rpg_act_square (a Torch) and rpg_set_ground.$a$,
$b$-- (rpg_burn_out: a Sunk Bramblemaw). Returns the log tail. Internal: rpg_act_square (a Torch) and rpg_set_square (fire by hand).$b$, 'ignite comment');
    EXECUTE v;
  END IF;

END $do$;

