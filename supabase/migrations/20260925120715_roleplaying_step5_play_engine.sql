-- Roleplaying step 5: the play engine without a map.
-- A fight (rpg_sessions) holds characters and creature instances (rpg_session_participants) in turn order; every
-- roll, hit and turn lands in the play log (rpg_events). One saved function per job: rolls go through rpg_roll, an
-- opponent's difficulty through rpg_difficulty, Needed through rpg_needed, damage through rpg_damage.

-- The Rules tab calculator calls these two from the browser. rpg_needed lost its grant when it was dropped and
-- recreated; rpg_difficulty never had one. Both answered "permission denied" to every signed-in user.
GRANT EXECUTE ON FUNCTION public.rpg_needed(numeric, numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_difficulty(numeric, boolean) TO authenticated;

-- Data the engine reads.
ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS agility_skill smallint;
UPDATE public.rpg_creatures SET agility_skill = 7 WHERE key = 'bramblemaw' AND agility_skill IS NULL;

ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS deals_damage boolean NOT NULL DEFAULT false;
UPDATE public.rpg_creature_actions a SET deals_damage = true
  FROM public.rpg_creatures c
 WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name IN ('Claw', 'Bite');

ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS is_attack boolean NOT NULL DEFAULT false;
UPDATE public.rpg_stat_definitions SET is_attack = true
 WHERE key IN ('battle_axe', 'crossbow', 'dagger', 'flail', 'hand_axe', 'hand_to_hand', 'lance', 'longbow',
               'military_fork', 'quarterstaff', 'sling', 'spear', 'sword', 'war_hammer', 'hurling', 'tossing');

INSERT INTO public.rpg_settings (key, value, label)
SELECT 'attacks_per_turn', 1, 'Attacks a character makes on each of their turns'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings WHERE key = 'attacks_per_turn');

-- Tables.
CREATE TABLE IF NOT EXISTS public.rpg_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  name text NOT NULL,
  status text NOT NULL DEFAULT 'setup' CHECK (status IN ('setup', 'active', 'ended')),
  round integer NOT NULL DEFAULT 0,
  current_participant_id uuid,
  turn_attacks integer NOT NULL DEFAULT 0,
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.rpg_session_participants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  session_id uuid NOT NULL REFERENCES public.rpg_sessions(id) ON DELETE CASCADE,
  character_id uuid REFERENCES public.rpg_characters(id) ON DELETE CASCADE,
  creature_id uuid REFERENCES public.rpg_creatures(id) ON DELETE CASCADE,
  name text NOT NULL,
  turn_order integer NOT NULL DEFAULT 0,
  vitality_damage integer NOT NULL DEFAULT 0,
  can_act boolean NOT NULL DEFAULT true,
  status_note text,
  legendary_left integer NOT NULL DEFAULT 0,
  recharge_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK ((character_id IS NULL) <> (creature_id IS NULL))
);
COMMENT ON COLUMN public.rpg_session_participants.vitality_damage IS 'Creatures only: damage this instance has taken in this fight. A character''s damage lives on rpg_characters.vitality_damage.';
COMMENT ON COLUMN public.rpg_session_participants.recharge_state IS 'Recharge actions used and waiting on their six-sided die: {"<action id>": true}.';
CREATE UNIQUE INDEX IF NOT EXISTS rpg_session_participants_character_once
  ON public.rpg_session_participants (session_id, character_id) WHERE character_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS rpg_session_participants_order ON public.rpg_session_participants (session_id, turn_order);

CREATE TABLE IF NOT EXISTS public.rpg_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  session_id uuid NOT NULL REFERENCES public.rpg_sessions(id) ON DELETE CASCADE,
  round integer NOT NULL DEFAULT 0,
  kind text NOT NULL,
  actor_id uuid REFERENCES public.rpg_session_participants(id) ON DELETE SET NULL,
  target_id uuid REFERENCES public.rpg_session_participants(id) ON DELETE SET NULL,
  roll_id uuid REFERENCES public.rpg_rolls(id) ON DELETE SET NULL,
  damage integer,
  text text NOT NULL,
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS rpg_events_session ON public.rpg_events (session_id, created_at DESC);

-- A creature's rolls land in the same roll log, tied to its place in the fight instead of a character.
ALTER TABLE public.rpg_rolls ALTER COLUMN character_id DROP NOT NULL;
ALTER TABLE public.rpg_rolls ADD COLUMN IF NOT EXISTS participant_id uuid
  REFERENCES public.rpg_session_participants(id) ON DELETE SET NULL;

-- Row rules: parents read and write directly; the hub login plays through the functions below.
ALTER TABLE public.rpg_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_session_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.rpg_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS rpg_sessions_parents_all ON public.rpg_sessions;
CREATE POLICY rpg_sessions_parents_all ON public.rpg_sessions FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_session_participants_parents_all ON public.rpg_session_participants;
CREATE POLICY rpg_session_participants_parents_all ON public.rpg_session_participants FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
DROP POLICY IF EXISTS rpg_events_parents_all ON public.rpg_events;
CREATE POLICY rpg_events_parents_all ON public.rpg_events FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.rpg_sessions, public.rpg_session_participants, public.rpg_events TO authenticated;

