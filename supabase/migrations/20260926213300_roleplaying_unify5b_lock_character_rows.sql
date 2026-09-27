-- Step 3 of Peter's list: the kids' login can no longer read or change character rows directly. Everything goes
-- through functions, and those refuse a creature made for a fight to a player, unless a fight move or the rules
-- engine is the one reaching it.

CREATE OR REPLACE FUNCTION public.rpg_can_see_character(p_character_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether the one asking may read or change this character through a function. A parent may reach any. A player
-- may reach any character except a creature made for a fight (session_id set), unless a fight move (rpg.move, set
-- by rpg_act and rpg_act_extra) or the rules engine (rpg.engine, set by the turn functions) is doing the reaching;
-- both flags last only for that one call. Karen: true for the kids. A fight's Bramblemaw: false for the kids.
SELECT public.family_is_parent()
    OR current_setting('rpg.engine', true) = 'on'
    OR current_setting('rpg.move', true) = 'on'
    OR NOT EXISTS (SELECT 1 FROM public.rpg_characters c WHERE c.id = p_character_id AND c.session_id IS NOT NULL);
$function$;
REVOKE ALL ON FUNCTION public.rpg_can_see_character(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_can_see_character(uuid) TO service_role;

-- Guards and flags, patched into the long functions. Each anchor must be found exactly once.
DO $patch$
DECLARE
  f text[] := ARRAY['public.rpg_sheet', 'public.rpg_roll', 'public.rpg_act', 'public.rpg_act_extra'];
  a text[] := ARRAY[
    E'  IF NOT FOUND THEN RAISE EXCEPTION ''character not found''; END IF;\n  v_diff := coalesce(p_difficulty',
    E'  IF p_character_id IS NULL THEN RAISE EXCEPTION ''every roll needs a sheet''; END IF;\n',
    E'  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION ''not allowed''; END IF;\n  SELECT * INTO v_actor',
    E'  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION ''not allowed''; END IF;\n  SELECT * INTO v_ev'];
  b text[] := ARRAY[
    E'  IF NOT FOUND OR NOT public.rpg_can_see_character(p_character_id) THEN RAISE EXCEPTION ''character not found''; END IF;\n  v_diff := coalesce(p_difficulty',
    E'  IF p_character_id IS NULL THEN RAISE EXCEPTION ''every roll needs a sheet''; END IF;\n  IF NOT public.rpg_can_see_character(p_character_id) THEN RAISE EXCEPTION ''character not found''; END IF;\n',
    E'  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION ''not allowed''; END IF;\n  PERFORM set_config(''rpg.move'', ''on'', true);\n  SELECT * INTO v_actor',
    E'  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION ''not allowed''; END IF;\n  PERFORM set_config(''rpg.move'', ''on'', true);\n  SELECT * INTO v_ev'];
  i integer; c integer; d text;
BEGIN
  FOR i IN 1..4 LOOP
    d := pg_get_functiondef(f[i]::regproc);
    c := (length(d) - length(replace(d, a[i], ''))) / length(a[i]);
    IF c <> 1 THEN RAISE EXCEPTION '% anchor found % times', f[i], c; END IF;
    EXECUTE replace(d, a[i], b[i]);
  END LOOP;
END
$patch$;

CREATE OR REPLACE FUNCTION public.rpg_adjust_vitality(p_character_id uuid, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Hurt (+) or heal (−) a character by hand from the sheet page, or through a fight (rpg_session_adjust_vitality).
-- Damage never goes below 0. Karen with 10 damage, healed 15 → 0 damage. Returns the sheet.
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT public.rpg_can_see_character(p_character_id) THEN RAISE EXCEPTION 'character not found'; END IF;
  UPDATE public.rpg_characters SET vitality_damage = greatest(vitality_damage + coalesce(p_delta, 0), 0) WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_adjust_vitality(p_participant_id uuid, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Damage (+) or healing (−) for anyone in a fight, carried on their character through rpg_adjust_vitality. Damage
-- stops at 0 left, healing stops at full. Karen 41, hit for 94 → 0 left, down. A Bramblemaw 149, hit for 30 → 119.
-- Only the game master changes it by hand; a player's attack changes it through rpg_act (rpg.move).
DECLARE v_p record; v_v jsonb; v_delta integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT (public.family_is_parent() OR current_setting('rpg.engine', true) = 'on' OR current_setting('rpg.move', true) = 'on') THEN
    RAISE EXCEPTION 'only the game master changes vitality in a fight';
  END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  v_v := public.rpg_participant_vitality(p_participant_id);
  v_delta := CASE WHEN coalesce(p_delta, 0) > 0 THEN least(p_delta, (v_v->>'left')::integer)
                  ELSE greatest(coalesce(p_delta, 0), -(v_v->>'damage')::integer) END;
  IF v_delta <> 0 THEN PERFORM public.rpg_adjust_vitality(v_p.character_id, v_delta); END IF;
  RETURN public.rpg_participant_vitality(p_participant_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_reroll_character(p_character_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The character made again from its own card: a Human rolls every trait again; a card's set numbers come back the
-- same; a card's experience is spent again from the new roll. A player may re-roll only a character that has not
-- played yet.
DECLARE
  v_card text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) OR NOT public.rpg_can_see_character(p_character_id) THEN
    RAISE EXCEPTION 'character not found';
  END IF;
  IF NOT public.family_is_parent() AND EXISTS (SELECT 1 FROM public.rpg_rolls WHERE character_id = p_character_id) THEN
    RAISE EXCEPTION 'this character has already played; ask a parent to re-roll';
  END IF;
  UPDATE public.rpg_characters SET inputs = public.rpg_roll_inputs(template_key) WHERE id = p_character_id
  RETURNING template_key INTO v_card;
  PERFORM public.rpg_apply_experience(p_character_id, v_card);
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_recent_rolls(p_character_id uuid, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A character's latest rolls, newest first, for the sheet page. Empty for a character the asker cannot reach.
SELECT public.require_login('family');
  SELECT coalesce(jsonb_agg(jsonb_build_object('roll_id', r.id, 'stat_key', r.stat_key, 'stat_name', d.name, 'skill', r.skill,
           'difficulty', r.difficulty, 'needed', r.needed, 'critical', r.critical_at, 'roll', r.roll, 'result', r.result,
           'points', round(r.points_awarded, 1), 'level_before', r.level_before, 'level_after', r.level_after,
           'extra_pending', r.extra_pending, 'parent_roll_id', r.parent_roll_id, 'label', r.label, 'created_at', r.created_at)
           ORDER BY r.created_at DESC), '[]'::jsonb)
  FROM (SELECT * FROM public.rpg_rolls WHERE character_id = p_character_id AND (SELECT public.rpg_can_play())
          AND public.rpg_can_see_character(p_character_id)
        ORDER BY created_at DESC LIMIT greatest(coalesce(p_limit, 20), 1)) r
  LEFT JOIN public.rpg_stat_definitions d ON d.key = r.stat_key AND d.agency_id = r.agency_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_character_update(p_character_id uuid, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A character's own details and purse, changed from the sheet page: name, kid_id, is_npc, color, notes, and the
-- coins platinum, gold, silver, copper (whole numbers, 0 or more). Nothing else on the row changes here; the
-- numbers on a sheet change only by the rules. {"gold": 12} gives Karen 12 gold. Returns the sheet.
DECLARE v_bad text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) OR NOT public.rpg_can_see_character(p_character_id) THEN
    RAISE EXCEPTION 'character not found';
  END IF;
  IF jsonb_typeof(p_patch) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'nothing to change'; END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(p_patch) k
   WHERE k NOT IN ('name', 'kid_id', 'is_npc', 'color', 'notes', 'platinum', 'gold', 'silver', 'copper') LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION '% cannot be changed here', v_bad; END IF;
  IF p_patch ? 'name' AND coalesce(btrim(p_patch->>'name'), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT k INTO v_bad FROM jsonb_object_keys(p_patch) k
   WHERE k IN ('platinum', 'gold', 'silver', 'copper') AND coalesce(p_patch->>k, '') !~ '^[0-9]+$' LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION '% must be a whole number, 0 or more', v_bad; END IF;
  UPDATE public.rpg_characters SET
    name     = CASE WHEN p_patch ? 'name' THEN btrim(p_patch->>'name') ELSE name END,
    kid_id   = CASE WHEN p_patch ? 'kid_id' THEN nullif(p_patch->>'kid_id', '')::uuid ELSE kid_id END,
    is_npc   = CASE WHEN p_patch ? 'is_npc' THEN coalesce((p_patch->>'is_npc')::boolean, false) ELSE is_npc END,
    color    = CASE WHEN p_patch ? 'color' THEN coalesce(nullif(p_patch->>'color', ''), color) ELSE color END,
    notes    = CASE WHEN p_patch ? 'notes' THEN nullif(p_patch->>'notes', '') ELSE notes END,
    platinum = CASE WHEN p_patch ? 'platinum' THEN (p_patch->>'platinum')::integer ELSE platinum END,
    gold     = CASE WHEN p_patch ? 'gold' THEN (p_patch->>'gold')::integer ELSE gold END,
    silver   = CASE WHEN p_patch ? 'silver' THEN (p_patch->>'silver')::integer ELSE silver END,
    copper   = CASE WHEN p_patch ? 'copper' THEN (p_patch->>'copper')::integer ELSE copper END
  WHERE id = p_character_id;
  RETURN public.rpg_sheet(p_character_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_item_add(p_character_id uuid, p_name text, p_stat_key text DEFAULT NULL::text, p_bonus integer DEFAULT 0, p_uses_left integer DEFAULT NULL::integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds an item to a character from the sheet page: a name, the stat it adds to and by how much, and how many uses
-- it has (blank = it never runs out). Hairband of Kindness, Kindness +1. It goes to the end of their list, equipped.
DECLARE v_id uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) OR NOT public.rpg_can_see_character(p_character_id) THEN
    RAISE EXCEPTION 'character not found';
  END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  IF nullif(p_stat_key, '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions WHERE key = p_stat_key) THEN
    RAISE EXCEPTION 'unknown stat %', p_stat_key;
  END IF;
  IF p_uses_left IS NOT NULL AND p_uses_left < 0 THEN RAISE EXCEPTION 'uses cannot be negative'; END IF;
  INSERT INTO public.rpg_items (agency_id, character_id, name, stat_key, bonus, uses_left, sort_order)
  SELECT c.agency_id, c.id, btrim(p_name), nullif(p_stat_key, ''), coalesce(p_bonus, 0), p_uses_left,
         (SELECT count(*) FROM public.rpg_items i WHERE i.character_id = c.id) + 1
    FROM public.rpg_characters c WHERE c.id = p_character_id
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_item_set_equipped(p_item_id uuid, p_equipped boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Equips or puts away one item. Only an equipped item adds its bonus or blocks a blow.
DECLARE v_char uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT character_id INTO v_char FROM public.rpg_items WHERE id = p_item_id;
  IF v_char IS NULL OR NOT public.rpg_can_see_character(v_char) THEN RAISE EXCEPTION 'item not found'; END IF;
  UPDATE public.rpg_items SET equipped = coalesce(p_equipped, false) WHERE id = p_item_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_item_use(p_item_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Uses up one use of an item that has uses (Oil of Righteousness, 5 uses → 4). Returns the uses left.
DECLARE v_char uuid; v_left integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT character_id INTO v_char FROM public.rpg_items WHERE id = p_item_id;
  IF v_char IS NULL OR NOT public.rpg_can_see_character(v_char) THEN RAISE EXCEPTION 'item not found'; END IF;
  UPDATE public.rpg_items SET uses_left = uses_left - 1 WHERE id = p_item_id AND uses_left > 0 RETURNING uses_left INTO v_left;
  IF v_left IS NULL THEN RAISE EXCEPTION 'that item has no uses left'; END IF;
  RETURN v_left;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_item_delete(p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Removes one item from a character for good.
DECLARE v_char uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT character_id INTO v_char FROM public.rpg_items WHERE id = p_item_id;
  IF v_char IS NULL OR NOT public.rpg_can_see_character(v_char) THEN RAISE EXCEPTION 'item not found'; END IF;
  DELETE FROM public.rpg_items WHERE id = p_item_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpg_character_update(uuid, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpg_item_add(uuid, text, text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpg_item_set_equipped(uuid, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpg_item_use(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpg_item_delete(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_character_update(uuid, jsonb), public.rpg_item_add(uuid, text, text, integer, integer),
  public.rpg_item_set_equipped(uuid, boolean), public.rpg_item_use(uuid), public.rpg_item_delete(uuid) TO authenticated, service_role;

-- The fight's inner workings are called only by the fight functions, never straight from a login.
REVOKE EXECUTE ON FUNCTION public.rpg_action_ready(uuid, uuid), public.rpg_action_score(uuid, uuid, uuid),
  public.rpg_best_aim(uuid, uuid, uuid[]), public.rpg_damage(uuid), public.rpg_item_damage(uuid, integer),
  public.rpg_participant_apply_effect(uuid, jsonb, text, integer), public.rpg_participant_burden(uuid, text),
  public.rpg_participant_can_act(uuid), public.rpg_participant_energy(uuid), public.rpg_participant_value(uuid, text),
  public.rpg_participant_values(uuid, text[]), public.rpg_participant_vitality(uuid) FROM PUBLIC, anon, authenticated;

-- Character rows: parents only. The kids' login reaches them through the functions above.
DROP POLICY IF EXISTS rpg_characters_play_all ON public.rpg_characters;
DROP POLICY IF EXISTS rpg_characters_parents_all ON public.rpg_characters;
CREATE POLICY rpg_characters_parents_all ON public.rpg_characters FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_character_skills_play_all ON public.rpg_character_skills;
DROP POLICY IF EXISTS rpg_character_skills_parents_all ON public.rpg_character_skills;
CREATE POLICY rpg_character_skills_parents_all ON public.rpg_character_skills FOR ALL TO authenticated
  USING ((SELECT public.family_is_parent())) WITH CHECK ((SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_items_play_all ON public.rpg_items;
DROP POLICY IF EXISTS rpg_items_parents_all ON public.rpg_items;
CREATE POLICY rpg_items_parents_all ON public.rpg_items FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_rolls_play_all ON public.rpg_rolls;
DROP POLICY IF EXISTS rpg_rolls_parents_all ON public.rpg_rolls;
CREATE POLICY rpg_rolls_parents_all ON public.rpg_rolls FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));

