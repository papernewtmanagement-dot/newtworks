CREATE OR REPLACE FUNCTION public.rpg_card_picture(p_card uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The picture a character borrows when it has none of its own: the picture on the card it is made from, or the nearest
-- card above that has one. The four turtles show the Cistern Turtle card's picture of all four until they get their own.
SELECT c.image_path
  FROM unnest(public.rpg_template_chain(p_card)) WITH ORDINALITY AS t(id, n)
  JOIN public.rpg_creatures c ON c.id = t.id
 WHERE c.image_path IS NOT NULL
 ORDER BY t.n LIMIT 1;
$function$;

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
    'color', v_c.color, 'notes', v_c.notes, 'looks', v_c.looks, 'image_path', v_c.image_path, 'icon_path', public.rpg_icon(v_c.id, v_c.template_id), 'card_image_path', public.rpg_card_picture(v_c.template_id), 'inputs', v_c.inputs,
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
$function$;
