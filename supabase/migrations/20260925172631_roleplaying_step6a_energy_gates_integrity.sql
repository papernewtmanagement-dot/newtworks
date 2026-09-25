-- Roleplaying step 6a: energy, the three gates of an attack, and integrity (Peter 2026-09-25, spec "character model 2.0").
-- Energy: two pools on every fighter, physical and spiritual. Each action and weapon costs one of them; the pools
-- refill at the start of the fighter's turn by a rules-driven regain (derived stats on the sheet: Physical Energy =
-- Endurance × 3, regain Endurance ÷ 2; Spiritual Energy = Shield of Faith × 3, regain Hope ÷ 2; creatures from
-- strength and will). Cooldowns are gone; beats stay. Rest = the whole turn, one more regain. Defend = the whole
-- turn, rolls against you use × 3. Attacks run three gates, each a roll: land (vs evade × 2, burden lowers evade),
-- block (vs block × 2 when the defender holds something that blocks; spiritually the Shield of Faith), hit (damage
-- minus what armor absorbs; the object struck takes the blow's damage by the same rule as a person, rpg_damage).
-- Every object has integrity (its life); at 0 it stops working.

ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS role text NOT NULL DEFAULT 'wear' CHECK (role IN ('weapon', 'shield', 'armor', 'wear'));
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS weapon_key text;
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS block integer NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS absorb integer NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS weight numeric NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS integrity integer NOT NULL DEFAULT 20;
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS integrity_damage integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.rpg_items.role IS 'weapon (attacks with weapon_key), shield (blocks with block), armor (absorbs absorb), wear (anything else). integrity is the object''s life; integrity_damage what it has taken.';
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS spiritual_burden integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.rpg_characters.spiritual_burden IS 'Sins and bad decisions weighing on the character; lowers spiritual evade. Worked off by Bible study and prayer.';
ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS energy_cost integer NOT NULL DEFAULT 3;
ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS energy_type text NOT NULL DEFAULT 'physical' CHECK (energy_type IN ('physical', 'spiritual'));
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS energy_cost integer NOT NULL DEFAULT 4;
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS energy_type text NOT NULL DEFAULT 'physical' CHECK (energy_type IN ('physical', 'spiritual'));
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS energy_used_physical integer NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS energy_used_spiritual integer NOT NULL DEFAULT 0;

INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.value, v.label FROM (VALUES
  ('defend_multiplier', 3, 'Defending: rolls against you use your skill × this instead of × 2'),
  ('carry_per_strength', 2, 'Weight a character carries without burden = Strength × this')) v(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.key = v.key);

-- Energy and block as derived stats on the sheet, editable formulas like every other one.
INSERT INTO public.rpg_stat_definitions (agency_id, key, name, abbr, grp, kind, trainable, formula, sort_order, is_attack)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.name, v.abbr, v.grp, 'derived', false, v.formula::jsonb, v.so, false FROM (VALUES
  ('PEN', 'Physical Energy', 'PEN', 'physical', '{"div": 1, "parts": [["EN", 3]]}', 40),
  ('PER', 'Physical Energy Regain', 'PER', 'physical', '{"div": 2, "parts": [["EN", 1]]}', 41),
  ('SEN', 'Spiritual Energy', 'SEN', 'spiritual', '{"div": 1, "parts": [["SF", 3]]}', 70),
  ('SER', 'Spiritual Energy Regain', 'SER', 'spiritual', '{"div": 2, "parts": [["HO", 1]]}', 71),
  ('BLK', 'Block', 'BLK', 'ability', '{"div": 3, "parts": [["ST", 1], ["AG", 1], ["SC", 1]]}', 95)) v(key, name, abbr, grp, formula, so)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.key = v.key);
-- Weapon energy costs by weight; creature action costs.
UPDATE public.rpg_stat_definitions SET energy_cost = CASE key WHEN 'dagger' THEN 3 WHEN 'sling' THEN 3 WHEN 'hand_to_hand' THEN 3 WHEN 'tossing' THEN 3 WHEN 'quarterstaff' THEN 4 WHEN 'crossbow' THEN 4 WHEN 'hurling' THEN 4
  WHEN 'sword' THEN 5 WHEN 'hand_axe' THEN 5 WHEN 'spear' THEN 5 WHEN 'longbow' THEN 5 WHEN 'flail' THEN 6 WHEN 'military_fork' THEN 6 WHEN 'lance' THEN 7 WHEN 'battle_axe' THEN 8 WHEN 'war_hammer' THEN 8 ELSE energy_cost END
 WHERE is_attack;
UPDATE public.rpg_creature_actions SET energy_cost = CASE name WHEN 'Claw' THEN 3 WHEN 'Bite' THEN 6 WHEN 'Briar Roar' THEN 10 WHEN 'Rootstep' THEN 2 WHEN 'Rending Swipe' THEN 6 WHEN 'Sink Into Soil' THEN 4
    WHEN 'Grasping Roots' THEN 6 WHEN 'Living Silence' THEN 4 WHEN 'Briar Shift' THEN 4 WHEN 'Talon Dive' THEN 5 WHEN 'Hunting Screech' THEN 8 WHEN 'Shell Slam' THEN 7 WHEN 'Snapping Bite' THEN 3
    WHEN 'Lure' THEN 8 WHEN 'Cold Touch' THEN 3 WHEN 'Gore' THEN 5 WHEN 'Charge' THEN 6 ELSE energy_cost END,
  energy_type = CASE WHEN name IN ('Briar Roar', 'Grasping Roots', 'Living Silence', 'Briar Shift', 'Hunting Screech', 'Lure', 'Cold Touch') THEN 'spiritual' ELSE 'physical' END
 WHERE kind <> 'trait';