CREATE OR REPLACE FUNCTION public.rpg_participant_value(p_participant_id uuid, p_stat_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One participant's value for one stat. Characters read their sheet (rpg_sheet), so items and earned levels count.
-- Creatures read the character-scale column that plays that stat: Evade Enemy EE → defense_skill, Courage CO →
-- will_skill, Strength ST → strength_skill, Agility AG → agility_skill, Physical Vitality PV → vitality; and their
-- own skills by name (attack, defense, strength, will, stealth, awareness, agility).
-- Karen: EE → 5, AG → 1. Bramblemaw: EE → 8, CO → 10, ST → 10, AG → 7, PV → 150.
DECLARE v_p record; v_c record; v_val numeric;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  IF v_p.character_id IS NOT NULL THEN
    SELECT (s->>'value')::numeric INTO v_val
      FROM jsonb_array_elements(public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'))->'stats') s
     WHERE s->>'key' = p_stat_key;
    RETURN v_val;
  END IF;
  SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
  RETURN CASE p_stat_key
    WHEN 'EE' THEN v_c.defense_skill   WHEN 'defense'   THEN v_c.defense_skill
    WHEN 'CO' THEN v_c.will_skill      WHEN 'will'      THEN v_c.will_skill
    WHEN 'ST' THEN v_c.strength_skill  WHEN 'strength'  THEN v_c.strength_skill
    WHEN 'AG' THEN v_c.agility_skill   WHEN 'agility'   THEN v_c.agility_skill
    WHEN 'PV' THEN v_c.vitality        WHEN 'attack'    THEN v_c.attack_skill
    WHEN 'stealth' THEN v_c.stealth_skill WHEN 'awareness' THEN v_c.awareness_skill
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_vitality(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A participant's vitality as {max, left, damage}. Characters: Physical Vitality from the sheet less the damage on the
-- character (25 with 10 damage → 15 left). Creatures: the card's vitality less this fight's damage (150 with 30 → 120).
-- Left never shows below 0.
DECLARE v_p record; v_sheet jsonb; v_max integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  IF v_p.character_id IS NOT NULL THEN
    v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
    RETURN jsonb_build_object('max', (v_sheet->>'vitality_max')::integer,
                              'left', greatest((v_sheet->>'vitality_left')::integer, 0),
                              'damage', (v_sheet->>'vitality_damage')::integer);
  END IF;
  SELECT coalesce(c.vitality, c.hit_points) INTO v_max FROM public.rpg_creatures c WHERE c.id = v_p.creature_id;
  RETURN jsonb_build_object('max', v_max, 'left', greatest(v_max - v_p.vitality_damage, 0), 'damage', v_p.vitality_damage);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_damage(p_roll_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Damage from one attack roll (rule card "Damage"): die − Needed, divided by damage_divisor (1), rounded down, at least
-- 1 on a hit that lands, 0 on a miss. A critical's additional roll adds its result, and so does every roll chained
-- after it. Skill 5 against an opponent of skill 5 (difficulty 10, Needed 66.67): 80 does 13, 68 does 1.
-- A critical 97 at Needed 66.67 does 30; an additional roll of 64 makes it 94.
SELECT public.require_login('family');
WITH RECURSIVE chain AS (
  SELECT r.id, r.roll FROM public.rpg_rolls r WHERE r.parent_roll_id = p_roll_id
  UNION ALL
  SELECT r.id, r.roll FROM public.rpg_rolls r JOIN chain c ON r.parent_roll_id = c.id
)
SELECT CASE WHEN r.result = '' THEN 0
            ELSE greatest(floor((r.roll - r.needed) / nullif(public.rpg_setting('damage_divisor'), 0)), 1)::integer
                 + coalesce((SELECT sum(roll) FROM chain), 0)::integer
       END
  FROM public.rpg_rolls r WHERE r.id = p_roll_id;
$function$;

DROP FUNCTION IF EXISTS public.rpg_roll(uuid, text, numeric, text, uuid, uuid);
CREATE FUNCTION public.rpg_roll(p_character_id uuid, p_stat_key text, p_difficulty numeric DEFAULT NULL::numeric,
  p_label text DEFAULT NULL::text, p_parent_roll_id uuid DEFAULT NULL::uuid, p_session_id uuid DEFAULT NULL::uuid,
  p_participant_id uuid DEFAULT NULL::uuid, p_skill numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One d100 roll. A character rolls a stat from their sheet and earns skill points on a trainable one, every roll:
-- die × Needed ÷ 100 (Peter 2026-09-24). A creature in a fight (no character; its participant and skill passed in)
-- rolls the skill it is handed, an action's or one of its own, earns nothing, and only the game master rolls it.
-- Needed comes from rpg_needed; an opponent's difficulty arrives already derived by rpg_difficulty.
DECLARE
  v_sheet jsonb; v_stat jsonb; v_skill numeric; v_diff numeric; v_nc jsonb; v_roll integer; v_result text;
  v_points numeric := 0; v_before integer; v_after integer; v_cost numeric; v_sp numeric; v_earned integer;
  v_id uuid; v_agency uuid; v_name text; v_trainable boolean := false;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_diff := coalesce(p_difficulty, public.rpg_setting('default_difficulty'));
  IF v_diff < 0 THEN RAISE EXCEPTION 'difficulty cannot be negative'; END IF;

  IF p_character_id IS NULL THEN
    IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master rolls for a creature'; END IF;
    IF p_participant_id IS NULL OR p_skill IS NULL THEN RAISE EXCEPTION 'a creature roll needs the creature and its skill'; END IF;
    SELECT s.agency_id INTO v_agency
      FROM public.rpg_session_participants p JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE p.id = p_participant_id AND p.creature_id IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'that is not a creature in a fight'; END IF;
    v_skill := greatest(p_skill, 0);
    v_name := p_stat_key;
  ELSE
    v_sheet := public.rpg_sheet(p_character_id, v_diff);
    SELECT s INTO v_stat FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = p_stat_key;
    IF v_stat IS NULL THEN RAISE EXCEPTION 'unknown stat %', p_stat_key; END IF;
    v_skill := (v_stat->>'value')::numeric;
    v_name := v_stat->>'name';
    v_trainable := coalesce((v_stat->>'trainable')::boolean, false);
    SELECT agency_id INTO v_agency FROM public.rpg_characters WHERE id = p_character_id;
  END IF;

  v_nc := public.rpg_needed(v_skill, v_diff);
  v_roll := floor(random() * 100)::integer + 1;
  v_result := CASE WHEN v_roll >= (v_nc->>'critical')::numeric THEN 'C'
                   WHEN v_roll >= (v_nc->>'needed')::numeric THEN 'Y' ELSE '' END;
  v_before := v_skill::integer; v_after := v_before;

  IF v_trainable THEN
    v_points := v_roll * (v_nc->>'needed')::numeric / 100;
    INSERT INTO public.rpg_character_skills (character_id, stat_key) VALUES (p_character_id, p_stat_key)
      ON CONFLICT (character_id, stat_key) DO NOTHING;
    SELECT skill_points, earned_levels INTO v_sp, v_earned
      FROM public.rpg_character_skills WHERE character_id = p_character_id AND stat_key = p_stat_key FOR UPDATE;
    v_sp := v_sp + v_points;
    LOOP
      v_cost := public.rpg_level_cost(v_after);
      EXIT WHEN v_sp < v_cost;
      v_sp := v_sp - v_cost; v_earned := v_earned + 1; v_after := v_after + 1;
    END LOOP;
    UPDATE public.rpg_character_skills SET skill_points = v_sp, earned_levels = v_earned
     WHERE character_id = p_character_id AND stat_key = p_stat_key;
  END IF;

  INSERT INTO public.rpg_rolls (agency_id, character_id, participant_id, session_id, stat_key, skill, difficulty, needed,
                                critical_at, roll, result, points_awarded, level_before, level_after, parent_roll_id,
                                extra_pending, label)
  VALUES (v_agency, p_character_id, p_participant_id, p_session_id, p_stat_key, v_skill, v_diff,
          (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, v_roll, v_result, v_points, v_before, v_after,
          p_parent_roll_id, v_result = 'C', p_label)
  RETURNING id INTO v_id;
  IF p_parent_roll_id IS NOT NULL THEN
    UPDATE public.rpg_rolls SET extra_pending = false WHERE id = p_parent_roll_id;
  END IF;

  RETURN jsonb_build_object('roll_id', v_id, 'character_id', p_character_id, 'participant_id', p_participant_id,
    'stat_key', p_stat_key, 'stat_name', v_name, 'skill', v_skill, 'difficulty', v_diff, 'needed', v_nc->'needed',
    'critical', v_nc->'critical', 'roll', v_roll, 'result', v_result, 'points', round(v_points, 1),
    'level_before', v_before, 'level_after', v_after, 'extra_pending', v_result = 'C',
    'parent_roll_id', p_parent_roll_id, 'label', p_label, 'created_at', now());
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_roll_extra(p_parent_roll_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The additional roll a critical prompts: same stat, same difficulty, same fight. A creature's roll keeps its skill.
DECLARE v_p record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_rolls WHERE id = p_parent_roll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'roll not found'; END IF;
  IF NOT v_p.extra_pending THEN RAISE EXCEPTION 'that roll has no additional roll waiting'; END IF;
  RETURN public.rpg_roll(v_p.character_id, v_p.stat_key, v_p.difficulty, v_p.label, p_parent_roll_id, v_p.session_id,
                         v_p.participant_id, CASE WHEN v_p.character_id IS NULL THEN v_p.skill END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_new(p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A new fight. It waits in setup while the game master adds characters and creatures; the first turn starts it.
DECLARE v_id uuid;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master starts a fight'; END IF;
  INSERT INTO public.rpg_sessions (name)
  VALUES (coalesce(nullif(btrim(p_name), ''), 'Fight on ' || to_char(now() AT TIME ZONE 'America/Chicago', 'FMMonth FMDD')))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_add(p_session_id uuid, p_character_id uuid DEFAULT NULL::uuid,
  p_creature_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Adds one character or one creature to a fight at its Agility place: ahead of the first one in line with lower
-- Agility, so higher Agility acts first and a tie goes after whoever joined first. The game master's own moves stay.
-- Bramblemaw (Agility 7) lands ahead of Karen (Agility 1). A second Bramblemaw is named "Bramblemaw 2".
DECLARE v_s record; v_name text; v_leg integer := 0; v_n integer; v_id uuid; v_ag numeric; v_pos integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master adds to a fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF (p_character_id IS NULL) = (p_creature_id IS NULL) THEN RAISE EXCEPTION 'add one character or one creature'; END IF;
  IF p_character_id IS NOT NULL THEN
    SELECT name INTO v_name FROM public.rpg_characters WHERE id = p_character_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'character not found'; END IF;
    IF EXISTS (SELECT 1 FROM public.rpg_session_participants WHERE session_id = p_session_id AND character_id = p_character_id) THEN
      RAISE EXCEPTION '% is already in this fight', v_name;
    END IF;
  ELSE
    SELECT name, legendary_per_round INTO v_name, v_leg FROM public.rpg_creatures WHERE id = p_creature_id AND is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'creature not found'; END IF;
    SELECT count(*) INTO v_n FROM public.rpg_session_participants WHERE session_id = p_session_id AND creature_id = p_creature_id;
    IF v_n > 0 THEN v_name := v_name || ' ' || (v_n + 1); END IF;
  END IF;
  INSERT INTO public.rpg_session_participants (agency_id, session_id, character_id, creature_id, name, legendary_left)
  VALUES (v_s.agency_id, p_session_id, p_character_id, p_creature_id, v_name, coalesce(v_leg, 0))
  RETURNING id INTO v_id;
  v_ag := coalesce(public.rpg_participant_value(v_id, 'AG'), 0);
  SELECT min(p.turn_order) INTO v_pos FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.id <> v_id AND coalesce(public.rpg_participant_value(p.id, 'AG'), 0) < v_ag;
  IF v_pos IS NULL THEN
    SELECT coalesce(max(turn_order), 0) + 1 INTO v_pos
      FROM public.rpg_session_participants WHERE session_id = p_session_id AND id <> v_id;
  ELSE
    UPDATE public.rpg_session_participants SET turn_order = turn_order + 1
     WHERE session_id = p_session_id AND id <> v_id AND turn_order >= v_pos;
  END IF;
  UPDATE public.rpg_session_participants SET turn_order = v_pos WHERE id = v_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_s.round, 'join', v_id, v_name || ' joins the fight (Agility ' || trim_scale(v_ag) || ').');
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_set_order(p_session_id uuid, p_order uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master's turn order: every participant's id once, in the order they act.
DECLARE v_have integer; v_given integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master changes the turn order'; END IF;
  SELECT count(*) INTO v_have FROM public.rpg_session_participants WHERE session_id = p_session_id;
  SELECT count(DISTINCT x) INTO v_given FROM unnest(p_order) x
   WHERE x IN (SELECT id FROM public.rpg_session_participants WHERE session_id = p_session_id);
  IF v_given <> v_have OR coalesce(cardinality(p_order), 0) <> v_have THEN RAISE EXCEPTION 'list everyone in the fight once'; END IF;
  UPDATE public.rpg_session_participants p SET turn_order = o.n
    FROM unnest(p_order) WITH ORDINALITY AS o(id, n)
   WHERE p.id = o.id AND p.session_id = p_session_id;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_set_status(p_participant_id uuid, p_can_act boolean, p_status_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master marks whether someone can act, with a short note the table sees ("Held until the next round").
-- Someone who cannot act is hit at their skill × 1 instead of × 2: Evade Enemy 5 → difficulty 5 instead of 10.
DECLARE v_p record; v_note text := nullif(btrim(p_status_note), '');
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master changes this'; END IF;
  SELECT p.*, s.round AS s_round INTO v_p
    FROM public.rpg_session_participants p JOIN public.rpg_sessions s ON s.id = p.session_id WHERE p.id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  UPDATE public.rpg_session_participants SET can_act = coalesce(p_can_act, can_act), status_note = v_note WHERE id = p_participant_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_p.agency_id, v_p.session_id, v_p.s_round, 'status', p_participant_id,
          v_p.name || CASE WHEN coalesce(p_can_act, v_p.can_act) THEN ' can act' ELSE ' cannot act' END
                   || coalesce(': ' || v_note, '') || '.');
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_p.session_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_adjust_vitality(p_participant_id uuid, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Damage (+) or healing (−) for anyone in a fight. Damage stops at 0 left, healing stops at full. Characters go
-- through rpg_adjust_vitality (their damage lives on the character); creatures keep this fight's own count.
-- Karen 25, hit for 94 → 0 left, down. Bramblemaw 150, hit for 30 → 120 left.
DECLARE v_p record; v_v jsonb; v_delta integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  v_v := public.rpg_participant_vitality(p_participant_id);
  v_delta := CASE WHEN coalesce(p_delta, 0) > 0 THEN least(p_delta, (v_v->>'left')::integer)
                  ELSE greatest(coalesce(p_delta, 0), -(v_v->>'damage')::integer) END;
  IF v_delta <> 0 THEN
    IF v_p.character_id IS NOT NULL THEN
      PERFORM public.rpg_adjust_vitality(v_p.character_id, v_delta);
    ELSE
      UPDATE public.rpg_session_participants SET vitality_damage = vitality_damage + v_delta WHERE id = p_participant_id;
    END IF;
  END IF;
  RETURN public.rpg_participant_vitality(p_participant_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one in turn order; after the last one a new round begins at the top.
-- In setup this starts the fight at round 1. When a creature's turn starts its legendary actions come back
-- (Bramblemaw: 3) and each recharge action it has used rolls a six-sided die: Briar Roar is ready again on 5 or 6.
-- The game master can pass any turn; a player can end a character's turn.
DECLARE
  v_s record; v_cur_id uuid; v_cur_order integer; v_cur_created timestamptz; v_cur_char uuid;
  v_next_id uuid; v_round integer; v_new_round boolean := false; v_next record; v_state jsonb; v_a record; v_d6 integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT id, turn_order, created_at, character_id INTO v_cur_id, v_cur_order, v_cur_created, v_cur_char
    FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur_id IS NULL OR v_cur_char IS NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;
  v_round := greatest(v_s.round, 1);
  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    SELECT id INTO v_next_id FROM public.rpg_session_participants
     WHERE session_id = p_session_id AND (turn_order, created_at) > (v_cur_order, v_cur_created)
     ORDER BY turn_order, created_at LIMIT 1;
  END IF;
  IF v_next_id IS NULL THEN
    SELECT id INTO v_next_id FROM public.rpg_session_participants WHERE session_id = p_session_id
     ORDER BY turn_order, created_at LIMIT 1;
    IF v_next_id IS NULL THEN RAISE EXCEPTION 'add someone to the fight first'; END IF;
    IF v_s.status = 'active' THEN v_round := v_s.round + 1; v_new_round := true; END IF;
  END IF;
  UPDATE public.rpg_sessions SET status = 'active', round = v_round, current_participant_id = v_next_id,
         turn_attacks = 0, updated_at = now()
   WHERE id = p_session_id;
  IF v_s.status = 'setup' THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'start', 'The fight begins. Round 1.');
  ELSIF v_new_round THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'round', 'Round ' || v_round || ' begins.');
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  IF v_next.creature_id IS NOT NULL THEN
    v_state := v_next.recharge_state;
    FOR v_a IN SELECT a.id, a.name, a.recharge_min FROM public.rpg_creature_actions a
                WHERE a.creature_id = v_next.creature_id AND a.recharge_min IS NOT NULL AND v_state ? a.id::text
                ORDER BY a.sort_order LOOP
      v_d6 := floor(random() * 6)::integer + 1;
      IF v_d6 >= v_a.recharge_min THEN v_state := v_state - v_a.id::text; END IF;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'recharge', v_next_id,
              v_next.name || ' rolls a six-sided die for ' || v_a.name || ': ' || v_d6 || '. '
              || CASE WHEN v_d6 >= v_a.recharge_min THEN 'Ready again.'
                      ELSE 'Not yet, it needs ' || v_a.recharge_min || ' or more.' END);
    END LOOP;
    UPDATE public.rpg_session_participants
       SET legendary_left = coalesce((SELECT legendary_per_round FROM public.rpg_creatures WHERE id = v_next.creature_id), 0),
           recharge_state = v_state
     WHERE id = v_next_id;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'current_participant_id', v_next_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_remove(p_participant_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master takes someone out of a fight. If it was their turn, the turn passes on first.
DECLARE v_p record; v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master removes someone'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.current_participant_id = p_participant_id AND v_s.status = 'active' THEN
    PERFORM public.rpg_session_next_turn(v_p.session_id);
  END IF;
  DELETE FROM public.rpg_session_participants WHERE id = p_participant_id;
  UPDATE public.rpg_sessions SET current_participant_id = NULL
   WHERE id = v_p.session_id AND current_participant_id = p_participant_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, text)
  SELECT v_p.agency_id, v_p.session_id, s.round, 'leave', v_p.name || ' leaves the fight.'
    FROM public.rpg_sessions s WHERE s.id = v_p.session_id;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_p.session_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_end(p_session_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master ends a fight. It stays in the list with its log, and nothing more can happen in it.
DECLARE v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master ends a fight'; END IF;
  UPDATE public.rpg_sessions SET status = 'ended', ended_at = now(), current_participant_id = NULL, updated_at = now()
   WHERE id = p_session_id AND status <> 'ended'
  RETURNING * INTO v_s;
  IF FOUND THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'end',
            CASE WHEN v_s.round = 0 THEN 'The fight is over.'
                 ELSE 'The fight is over after ' || v_s.round || CASE WHEN v_s.round = 1 THEN ' round.' ELSE ' rounds.' END END);
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[],
  p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text,
  p_difficulty numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One move in a fight. Each target gets its own roll through rpg_roll against a difficulty from rpg_difficulty: the
-- target's stat × 2 when they can act, × 1 when they cannot. With no target the roll is a check against a fixed
-- difficulty: Courage 7 against 8 to shake off fear needs 54 or more.
--   A character attacks with a weapon skill (rpg_stat_definitions.is_attack) against Evade Enemy. Dagger 6 at Bramblemaw
--   (defense 8 → difficulty 16) needs 73; a roll of 90 does 17 (rpg_damage). A character makes attacks_per_turn
--   attacks on their own turn (1).
--   A creature uses a card action: the action's skill against the action's stat (Claw 10 against Evade Enemy). Only
--   actions marked deals_damage (Claw, Bite) do damage. An action that makes one other attack rolls that attack
--   (Rending Swipe rolls a Claw); one that makes several is rolled an attack at a time. Legendary actions spend
--   legendary_left; a recharge action waits for its six-sided die once used; an action with no skill is used without
--   a roll (Rootstep).
--   A creature can also roll one of its own skills against a target's stat (Strength 10 against Strength when a Claw
--   knocks someone down).
-- A critical's additional rolls are rolled here with rpg_roll_extra (they chain) and add to damage.
-- Players act for the character whose turn it is; the game master acts for anyone, any time.
DECLARE
  v_gm boolean := public.family_is_parent();
  v_actor record; v_s record; v_act record; v_use record; v_t record;
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_skill numeric; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text;
  v_tid uuid; v_def numeric; v_diff numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status = 'setup' THEN RAISE EXCEPTION 'the fight has not started yet'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF NOT v_gm AND (v_actor.character_id IS NULL OR v_s.current_participant_id IS DISTINCT FROM p_actor_id) THEN
    RAISE EXCEPTION 'it is not %''s turn', v_actor.name;
  END IF;
  IF NOT v_actor.can_act THEN RAISE EXCEPTION '% cannot act%', v_actor.name, coalesce(': ' || v_actor.status_note, ''); END IF;
  IF (public.rpg_participant_vitality(p_actor_id)->>'left')::integer <= 0 THEN RAISE EXCEPTION '% is down', v_actor.name; END IF;
  IF p_actor_id = ANY (v_targets) THEN RAISE EXCEPTION 'choose someone else to aim at'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_targets) t(id)
              WHERE NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.id = t.id AND p.session_id = v_s.id)) THEN
    RAISE EXCEPTION 'every target must be in this fight';
  END IF;

  IF v_actor.character_id IS NOT NULL THEN
    SELECT name, is_attack INTO v_stat_name, v_is_attack FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'choose a skill'; END IF;
    v_key := p_stat_key; v_label := v_stat_name;
    IF cardinality(v_targets) > 0 THEN
      IF NOT v_is_attack THEN RAISE EXCEPTION 'choose a weapon skill to attack with'; END IF;
      IF cardinality(v_targets) > 1 THEN RAISE EXCEPTION 'attack one target at a time'; END IF;
      IF v_s.current_participant_id = p_actor_id AND v_s.turn_attacks >= public.rpg_setting('attacks_per_turn') THEN
        RAISE EXCEPTION '% has already attacked this turn', v_actor.name;
      END IF;
      v_kind := 'attack'; v_against := 'EE'; v_damage_ok := true;
    ELSE
      v_kind := 'check';
    END IF;
  ELSIF p_action_id IS NOT NULL THEN
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;
    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF jsonb_typeof(v_act.makes_attacks) = 'array' AND jsonb_array_length(v_act.makes_attacks) > 0 THEN
      IF jsonb_array_length(v_act.makes_attacks) > 1 OR coalesce((v_act.makes_attacks->0->>'count')::integer, 1) > 1 THEN
        RAISE EXCEPTION '% is several rolls. Roll them one at a time: %', v_act.name,
          (SELECT string_agg((e->>'count') || ' × ' || (e->>'action'), ', ') FROM jsonb_array_elements(v_act.makes_attacks) e);
      END IF;
      SELECT * INTO v_use FROM public.rpg_creature_actions
       WHERE creature_id = v_actor.creature_id AND name = v_act.makes_attacks->0->>'action' LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION '% names an attack that is not on the card', v_act.name; END IF;
    ELSE
      v_use := v_act;
    END IF;
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF v_act.recharge_min IS NOT NULL AND v_actor.recharge_state ? v_act.id::text THEN
      RAISE EXCEPTION '% is not ready. It comes back on a six-sided die roll of % or more at the start of %''s turn',
        v_act.name, v_act.recharge_min, v_actor.name;
    END IF;
    v_kind := 'action'; v_label := v_act.name; v_key := v_use.name; v_skill := v_use.skill;
    v_against := v_use.against; v_damage_ok := v_use.deals_damage;
    IF v_skill IS NOT NULL AND cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
  ELSE
    IF p_stat_key IS NULL OR p_stat_key NOT IN ('attack', 'defense', 'strength', 'will', 'stealth', 'awareness', 'agility') THEN
      RAISE EXCEPTION 'choose one of the creature''s skills';
    END IF;
    v_skill := public.rpg_participant_value(p_actor_id, p_stat_key);
    IF v_skill IS NULL THEN RAISE EXCEPTION '% has no % skill on its card', v_actor.name, p_stat_key; END IF;
    v_kind := 'check'; v_key := initcap(p_stat_key); v_label := initcap(p_stat_key); v_against := p_against;
    IF cardinality(v_targets) > 0 AND v_against IS NULL THEN RAISE EXCEPTION 'choose what it rolls against'; END IF;
  END IF;
  IF cardinality(v_targets) > 0 THEN
    SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
    IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
  END IF;

  IF v_kind = 'action' AND v_skill IS NULL THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', p_actor_id, v_actor.name || ' uses ' || v_act.name || '.');
  ELSIF cardinality(v_targets) = 0 THEN
    v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
    v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                              CASE WHEN v_actor.character_id IS NULL THEN v_skill END);
    v_first := v_roll; v_extras := '{}'; v_i := 0;
    WHILE coalesce((v_roll->>'extra_pending')::boolean, false) AND v_i < 20 LOOP
      v_roll := public.rpg_roll_extra((v_roll->>'roll_id')::uuid);
      v_extras := v_extras || (v_roll->>'roll')::integer; v_i := v_i + 1;
    END LOOP;
    v_needs := ceil((v_first->>'needed')::numeric)::integer;
    v_levelup := CASE WHEN (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                      THEN ' ' || v_actor.name || '''s ' || v_label || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
    v_text := v_actor.name || ' rolls ' || v_label || ' against difficulty ' || trim_scale(v_diff) || ': rolled '
              || (v_first->>'roll') || ', needs ' || v_needs || '. '
              || CASE WHEN v_first->>'result' = 'C' THEN 'Critical! ' ELSE '' END
              || CASE WHEN cardinality(v_extras) > 0
                      THEN 'Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END
                           || array_to_string(v_extras, ' and ') || '. ' ELSE '' END
              || CASE WHEN v_first->>'result' = '' THEN 'Fail.' ELSE 'Success.' END || v_levelup;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, roll_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', p_actor_id, (v_first->>'roll_id')::uuid, v_text);
    v_results := v_results || jsonb_build_array(jsonb_build_object('roll', v_first->'roll', 'needed', v_first->'needed',
                   'result', v_first->'result', 'extras', to_jsonb(v_extras), 'difficulty', v_diff, 'text', v_text));
  ELSE
    FOREACH v_tid IN ARRAY v_targets LOOP
      SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_def := coalesce(public.rpg_participant_value(v_tid, v_against), 0);
      v_diff := public.rpg_difficulty(v_def, v_t.can_act);
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                                CASE WHEN v_actor.character_id IS NULL THEN v_skill END);
      v_first := v_roll; v_extras := '{}'; v_i := 0;
      WHILE coalesce((v_roll->>'extra_pending')::boolean, false) AND v_i < 20 LOOP
        v_roll := public.rpg_roll_extra((v_roll->>'roll_id')::uuid);
        v_extras := v_extras || (v_roll->>'roll')::integer; v_i := v_i + 1;
      END LOOP;
      v_dmg := CASE WHEN v_damage_ok THEN public.rpg_damage((v_first->>'roll_id')::uuid) ELSE 0 END;
      IF v_dmg > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_dmg);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      v_needs := ceil((v_first->>'needed')::numeric)::integer;
      v_levelup := CASE WHEN v_actor.character_id IS NOT NULL AND (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                        THEN ' ' || v_actor.name || '''s ' || v_label || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
      v_text := CASE v_kind
                  WHEN 'attack' THEN v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label
                  WHEN 'action' THEN v_actor.name || '''s ' || v_label || ' at ' || v_t.name
                                     || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END
                  ELSE v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name END
                || ': rolled ' || (v_first->>'roll') || ', needs ' || v_needs || '. '
                || CASE WHEN v_first->>'result' = 'C' THEN 'Critical! ' ELSE '' END
                || CASE WHEN cardinality(v_extras) > 0
                        THEN 'Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END
                             || array_to_string(v_extras, ' and ') || '. ' ELSE '' END
                || CASE WHEN v_first->>'result' = '' THEN CASE WHEN v_damage_ok THEN 'Miss.' ELSE 'It fails.' END
                        WHEN v_damage_ok THEN 'Hit for ' || v_dmg || '.'
                        ELSE 'It lands.' END
                || CASE WHEN v_dmg > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' is down.'
                        WHEN v_dmg > 0 AND v_t.character_id IS NOT NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                        ELSE '' END
                || v_levelup;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, actor_id, target_id, roll_id, damage, text)
      VALUES (v_s.agency_id, v_s.id, v_s.round, v_kind, p_actor_id, v_tid, (v_first->>'roll_id')::uuid, v_dmg, v_text);
      v_results := v_results || jsonb_build_array(jsonb_build_object('target_id', v_tid, 'target_name', v_t.name,
                     'roll', v_first->'roll', 'needed', v_first->'needed', 'result', v_first->'result',
                     'extras', to_jsonb(v_extras), 'difficulty', v_diff, 'damage', v_dmg,
                     'down', (v_vit->>'left')::integer <= 0, 'text', v_text));
    END LOOP;
  END IF;

  IF v_kind = 'attack' AND v_s.current_participant_id = p_actor_id THEN
    UPDATE public.rpg_sessions SET turn_attacks = turn_attacks + 1 WHERE id = v_s.id;
  END IF;
  IF v_kind = 'action' THEN
    UPDATE public.rpg_session_participants
       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END,
           recharge_state = CASE WHEN v_act.recharge_min IS NOT NULL
                                 THEN recharge_state || jsonb_build_object(v_act.id::text, true) ELSE recharge_state END
     WHERE id = p_actor_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_kind, 'label', v_label, 'results', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everything the Play tab shows for one fight in one read: the fight, everyone in turn order, the last 60 lines of
-- the log. Players get creatures without their numbers (vitality only as a share of full) and no game-master lists.
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY turn_order, created_at LOOP
    IF v_p.character_id IS NOT NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value')
                                    ORDER BY (s->>'value')::numeric DESC, s->>'name'), '[]'::jsonb)
                      FROM jsonb_array_elements(v_sheet->'stats') s
                      JOIN public.rpg_stat_definitions d ON d.key = s->>'key' AND d.is_attack),
        'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value')
                                  ORDER BY s->>'name'), '[]'::jsonb)
                    FROM jsonb_array_elements(v_sheet->'stats') s));
    ELSE
      SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
      v_vit := public.rpg_participant_vitality(v_p.id);
      v_item := jsonb_build_object('kind', 'creature', 'creature_id', v_p.creature_id, 'color', v_c.color,
        'vitality_share', CASE WHEN (v_vit->>'max')::numeric > 0
                               THEN round((v_vit->>'left')::numeric / (v_vit->>'max')::numeric, 3) END);
      IF v_gm THEN
        v_item := v_item || jsonb_build_object(
          'vitality_max', (v_vit->>'max')::integer, 'vitality_left', (v_vit->>'left')::integer,
          'legendary_left', v_p.legendary_left, 'legendary_per_round', v_c.legendary_per_round, 'agility', v_c.agility_skill,
          'skills', jsonb_build_object('attack', v_c.attack_skill, 'defense', v_c.defense_skill, 'strength', v_c.strength_skill,
                                       'will', v_c.will_skill, 'stealth', v_c.stealth_skill,
                                       'awareness', v_c.awareness_skill, 'agility', v_c.agility_skill),
          'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill', coalesce(u.skill, a.skill),
                          'against', coalesce(u.against, a.against), 'against_name', d.name,
                          'deals_damage', coalesce(u.deals_damage, a.deals_damage), 'table_note', a.table_note,
                          'recharge_min', a.recharge_min, 'spent', v_p.recharge_state ? a.id::text,
                          'legendary_cost', a.legendary_cost,
                          'several', jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) > 1
                                     OR coalesce((a.makes_attacks->0->>'count')::integer, 1) > 1)
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3
                                             WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM public.rpg_creature_actions a
                        LEFT JOIN public.rpg_creature_actions u
                               ON u.creature_id = a.creature_id AND u.name = a.makes_attacks->0->>'action'
                              AND jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) = 1
                        LEFT JOIN public.rpg_stat_definitions d ON d.key = coalesce(u.against, a.against)
                       WHERE a.creature_id = v_p.creature_id AND a.kind <> 'trait'));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note,
                 'is_current', coalesce(v_p.id = v_s.current_participant_id, false)) || v_item);
  END LOOP;
  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'turn_attacks', v_s.turn_attacks,
                 'attacks_per_turn', public.rpg_setting('attacks_per_turn'), 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p
                                                           WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c WHERE c.is_active)) END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The fights for the Play tab: open ones first, newest on top, then the last ten that are over.
SELECT public.require_login('family');
SELECT CASE WHEN NOT public.rpg_can_play() THEN '[]'::jsonb ELSE coalesce((
  SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'status', s.status, 'round', s.round,
                     'updated_at', s.updated_at,
                     'who', (SELECT string_agg(p.name, ', ' ORDER BY p.turn_order, p.created_at)
                               FROM public.rpg_session_participants p WHERE p.session_id = s.id))
                   ORDER BY (s.status = 'ended'), s.updated_at DESC)
    FROM public.rpg_sessions s
   WHERE s.status <> 'ended'
      OR s.id IN (SELECT e.id FROM public.rpg_sessions e WHERE e.status = 'ended' ORDER BY e.ended_at DESC NULLS LAST LIMIT 10)
), '[]'::jsonb) END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpg_roll(uuid, text, numeric, text, uuid, uuid, uuid, numeric),
  public.rpg_participant_value(uuid, text), public.rpg_participant_vitality(uuid), public.rpg_damage(uuid),
  public.rpg_session_new(text), public.rpg_session_add(uuid, uuid, uuid), public.rpg_session_set_order(uuid, uuid[]),
  public.rpg_session_set_status(uuid, boolean, text), public.rpg_session_adjust_vitality(uuid, integer),
  public.rpg_session_next_turn(uuid), public.rpg_session_remove(uuid), public.rpg_session_end(uuid),
  public.rpg_act(uuid, uuid[], text, uuid, text, numeric), public.rpg_session_state(uuid), public.rpg_session_list()
  TO authenticated;

-- The rule card for turns (the manual page follows by trigger).
INSERT INTO public.rpg_rules (key, title, body, source, sort_order)
SELECT 'turn_order', 'Taking Turns', $rule$Everyone in a fight takes turns, highest Agility first. Bramblemaw (Agility 7) goes before Karen (Agility 1). When two are tied, whoever joined the fight first goes first. The game master can move anyone up or down the line.

On your turn you make one attack, then end your turn. Creatures follow their card: Bramblemaw's Multiattack is two Claw rolls and one Bite roll.

When the last one in line ends their turn, a new round starts at the top. When a creature's turn starts, its legendary actions come back (Bramblemaw has 3), and each recharge action it has used rolls a six-sided die: Briar Roar is ready again on a 5 or 6.

Someone who cannot act (down, asleep, held, knocked down) is easier to hit. Their difficulty is their skill × 1 instead of × 2: Evade Enemy 5 is difficulty 5 instead of 10, so an attacker with skill 5 needs 50 instead of 67.$rule$, 'engine', 95
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_rules WHERE key = 'turn_order');

-- Guard: exactly one rpg_roll, and every rpg_ function the app calls is open to signed-in users.
DO $$
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpg_roll') <> 1 THEN
    RAISE EXCEPTION 'rpg_roll must have exactly one signature';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'rpg\_%'
              AND p.prorettype <> 'trigger'::regtype AND p.proname <> 'rpg_manual_page_sync'
              AND NOT has_function_privilege('authenticated', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'an rpg_ function the app calls is missing the authenticated grant';
  END IF;
END $$;
