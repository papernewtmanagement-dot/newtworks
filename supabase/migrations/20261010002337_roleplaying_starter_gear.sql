-- Starter gear by rule (Peter's list 2026-10-09): a new player character begins with a starter kit.

CREATE OR REPLACE FUNCTION public.rpg_starter_gear(p_character_id uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- The starter kit a player character begins with (starter gear by rule, Peter's list 2026-10-09), the one home of it:
-- the weapon they are best with (the highest of their weapon skills on their own sheet, rpg_sheet_values; a tie goes
-- to one that leaves a hand free, rpg_item_slot, then the card order; never a lance, which needs a horse), a shield
-- when that weapon leaves a hand free, a cloak, and a torch with 5 uses packed away (not in hand). Each is rolled from
-- its card like any item (rpg_item_add). Returns what was given, in words. Internal: rpg_new_character (a new player
-- character from the Human card) and rpg_give_starter_gear (the game master, for a character made before).
DECLARE v_vals jsonb; v_w record; v_names text[] := '{}'; v_torch uuid;
BEGIN
  IF public.rpg_is_object_card((SELECT template_id FROM public.rpg_characters WHERE id = p_character_id)) THEN RETURN NULL; END IF;
  v_vals := public.rpg_sheet_values(p_character_id) -> 'values';
  SELECT k.id, k.name, public.rpg_item_slot(k.key, k.name, false) AS slot INTO v_w
    FROM public.rpg_creatures k
   WHERE k.is_active AND k.weapon_key IS NOT NULL AND k.key <> 'lance' AND public.rpg_is_object_card(k.id)
   ORDER BY coalesce((v_vals ->> k.weapon_key)::numeric, 0) DESC, (public.rpg_item_slot(k.key, k.name, false) = 'hand') DESC, k.sort_order, k.name
   LIMIT 1;
  IF v_w.id IS NOT NULL THEN
    PERFORM public.rpg_item_add(p_character_id, v_w.id, v_w.name, NULL, 0, NULL);
    v_names := v_names || v_w.name;
  END IF;
  IF v_w.slot = 'hand' THEN
    PERFORM public.rpg_item_add(p_character_id, k.id, k.name, NULL, 0, NULL) FROM public.rpg_creatures k WHERE k.key = 'shield' AND k.is_active;
    v_names := v_names || 'Shield'::text;
  END IF;
  PERFORM public.rpg_item_add(p_character_id, k.id, k.name, NULL, 0, NULL) FROM public.rpg_creatures k WHERE k.key = 'cloak' AND k.is_active;
  v_names := v_names || 'Cloak'::text;
  SELECT public.rpg_item_add(p_character_id, k.id, k.name, NULL, 0, 5) INTO v_torch FROM public.rpg_creatures k WHERE k.key = 'torch' AND k.is_active;
  UPDATE public.rpg_items SET equipped = false WHERE id = v_torch;
  v_names := v_names || 'Torch (5 uses, packed)'::text;
  RETURN 'Starter gear: ' || array_to_string(v_names, ', ') || '.';
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_starter_gear(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_starter_gear(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_give_starter_gear(p_character_id uuid)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- The game master gives a character made before starter gear by rule its starter kit (rpg_starter_gear). Parents only.
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master gives starter gear'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) THEN RAISE EXCEPTION 'character not found'; END IF;
  RETURN public.rpg_starter_gear(p_character_id);
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_give_starter_gear(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_give_starter_gear(uuid) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.rpg_new_character(p_name text, p_kid_id uuid DEFAULT NULL::uuid, p_is_npc boolean DEFAULT false, p_card uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Makes a character from a card, named by its row id (none = the Human card). Its inputs come from
-- rpg_roll_inputs(card): a Human rolls every trait d100 ÷ 10, rounded up (a 47 makes 5); another card rolls with its
-- own dividers and set numbers, then its experience is spent by rpg_apply_experience (a Thornfield Boar rolls
-- Toughness d100 ÷ 10, so a 47 makes 5, and its card's growth takes that to 16).
-- Anyone may make a Human (the players' own card). Players may use another card once it has been shown to them;
-- the game master may use any card on the list.
DECLARE
  v_id      uuid;
  v_n       integer;
  v_card    uuid;
  v_key     text;
  v_active  boolean;
  v_shown   boolean;
  v_palette text[] := ARRAY['#737A59','#A88B5F','#5E7A77','#6E5B7A','#A87A75','#255C99','#2E8B57','#D4A017'];
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT id, key, is_active, shown_to_players INTO v_card, v_key, v_active, v_shown
    FROM public.rpg_creatures
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND CASE WHEN p_card IS NULL THEN key = 'human' ELSE id = p_card END;
  IF v_card IS NULL OR NOT v_active THEN RAISE EXCEPTION 'that card is not on the list'; END IF;
  -- an item's card (under Object) is everyone's, like Human: nobody has to be shown a Dagger
  IF v_key <> 'human' AND NOT v_shown AND NOT public.family_is_parent() AND NOT public.rpg_is_object_card(v_card) THEN
    RAISE EXCEPTION 'that card has not been shown to players';
  END IF;
  SELECT count(*) INTO v_n FROM public.rpg_characters WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  INSERT INTO public.rpg_characters (name, kid_id, is_npc, template_id, inputs, color)
  VALUES (btrim(p_name), p_kid_id, coalesce(p_is_npc, false), v_card, public.rpg_roll_inputs(v_card), v_palette[(v_n % 8) + 1])
  RETURNING id INTO v_id;
  PERFORM public.rpg_apply_experience(v_id, v_card);
  -- (starter gear by rule) a new player character from the Human card begins with its starter kit (rpg_starter_gear)
  IF v_key = 'human' AND NOT coalesce(p_is_npc, false) THEN PERFORM public.rpg_starter_gear(v_id); END IF;
  RETURN v_id;
END;
$function$
;
UPDATE public.rpg_rules SET body = body || $a$
A new player character begins with a starter kit: the weapon they are best with (the highest of their weapon skills; a tie goes to one that leaves a hand free; never a lance, which needs a horse), a shield when that weapon leaves a hand free, a cloak, and a torch with 5 uses, packed away. Each is rolled from its card like any item. The game master can give the same kit to a character made before.
*Karen's best weapons are War Hammer 9 and Battle Axe 9. The war hammer leaves a hand free, so she would start with a war hammer and a shield, a cloak, and a torch.*$a$, updated_at = now() WHERE key = 'items' AND agency_id = '126794dd-25ff-47d2-a436-724499733365' AND position('starter kit' in body) = 0;
-- (one quote mark to balance the text above for the SQL tool) '