-- Rule cards.
UPDATE public.rpg_rules
   SET body = replace(body, 'Each action also has a cooldown in turns: a quick Claw has none, Bite is back next turn, Briar Roar three turns later.',
     'Every action also costs energy, physical or spiritual, and the pools refill each turn: see the Energy card.')
 WHERE key = 'turn_order';
INSERT INTO public.rpg_rules (key, title, body, source, sort_order, section)
SELECT v.key, v.title, v.body, 'engine', v.so, 'Fights' FROM (VALUES
  ('energy', 'Energy', E'Everyone has two pools: physical energy and spiritual energy. Every action and every weapon costs one of them (a Claw 3 physical, a sword swing 5, Briar Roar 10 spiritual). The pools refill at the start of your turn by your regain. Both are numbers on your sheet: Physical Energy = Endurance × 3 and regains Endurance ÷ 2 a turn (Endurance 8 → pool 24, regain 4); Spiritual Energy = Shield of Faith × 3 and regains Hope ÷ 2. A creature''s pools come from its strength and will the same way (Bramblemaw: 30 and 30, regains 5 and 5).\n\nA move you cannot pay for is not offered. Rest takes the whole turn and gives one more regain on top. Defend takes the whole turn: until your next turn, rolls against you face your evade × 3 instead of × 2 (Evade Enemy 5 → difficulty 15, needs 75 instead of 67). Too tired for anything else? Rest or Defend.', 42),
  ('attack_gates', 'Land, Block, Hit', E'An attack passes three gates, each its own roll.\n\n1. Land: the attacker''s skill against the defender''s evade × 2 (Evade Enemy for a blow; Boots of the Gospel of Peace for a spiritual attack; a creature''s defense or will). A die under what a still target would need is a Miss (a bad swing); a die between that and the real number is Evaded. Burden lowers evade: weight carried past Strength × 2, or a spiritual burden of sins and bad decisions.\n\n2. Block: if the defender holds something that blocks (a shield, a weapon; the Shield of Faith against a spiritual attack), the attacker rolls again against Block × 2 (Block = Strength, Agility and Self-Control averaged, plus the shield''s block). A fail is Blocked: nothing gets through, and the blocking thing takes the blow.\n\n3. Hit: damage is die − Needed as always. Worn armor absorbs its absorb value first and takes that much itself (spiritually the Breastplate of Righteousness for attacks on the heart such as fear, the Helmet of Salvation for attacks on the mind such as lies). What is left reaches the target.\n\nObjects take damage by the same rule as people: whatever the blow would do, the shield or armor takes. A weapon that strikes something hard takes a fifth of that. Every object has integrity, its life; at 0 it stops working until it is repaired, at a shop for the physical, by Bible study and prayer for the armor of God.', 45)) v(key, title, body, so)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_rules r WHERE r.key = v.key);

DROP FUNCTION IF EXISTS public.rpg_difficulty(numeric, boolean);
CREATE FUNCTION public.rpg_difficulty(p_skill numeric, p_can_act boolean DEFAULT true, p_defending boolean DEFAULT false)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A defender's difficulty: their skill × opponent_will_multiplier when they can act (skill and will), × defend_multiplier
-- when they are Defending, their skill when they cannot act. Skill 5: can act → 10; defending → 15; asleep → 5.
-- The play engine and the Rules tab calculator both call this; nothing re-implements it.
SELECT public.require_login('family');
  SELECT greatest(coalesce(p_skill, 0), 0) * CASE WHEN NOT p_can_act THEN 1 WHEN p_defending THEN public.rpg_setting('defend_multiplier') ELSE public.rpg_setting('opponent_will_multiplier') END;
$function$;
GRANT EXECUTE ON FUNCTION public.rpg_difficulty(numeric, boolean, boolean) TO authenticated;

