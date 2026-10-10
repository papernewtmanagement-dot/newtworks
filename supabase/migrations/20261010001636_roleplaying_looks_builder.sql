-- Looks builder (Peter 2026-10-10): how a character looks, and the slots of the body that decide what is equipped.

CREATE OR REPLACE FUNCTION public.rpg_item_slot(p_card_key text, p_name text, p_worn boolean)
 RETURNS text LANGUAGE sql IMMUTABLE
AS $fn$
-- Where on the body a thing goes (looks builder, Peter 2026-10-10: a player switches armor and weapons in the builder
-- and that changes what is equipped), the one home of it: by its card (a weapon, shield or torch in the hand; a
-- longbow, crossbow, quarterstaff, battle axe, military fork or lance takes both hands; a cloak on the back; armor on
-- the body; oil anoints), else by its name (helm, hat, crown, hair band -> head; necklace, amulet -> neck; cloak, cape
-- -> back; armor, mail, robe, tunic -> body; bracelet, glove, ring -> wrists; shoes, boots -> feet; oil -> anointed;
-- a blade, axe, bow, staff, shield or torch -> hand), else worn things at the neck and held things in the hand.
-- Slots: head, neck, back, body, wrists, feet, anoint, hand, hand2 (both hands). One thing is equipped in each slot of
-- the body, two in the hands (rpg_item_set_equipped).
SELECT CASE
  WHEN p_card_key IN ('longbow', 'crossbow', 'quarterstaff', 'battle_axe', 'military_fork', 'lance') THEN 'hand2'
  WHEN p_card_key IN ('dagger', 'bastard_sword', 'long_sword', 'sword', 'hand_axe', 'war_hammer', 'flail', 'spear', 'sling', 'shield', 'torch') THEN 'hand'
  WHEN p_card_key = 'cloak' THEN 'back'
  WHEN p_card_key = 'armor' THEN 'body'
  WHEN p_card_key = 'oil' THEN 'anoint'
  WHEN n ~ '(helm|hat\M|hood|crown|circlet|tiara|hair ?band|headband|cap\M)' THEN 'head'
  WHEN n ~ '(necklace|amulet|pendant|locket|torc|medallion)' THEN 'neck'
  WHEN n ~ '(cloak|cape|mantle)' THEN 'back'
  WHEN n ~ '(armou?r|mail|breastplate|robe|tunic|vest|coat|belt)' THEN 'body'
  WHEN n ~ '(bracelet|bracer|bangle|gauntlet|glove|ring\M)' THEN 'wrists'
  WHEN n ~ '(shoe|boot|sandal|slipper)' THEN 'feet'
  WHEN n ~ '(oil|ointment|perfume|balm)' THEN 'anoint'
  WHEN n ~ '(longbow|crossbow|quarterstaff|battle ?axe|\mstaff\M|\mbow\M)' THEN 'hand2'
  WHEN n ~ '(dagger|knife|sword|blade|axe|hammer|mace|club|spear|sling|shield|torch|wand)' THEN 'hand'
  WHEN coalesce(p_worn, false) THEN 'neck'
  ELSE 'hand' END
  FROM (SELECT lower(coalesce(p_name, '')) AS n) q;
