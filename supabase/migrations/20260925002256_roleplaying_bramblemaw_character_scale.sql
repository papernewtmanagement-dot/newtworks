-- Roleplaying: Bramblemaw re-derived on the character scale (Peter 2026-09-25: "it should be a massive challenge").
-- A creature now carries the same kind of numbers a character has, set by the game master on the character scale:
--   attack, defense, strength, will, stealth, awareness (1 to 10 like a rolled character; a legendary sits at the top)
--   and vitality (a hero carries about 25 to 30). The d20 stat block stays on the card as reading and flavor only.
-- Bramblemaw: attack 10, defense 8, strength 10, will 10, stealth 8, awareness 8, vitality 150 (five heroes' worth).
--   Why: its d20 card (+10 to hit, AC 16 natural armor, 189 hp, resists ordinary weapons, 4 claw or bite rolls a round)
--   is a top-tier threat. On our scale: it rolls 10 against a hero's Evade Enemy 5 (difficulty 10) → needs 50, lands
--   about half the time, a landing claw does about 25; four rolls a round is roughly 50 damage against heroes of 25 to 30
--   vitality. Heroes hit it with sword 6 against defense 8 (difficulty 16) → need 73, land about 28%, about 14 a hit;
--   four heroes do about 22 a round, so 150 vitality is about seven rounds of everyone landing hits. Its hide turning
--   ordinary blades is folded into that vitality. Defense stays 8, not 10: it is huge and slow, the danger is what it does
--   to you and how much it takes, not that it cannot be touched. Asleep or held it is difficulty 8 (sword 6 needs 58).
-- Each attack or save action carries the skill it rolls and the character stat the target defends with; the d20 save DCs
-- and to-hit bonuses no longer drive any number. rpg_card_difficulty / card_difficulty_offset are left in place but
-- unused (dropping them is Peter's call). Nothing is deleted; the verbatim card text is untouched.

-- 1. Character-scale columns (additive).
ALTER TABLE public.rpg_creatures
  ADD COLUMN IF NOT EXISTS attack_skill    smallint CHECK (attack_skill    IS NULL OR attack_skill    >= 0),
  ADD COLUMN IF NOT EXISTS defense_skill   smallint CHECK (defense_skill   IS NULL OR defense_skill   >= 0),
  ADD COLUMN IF NOT EXISTS strength_skill  smallint CHECK (strength_skill  IS NULL OR strength_skill  >= 0),
  ADD COLUMN IF NOT EXISTS will_skill      smallint CHECK (will_skill      IS NULL OR will_skill      >= 0),
  ADD COLUMN IF NOT EXISTS stealth_skill   smallint CHECK (stealth_skill   IS NULL OR stealth_skill   >= 0),
  ADD COLUMN IF NOT EXISTS awareness_skill smallint CHECK (awareness_skill IS NULL OR awareness_skill >= 0),
  ADD COLUMN IF NOT EXISTS vitality        integer  CHECK (vitality        IS NULL OR vitality        >= 0);

COMMENT ON COLUMN public.rpg_creatures.attack_skill    IS 'Character scale. Its attacks roll this against the target''s Evade Enemy × 2.';
COMMENT ON COLUMN public.rpg_creatures.defense_skill   IS 'Character scale. Difficulty to hit it = rpg_difficulty(defense_skill, can_act): × 2 when it can act, × 1 asleep or held.';
COMMENT ON COLUMN public.rpg_creatures.strength_skill  IS 'Character scale. Contests of force (breaking a hold, shoving).';
COMMENT ON COLUMN public.rpg_creatures.will_skill      IS 'Character scale. Persuading, tricking or frightening it rolls against will × 2.';
COMMENT ON COLUMN public.rpg_creatures.stealth_skill   IS 'Character scale. Spotting it hidden rolls Vision or Listening against stealth × 2.';
COMMENT ON COLUMN public.rpg_creatures.awareness_skill IS 'Character scale. Sneaking past it rolls Quiet Movement or Blend With Surroundings against awareness × 2.';
COMMENT ON COLUMN public.rpg_creatures.vitality        IS 'Character scale. Damage it can take (a hero carries about 25 to 30). Replaces hit_points at the table.';

ALTER TABLE public.rpg_creature_actions
  ADD COLUMN IF NOT EXISTS skill      smallint CHECK (skill IS NULL OR skill >= 0),
  ADD COLUMN IF NOT EXISTS against    text,
  ADD COLUMN IF NOT EXISTS table_note text;

COMMENT ON COLUMN public.rpg_creature_actions.skill      IS 'Character scale. The skill the creature rolls for this action.';
COMMENT ON COLUMN public.rpg_creature_actions.against    IS 'rpg_stat_definitions.key the target defends with (EE, CO, ST ...). Difficulty = that stat × 2 while the target can act.';
COMMENT ON COLUMN public.rpg_creature_actions.table_note IS 'Plain-English line for the game master: what the roll is and what happens on a hit, with the numbers.';

-- 2. Bramblemaw's numbers.
UPDATE public.rpg_creatures SET
  attack_skill = 10, defense_skill = 8, strength_skill = 10, will_skill = 10, stealth_skill = 8, awareness_skill = 8,
  vitality = 150, updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'bramblemaw';

UPDATE public.rpg_creature_actions a SET skill = v.skill, against = v.against, table_note = v.table_note
FROM (VALUES
 ('Claw', 10, 'EE', 'Rolls 10 against the target''s Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 50 or more; a roll of 80 does 30). A hit also rolls 10 against their Strength × 2; if that lands the target is knocked down and cannot act until they get up, so hitting them costs only Evade Enemy × 1.'),
 ('Bite', 10, 'EE', 'Rolls 10 against Evade Enemy × 2. A target who is down or held cannot act, so their difficulty is Evade Enemy × 1 (Evade Enemy 5 → difficulty 5 → needs 34 or more; a roll of 80 does 46).'),
 ('Briar Roar', 8, 'CO', 'Rolls 8 against each target''s Courage × 2 (Courage 7 → difficulty 14 → needs 64 or more). Those it beats are frightened: on each of their turns they may roll Courage against difficulty 8 to shake it off (Courage 7 needs 54 or more).'),
 ('Grasping Roots', 7, 'ST', 'Rolls 7 against each target''s Strength × 2 (Strength 5 → difficulty 10 → needs 59 or more). Those it beats are held until the next round and cannot act, so hitting them costs only Evade Enemy × 1.'),
 ('Multiattack', NULL, NULL, 'Two Claw rolls and one Bite roll every round, and a Rending Swipe (one more Claw) from its legendary actions.'),
 ('Rending Swipe', NULL, NULL, 'One Claw roll.'),
 ('Rooted Resilience', NULL, NULL, 'At 0 vitality in a forest it sinks and lies inert. Burn or sanctify the body within a minute, or it heals 1 vitality and escapes underground after an hour.')
) AS v(name, skill, against, table_note)
WHERE a.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND a.name = v.name
  AND a.creature_id = (SELECT id FROM public.rpg_creatures WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'bramblemaw');

-- 3. The card reads the character-scale numbers through the saved functions (difficulty to hit it from rpg_difficulty).
CREATE OR REPLACE FUNCTION public.rpg_creature_card(p_creature_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'abilities', jsonb_build_array(
        jsonb_build_object('key', 'str', 'label', 'STR', 'score', v_c.str_score, 'mod', floor((v_c.str_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'dex', 'label', 'DEX', 'score', v_c.dex_score, 'mod', floor((v_c.dex_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'con', 'label', 'CON', 'score', v_c.con_score, 'mod', floor((v_c.con_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'int', 'label', 'INT', 'score', v_c.int_score, 'mod', floor((v_c.int_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'wis', 'label', 'WIS', 'score', v_c.wis_score, 'mod', floor((v_c.wis_score - 10) / 2.0)::int),
        jsonb_build_object('key', 'cha', 'label', 'CHA', 'score', v_c.cha_score, 'mod', floor((v_c.cha_score - 10) / 2.0)::int)),
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
    -- The character-scale numbers the table uses. Difficulties come from rpg_difficulty, never computed here.
    'table', jsonb_build_object(
        'attack_skill', v_c.attack_skill,
        'defense_skill', v_c.defense_skill,
        'difficulty_to_hit', CASE WHEN v_c.defense_skill IS NULL THEN NULL ELSE public.rpg_difficulty(v_c.defense_skill, true) END,
        'difficulty_to_hit_still', CASE WHEN v_c.defense_skill IS NULL THEN NULL ELSE public.rpg_difficulty(v_c.defense_skill, false) END,
        'vitality', v_c.vitality,
        'strength_skill', v_c.strength_skill,
        'will_skill', v_c.will_skill,
        'stealth_skill', v_c.stealth_skill,
        'awareness_skill', v_c.awareness_skill,
        'will_multiplier', public.rpg_setting('opponent_will_multiplier'),
        'attacks_roll_against', (SELECT d.name FROM public.rpg_stat_definitions d
                                  WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = 'EE')),
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
        'skill', a.skill, 'against', a.against,
        'against_name', (SELECT d.name FROM public.rpg_stat_definitions d
                          WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND d.key = a.against),
        'table_note', a.table_note,
        'recharge_min', a.recharge_min, 'legendary_cost', a.legendary_cost, 'makes_attacks', a.makes_attacks)
      ORDER BY array_position(ARRAY['trait','action','bonus_action','reaction','legendary','lair'], a.kind), a.sort_order), '[]'::jsonb)
      FROM public.rpg_creature_actions a WHERE a.creature_id = v_c.id));
END;
$function$;

-- 4. The list shows the game master the table numbers, not the d20 ones.
CREATE OR REPLACE FUNCTION public.rpg_creature_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm)
  SELECT coalesce(jsonb_agg(
           jsonb_build_object('id', c.id, 'key', c.key, 'name', c.name, 'color', c.color, 'epigraph', c.epigraph)
           || CASE WHEN gm.is_gm THEN jsonb_build_object('challenge', c.challenge, 'armor_class', c.armor_class,
                'hit_points', c.hit_points, 'attack_skill', c.attack_skill, 'defense_skill', c.defense_skill,
                'vitality', c.vitality, 'shown_to_players', c.shown_to_players) ELSE '{}'::jsonb END
           ORDER BY c.sort_order, c.name), '[]'::jsonb)
  FROM public.rpg_creatures c CROSS JOIN gm
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
    AND (SELECT public.rpg_can_play()) AND (gm.is_gm OR c.shown_to_players);
$function$;

-- 5. The creature rule, rewritten in place (the manual page follows by trigger).
UPDATE public.rpg_rules SET
  body = 'Every creature carries the same kind of numbers a character has, set by the game master on the character scale: Attack, Defense, Strength, Will, Stealth and Awareness (1 to 10 like a rolled character; a legendary creature sits at the top) and Vitality (a hero carries about 25 to 30).
*The Bramblemaw: Attack 10, Defense 8, Strength 10, Will 10, Stealth 8, Awareness 8, Vitality 150. Five heroes'' worth of wounds. Its hide turning ordinary blades is in that number.*

Its attacks are rolls like anyone''s: it rolls its Attack against the target''s Evade Enemy × 2, and damage is the die − Needed.
*Attack 10 against a hero with Evade Enemy 5: difficulty 10, needs 50 or more, lands about half the time, and a roll of 80 does 30.*
Each special action names the skill it rolls and the stat the target defends with. *Its roar rolls 8 against Courage × 2. Its roots roll 7 against Strength × 2.* A target who is knocked down or held cannot act, so their difficulty drops to Evade Enemy × 1.

Hitting it: your weapon skill against its Defense × 2. *Sword 6 against Defense 8: difficulty 16, needs 73 or more, lands about one time in four, and a roll of 90 does 17.* Asleep or held it cannot act, so its Defense × 1. *Difficulty 8, sword 6 needs 58 or more.*
Persuading, tricking or frightening it: your skill against its Will × 2. Sneaking past it: Quiet Movement or Blend With Surroundings against its Awareness × 2. Spotting it hidden: Vision or Listening against its Stealth × 2.

The d20 stat block printed on a card (armor class, hit points, saving throws, +to hit, DCs) is kept for reading and flavor. It does not drive any roll.',
  source = 'peter',
  updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'creature_conversion';

-- 6. Guards.
DO $$
DECLARE v_card jsonb; v_page text; v_n integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
  SELECT public.rpg_creature_card(id) INTO v_card FROM public.rpg_creatures WHERE key = 'bramblemaw';
  IF (v_card->'table'->>'attack_skill')::int <> 10 OR (v_card->'table'->>'difficulty_to_hit')::numeric <> 16
     OR (v_card->'table'->>'difficulty_to_hit_still')::numeric <> 8 OR (v_card->'table'->>'vitality')::int <> 150 THEN
    RAISE EXCEPTION 'Bramblemaw table numbers wrong: %', v_card->'table';
  END IF;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v_card->'actions') a WHERE a->>'skill' IS NOT NULL AND a->>'against_name' IS NOT NULL;
  IF v_n <> 4 THEN RAISE EXCEPTION 'expected 4 actions with a skill and a defending stat, found %', v_n; END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT content INTO v_page FROM public.manuals WHERE id = 'd2ed2aac-1621-4ce2-860c-095ecfc15ade';
  IF position('Vitality 150' in v_page) = 0 THEN RAISE EXCEPTION 'manual page did not follow the creature rule'; END IF;
END $$;