DROP FUNCTION IF EXISTS public.rpg_outcome(integer, numeric, numeric, boolean, integer);
CREATE FUNCTION public.rpg_outcome(p_roll integer, p_needed numeric, p_critical numeric, p_damage_roll boolean, p_damage integer, p_needed_still numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The word the log leads with and its key for color (rule card "What the Log Says"). p_needed_still is what a still
-- target would need: a fail above it was the defender's doing. Attacks: Wild miss (30 or more under), Miss, Evaded
-- (above the still line), Weak hit (1 to 5 damage), Solid hit (6 to 20), Big hit (21 or more), Critical hit.
-- Other rolls: Fail, Resisted, Success, Critical success. Blocked is set by the fight itself.
SELECT CASE
  WHEN p_roll < p_needed THEN CASE WHEN p_needed_still IS NOT NULL AND p_roll >= p_needed_still THEN jsonb_build_object('key', 'evaded', 'label', CASE WHEN p_damage_roll THEN 'Evaded' ELSE 'Resisted' END)
                                   WHEN NOT p_damage_roll THEN jsonb_build_object('key', 'fail', 'label', 'Fail')
                                   WHEN p_roll <= p_needed - 30 THEN jsonb_build_object('key', 'wild_miss', 'label', 'Wild miss')
                                   ELSE jsonb_build_object('key', 'miss', 'label', 'Miss') END
  WHEN p_roll >= p_critical THEN jsonb_build_object('key', 'critical', 'label', CASE WHEN p_damage_roll THEN 'Critical hit' ELSE 'Critical success' END)
  WHEN NOT p_damage_roll THEN jsonb_build_object('key', 'success', 'label', 'Success')
  WHEN p_damage <= 5 THEN jsonb_build_object('key', 'weak_hit', 'label', 'Weak hit')
  WHEN p_damage <= 20 THEN jsonb_build_object('key', 'hit', 'label', 'Solid hit')
  ELSE jsonb_build_object('key', 'big_hit', 'label', 'Big hit') END;
$function$;
GRANT EXECUTE ON FUNCTION public.rpg_outcome(integer, numeric, numeric, boolean, integer, numeric) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpg_participant_value(p_participant_id uuid, p_stat_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One participant's value for one stat. Characters read their sheet (rpg_sheet), so items and earned levels count.
-- Creatures read the character-scale column that plays that stat: Evade Enemy EE → defense_skill, Courage CO →
-- will_skill, Strength ST → strength_skill, Agility AG → agility_skill, Physical Vitality PV → vitality, Boots of the
-- Gospel of Peace BGP and Shield of Faith SF → will_skill; energy: PEN strength × 3, PER strength ÷ 2, SEN will × 3,
-- SER will ÷ 2; and their own skills by name. An effect with a bonus for that stat adds to it (Dug in: defense 8 + 4).
-- Karen: EE → 5, AG → 1. Bramblemaw: EE → 8, CO → 10, ST → 10, AG → 7, PV → 150, PEN → 30, PER → 5.
DECLARE v_p record; v_c record; v_val numeric; v_key text; v_bonus numeric;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  IF v_p.character_id IS NOT NULL THEN
    v_key := p_stat_key;
    SELECT (s->>'value')::numeric INTO v_val
      FROM jsonb_array_elements(public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'))->'stats') s
     WHERE s->>'key' = p_stat_key;
  ELSE
    SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
    v_key := CASE p_stat_key WHEN 'EE' THEN 'defense' WHEN 'CO' THEN 'will' WHEN 'ST' THEN 'strength' WHEN 'AG' THEN 'agility' WHEN 'PV' THEN 'vitality'
                             WHEN 'BGP' THEN 'will' WHEN 'SF' THEN 'will' ELSE p_stat_key END;
    v_val := CASE v_key
      WHEN 'defense' THEN v_c.defense_skill WHEN 'will' THEN v_c.will_skill WHEN 'strength' THEN v_c.strength_skill
      WHEN 'agility' THEN v_c.agility_skill WHEN 'vitality' THEN v_c.vitality WHEN 'attack' THEN v_c.attack_skill
      WHEN 'stealth' THEN v_c.stealth_skill WHEN 'awareness' THEN v_c.awareness_skill
      WHEN 'PEN' THEN v_c.strength_skill * 3 WHEN 'PER' THEN ceil(v_c.strength_skill / 2.0)
      WHEN 'SEN' THEN v_c.will_skill * 3 WHEN 'SER' THEN ceil(v_c.will_skill / 2.0) END;
  END IF;
  IF v_val IS NULL THEN RETURN NULL; END IF;
  SELECT coalesce(sum((e->'bonus'->>v_key)::numeric), 0) INTO v_bonus FROM jsonb_array_elements(v_p.effects) e WHERE e ? 'bonus';
  RETURN v_val + v_bonus;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_energy(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Both pools for one fighter: max and regain from the rules (rpg_participant_value PEN/PER/SEN/SER), left = max
-- minus what has been spent (energy_used_*). Bramblemaw: physical 30, regain 5; a fresh fight starts full.
SELECT jsonb_build_object(
  'physical', jsonb_build_object('max', coalesce(public.rpg_participant_value(p.id, 'PEN'), 0)::integer,
                                 'left', greatest(coalesce(public.rpg_participant_value(p.id, 'PEN'), 0)::integer - p.energy_used_physical, 0),
                                 'regain', coalesce(public.rpg_participant_value(p.id, 'PER'), 0)::integer),
  'spiritual', jsonb_build_object('max', coalesce(public.rpg_participant_value(p.id, 'SEN'), 0)::integer,
                                  'left', greatest(coalesce(public.rpg_participant_value(p.id, 'SEN'), 0)::integer - p.energy_used_spiritual, 0),
                                  'regain', coalesce(public.rpg_participant_value(p.id, 'SER'), 0)::integer))
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_action_ready(p_participant_id uuid, p_action_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a creature can use an action right now: its pool of that energy holds the cost (Claw 3 physical against
-- physical energy left). Cooldowns are gone; energy is the limit.
SELECT (public.rpg_participant_energy(p_participant_id)->a.energy_type->>'left')::integer >= a.energy_cost
  FROM public.rpg_creature_actions a WHERE a.id = p_action_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_burden(p_participant_id uuid, p_kind text)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What weighs a character down. Physical: weight carried (equipped items) past Strength × carry_per_strength
-- (Strength 10 carries 20; 26 carried → burden 6). Spiritual: the character's spiritual burden. Creatures carry none.
SELECT CASE WHEN c.id IS NULL THEN 0
            WHEN p_kind = 'spiritual' THEN c.spiritual_burden
            ELSE greatest(coalesce((SELECT sum(i.weight) FROM public.rpg_items i WHERE i.character_id = c.id AND i.equipped), 0)
                          - coalesce(public.rpg_participant_value(p.id, 'ST'), 0) * public.rpg_setting('carry_per_strength'), 0) END
  FROM public.rpg_session_participants p LEFT JOIN public.rpg_characters c ON c.id = p.character_id WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_item_damage(p_item_id uuid, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- An object takes damage like a person does: its integrity_damage goes up, capped at its integrity. Returns what is
-- left and whether it broke on this blow. A shield of integrity 20 that has taken 15 and now takes 8 → 0 left, broke.
DECLARE v_i record; v_left integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_i FROM public.rpg_items WHERE id = p_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'item not found'; END IF;
  UPDATE public.rpg_items SET integrity_damage = least(integrity_damage + greatest(p_amount, 0), integrity) WHERE id = p_item_id
  RETURNING integrity - integrity_damage INTO v_left;
  RETURN jsonb_build_object('item_id', p_item_id, 'name', v_i.name, 'left', v_left, 'broke', v_left <= 0 AND v_i.integrity - v_i.integrity_damage > 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text,
  p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric,
  p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One move in a fight, by the one whose turn it is. Every roll goes through rpg_roll.
--   REST / DEFEND (p_stat_key) take the whole turn: Rest gives one more regain; Defend puts "Defending" on you until
--   your next turn so rolls against you face your skill × 3 (rpg_difficulty).
--   A character attacks with a weapon skill; a creature uses a card action. Both cost beats of the turn and energy
--   (energy_cost of that energy_type); a move you cannot pay for is refused.
--   An attack runs three gates (rule card "Land, Block, Hit"). Land: the skill against the target's evade × 2
--   (rpg_difficulty; evade lowered by rpg_participant_burden). Under the still-target line is a Miss, above it Evaded.
--   Block: a character holding a shield or weapon blocks with Block + the item's block, × 2; a spiritual attack that
--   lands an effect is blocked by the Shield of Faith. Fail = Blocked; the blocking item takes the blow's damage
--   (rpg_item_damage) and the weapon a fifth of it. Hit: rpg_damage minus what worn armor absorbs (the armor takes
--   that; the weapon a fifth); the rest reaches the target. A landed effect goes on the target as the card says
--   (Briar Roar → Frightened; a Claw hit → Strength contest → Knocked down). Legendary actions may be used on other
--   turns by the game master or the rules engine (rpg.engine). A check a rule demands (p_effect) comes before an
--   attack. p_roll is a die rolled by hand: a manual critical waits for rpg_act_extra.
DECLARE
  v_gm boolean := public.family_is_parent() OR current_setting('rpg.engine', true) = 'on';
  v_actor record; v_s record; v_act record; v_use record; v_t record; v_item record;
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_skill numeric; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text;
  v_tid uuid; v_cid uuid; v_def numeric; v_diff numeric; v_diff_still numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_net integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
  v_eff jsonb; v_fx jsonb; v_out jsonb; v_pending boolean; v_tail text; v_who text; v_xtext text;
  v_croll jsonb; v_cskill numeric; v_cdiff numeric; v_per integer := public.rpg_setting('beats_per_turn')::integer;
  v_plan jsonb := '[]'::jsonb; v_step jsonb; v_e jsonb; v_n integer; v_beats integer := 0;
  v_ecost integer := 0; v_etype text := 'physical'; v_energy jsonb; v_defending boolean;
  v_blk numeric; v_blocker uuid; v_blocker_name text; v_broll jsonb; v_blocked boolean; v_absorb integer; v_wear jsonb; v_weapon uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status = 'setup' THEN RAISE EXCEPTION 'the fight has not started yet'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN
    IF NOT (v_gm AND v_actor.creature_id IS NOT NULL AND p_action_id IS NOT NULL
            AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.id = p_action_id AND a.kind = 'legendary')) THEN
      RAISE EXCEPTION 'it is not %''s turn', v_actor.name;
    END IF;
  END IF;
  IF NOT v_gm AND v_actor.character_id IS NULL THEN RAISE EXCEPTION 'the game master rolls for %', v_actor.name; END IF;
  IF NOT v_actor.can_act THEN RAISE EXCEPTION '% cannot act%', v_actor.name, coalesce(': ' || v_actor.status_note, ''); END IF;
  IF (public.rpg_participant_vitality(p_actor_id)->>'left')::integer <= 0 THEN RAISE EXCEPTION '% is down', v_actor.name; END IF;
  SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e WHERE coalesce((e->>'cannot_act')::boolean, false) LIMIT 1;
  IF v_who IS NOT NULL AND p_effect IS DISTINCT FROM v_who THEN RAISE EXCEPTION '% is % and cannot act', v_actor.name, v_who; END IF;
  IF p_actor_id = ANY (v_targets) THEN RAISE EXCEPTION 'choose someone else to aim at'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_targets) t(id)
              WHERE NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.id = t.id AND p.session_id = v_s.id)) THEN
    RAISE EXCEPTION 'every target must be in this fight';
  END IF;
  v_energy := public.rpg_participant_energy(p_actor_id);

  -- Rest and Defend: the whole turn.
  IF p_stat_key IN ('REST', 'DEFEND') THEN
    IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'it is not %''s turn', v_actor.name; END IF;
    IF v_s.turn_beats > 0 THEN RAISE EXCEPTION '% has already used part of this turn', v_actor.name; END IF;
    IF p_stat_key = 'REST' THEN
      UPDATE public.rpg_session_participants SET energy_used_physical = greatest(energy_used_physical - (v_energy->'physical'->>'regain')::integer, 0),
             energy_used_spiritual = greatest(energy_used_spiritual - (v_energy->'spiritual'->>'regain')::integer, 0) WHERE id = p_actor_id;
      v_text := v_actor.name || ' rests and regains ' || (v_energy->'physical'->>'regain') || ' physical and ' || (v_energy->'spiritual'->>'regain') || ' spiritual energy.';
    ELSE
      PERFORM public.rpg_participant_apply_effect(p_actor_id, '{"name": "Defending", "cannot_act": false, "clear": "turn_start", "defend": true}'::jsonb, 'Defend', v_s.round);
      v_text := v_actor.name || ' defends: until ' || CASE WHEN v_actor.character_id IS NOT NULL THEN 'their' ELSE 'its' END || ' next turn, rolls against ' || CASE WHEN v_actor.character_id IS NOT NULL THEN 'them' ELSE 'it' END || ' face evade × ' || trim_scale(public.rpg_setting('defend_multiplier')) || '.';
    END IF;
    UPDATE public.rpg_sessions SET turn_beats = v_per, updated_at = now() WHERE id = v_s.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_text);
    RETURN jsonb_build_object('kind', lower(p_stat_key), 'label', initcap(lower(p_stat_key)), 'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
  END IF;

  IF p_effect IS NOT NULL THEN
    SELECT e INTO v_eff FROM jsonb_array_elements(v_actor.effects) e WHERE e->>'name' = p_effect AND e->>'clear' = 'check';
    IF v_eff IS NULL THEN RAISE EXCEPTION '% is not % right now', v_actor.name, p_effect; END IF;
    IF v_actor.character_id IS NULL THEN RAISE EXCEPTION 'only characters shake off effects'; END IF;
    IF (v_eff->>'checked_round')::integer = v_s.round THEN RAISE EXCEPTION '% already tried this round', v_actor.name; END IF;
    v_kind := 'check'; v_key := v_eff->>'check_stat'; v_targets := '{}';
    SELECT name INTO v_label FROM public.rpg_stat_definitions WHERE key = v_key;
    v_diff := (v_eff->>'check_difficulty')::numeric;
  ELSIF v_actor.character_id IS NOT NULL THEN
    SELECT name, is_attack, beats, energy_cost, energy_type INTO v_stat_name, v_is_attack, v_beats, v_ecost, v_etype FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'choose a skill'; END IF;
    v_key := p_stat_key; v_label := v_stat_name;
    IF cardinality(v_targets) > 0 THEN
      IF NOT v_is_attack THEN RAISE EXCEPTION 'choose a weapon skill to attack with'; END IF;
      IF cardinality(v_targets) > 1 THEN RAISE EXCEPTION 'attack one target at a time'; END IF;
      IF v_s.turn_beats + v_beats > v_per THEN RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_stat_name, v_beats; END IF;
      IF (v_energy->v_etype->>'left')::integer < v_ecost THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e
       WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1;
      IF v_who IS NOT NULL THEN RAISE EXCEPTION '% must shake off % first', v_actor.name, v_who; END IF;
      v_kind := 'attack'; v_against := 'EE'; v_damage_ok := true;
      SELECT id INTO v_weapon FROM public.rpg_items WHERE character_id = v_actor.character_id AND equipped AND role = 'weapon' AND weapon_key = p_stat_key AND integrity_damage < integrity ORDER BY sort_order LIMIT 1;
    ELSE
      v_kind := 'check'; v_beats := 0; v_ecost := 0;
      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
    END IF;
  ELSIF p_action_id IS NOT NULL THEN
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;
    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN
      RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_act.energy_type->>'left', v_act.energy_type, v_act.name, v_act.energy_cost;
    END IF;
    IF (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(v_act.makes_attacks, '[]'::jsonb)) e) > 1 THEN
      RAISE EXCEPTION '% makes one attack a turn; % is not used. Pick one of its attacks', v_actor.name, v_act.name;
    END IF;
    IF v_act.kind IN ('action', 'bonus_action') AND v_s.current_participant_id = p_actor_id THEN
      IF v_s.turn_beats + v_act.beats > v_per THEN
        RAISE EXCEPTION '% has % of % beats left this turn and % takes %', v_actor.name, v_per - v_s.turn_beats, v_per, v_act.name, v_act.beats;
      END IF;
      v_beats := v_act.beats;
    END IF;
    v_ecost := v_act.energy_cost; v_etype := v_act.energy_type;
    v_kind := 'action'; v_label := v_act.name;
    IF jsonb_typeof(v_act.makes_attacks) = 'array' AND jsonb_array_length(v_act.makes_attacks) > 0 THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOR v_e IN SELECT e FROM jsonb_array_elements(v_act.makes_attacks) e LOOP
        SELECT id INTO v_cid FROM public.rpg_creature_actions WHERE creature_id = v_actor.creature_id AND name = v_e->>'action' LIMIT 1;
        IF NOT FOUND THEN RAISE EXCEPTION '% names an attack that is not on the card', v_act.name; END IF;
        FOR v_n IN 1..greatest(coalesce((v_e->>'count')::integer, 1), 1) LOOP
          v_plan := v_plan || jsonb_build_object('a', v_cid, 't', v_targets[1 + floor(random() * cardinality(v_targets))::integer]);
        END LOOP;
      END LOOP;
    ELSIF v_act.skill IS NOT NULL THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('a', v_act.id, 't', v_tid); END LOOP;
    END IF;
  ELSE
    IF p_stat_key IS NULL OR p_stat_key NOT IN ('attack', 'defense', 'strength', 'will', 'stealth', 'awareness', 'agility') THEN
      RAISE EXCEPTION 'choose one of the creature''s skills';
    END IF;
    v_skill := public.rpg_participant_value(p_actor_id, p_stat_key);
    IF v_skill IS NULL THEN RAISE EXCEPTION '% has no % skill on its card', v_actor.name, p_stat_key; END IF;
    v_kind := 'check'; v_key := initcap(p_stat_key); v_label := initcap(p_stat_key); v_against := p_against;
    v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
    IF cardinality(v_targets) > 0 AND v_against IS NULL THEN RAISE EXCEPTION 'choose what it rolls against'; END IF;
  END IF;
  IF v_kind <> 'action' THEN
    FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('t', v_tid); END LOOP;
    IF cardinality(v_targets) > 0 THEN
      SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
      IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
    END IF;
  END IF;

  IF v_kind = 'action' AND jsonb_array_length(v_plan) = 0 THEN
    IF v_act.effect->>'on' = 'self' THEN
      PERFORM public.rpg_participant_apply_effect(p_actor_id, v_act.effect->'apply', v_act.name, v_s.round);
    END IF;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_actor.name || ' uses ' || v_act.name || '.'
            || CASE WHEN v_act.effect->>'on' = 'self' THEN ' It is ' || (v_act.effect->'apply'->>'name') || '.' ELSE '' END);
  ELSIF cardinality(v_targets) = 0 THEN
    v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                              CASE WHEN v_actor.character_id IS NULL THEN v_skill END, p_roll);
    v_first := v_roll; v_extras := '{}'; v_i := 0; v_pending := false;
    IF p_roll IS NOT NULL THEN
      v_pending := coalesce((v_roll->>'extra_pending')::boolean, false);
    ELSE
      WHILE coalesce((v_roll->>'extra_pending')::boolean, false) AND v_i < 20 LOOP
        v_roll := public.rpg_roll_extra((v_roll->>'roll_id')::uuid);
        v_extras := v_extras || (v_roll->>'roll')::integer; v_i := v_i + 1;
      END LOOP;
    END IF;
    v_needs := ceil((v_first->>'needed')::numeric)::integer;
    v_out := public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, false, 0);
    v_levelup := CASE WHEN (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                      THEN ' ' || v_actor.name || '''s ' || v_label || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
    v_tail := '';
    IF p_effect IS NOT NULL THEN
      IF v_first->>'result' <> '' THEN
        UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> p_effect)
         WHERE p.id = p_actor_id;
        v_tail := ' ' || v_actor.name || ' shakes off ' || p_effect || '.';
      ELSE
        UPDATE public.rpg_session_participants p
           SET effects = (SELECT coalesce(jsonb_agg(CASE WHEN e->>'name' = p_effect THEN e || jsonb_build_object('checked_round', v_s.round) ELSE e END), '[]'::jsonb)
                            FROM jsonb_array_elements(p.effects) e)
         WHERE p.id = p_actor_id;
        IF v_eff->>'on_fail' = 'no_attack' THEN
          UPDATE public.rpg_sessions SET turn_beats = v_per WHERE id = v_s.id;
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || ' and cannot attack this turn.';
        ELSE
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || '.';
        END IF;
      END IF;
    END IF;
    v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
    v_text := (v_out->>'label') || ': ' || v_actor.name || ' rolls ' || v_label || ' against ' || trim_scale(v_diff)
              || CASE WHEN p_effect IS NOT NULL THEN ' to shake off ' || p_effect ELSE '' END
              || '. Rolled ' || (v_first->>'roll') || ', needs ' || v_needs || '.' || v_xtext
              || CASE WHEN v_pending THEN ' Roll again and enter it.' ELSE '' END || v_tail || v_levelup;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, roll_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', v_out->>'key', p_actor_id, (v_first->>'roll_id')::uuid, v_text);
    v_results := v_results || jsonb_build_array(jsonb_build_object('roll_id', v_first->'roll_id', 'roll', v_first->'roll', 'needed', v_first->'needed',
                   'result', v_first->'result', 'outcome', v_out->>'key', 'extras', to_jsonb(v_extras), 'extra_pending', v_pending,
                   'difficulty', v_diff, 'text', v_text));
  ELSE
    FOR v_step IN SELECT s FROM jsonb_array_elements(v_plan) s LOOP
      v_tid := (v_step->>'t')::uuid;
      IF v_kind = 'action' AND jsonb_array_length(v_plan) > 1 AND (public.rpg_participant_vitality(v_tid)->>'left')::integer <= 0 THEN
        SELECT p.id INTO v_tid FROM public.rpg_session_participants p
         WHERE p.id = ANY (v_targets) AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0 ORDER BY random() LIMIT 1;
        EXIT WHEN v_tid IS NULL;
      END IF;
      IF v_kind = 'action' THEN
        SELECT * INTO v_use FROM public.rpg_creature_actions WHERE id = (v_step->>'a')::uuid;
        IF v_use.skill IS NULL THEN RAISE EXCEPTION '% has no roll on the card', v_use.name; END IF;
        v_key := v_use.name; v_skill := v_use.skill; v_against := v_use.against; v_damage_ok := coalesce(v_use.deals_damage, false); v_fx := v_use.effect;
        SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
      END IF;
      SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_defending := EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE coalesce((e->>'defend')::boolean, false));
      -- Gate 1: land. Evade lowered by burden.
      v_def := greatest(coalesce(public.rpg_participant_value(v_tid, v_against), 0)
                        - CASE WHEN v_against IN ('EE', 'BGP') THEN public.rpg_participant_burden(v_tid, CASE WHEN v_against = 'BGP' THEN 'spiritual' ELSE 'physical' END) ELSE 0 END, 0);
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid), v_defending);
      v_diff_still := public.rpg_difficulty(v_def, false);
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                                CASE WHEN v_actor.character_id IS NULL THEN v_skill END,
                                CASE WHEN jsonb_array_length(v_plan) = 1 THEN p_roll END);
      v_first := v_roll; v_extras := '{}'; v_i := 0; v_pending := false;
      IF p_roll IS NOT NULL AND jsonb_array_length(v_plan) = 1 THEN
        v_pending := coalesce((v_roll->>'extra_pending')::boolean, false);
      ELSE
        WHILE coalesce((v_roll->>'extra_pending')::boolean, false) AND v_i < 20 LOOP
          v_roll := public.rpg_roll_extra((v_roll->>'roll_id')::uuid);
          v_extras := v_extras || (v_roll->>'roll')::integer; v_i := v_i + 1;
        END LOOP;
      END IF;
      v_needs := ceil((v_first->>'needed')::numeric)::integer;
      v_dmg := CASE WHEN v_damage_ok THEN public.rpg_damage((v_first->>'roll_id')::uuid) ELSE 0 END;
      v_tail := ''; v_blocked := false; v_net := v_dmg; v_absorb := 0;
      -- Gate 2: block. A character holding a shield or weapon; the Shield of Faith against a spiritual effect.
      IF v_first->>'result' <> '' AND v_t.character_id IS NOT NULL AND (v_damage_ok OR (v_fx IS NOT NULL AND v_use.energy_type = 'spiritual')) THEN
        v_blk := NULL; v_blocker := NULL; v_blocker_name := NULL;
        IF v_damage_ok THEN
          SELECT i.id, i.name, i.block INTO v_blocker, v_blocker_name, v_blk FROM public.rpg_items i
           WHERE i.character_id = v_t.character_id AND i.equipped AND i.role IN ('shield', 'weapon') AND i.integrity_damage < i.integrity
           ORDER BY i.block DESC, i.sort_order LIMIT 1;
          IF v_blocker IS NOT NULL THEN v_blk := coalesce(public.rpg_participant_value(v_tid, 'BLK'), 0) + coalesce(v_blk, 0); END IF;
        ELSE
          v_blk := public.rpg_participant_value(v_tid, 'SF'); v_blocker_name := 'Shield of Faith';
        END IF;
        IF v_blk IS NOT NULL THEN
          v_broll := public.rpg_roll(v_actor.character_id, v_key, public.rpg_difficulty(v_blk, public.rpg_participant_can_act(v_tid), v_defending), v_label || ' (block)', NULL, v_s.id, p_actor_id,
                                     CASE WHEN v_actor.character_id IS NULL THEN v_skill END);
          IF v_broll->>'result' = '' THEN
            v_blocked := true; v_net := 0;
            v_tail := ' Blocked by ' || CASE WHEN v_blocker IS NOT NULL THEN v_t.name || '''s ' || v_blocker_name ELSE v_t.name || '''s Shield of Faith' END
                      || ' (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
            IF v_blocker IS NOT NULL AND v_dmg > 0 THEN
              v_wear := public.rpg_item_damage(v_blocker, v_dmg);
              v_tail := v_tail || ' The ' || v_blocker_name || ' takes ' || v_dmg || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left') || ' left.' END;
              IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_dmg / 5.0)::integer); END IF;
            END IF;
          ELSE
            v_tail := ' Past the block (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
          END IF;
        END IF;
      END IF;
      -- Gate 3: hit. Armor absorbs and takes what it absorbed; the weapon a fifth.
      IF v_dmg > 0 AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        FOR v_item IN SELECT i.id, i.name, i.absorb FROM public.rpg_items i
                       WHERE i.character_id = v_t.character_id AND i.equipped AND i.role = 'armor' AND i.absorb > 0 AND i.integrity_damage < i.integrity ORDER BY i.absorb DESC LOOP
          EXIT WHEN v_net <= 0;
          v_absorb := least(v_item.absorb, v_net);
          v_net := v_net - v_absorb;
          v_wear := public.rpg_item_damage(v_item.id, v_absorb);
          v_tail := v_tail || ' ' || v_item.name || ' absorbs ' || v_absorb || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE '.' END;
          IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_absorb / 5.0)::integer); END IF;
        END LOOP;
      END IF;
      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      v_out := CASE WHEN v_blocked THEN jsonb_build_object('key', 'blocked', 'label', 'Blocked')
                    ELSE public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, v_damage_ok, v_net,
                                            (public.rpg_needed(coalesce(v_first->>'skill', '0')::numeric, v_diff_still)->>'needed')::numeric) END;
      v_levelup := CASE WHEN v_actor.character_id IS NOT NULL AND (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                        THEN ' ' || v_actor.name || '''s ' || v_label || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
      v_who := CASE v_kind
                 WHEN 'attack' THEN v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label
                 WHEN 'action' THEN v_actor.name || '''s ' || v_use.name || CASE WHEN v_use.id <> v_act.id THEN ' (' || v_act.name || ')' ELSE '' END
                                    || ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END
                 ELSE v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name END;
      v_tail := v_tail || CASE WHEN v_net > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' is down.'
                               WHEN v_net > 0 AND v_t.character_id IS NOT NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                               ELSE '' END;
      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND NOT v_blocked AND (v_vit->>'left')::integer > 0 THEN
        IF v_fx->>'on' = 'land' AND NOT v_damage_ok THEN
          PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_use.name, v_s.round);
          v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name') || '.';
        ELSIF v_fx->>'on' = 'hit' AND v_net > 0 AND v_fx ? 'contest' THEN
          v_cskill := coalesce(public.rpg_participant_value(p_actor_id, v_fx->'contest'->>'skill_key'), 0);
          v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0), public.rpg_participant_can_act(v_tid), v_defending);
          v_croll := public.rpg_roll(NULL, initcap(v_fx->'contest'->>'skill_key'), v_cdiff, v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, v_cskill);
          IF v_croll->>'result' <> '' THEN
            PERFORM public.rpg_participant_apply_effect(v_tid, v_fx->'apply', v_use.name, v_s.round);
            v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name');
          ELSE
            v_tail := v_tail || ' ' || v_t.name || ' stays up';
          END IF;
          v_tail := v_tail || ' (' || initcap(v_fx->'contest'->>'skill_key') || ' ' || trim_scale(v_cskill) || ' against ' || trim_scale(v_cdiff)
                    || ': rolled ' || (v_croll->>'roll') || ', needs ' || ceil((v_croll->>'needed')::numeric) || ').';
        END IF;
      END IF;
      v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
      v_text := (v_out->>'label') || CASE WHEN v_damage_ok AND v_net > 0 THEN ' for ' || v_net || CASE WHEN v_pending THEN ' so far' ELSE '' END ELSE '' END
                || ': ' || v_who || '. Rolled ' || (v_first->>'roll') || ', needs ' || v_needs || '.' || v_xtext
                || CASE WHEN v_pending THEN ' Roll again and enter it.' ELSE '' END || v_tail || v_levelup;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, target_id, roll_id, damage, text)
      VALUES (v_s.agency_id, v_s.id, v_s.round, v_kind, v_out->>'key', p_actor_id, v_tid, (v_first->>'roll_id')::uuid, v_net, v_text);
      v_results := v_results || jsonb_build_array(jsonb_build_object('roll_id', v_first->'roll_id', 'target_id', v_tid, 'target_name', v_t.name,
                     'roll', v_first->'roll', 'needed', v_first->'needed', 'result', v_first->'result', 'outcome', v_out->>'key',
                     'extras', to_jsonb(v_extras), 'extra_pending', v_pending, 'difficulty', v_diff, 'damage', v_net,
                     'down', (v_vit->>'left')::integer <= 0, 'text', v_text));
    END LOOP;
  END IF;

  IF v_beats > 0 AND v_kind IN ('attack', 'action') THEN
    UPDATE public.rpg_sessions SET turn_beats = turn_beats + v_beats WHERE id = v_s.id;
  END IF;
  IF v_ecost > 0 AND v_kind IN ('attack', 'action') THEN
    IF v_etype = 'spiritual' THEN UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_ecost WHERE id = p_actor_id;
    ELSE UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_ecost WHERE id = p_actor_id; END IF;
  END IF;
  IF v_kind = 'action' THEN
    UPDATE public.rpg_session_participants
       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END
     WHERE id = p_actor_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_kind, 'label', v_label, 'results', v_results);