$fn$;
REVOKE ALL ON FUNCTION public.rpg_item_slot(text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_item_slot(text, text, boolean) TO authenticated, service_role;

ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS looks jsonb NOT NULL DEFAULT '{}'::jsonb;
COMMENT ON COLUMN public.rpg_characters.looks IS 'How the character looks (looks builder, 2026-10-10): skin, hair, hair_color, eyes, ears, build, height, outfit, outfit_color, trim_color, extra; drawn by the Roleplaying page (CharacterPortrait).';

CREATE OR REPLACE FUNCTION public.rpg_character_set_looks(p_character_id uuid, p_looks jsonb)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- Sets how a character looks (looks builder, Peter 2026-10-10: a player sets up their character at the start and
-- changes it any time). Anyone who may play and reach the character (rpg_can_see_character: a player their own and the
-- party's, a parent any). Keeps only the known choices, each a short word (the page holds the lists and draws them);
-- looks change nothing in the rules. Returns the looks kept.
DECLARE v jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_characters c WHERE c.id = p_character_id) OR NOT public.rpg_can_see_character(p_character_id) THEN
    RAISE EXCEPTION 'character not found';
  END IF;
  SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) INTO v
    FROM jsonb_each(coalesce(p_looks, '{}'::jsonb)) AS e
   WHERE e.key IN ('skin', 'hair', 'hair_color', 'eyes', 'ears', 'build', 'height', 'outfit', 'outfit_color', 'trim_color', 'extra')
     AND jsonb_typeof(e.value) = 'string' AND length(e.value #>> '{}') BETWEEN 1 AND 24 AND (e.value #>> '{}') ~ '^[a-z0-9_]+$';
  UPDATE public.rpg_characters SET looks = v, updated_at = now() WHERE id = p_character_id;
  RETURN v;
END $fn$;
REVOKE ALL ON FUNCTION public.rpg_character_set_looks(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_character_set_looks(uuid, jsonb) TO authenticated, service_role;
CREATE OR REPLACE FUNCTION public.rpg_item_row(p_item_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One item as the pages show it: what the player gave it (name, the stat it adds to and by how much, uses, equipped,
-- notes, held or worn) and what its own object says (rpg_object_state: the card, the skill that swings it, life and
-- life left, broken, the Integrity it turns aside, its Weight, its Strength, Agility and Toughness), plus who holds
-- it. The one writer of this row: rpg_sheet's items list and rpg_object_list read it. Internal.
SELECT jsonb_build_object('id', i.id, 'name', i.name, 'stat_key', i.stat_key, 'stat_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = i.stat_key),
         'bonus', i.bonus, 'uses_left', i.uses_left, 'equipped', i.equipped, 'notes', i.notes, 'worn', i.worn, 'object_id', i.object_id,
         'owner_id', i.character_id, 'owner', (SELECT c.name FROM public.rpg_characters c WHERE c.id = i.character_id),
         'card_id', s->>'card_id', 'card', s->>'card', 'weapon_key', s->>'weapon_key', 'weapon_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = s->>'weapon_key'),
         'life', s->'pv', 'life_left', s->'left', 'broken', s->'broken', 'integrity', s->'ig', 'weight', s->'wt', 'bulk', s->'bk',
         'strength', s->'st', 'agility', s->'ag', 'toughness', s->'to',
         -- (looks builder) where on the body it goes (rpg_item_slot)
         'slot', public.rpg_item_slot((SELECT k.key FROM public.rpg_creatures k WHERE k.id = (s->>'card_id')::uuid), i.name, i.worn))
  FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
 WHERE i.id = p_item_id;
$function$
;
CREATE OR REPLACE FUNCTION public.rpg_item_set_equipped(p_item_id uuid, p_equipped boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Equips or puts away one item. Only an equipped item adds its bonus or blocks a blow. (Looks builder, Peter
-- 2026-10-10) Equipping puts away what it replaces (rpg_item_slot): another thing in the same slot of the body; in the
-- hands, everything else when it takes both hands, a two-handed thing when it takes one, and the earliest of two others.
DECLARE v_char uuid; v_slot text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT character_id INTO v_char FROM public.rpg_items WHERE id = p_item_id;
  IF v_char IS NULL OR NOT public.rpg_can_see_character(v_char) THEN RAISE EXCEPTION 'item not found'; END IF;
  IF coalesce(p_equipped, false) THEN
    SELECT r->>'slot' INTO v_slot FROM public.rpg_item_row(p_item_id) r;
    IF v_slot IN ('head', 'neck', 'back', 'body', 'wrists', 'feet') THEN
      UPDATE public.rpg_items i SET equipped = false
       WHERE i.character_id = v_char AND i.id <> p_item_id AND i.equipped AND (public.rpg_item_row(i.id)->>'slot') = v_slot;
    ELSIF v_slot IN ('hand', 'hand2') THEN
      UPDATE public.rpg_items i SET equipped = false
       WHERE i.character_id = v_char AND i.id <> p_item_id AND i.equipped
         AND ((public.rpg_item_row(i.id)->>'slot') = 'hand2' OR (v_slot = 'hand2' AND (public.rpg_item_row(i.id)->>'slot') = 'hand'));
      IF v_slot = 'hand' THEN
        UPDATE public.rpg_items i SET equipped = false
         WHERE i.id IN (SELECT o.id FROM public.rpg_items o
                         WHERE o.character_id = v_char AND o.id <> p_item_id AND o.equipped AND (public.rpg_item_row(o.id)->>'slot') = 'hand'
                         ORDER BY o.sort_order, o.created_at
                         OFFSET 0 LIMIT greatest((SELECT count(*) FROM public.rpg_items h WHERE h.character_id = v_char AND h.id <> p_item_id AND h.equipped
                                                    AND (public.rpg_item_row(h.id)->>'slot') = 'hand') - 1, 0));
      END IF;
    END IF;
  END IF;
  UPDATE public.rpg_items SET equipped = coalesce(p_equipped, false) WHERE id = p_item_id;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.rpg_sheet(p_character_id uuid, p_difficulty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One character's whole sheet. Its stats are the ones its card gives it (rpg_template_stat_defs): every shared stat,
-- plus any that belong to the card it is made from or a card above it. A Human has only the shared ones.
-- The numbers come from rpg_sheet_values; this adds what the page shows (names, formulas, what a roll needs).
-- A knowledge row (rpg_stat_definitions.knows_id: Knowing Bramblemaw) is a kid's to see once its card is shown to
-- players, is on the character's own chain or is a top card, or once this character has met or studied it (any
-- points banked); the game master sees every open one.
DECLARE
  v_c       record;
  v_calc    jsonb;
  v_defs    public.rpg_stat_definitions[];
  v_d       public.rpg_stat_definitions;
  v_vals    jsonb;
  v_bonus   jsonb;
  v_earned  jsonb;
  v_points  jsonb;
  v_names   jsonb;
  v_v       numeric;
  v_diff    numeric;
  v_nc      jsonb;
  v_stats   jsonb := '[]'::jsonb;
  v_kid     text;
  v_items   jsonb;
  v_pv      numeric;
  v_raw     jsonb;
  v_good    numeric;
  v_evil    numeric;
  v_basics  jsonb := '[]'::jsonb;
  v_mix     jsonb;
  v_tree    jsonb;
  v_sections jsonb;
  v_bulk    jsonb;
  v_gm      boolean;
  v_chain   uuid[];
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_characters WHERE id = p_character_id;
  IF NOT FOUND OR NOT public.rpg_can_see_character(p_character_id) THEN RAISE EXCEPTION 'character not found'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  v_calc := public.rpg_sheet_values(p_character_id);
  v_vals := v_calc->'values'; v_raw := v_calc->'raw';
  v_bonus := v_calc->'bonus'; v_earned := v_calc->'earned'; v_points := v_calc->'points';
  v_defs := ARRAY(SELECT d FROM public.rpg_template_stat_defs(v_c.template_id) d ORDER BY d.sort_order, d.key);
  SELECT coalesce(jsonb_object_agg(t.key, t.name), '{}'::jsonb) INTO v_names
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;
  -- each stat's section (rpg_section), the mix line (rpg_sheet_mix) and the parents a calculated stat is built from (rpg_stat_parents)
  SELECT coalesce(jsonb_object_agg(t.key, public.rpg_section(t.grp)), '{}'::jsonb) INTO v_sections
  FROM public.rpg_stat_definitions t WHERE t.agency_id = v_c.agency_id;
  v_mix := public.rpg_sheet_mix(v_c.template_id, v_vals);
  -- open / second nature for every skill (rpg_skill_tree, the one home of the tree)
  v_tree := public.rpg_skill_tree(v_c.template_id, v_vals);
  v_gm := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_chain := public.rpg_template_chain(v_c.template_id);

  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.side = 'evil' OR v_d.grp = 'basic';
    -- a shut skill is not on the sheet (rpg_skill_tree: a parent not yet open, or under a third of its own bar)
    CONTINUE WHEN v_d.trainable AND v_tree ? v_d.key AND NOT (v_tree -> v_d.key ->> 'open')::boolean;
    -- a knowledge row a kid has no reason to see yet (the card unshown, unmet, unstudied) stays off the sheet
    CONTINUE WHEN v_d.knows_id IS NOT NULL AND NOT v_gm
      AND NOT EXISTS (SELECT 1 FROM public.rpg_creatures k WHERE k.id = v_d.knows_id AND (k.shown_to_players OR k.parent_id IS NULL OR k.id = ANY (v_chain)))
      AND NOT EXISTS (SELECT 1 FROM public.rpg_character_skills s WHERE s.character_id = p_character_id AND s.stat_key = v_d.key AND (s.skill_points > 0 OR s.earned_levels > 0));
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    -- Prayer and Bible Study face the difficulty plus the spiritual burden, as rpg_roll charges it (burden 6: 5 becomes 11)
    -- a weapon skill with a bulky weapon in hand rolls lower by the bulk past the handling (rpg_weapon_bulk), so its "needs" says so too
    v_bulk := CASE WHEN v_d.is_attack THEN public.rpg_weapon_bulk(p_character_id, v_d.key) END;
    v_nc := public.rpg_needed(greatest(v_v - coalesce((v_bulk->>'over')::numeric, 0), 0), v_diff + CASE WHEN v_d.spirit_discipline THEN coalesce(v_c.spiritual_burden, 0) ELSE 0 END);
    v_good := coalesce((v_raw->>v_d.key)::numeric, 0); v_evil := CASE WHEN v_d.pair_key IS NULL THEN 0 ELSE coalesce((v_raw->>v_d.pair_key)::numeric, 0) END;
    v_stats := v_stats || jsonb_build_object(
      'key', v_d.key, 'name', CASE WHEN v_d.pair_key IS NOT NULL AND v_evil > v_good THEN v_names->>v_d.pair_key ELSE v_d.name END,
      'pair_key', v_d.pair_key, 'side', CASE WHEN v_d.pair_key IS NULL THEN NULL WHEN v_evil > v_good THEN 'evil' ELSE 'good' END,
      'good_name', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_d.name END, 'evil_name', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_names->>v_d.pair_key END,
      'good', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_good END, 'evil', CASE WHEN v_d.pair_key IS NULL THEN NULL ELSE v_evil END, 'abbr', v_d.abbr, 'grp', v_d.grp, 'kind', v_d.kind, 'trainable', v_d.trainable,
      'value', v_v,
      'base', v_v - coalesce((v_bonus->>v_d.key)::numeric, 0) - coalesce((v_earned->>v_d.key)::numeric, 0),
      'item_bonus', coalesce((v_bonus->>v_d.key)::numeric, 0),
      'earned_levels', coalesce((v_earned->>v_d.key)::numeric, 0),
      'skill_points', round(coalesce((v_points->>v_d.key)::numeric, 0), 1),
      'next_level_cost', CASE WHEN v_d.trainable THEN public.rpg_level_cost(v_v::integer) ELSE NULL END,
      'needed', v_nc->'needed', 'critical', v_nc->'critical', 'bulk', v_bulk,
      'formula_text', public.rpg_formula_text(v_d.formula, v_names),
      'section', public.rpg_section(v_d.grp), 'tree', v_tree -> v_d.key, 'mix', CASE WHEN v_d.kind = 'derived' THEN v_mix -> v_d.key END,
      'parents', CASE WHEN v_d.kind = 'derived' THEN public.rpg_stat_parents(v_d.formula, v_vals, v_names, v_sections) END);
  END LOOP;

  -- the hidden basics (Swing arm, Grip, ...): not stats on the sheet, shown inside the skills built on them
  FOREACH v_d IN ARRAY v_defs LOOP
    CONTINUE WHEN v_d.grp <> 'basic';
    v_v := coalesce((v_vals->>v_d.key)::numeric, 0);
    v_basics := v_basics || jsonb_build_object('key', v_d.key, 'name', v_d.name, 'abbr', v_d.abbr, 'value', v_v,
      'skill_points', round(coalesce((v_points->>v_d.key)::numeric, 0), 1), 'next_level_cost', public.rpg_level_cost(v_v::integer), 'tree', v_tree -> v_d.key);
  END LOOP;

  SELECT k.name INTO v_kid FROM public.family_kids k WHERE k.id = v_c.kid_id;
  -- each item's row comes from rpg_item_row, the one writer of it (the Objects tab reads the same rows)
  SELECT coalesce(jsonb_agg(public.rpg_item_row(i.id) ORDER BY i.sort_order, i.created_at), '[]'::jsonb)
    INTO v_items FROM public.rpg_items i WHERE i.character_id = p_character_id;
  v_pv := (v_calc->>'vitality_max')::numeric;

  RETURN jsonb_build_object(
    'id', v_c.id, 'name', v_c.name, 'template_id', v_c.template_id, 'side', v_calc->>'side', 'kid_id', v_c.kid_id, 'kid_name', v_kid, 'is_npc', v_c.is_npc,
    'color', v_c.color, 'notes', v_c.notes, 'looks', v_c.looks, 'image_path', v_c.image_path, 'icon_path', public.rpg_icon(v_c.id, v_c.template_id), 'inputs', v_c.inputs,
    'vitality_max', v_pv, 'vitality_damage', v_c.vitality_damage, 'vitality_left', greatest(v_pv - v_c.vitality_damage, 0),
    'coins', jsonb_build_object('platinum', v_c.platinum, 'gold', v_c.gold, 'silver', v_c.silver, 'copper', v_c.copper),
    'difficulty', v_diff, 'crit_chance', public.rpg_setting('crit_chance'),
    'spiritual_burden', coalesce(v_c.spiritual_burden, 0),
    -- the armor of God pieces that wear (rpg_stat_definitions.guards): the Shield of Faith, the Breastplate, the Helmet
    'armor', (SELECT coalesce(jsonb_agg(public.rpg_armor_state(p_character_id, d.key) ORDER BY d.sort_order), '[]'::jsonb)
                FROM public.rpg_stat_definitions d WHERE d.agency_id = v_c.agency_id AND d.guards IS NOT NULL),
    'items', v_items, 'stats', v_stats, 'basics', v_basics,
    'object_cards', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'worn', k.worn, 'weapon_key', k.weapon_key) ORDER BY k.sort_order, k.name), '[]'::jsonb)
                        FROM public.rpg_creatures k WHERE k.agency_id = v_c.agency_id AND k.is_active AND k.key <> 'object' AND public.rpg_is_object_card(k.id)));
END;
$function$
;
-- (one quote mark to balance the text above for the SQL tool) '

