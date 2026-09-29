-- roleplaying_unify9d_items_from_object_cards
-- Sheet redesign, step 4 (Peter 2026-09-28, "defaults" = 5A): every item is a thing made from a card under Object, the
-- way a character is made from the Human card. It has its own Strength, Agility and Toughness (rolled with the card's
-- dividers), so its life is its Physical Vitality (3 × Toughness + 2 × Strength), its Integrity (Toughness ÷ 5) is how
-- much of a blow it turns aside (held: added to Block; worn: absorbed), and its Weight is a fixed stat the card sets.
-- rpg_items keeps the link: the owner, the object, the player's name for it, the stat it adds to and by how much, its
-- uses, held or worn. The six columns the object now carries (weapon_key, block, absorb, weight, integrity,
-- integrity_damage) are dropped (Peter's yes). Broken (life at 0) = no bonus, no block, no absorb until repaired.
-- One home for an object's numbers: rpg_object_state. The card says which skill swings it (weapon_key) and whether it
-- is worn (worn).

-- 1. Object cards carry the kind of thing they make
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS weapon_key text;
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS worn boolean NOT NULL DEFAULT false;
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rpg_creatures_weapon_key_fkey') THEN
    ALTER TABLE public.rpg_creatures ADD CONSTRAINT rpg_creatures_weapon_key_fkey
      FOREIGN KEY (agency_id, weapon_key) REFERENCES public.rpg_stat_definitions(agency_id, key) ON UPDATE CASCADE;
  END IF;
END $do$;

-- 2. Weight: a fixed stat every Object has, set by its card (a sword 3, a shield 6, a trinket 0)
INSERT INTO public.rpg_stat_definitions
  (agency_id, key, name, abbr, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, template_id)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'WT', 'Weight', 'WT', 'physical', 'fixed', false, NULL, 1, 135, false, 2, 4, 'physical', c.id
  FROM public.rpg_creatures c WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'object'
ON CONFLICT (agency_id, key) DO NOTHING;

-- 3. Which cards are object cards, and an object's numbers in one place
CREATE OR REPLACE FUNCTION public.rpg_is_object_card(p_card uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  -- True for the Object card and every card under it (Dagger, Cloak, Trinket): the cards items are made from.
  -- Object cards are not creatures: they stay off the Creatures tab and a fight's Add list, and anyone may make an
  -- item from one. Used by rpg_new_character, rpg_item_add, rpg_character_list, rpg_creature_list, rpg_session_state.
  SELECT p_card IS NOT NULL AND (SELECT c.id FROM public.rpg_creatures c
                                  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.key = 'object')
                                 = ANY (public.rpg_template_chain(p_card));
$fn$;
REVOKE ALL ON FUNCTION public.rpg_is_object_card(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.rpg_object_state(p_object uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  -- An object's numbers, figured from its own sheet (rpg_sheet_values) and its card: life = Physical Vitality
  -- (3 × Toughness + 2 × Strength: Toughness 4 and Strength 3 give 18), what it has left, whether it is broken (life at
  -- 0), its Integrity (Toughness ÷ 5: 4 gives 0, 12 gives 2) which is what it turns aside held or worn, its Weight, and
  -- from the card which skill swings it and whether it is worn. The one place these are read: rpg_act (the weapon, the
  -- block, the absorb), rpg_item_damage, rpg_participant_burden, rpg_sheet_values (a broken item gives no bonus) and
  -- rpg_sheet (the items list). Internal.
  SELECT jsonb_build_object(
    'id', c.id, 'name', c.name, 'card_id', k.id, 'card', k.name, 'weapon_key', k.weapon_key, 'worn', k.worn,
    'pv', coalesce((v ->> 'vitality_max')::numeric, 0), 'damage', c.vitality_damage,
    'left', greatest(coalesce((v ->> 'vitality_max')::numeric, 0) - c.vitality_damage, 0),
    'broken', c.vitality_damage >= coalesce((v ->> 'vitality_max')::numeric, 0),
    'ig', coalesce((v -> 'values' ->> 'IG')::numeric, 0), 'wt', coalesce((v -> 'values' ->> 'WT')::numeric, 0),
    'st', (v -> 'values' ->> 'ST')::numeric, 'ag', (v -> 'values' ->> 'AG')::numeric, 'to', (v -> 'values' ->> 'TO')::numeric)
  FROM public.rpg_characters c
  JOIN public.rpg_creatures k ON k.id = c.template_id
  CROSS JOIN LATERAL public.rpg_sheet_values(c.id) v
  WHERE c.id = p_object;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_object_state(uuid) FROM PUBLIC, anon, authenticated;

-- 4. The item cards, all under Object (Toughness rolls with each kind's divider; Weight set; the rest standard)
INSERT INTO public.rpg_creatures (agency_id, key, name, parent_id, blueprint, weapon_key, worn, shown_to_players, sort_order, color)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, o.id, v.blueprint::jsonb, v.weapon_key, v.worn, false, v.sort_order, '#8A7B6B'
  FROM (VALUES
    ('dagger',        'Dagger',        '{"TO": {"divisor": 10}, "WT": 1}',  'dagger',        false, 1001),
    ('sword',         'Sword',         '{"TO": {"divisor": 5},  "WT": 3}',  'sword',         false, 1002),
    ('hand_axe',      'Hand axe',      '{"TO": {"divisor": 10}, "WT": 2}',  'hand_axe',      false, 1003),
    ('battle_axe',    'Battle axe',    '{"TO": {"divisor": 5},  "WT": 5}',  'battle_axe',    false, 1004),
    ('war_hammer',    'War hammer',    '{"TO": {"divisor": 5},  "WT": 5}',  'war_hammer',    false, 1005),
    ('flail',         'Flail',         '{"TO": {"divisor": 5},  "WT": 4}',  'flail',         false, 1006),
    ('quarterstaff',  'Quarterstaff',  '{"TO": {"divisor": 10}, "WT": 2}',  'quarterstaff',  false, 1007),
    ('spear',         'Spear',         '{"TO": {"divisor": 10}, "WT": 3}',  'spear',         false, 1008),
    ('lance',         'Lance',         '{"TO": {"divisor": 5},  "WT": 6}',  'lance',         false, 1009),
    ('military_fork', 'Military fork', '{"TO": {"divisor": 5},  "WT": 4}',  'military_fork', false, 1010),
    ('crossbow',      'Crossbow',      '{"TO": {"divisor": 10}, "WT": 4}',  'crossbow',      false, 1011),
    ('longbow',       'Longbow',       '{"TO": {"divisor": 10}, "WT": 2}',  'longbow',       false, 1012),
    ('sling',         'Sling',         '{"TO": {"divisor": 20}, "WT": 1}',  'sling',         false, 1013),
    ('shield',        'Shield',        '{"TO": {"divisor": 4},  "WT": 6}',  NULL,            false, 1014),
    ('cloak',         'Cloak',         '{"TO": {"divisor": 20}, "WT": 1}',  NULL,            true,  1015),
    ('armor',         'Armor',         '{"TO": {"divisor": 4},  "WT": 10}', NULL,            true,  1016),
    ('trinket',       'Trinket',       '{"TO": {"divisor": 20}, "WT": 0}',  NULL,            true,  1017),
    ('oil',           'Oil',           '{"TO": {"divisor": 20}, "WT": 0}',  NULL,            true,  1018)
  ) AS v(key, name, blueprint, weapon_key, worn, sort_order)
  JOIN public.rpg_creatures o ON o.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND o.key = 'object'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creatures x WHERE x.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND x.key = v.key);

-- 5. Anyone may make an item from an object card (rpg_new_character, patched on the live body by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_new_character';
  IF v_src LIKE '%rpg_is_object_card%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  IF v_key <> ''human'' AND NOT v_shown AND NOT public\.family_is_parent\(\) THEN\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_new_character anchor found % times', v_n; END IF;
  v_src := replace(v_src, E'  IF v_key <> ''human'' AND NOT v_shown AND NOT public.family_is_parent() THEN\n',
                          E'  -- an item''s card (under Object) is everyone''s, like Human: nobody has to be shown a Dagger\n  IF v_key <> ''human'' AND NOT v_shown AND NOT public.family_is_parent() AND NOT public.rpg_is_object_card(v_card) THEN\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_new_character(p_name text, p_kid_id uuid DEFAULT NULL::uuid, p_is_npc boolean DEFAULT false, p_card uuid DEFAULT NULL::uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 6. Each item gets its object
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS object_id uuid REFERENCES public.rpg_characters(id) ON DELETE CASCADE;
DO $do$
DECLARE v_i record; v_card uuid; v_obj uuid;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
  FOR v_i IN SELECT * FROM public.rpg_items WHERE object_id IS NULL ORDER BY created_at LOOP
    SELECT c.id INTO v_card FROM public.rpg_creatures c
     WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'
       AND c.key = CASE WHEN v_i.weapon_key IS NOT NULL THEN v_i.weapon_key
                        WHEN v_i.name ILIKE '%cloak%' THEN 'cloak'
                        WHEN v_i.name ILIKE '%oil%' OR v_i.uses_left IS NOT NULL THEN 'oil'
                        ELSE 'trinket' END;
    IF v_card IS NULL THEN RAISE EXCEPTION 'no object card for item %', v_i.name; END IF;
    v_obj := public.rpg_new_character(v_i.name, NULL, true, v_card);
    UPDATE public.rpg_characters SET vitality_damage = least(coalesce(v_i.integrity_damage, 0),
             (public.rpg_object_state(v_obj) ->> 'pv')::integer) WHERE id = v_obj;
    UPDATE public.rpg_items SET object_id = v_obj WHERE id = v_i.id;
  END LOOP;
END $do$;
ALTER TABLE public.rpg_items ALTER COLUMN object_id SET NOT NULL;

-- 7. The object now carries what these columns held (Peter's yes, 2026-09-28)
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS weapon_key;
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS block;
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS absorb;
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS weight;
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS integrity;
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS integrity_damage;

-- 8. An item gone means its object gone (a deleted item, or a deleted owner cascading through rpg_items)
CREATE OR REPLACE FUNCTION public.rpg_items_delete_object()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- The object exists only as this item: when the item row goes, so does its rpg_characters row.
BEGIN
  DELETE FROM public.rpg_characters WHERE id = OLD.object_id;
  RETURN OLD;
END;
$fn$;
DROP TRIGGER IF EXISTS rpg_items_delete_object ON public.rpg_items;
CREATE TRIGGER rpg_items_delete_object AFTER DELETE ON public.rpg_items FOR EACH ROW EXECUTE FUNCTION public.rpg_items_delete_object();

-- 9. Adding an item makes its object; the old signature goes (no database caller; the page moves with this step)
DO $do$
DECLARE v_callers text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_callers FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname <> 'rpg_item_add' AND pg_get_functiondef(p.oid) LIKE '%rpg_item_add(%';
  IF v_callers IS NOT NULL THEN RAISE EXCEPTION 'rpg_item_add still called by: %', v_callers; END IF;
END $do$;
DROP FUNCTION IF EXISTS public.rpg_item_add(uuid, text, text, integer, integer);
CREATE OR REPLACE FUNCTION public.rpg_item_add(p_character_id uuid, p_card uuid, p_name text, p_stat_key text DEFAULT NULL::text, p_bonus integer DEFAULT 0, p_uses_left integer DEFAULT NULL::integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Adds an item to a character from the sheet page. Every item is a thing made from an Object card the way a
-- character is made from the Human card (rpg_new_character): it rolls its own Strength, Agility and Toughness, so its
-- life, its Integrity and its Weight come from its own sheet and card. The player gives it a name, the stat it adds to
-- and by how much, and how many uses it has (blank = it never runs out): Hairband of Kindness from the Trinket card,
-- Kindness +1. It goes to the end of their list, equipped, worn or held as its card says.
DECLARE v_id uuid; v_obj uuid; v_worn boolean;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters WHERE id = p_character_id) OR NOT public.rpg_can_see_character(p_character_id) THEN
    RAISE EXCEPTION 'character not found';
  END IF;
  IF public.rpg_is_object_card((SELECT template_id FROM public.rpg_characters WHERE id = p_character_id)) THEN
    RAISE EXCEPTION 'an object cannot carry items';
  END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT worn INTO v_worn FROM public.rpg_creatures WHERE id = p_card AND is_active AND public.rpg_is_object_card(id);
  IF NOT FOUND THEN RAISE EXCEPTION 'choose what kind of thing it is'; END IF;
  IF nullif(p_stat_key, '') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions WHERE key = p_stat_key) THEN
    RAISE EXCEPTION 'unknown stat %', p_stat_key;
  END IF;
  IF p_uses_left IS NOT NULL AND p_uses_left < 0 THEN RAISE EXCEPTION 'uses cannot be negative'; END IF;
  v_obj := public.rpg_new_character(btrim(p_name), NULL, true, p_card);
  INSERT INTO public.rpg_items (agency_id, character_id, object_id, name, stat_key, bonus, uses_left, worn, sort_order)
  SELECT c.agency_id, c.id, v_obj, btrim(p_name), nullif(p_stat_key, ''), coalesce(p_bonus, 0), p_uses_left, v_worn,
         (SELECT count(*) FROM public.rpg_items i WHERE i.character_id = c.id) + 1
    FROM public.rpg_characters c WHERE c.id = p_character_id
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;
GRANT EXECUTE ON FUNCTION public.rpg_item_add(uuid, uuid, text, text, integer, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpg_item_delete(p_item_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- Removes one item from a character for good; its object goes with it (trigger rpg_items_delete_object).
DECLARE v_char uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT character_id INTO v_char FROM public.rpg_items WHERE id = p_item_id;
  IF v_char IS NULL OR NOT public.rpg_can_see_character(v_char) THEN RAISE EXCEPTION 'item not found'; END IF;
  DELETE FROM public.rpg_items WHERE id = p_item_id;
END;
$fn$;

-- 10. Wear lands on the object's life
CREATE OR REPLACE FUNCTION public.rpg_item_damage(p_item_id uuid, p_amount integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
-- An object takes damage like a person does: the blow lands on its object's vitality_damage, capped at its life
-- (Physical Vitality). Returns what is left and whether it broke on this blow. A shield with 18 life that has taken 15
-- and now takes 8 → 0 left, broke. Used by rpg_act (a block, an absorb, a fifth of either for the weapon).
DECLARE v_i record; v_s jsonb; v_before integer; v_left integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_i FROM public.rpg_items WHERE id = p_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'item not found'; END IF;
  v_s := public.rpg_object_state(v_i.object_id);
  v_before := (v_s ->> 'left')::integer;
  UPDATE public.rpg_characters
     SET vitality_damage = least(vitality_damage + greatest(coalesce(p_amount, 0), 0), (v_s ->> 'pv')::integer)
   WHERE id = v_i.object_id
  RETURNING greatest((v_s ->> 'pv')::integer - vitality_damage, 0) INTO v_left;
  RETURN jsonb_build_object('item_id', p_item_id, 'name', v_i.name, 'left', v_left, 'broke', v_left <= 0 AND v_before > 0);
END;
$fn$;

-- 11. Burden reads each object's Weight
CREATE OR REPLACE FUNCTION public.rpg_participant_burden(p_participant_id uuid, p_kind text)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
-- What weighs a character down. Physical: the Weight of every equipped item's object (from its card: a sword 3, a
-- shield 6) past Strength × carry_per_strength (Strength 10 carries 20; 26 carried → burden 6). Spiritual: the
-- character's spiritual burden. Creatures carry none.
SELECT CASE WHEN c.id IS NULL THEN 0
            WHEN p_kind = 'spiritual' THEN c.spiritual_burden
            ELSE greatest(coalesce((SELECT sum((public.rpg_object_state(i.object_id) ->> 'wt')::numeric)
                                      FROM public.rpg_items i WHERE i.character_id = c.id AND i.equipped), 0)
                          - coalesce(public.rpg_participant_value(p.id, 'ST'), 0) * public.rpg_setting('carry_per_strength'), 0) END
  FROM public.rpg_session_participants p LEFT JOIN public.rpg_characters c ON c.id = p.character_id WHERE p.id = p_participant_id;
$fn$;

-- 12. A broken item gives no bonus (rpg_sheet_values, patched on the live body by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet_values';
  IF v_src LIKE '%rpg_object_state%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '          AND \(i\.uses_left IS NULL OR i\.uses_left > 0\)\n        GROUP BY i\.stat_key\) x;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet_values anchor found % times', v_n; END IF;
  v_src := replace(v_src, E'          AND (i.uses_left IS NULL OR i.uses_left > 0)\n        GROUP BY i.stat_key) x;\n',
                          E'          AND (i.uses_left IS NULL OR i.uses_left > 0)\n          AND NOT coalesce((public.rpg_object_state(i.object_id) ->> ''broken'')::boolean, false)\n        GROUP BY i.stat_key) x;\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_sheet_values(p_character_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 13. The sheet's item list reads the object; the object cards for the add form (rpg_sheet, patched by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_sheet';
  IF v_src LIKE '%object_cards%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '           ''stat_name'', v_names->>i\.stat_key, ''bonus'', i\.bonus, ''uses_left'', i\.uses_left, ''equipped'', i\.equipped, ''notes'', i\.notes\)\n           ORDER BY i\.sort_order, i\.created_at\), ''\[\]''::jsonb\)\n    INTO v_items FROM public\.rpg_items i WHERE i\.character_id = p_character_id;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics\);', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_sheet anchor 2 found % times', v_n; END IF;
  v_src := replace(v_src,
    E'           ''stat_name'', v_names->>i.stat_key, ''bonus'', i.bonus, ''uses_left'', i.uses_left, ''equipped'', i.equipped, ''notes'', i.notes)\n           ORDER BY i.sort_order, i.created_at), ''[]''::jsonb)\n    INTO v_items FROM public.rpg_items i WHERE i.character_id = p_character_id;\n',
    E'           ''stat_name'', v_names->>i.stat_key, ''bonus'', i.bonus, ''uses_left'', i.uses_left, ''equipped'', i.equipped, ''notes'', i.notes,\n           ''worn'', i.worn, ''object_id'', i.object_id, ''card'', s->>''card'', ''weapon_key'', s->>''weapon_key'', ''weapon_name'', v_names->>(s->>''weapon_key''),\n           ''life'', s->''pv'', ''life_left'', s->''left'', ''broken'', s->''broken'', ''integrity'', s->''ig'', ''weight'', s->''wt'',\n           ''strength'', s->''st'', ''agility'', s->''ag'', ''toughness'', s->''to'')\n           ORDER BY i.sort_order, i.created_at), ''[]''::jsonb)\n    INTO v_items FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s WHERE i.character_id = p_character_id;\n');
  v_src := replace(v_src, '    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics);',
    E'    ''items'', v_items, ''stats'', v_stats, ''basics'', v_basics,\n    ''object_cards'', (SELECT coalesce(jsonb_agg(jsonb_build_object(''id'', k.id, ''name'', k.name, ''worn'', k.worn, ''weapon_key'', k.weapon_key) ORDER BY k.sort_order, k.name), ''[]''::jsonb)\n                        FROM public.rpg_creatures k WHERE k.agency_id = v_c.agency_id AND k.is_active AND k.key <> ''object'' AND public.rpg_is_object_card(k.id)));');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 14. The fight reads the weapon, the block and the absorb from the object (rpg_act, patched by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_act';
  IF v_src LIKE '%rpg_object_state%' THEN RETURN; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '      SELECT id INTO v_weapon FROM public\.rpg_items WHERE character_id = v_actor\.character_id AND equipped AND NOT worn AND weapon_key = p_stat_key AND integrity_damage < integrity ORDER BY sort_order LIMIT 1;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 1 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '          SELECT i\.id, i\.name, i\.block INTO v_blocker, v_blocker_name, v_blk FROM public\.rpg_items i\n           WHERE i\.character_id = v_t\.character_id AND i\.equipped AND NOT i\.worn AND i\.integrity_damage < i\.integrity\n           ORDER BY i\.block DESC, i\.sort_order LIMIT 1;\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 2 found % times', v_n; END IF;
  SELECT count(*) INTO v_n FROM regexp_matches(v_src, '        FOR v_item IN SELECT i\.id, i\.name, i\.absorb FROM public\.rpg_items i\n                       WHERE i\.character_id = v_t\.character_id AND i\.equipped AND i\.worn AND i\.absorb > 0 AND i\.integrity_damage < i\.integrity ORDER BY i\.absorb DESC LOOP\n', 'g');
  IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 3 found % times', v_n; END IF;
  v_src := replace(v_src,
    E'      SELECT id INTO v_weapon FROM public.rpg_items WHERE character_id = v_actor.character_id AND equipped AND NOT worn AND weapon_key = p_stat_key AND integrity_damage < integrity ORDER BY sort_order LIMIT 1;\n',
    E'      -- the weapon: an unbroken held item whose card is swung with this skill (its object takes a fifth of what it strikes)\n      SELECT i.id INTO v_weapon FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s\n       WHERE i.character_id = v_actor.character_id AND i.equipped AND NOT i.worn AND s->>''weapon_key'' = p_stat_key AND NOT (s->>''broken'')::boolean\n       ORDER BY i.sort_order LIMIT 1;\n');
  v_src := replace(v_src,
    E'          SELECT i.id, i.name, i.block INTO v_blocker, v_blocker_name, v_blk FROM public.rpg_items i\n           WHERE i.character_id = v_t.character_id AND i.equipped AND NOT i.worn AND i.integrity_damage < i.integrity\n           ORDER BY i.block DESC, i.sort_order LIMIT 1;\n',
    E'          -- the best unbroken thing held: its object''s Integrity (Toughness ÷ 5) adds to Block\n          SELECT i.id, i.name, (s->>''ig'')::numeric INTO v_blocker, v_blocker_name, v_blk FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s\n           WHERE i.character_id = v_t.character_id AND i.equipped AND NOT i.worn AND NOT (s->>''broken'')::boolean\n           ORDER BY (s->>''ig'')::numeric DESC, i.sort_order LIMIT 1;\n');
  v_src := replace(v_src,
    E'        FOR v_item IN SELECT i.id, i.name, i.absorb FROM public.rpg_items i\n                       WHERE i.character_id = v_t.character_id AND i.equipped AND i.worn AND i.absorb > 0 AND i.integrity_damage < i.integrity ORDER BY i.absorb DESC LOOP\n',
    E'        -- worn and unbroken: each absorbs its object''s Integrity (Toughness ÷ 5) and takes that much itself\n        FOR v_item IN SELECT i.id, i.name, (s->>''ig'')::integer AS absorb FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s\n                       WHERE i.character_id = v_t.character_id AND i.equipped AND i.worn AND (s->>''ig'')::integer > 0 AND NOT (s->>''broken'')::boolean ORDER BY (s->>''ig'')::integer DESC LOOP\n');
  EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L', v_src);
END $do$;

-- 15. Objects are not on the character list, the fight's Add list or the Creatures tab (patched by anchors)
DO $do$
DECLARE v_src text; v_n int;
BEGIN
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_character_list';
  IF v_src NOT LIKE '%rpg_is_object_card%' THEN
    SELECT count(*) INTO v_n FROM regexp_matches(v_src, '  WHERE c\.agency_id = ''126794dd-25ff-47d2-a436-724499733365'' AND c\.is_active AND c\.session_id IS NULL AND \(SELECT public\.rpg_can_play\(\)\);', 'g');
    IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_character_list anchor found % times', v_n; END IF;
    v_src := replace(v_src, '  WHERE c.agency_id = ''126794dd-25ff-47d2-a436-724499733365'' AND c.is_active AND c.session_id IS NULL AND (SELECT public.rpg_can_play());',
                            E'  WHERE c.agency_id = ''126794dd-25ff-47d2-a436-724499733365'' AND c.is_active AND c.session_id IS NULL\n    AND NOT public.rpg_is_object_card(c.template_id) AND (SELECT public.rpg_can_play());');
    EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_character_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
  END IF;

  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_creature_list';
  IF v_src NOT LIKE '%rpg_is_object_card%' THEN
    SELECT count(*) INTO v_n FROM regexp_matches(v_src, '    AND \(SELECT public\.rpg_can_play\(\)\) AND \(gm\.is_gm OR c\.shown_to_players\);', 'g');
    IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_creature_list anchor found % times', v_n; END IF;
    v_src := replace(v_src, '    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);',
                            E'    AND NOT public.rpg_is_object_card(c.id)\n    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);');
    EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_creature_list() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
  END IF;

  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_session_state';
  IF v_src NOT LIKE '%rpg_is_object_card%' THEN
    SELECT count(*) INTO v_n FROM regexp_matches(v_src, '                        WHERE c\.is_active AND c\.session_id IS NULL\n', 'g');
    IF v_n <> 1 THEN RAISE EXCEPTION 'rpg_session_state anchor found % times', v_n; END IF;
    v_src := replace(v_src, E'                        WHERE c.is_active AND c.session_id IS NULL\n',
                            E'                        WHERE c.is_active AND c.session_id IS NULL AND NOT public.rpg_is_object_card(c.template_id)\n');
    EXECUTE format('CREATE OR REPLACE FUNCTION public.rpg_session_state(p_session_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS %L', v_src);
  END IF;
END $do$;

-- 16. The rule cards
UPDATE public.rpg_rules SET body = replace(replace(replace(body,
  'plus what is held)',
  'plus the Integrity of the thing held, its Toughness ÷ 5: a shield of Toughness 20 adds 4, a dagger of Toughness 6 adds 1)'),
  'Anything worn absorbs its absorb value first and takes that much itself',
  'Anything worn absorbs its own Integrity (Toughness ÷ 5) first and takes that much itself'),
  'Every object has a life of its own, like a character''s vitality; at 0 it stops working until it is repaired',
  'Every object is made from a card with its own Strength, Agility and Toughness, and its life is its Physical Vitality (3 × Toughness + 2 × Strength: Toughness 4 and Strength 3 give 18); at 0 it is broken and stops working until it is repaired')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'attack_gates';

INSERT INTO public.rpg_rules (agency_id, key, title, body, source, section, sort_order)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'items', 'Items',
E'Every item is a thing made from an Object card, the way a character is made from the Human card: it rolls its own Strength, Agility and Toughness. Each kind rolls Toughness with its own divider (a dagger d100 ÷ 10, so 1 to 10; a sword ÷ 5, up to 20; a shield or armor ÷ 4, up to 25; a cloak or trinket ÷ 20, 1 to 5) and carries the Weight its card sets (a dagger 1, a sword 3, a shield 6, armor 10, a trinket 0).\n\nIts life is its Physical Vitality (3 × Toughness + 2 × Strength: Toughness 4 and Strength 3 give 18), and it wears down by the same rule as a person: a blocking shield takes the whole blow, armor takes what it absorbs, a weapon takes a fifth of what it strikes. Its Integrity (Toughness ÷ 5, rounded down) is how much of a blow it turns aside: held, it adds to Block; worn, it absorbs that much.\n*A shield of Toughness 20 has Integrity 4: held, Block is 4 higher; a cloak of Toughness 3 has Integrity 0 and absorbs nothing.*\n\nWeight counts toward burden: Strength × 2 is carried free, and every point past it lowers Evade Enemy by one (Strength 10 carries 20).\n\nAt 0 life an item is broken: it gives no bonus, blocks nothing, absorbs nothing and cannot be swung until it is repaired. Items still carry what the player gave them: a name, a bonus to one stat (Hairband of Kindness, Kindness +1) and uses (Oil of Righteousness, 5 uses).',
'peter', 'Characters', 95)
ON CONFLICT (agency_id, key) DO NOTHING;