END;
$function$;

-- next turn: energy regains at the start of the turn; auto turn: rest when nothing is affordable; state: energy and costs.
DO $do$
DECLARE v_src text; a text; n text;
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_next_turn'::regproc);
  IF position('energy_used_physical' IN v_src) > 0 THEN RETURN; END IF;
  a := 'SET turns_taken = turns_taken + 1,';
  n := 'SET turns_taken = turns_taken + 1,' || E'\n'
    || '         energy_used_physical = greatest(energy_used_physical - coalesce(public.rpg_participant_value(id, ''PER''), 0)::integer, 0),' || E'\n'
    || '         energy_used_spiritual = greatest(energy_used_spiritual - coalesce(public.rpg_participant_value(id, ''SER''), 0)::integer, 0),';
  IF (length(v_src) - length(replace(v_src, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'next_turn anchor not unique'; END IF;
  EXECUTE replace(v_src, a, n);
END $do$;
DO $do$
DECLARE v_src text; a text; n text;
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_auto_turn'::regproc);
  IF position('''REST''' IN v_src) > 0 THEN RETURN; END IF;
  a := 'IF jsonb_array_length(v_lines) = 0 THEN' || E'\n'
    || '      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)' || E'\n'
    || '      VALUES (v_s.agency_id, p_session_id, v_s.round, ''action'', ''info'', v_p.id, v_p.name || '' has nothing worth using this turn.'');' || E'\n'
    || '    END IF;';
  n := 'IF jsonb_array_length(v_lines) = 0 AND (SELECT turn_beats FROM public.rpg_sessions WHERE id = p_session_id) = 0 THEN' || E'\n'
    || '      v_r := public.rpg_act(v_p.id, NULL, ''REST'');' || E'\n'
    || '      v_lines := v_lines || (v_r->''results'');' || E'\n'
    || '    END IF;';
  IF (length(v_src) - length(replace(v_src, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'auto_turn anchor not unique'; END IF;
  EXECUTE replace(v_src, a, n);
END $do$;
DO $do$
DECLARE v_src text; a text[]; n text[]; i integer;
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_state'::regproc);
  IF position('rpg_participant_energy' IN v_src) > 0 THEN RETURN; END IF;
  a := ARRAY['''is_current'', coalesce(v_p.id = v_s.current_participant_id, false))',
             '''beats'', a.beats, ''area'', a.area,',
             '''value'', s->''value'', ''beats'', d.beats)'];
  n := ARRAY['''energy'', public.rpg_participant_energy(v_p.id), ''is_current'', coalesce(v_p.id = v_s.current_participant_id, false))',
             '''beats'', a.beats, ''area'', a.area, ''energy_cost'', a.energy_cost, ''energy_type'', a.energy_type,',
             '''value'', s->''value'', ''beats'', d.beats, ''energy_cost'', d.energy_cost, ''energy_type'', d.energy_type)'];
  FOR i IN 1..3 LOOP
    IF (length(v_src) - length(replace(v_src, a[i], ''))) / length(a[i]) <> 1 THEN RAISE EXCEPTION 'state anchor % not unique', i; END IF;
    v_src := replace(v_src, a[i], n[i]);
  END LOOP;
  EXECUTE v_src;
END $do$;

GRANT EXECUTE ON FUNCTION public.rpg_participant_energy(uuid), public.rpg_participant_burden(uuid, text), public.rpg_item_damage(uuid, integer) TO authenticated;
DO $do$
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('rpg_difficulty', 'rpg_outcome', 'rpg_act')) <> 3 THEN RAISE EXCEPTION 'overloads appeared'; END IF;
  IF position('energy_used_physical' IN pg_get_functiondef('public.rpg_session_next_turn'::regproc)) = 0 THEN RAISE EXCEPTION 'next_turn edit did not land'; END IF;
  IF position('''REST''' IN pg_get_functiondef('public.rpg_session_auto_turn'::regproc)) = 0 THEN RAISE EXCEPTION 'auto_turn edit did not land'; END IF;
  IF position('rpg_participant_energy' IN pg_get_functiondef('public.rpg_session_state'::regproc)) = 0 THEN RAISE EXCEPTION 'state edit did not land'; END IF;
  IF NOT (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'rpg\_%' AND p.prorettype <> 'trigger'::regtype AND p.proname <> 'rpg_manual_page_sync') THEN
    RAISE EXCEPTION 'an rpg_ function lost its grant';
  END IF;
END $do$;
