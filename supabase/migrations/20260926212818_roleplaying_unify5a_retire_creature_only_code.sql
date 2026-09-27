-- Step 2 of Peter's list: fights no longer read anything printed for creatures, so the creature-only code and the
-- printed numbers go. Every roll comes from a sheet; a card keeps its d20 block only for reading.

-- rpg_roll: one path. The creature branch (no character, skill handed in) is gone with its p_skill argument.
DROP FUNCTION IF EXISTS public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, numeric, integer);
CREATE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric, p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid, p_participant_id uuid DEFAULT NULL::uuid, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One d100 roll of one stat from a sheet. Everyone who rolls has a sheet: a player character, or a creature made
-- from its card for a fight. Rolling a trainable stat earns skill points on every roll: die × Needed ÷ 100 (Peter
-- 2026-09-24), so a 70 when Needed is 50 earns 35. p_roll is a die rolled by hand (1 to 100) used in place of the
-- random one. Needed comes from rpg_needed; an opponent's difficulty arrives already derived by rpg_difficulty.
DECLARE
  v_sheet jsonb; v_stat jsonb; v_skill numeric; v_diff numeric; v_nc jsonb; v_roll integer; v_result text;
  v_points numeric := 0; v_before integer; v_after integer; v_id uuid; v_agency uuid; v_name text; v_trainable boolean := false;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  IF v_diff < 0 THEN RAISE EXCEPTION 'difficulty cannot be negative'; END IF;
  IF p_roll IS NOT NULL AND (p_roll < 1 OR p_roll > 100) THEN RAISE EXCEPTION 'a roll is 1 to 100'; END IF;
  IF p_character_id IS NULL THEN RAISE EXCEPTION 'every roll needs a sheet'; END IF;

  v_sheet := public.rpg_sheet(p_character_id, v_diff);
  SELECT s INTO v_stat FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = p_stat_key;
  IF v_stat IS NULL THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;
  v_skill := (v_stat->>'value')::numeric;
  v_name := v_stat->>'name';
  v_trainable := coalesce((v_stat->>'trainable')::boolean, false);
  SELECT agency_id INTO v_agency FROM public.rpg_characters WHERE id = p_character_id;

  v_nc := public.rpg_needed(v_skill, v_diff);
  v_roll := coalesce(p_roll, floor(random() * 100)::integer + 1);
  v_result := CASE WHEN v_roll >= (v_nc->>'critical')::numeric THEN 'C'
                   WHEN v_roll >= (v_nc->>'needed')::numeric THEN 'Y' ELSE '' END;
  v_before := v_skill::integer; v_after := v_before;

  IF v_trainable THEN
    v_points := v_roll * (v_nc->>'needed')::numeric / 100;
    v_after := public.rpg_add_skill_points(p_character_id, p_stat_key, v_points, v_before);
  END IF;

  INSERT INTO public.rpg_rolls (agency_id, character_id, participant_id, session_id, stat_key, skill, difficulty, needed,
                                critical_at, roll, result, points_awarded, level_before, level_after, parent_roll_id,
                                extra_pending, label, manual)
  VALUES (v_agency, p_character_id, p_participant_id, p_session_id, p_stat_key, v_skill, v_diff,
          (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, v_roll, v_result, v_points, v_before, v_after,
          p_parent_roll_id, v_result = 'C', p_label, p_roll IS NOT NULL)
  RETURNING id INTO v_id;
  IF p_parent_roll_id IS NOT NULL THEN
    UPDATE public.rpg_rolls SET extra_pending = false WHERE id = p_parent_roll_id;
  END IF;

  RETURN jsonb_build_object('roll_id', v_id, 'character_id', p_character_id, 'participant_id', p_participant_id,
    'stat_key', p_stat_key, 'stat_name', v_name, 'skill', v_skill, 'difficulty', v_diff, 'needed', v_nc->'needed',
    'critical', v_nc->'critical', 'roll', v_roll, 'result', v_result, 'points', round(v_points, 1),
    'level_before', v_before, 'level_after', v_after, 'extra_pending', v_result = 'C', 'manual', p_roll IS NOT NULL,
    'parent_roll_id', p_parent_roll_id, 'label', p_label, 'created_at', now());
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, integer) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpg_roll_extra(p_parent_roll_id uuid, p_roll integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The additional roll a critical prompts: same sheet, same stat, same difficulty, same fight. p_roll is a die rolled
-- by hand.
DECLARE v_p record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_rolls WHERE id = p_parent_roll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'roll not found'; END IF;
  IF NOT v_p.extra_pending THEN RAISE EXCEPTION 'that roll has no additional roll waiting'; END IF;
  RETURN public.rpg_roll(v_p.character_id, v_p.stat_key, v_p.difficulty, v_p.label, p_parent_roll_id, v_p.session_id,
                         v_p.participant_id, p_roll);
END;
$function$;

-- rpg_act's four rolls drop the old creature skill argument. Each anchor must be found exactly as often as expected.
DO $patch$
DECLARE
  d text := pg_get_functiondef('public.rpg_act'::regproc);
  a text[] := ARRAY['v_s.id, p_actor_id, NULL, p_roll);', E'p_actor_id, NULL,\n', 'p_actor_id, NULL);'];
  b text[] := ARRAY['v_s.id, p_actor_id, p_roll);',       E'p_actor_id,\n',       'p_actor_id);'];
  n integer[] := ARRAY[1, 1, 2];
  i integer; c integer;
BEGIN
  FOR i IN 1..3 LOOP
    c := (length(d) - length(replace(d, a[i], ''))) / length(a[i]);
    IF c <> n[i] THEN RAISE EXCEPTION 'rpg_act anchor % found % times, expected %', i, c, n[i]; END IF;
    d := replace(d, a[i], b[i]);
  END LOOP;
  IF position('p_actor_id, NULL' in d) > 0 THEN RAISE EXCEPTION 'rpg_act still passes the old argument'; END IF;
  EXECUTE d;
END
$patch$;

-- Damage in a fight lives on the sheet's character, for everyone.
CREATE OR REPLACE FUNCTION public.rpg_session_adjust_vitality(p_participant_id uuid, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Damage (+) or healing (−) for anyone in a fight, carried on their character through rpg_adjust_vitality. Damage
-- stops at 0 left, healing stops at full. Karen 41, hit for 94 → 0 left, down. A Bramblemaw 149, hit for 30 → 119.
DECLARE v_p record; v_v jsonb; v_delta integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  v_v := public.rpg_participant_vitality(p_participant_id);
  v_delta := CASE WHEN coalesce(p_delta, 0) > 0 THEN least(p_delta, (v_v->>'left')::integer)
                  ELSE greatest(coalesce(p_delta, 0), -(v_v->>'damage')::integer) END;
  IF v_delta <> 0 THEN PERFORM public.rpg_adjust_vitality(v_p.character_id, v_delta); END IF;
  RETURN public.rpg_participant_vitality(p_participant_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creature_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Creatures tab list. Players see a card once it is shown to them; the game master also gets the printed
-- challenge, armor class and hit points (d20 flavor, not used by any roll) and whether it is shown.
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm)
  SELECT coalesce(jsonb_agg(
           jsonb_build_object('id', c.id, 'key', c.key, 'name', c.name, 'color', c.color, 'epigraph', c.epigraph)
           || CASE WHEN gm.is_gm THEN jsonb_build_object('challenge', c.challenge, 'armor_class', c.armor_class,
                'hit_points', c.hit_points, 'shown_to_players', c.shown_to_players) ELSE '{}'::jsonb END
           ORDER BY c.sort_order, c.name), '[]'::jsonb)
  FROM public.rpg_creatures c CROSS JOIN gm
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creature_card(p_creature_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One creature card. Players get it once it is shown to them, and then only its names, haunts, epigraph, lore and
-- picture. The game master also gets the printed d20 block (for reading, it drives no roll), how a creature is made
-- from the card (template), and each action with the skill it rolls from the creature's own sheet (skill_key) and
-- the stat the target defends with. Every creature's numbers are on the sheet it is made with in a fight.
DECLARE
  v_gm   boolean := public.family_is_parent();
  v_c    public.rpg_creatures%ROWTYPE;
  v_card jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_c FROM public.rpg_creatures
   WHERE id = p_creature_id AND agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active;
  IF NOT FOUND OR NOT (v_gm OR v_c.shown_to_players) THEN RETURN NULL; END IF;

  v_card := jsonb_build_object(
    'id', v_c.id, 'key', v_c.key, 'name', v_c.name, 'color', v_c.color, 'is_gm', v_gm,
    'scholarly_name', v_c.scholarly_name, 'whispered_label', v_c.whispered_label,
    'whispered_names', to_jsonb(v_c.whispered_names), 'haunts', v_c.haunts,
    'epigraph', v_c.epigraph, 'lore', v_c.lore);
  v_card := v_card || jsonb_build_object('image_path', v_c.image_path);
  IF NOT v_gm THEN RETURN v_card; END IF;

  RETURN v_card || jsonb_build_object(
    'shown_to_players', v_c.shown_to_players,
    'source_manual_id', v_c.source_manual_id,
    'card_title', v_c.card_title,
    'type_line', v_c.size || ' ' || v_c.creature_type || coalesce(', ' || v_c.alignment, ''),
    'armor_text', v_c.armor_class || coalesce(' (' || v_c.armor_note || ')', ''),
    'hit_points_text', v_c.hit_points || coalesce(' (' || v_c.hit_dice || ')', ''),
    'speed_text', v_c.speed_ft || ' ft.'
        || coalesce(', burrow ' || v_c.burrow_ft || ' ft.', '') || coalesce(', climb ' || v_c.climb_ft || ' ft.', '')
        || coalesce(', fly ' || v_c.fly_ft || ' ft.', '') || coalesce(', swim ' || v_c.swim_ft || ' ft.', ''),
    'abilities', CASE WHEN v_c.str_score IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(
        jsonb_build_object('key', 'str', 'label', 'STR', 'score', v_c.str_score, 'mod', floor((v_c.str_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'dex', 'label', 'DEX', 'score', v_c.dex_score, 'mod', floor((v_c.dex_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'con', 'label', 'CON', 'score', v_c.con_score, 'mod', floor((v_c.con_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'int', 'label', 'INT', 'score', v_c.int_score, 'mod', floor((v_c.int_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'wis', 'label', 'WIS', 'score', v_c.wis_score, 'mod', floor((v_c.wis_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'cha', 'label', 'CHA', 'score', v_c.cha_score, 'mod', floor((v_c.cha_score - 10) / 2.0)::int)) END,
    'saving_throws_text', (SELECT string_agg(initcap(e->>'ability') || ' ' || CASE WHEN (e->>'bonus')::int < 0 THEN '−' ELSE '+' END
                             || abs((e->>'bonus')::int), ', ' ORDER BY o) FROM jsonb_array_elements(v_c.saving_throws) WITH ORDINALITY AS t(e, o)),
    'skills_text', (SELECT string_agg((e->>'name') || ' ' || CASE WHEN (e->>'bonus')::int < 0 THEN '−' ELSE '+' END
                      || abs((e->>'bonus')::int), ', ' ORDER BY o) FROM jsonb_array_elements(v_c.skills) WITH ORDINALITY AS t(e, o)),
    'damage_vulnerabilities', v_c.damage_vulnerabilities,
    'damage_resistances', v_c.damage_resistances,
    'damage_immunities', v_c.damage_immunities,
    'condition_immunities', v_c.condition_immunities,
    'senses', v_c.senses,
    'languages', v_c.languages,
    'challenge_text', v_c.challenge || coalesce(' (' || to_char(v_c.xp, 'FM999,999,990') || ' XP)', ''),
    'legendary_per_round', v_c.legendary_per_round,
    'legendary_intro', v_c.legendary_intro,
    'lair_title', v_c.lair_title,
    'lair_intro', v_c.lair_intro,
    'rumor_title', v_c.rumor_title,
    'rumor_intro', v_c.rumor_intro,
    'rumors', v_c.rumors,
    'rumor_note', v_c.rumor_note,
    'gm_tip', v_c.gm_tip,
    -- A roll against someone who can act faces their stat × this (rpg_difficulty): Evade Enemy 5 → difficulty 10.
    'opponent_multiplier', public.rpg_setting('opponent_will_multiplier'),
    -- How a character made from this card is rolled: its parent card, and its whole blueprint (its own entries and
    -- what it takes from the cards above it), a set number (a boss) or experience points spent up the level ladder
    -- (from_1 and from_top: where those points take a 1 and start_top, the top of that stat's own roll). Anything
    -- left out rolls the standard way.
    'template', jsonb_build_object(
        'parent_key', v_c.parent_key,
        'parent_name', (SELECT p.name FROM public.rpg_creatures p WHERE p.agency_id = v_c.agency_id AND p.key = v_c.parent_key),
        'entries', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'key', d.key, 'name', d.name,
                        'fixed',   CASE WHEN jsonb_typeof(b.value) = 'number' THEN (b.value #>> '{}')::numeric END,
                        'divisor', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'divisor')::numeric END, 'top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'divisor') THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) END, 'points', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (b.value ->> 'points')::numeric END, 'from_1', CASE WHEN jsonb_typeof(b.value) = 'object' THEN (SELECT c.level FROM public.rpg_climb_levels(1, (b.value ->> 'points')::numeric) c) END, 'start_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN CASE WHEN b.value ? 'divisor' THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) ELSE ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')) END END, 'from_top', CASE WHEN jsonb_typeof(b.value) = 'object' AND (b.value ? 'points') THEN (SELECT c.level FROM public.rpg_climb_levels(CASE WHEN b.value ? 'divisor' THEN ceil(public.rpg_setting('strength_roll_max') / greatest((b.value ->> 'divisor')::numeric, 1)) ELSE ceil(public.rpg_setting('strength_roll_max') / public.rpg_setting('strength_roll_divisor')) END::integer, (b.value ->> 'points')::numeric) c) END,
                        'inherited', NOT (v_c.blueprint ? d.key))
                      ORDER BY d.sort_order, d.key), '[]'::jsonb)
                      FROM jsonb_each(public.rpg_template_blueprint(v_c.key)) AS b
                      JOIN public.rpg_template_stat_defs(v_c.key) d ON d.key = b.key),
        'die', public.rpg_setting('strength_roll_max'),
        'divisor', public.rpg_setting('strength_roll_divisor')),
    'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'kind', a.kind, 'name', a.name,
        'heading', a.name
            || CASE WHEN a.recharge_min IS NULL THEN '' WHEN a.recharge_min < 6 THEN ' (Recharge ' || a.recharge_min || '–6)' ELSE ' (Recharge 6)' END
            || CASE WHEN a.kind = 'legendary' AND a.legendary_cost > 1 THEN ' (Costs ' || a.legendary_cost || ' Actions)' ELSE '' END,
        'description', a.description,
        'to_hit', a.to_hit, 'reach_ft', a.reach_ft, 'range_text', a.range_text,
        'save_dc', a.save_dc, 'save_ability', a.save_ability,
        'save_ability_name', CASE a.save_ability WHEN 'str' THEN 'Strength' WHEN 'dex' THEN 'Dexterity' WHEN 'con' THEN 'Constitution'
                               WHEN 'int' THEN 'Intelligence' WHEN 'wis' THEN 'Wisdom' WHEN 'cha' THEN 'Charisma' END,
        'skill_key', a.skill_key,
        'skill_name', (SELECT d.name FROM public.rpg_stat_definitions d
                        WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.skill_key),
        'against', a.against,
        'against_name', (SELECT d.name FROM public.rpg_stat_definitions d
                          WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.against),
        'table_note', a.table_note,
        'recharge_min', a.recharge_min, 'legendary_cost', a.legendary_cost, 'makes_attacks', a.makes_attacks)
      ORDER BY array_position(ARRAY['trait','action','bonus_action','reaction','legendary','lair'], a.kind), a.sort_order), '[]'::jsonb)
      FROM public.rpg_creature_actions a WHERE a.creature_id = v_c.id));
END;
$function$;

-- The printed numbers go. Peter's yes 2026-09-26 ("1a"). The d20 block (armor class, hit points, ability scores,
-- to-hit, save DC) stays on the card for reading.
ALTER TABLE public.rpg_creatures
  DROP COLUMN IF EXISTS attack_skill, DROP COLUMN IF EXISTS defense_skill, DROP COLUMN IF EXISTS strength_skill,
  DROP COLUMN IF EXISTS will_skill, DROP COLUMN IF EXISTS stealth_skill, DROP COLUMN IF EXISTS awareness_skill,
  DROP COLUMN IF EXISTS agility_skill, DROP COLUMN IF EXISTS vitality;
ALTER TABLE public.rpg_creature_actions DROP COLUMN IF EXISTS skill;
ALTER TABLE public.rpg_session_participants DROP COLUMN IF EXISTS vitality_damage;

