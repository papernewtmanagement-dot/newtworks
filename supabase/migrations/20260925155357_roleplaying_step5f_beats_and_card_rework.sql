-- Roleplaying step 5f: beats, and the creature cards reworked so nothing is a lookalike (Peter 2026-09-25).
-- A turn is beats_per_turn (2) beats. Every creature action and every weapon costs beats: a quick move (Claw,
-- Rootstep, Snapping Bite, Cold Touch) costs 1, a heavy one 2. Two quick moves fit one turn, or a quick move and a
-- step. Cooldowns in turns stay. Bramblemaw's printed Multiattack becomes the trait that states its quick Claw;
-- Rending Swipe becomes a sweep at everyone; Sink Into Soil digs in (defense +4 until its next turn, an effect on
-- itself that rpg_participant_value counts); Bite clamps a Held target. Area actions aim at everyone standing.

ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS beats integer NOT NULL DEFAULT 2;
COMMENT ON COLUMN public.rpg_creature_actions.beats IS 'Beats of the turn the action costs on the creature''s own turn: 1 quick, 2 the whole turn. Legendary and lair actions cost none (they have their own budget).';
ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS area boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.rpg_creature_actions.area IS 'Aimed at everyone standing when the site plays it (Briar Roar, Rending Swipe, Grasping Roots).';
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS beats integer NOT NULL DEFAULT 2;
COMMENT ON COLUMN public.rpg_stat_definitions.beats IS 'For a weapon skill: beats of the turn an attack with it costs (2 = the whole turn; 1 = quick, twice a turn).';
ALTER TABLE public.rpg_sessions ADD COLUMN IF NOT EXISTS turn_beats integer NOT NULL DEFAULT 0;
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'beats_per_turn', 2, 'Beats in a turn: a quick action costs 1, a whole-turn action 2'
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings WHERE key = 'beats_per_turn');
DELETE FROM public.rpg_settings WHERE key = 'attacks_per_turn';

-- Bramblemaw, reworked.
UPDATE public.rpg_creature_actions SET beats = 1, cooldown_turns = 1,
  table_note = 'Its quick attack (1 beat): two Claws in a turn, or a Claw and a Rootstep. Rolls 10 against Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 50 or more; a roll of 80 does 30). A hit also rolls 10 against their Strength × 2; if that lands the target is knocked down until their turn starts and cannot act, so hitting them costs only Evade Enemy × 1.'
 WHERE id = 'b0d44b36-f883-4776-bea2-175d85e3de5e';
UPDATE public.rpg_creature_actions SET beats = 2, cooldown_turns = 1,
  effect = '{"on": "hit", "contest": {"skill_key": "strength", "against": "ST"}, "apply": {"name": "Held", "cannot_act": true, "clear": "round"}}'::jsonb,
  table_note = 'Its heavy attack, the whole turn (2 beats). Rolls 10 against Evade Enemy × 2 (Evade Enemy 5 → difficulty 10 → needs 50 or more). A hit also rolls its Strength 10 against their Strength × 2; if that lands they are Held in its jaws until the next round and cannot act, so hitting them costs only Evade Enemy × 1.'
 WHERE id = '6cd6cf78-1de3-45f8-9ebc-2f532ac0a2b9';
UPDATE public.rpg_creature_actions SET beats = 2, cooldown_turns = 3, area = true WHERE id = '2d099318-eaa5-443e-ab54-1c782357c5cf';
UPDATE public.rpg_creature_actions SET kind = 'trait', makes_attacks = NULL, skill = NULL, against = NULL, deals_damage = false, beats = 0,
  description = 'The Bramblemaw''s claws are quick. In one turn it can strike twice with a Claw, or Claw and Rootstep; its Bite and its Briar Roar take the whole turn.',
  table_note = 'The beat rule on this card: Claw and Rootstep cost 1 beat, Bite and Briar Roar cost 2, and a turn has 2.'
 WHERE id = '9b5557a6-cb1b-421b-987c-a3c970128981';
UPDATE public.rpg_creature_actions SET makes_attacks = NULL, skill = 8, against = 'EE', deals_damage = true, area = true, cooldown_turns = 2, legendary_cost = 1, beats = 0,
  description = 'The Bramblemaw sweeps its claws in a wide arc at everyone within reach.',
  table_note = 'Legendary, costs 1: rolls 8 against every standing character''s Evade Enemy × 2, one roll each (Evade Enemy 5 → difficulty 10 → needs 56 or more), and does damage. Weaker than a Claw, but it reaches everyone.'
 WHERE id = '9488d06d-abb2-41fd-aec9-3e56f287ee80';
UPDATE public.rpg_creature_actions SET beats = 1, cooldown_turns = 1,
  table_note = 'A quick step (1 beat) that can go with a Claw on its own turn, or a legendary action on someone else''s. Where it steps matters once the map is in.'
 WHERE id = '91235dab-2083-4b75-828b-cb8021af9973';
UPDATE public.rpg_creature_actions SET cooldown_turns = 3, legendary_cost = 2, beats = 0,
  effect = '{"on": "self", "apply": {"name": "Dug in", "cannot_act": false, "clear": "turn_start", "bonus": {"defense": 4}}}'::jsonb,
  table_note = 'Legendary, costs 2: it sinks partly into the ground. Until its next turn starts its defense counts 4 higher: 12 instead of 8, so the difficulty to hit it is 24 instead of 16 (Dagger 5 needs 83 instead of 77).'
 WHERE id = 'a762e880-c750-4447-b547-ef6906a91e0a';
UPDATE public.rpg_creature_actions SET area = true, cooldown_turns = 3, beats = 0 WHERE id = '89e0bc67-161f-4568-afb4-5dc51a3aab8d';
UPDATE public.rpg_creature_actions SET cooldown_turns = 3, beats = 0 WHERE id IN ('317d2d1a-481e-4d15-9354-9877504f83b4', 'ff46f664-e22e-4273-a5be-3d8110d835a5');
-- The other four: one quick move and one heavy move each.
UPDATE public.rpg_creature_actions SET beats = 2, cooldown_turns = 1 WHERE name IN ('Talon Dive', 'Shell Slam', 'Gore') AND kind = 'action';
UPDATE public.rpg_creature_actions SET beats = 1, cooldown_turns = 1 WHERE name IN ('Snapping Bite', 'Cold Touch') AND kind = 'action';
UPDATE public.rpg_creature_actions SET beats = 2, cooldown_turns = 3, area = true WHERE name = 'Hunting Screech' AND kind = 'action';
UPDATE public.rpg_creature_actions SET beats = 2, cooldown_turns = 2, area = true WHERE name = 'Lure' AND kind = 'action';
UPDATE public.rpg_creature_actions SET beats = 2, cooldown_turns = 2 WHERE name = 'Charge' AND kind = 'action';
UPDATE public.rpg_creature_actions SET table_note = 'Quick (1 beat): twice in a turn. ' || table_note WHERE name IN ('Snapping Bite', 'Cold Touch') AND kind = 'action' AND table_note NOT LIKE 'Quick (1 beat)%';
UPDATE public.rpg_creature_actions SET table_note = 'The whole turn (2 beats). ' || table_note WHERE name IN ('Talon Dive', 'Shell Slam', 'Gore', 'Hunting Screech', 'Lure', 'Charge') AND kind = 'action' AND table_note NOT LIKE 'The whole turn%';
UPDATE public.rpg_rules
   SET body = replace(body,
     E'\n\nA creature''s actions cool down. After it uses one, that action comes back after its cooldown in turns: Claw on its next turn, Briar Roar three turns later. A creature makes one attack a turn; a printed Multiattack is not used. Its legendary actions come from a roll: at the end of anyone else''s turn the site rolls a six-sided die for it, and on 4 or more it spends one on its best ready move (Rending Swipe: one Claw), up to its number a round.',
     E'\n\nA turn is 2 beats, and every action costs beats. A quick one like Bramblemaw''s Claw costs 1, so it can claw twice or claw and step; a heavy one like its Bite or Briar Roar costs 2, the whole turn. A weapon costs 2 beats unless it is a quick one. Each action also has a cooldown in turns: Claw is back next turn, Briar Roar three turns later. A creature''s legendary actions come from a roll: at the end of anyone else''s turn the site rolls a six-sided die for it, and on 4 or more it spends one on its best ready move (Rending Swipe: a sweep at everyone), up to its number a round.')
 WHERE key = 'turn_order';

CREATE OR REPLACE FUNCTION public.rpg_participant_value(p_participant_id uuid, p_stat_key text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One participant's value for one stat. Characters read their sheet (rpg_sheet), so items and earned levels count.
-- Creatures read the character-scale column that plays that stat: Evade Enemy EE → defense_skill, Courage CO →
-- will_skill, Strength ST → strength_skill, Agility AG → agility_skill, Physical Vitality PV → vitality; and their
-- own skills by name (attack, defense, strength, will, stealth, awareness, agility). An effect on them with a
-- bonus for that stat adds to it: Dug in gives Bramblemaw defense 8 + 4 = 12.
-- Karen: EE → 5, AG → 1. Bramblemaw: EE → 8, CO → 10, ST → 10, AG → 7, PV → 150.
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
    v_key := CASE p_stat_key WHEN 'EE' THEN 'defense' WHEN 'CO' THEN 'will' WHEN 'ST' THEN 'strength' WHEN 'AG' THEN 'agility' WHEN 'PV' THEN 'vitality' ELSE p_stat_key END;
    v_val := CASE v_key
      WHEN 'defense' THEN v_c.defense_skill WHEN 'will' THEN v_c.will_skill WHEN 'strength' THEN v_c.strength_skill
      WHEN 'agility' THEN v_c.agility_skill WHEN 'vitality' THEN v_c.vitality WHEN 'attack' THEN v_c.attack_skill
      WHEN 'stealth' THEN v_c.stealth_skill WHEN 'awareness' THEN v_c.awareness_skill END;
  END IF;
  IF v_val IS NULL THEN RETURN NULL; END IF;
  SELECT coalesce(sum((e->'bonus'->>v_key)::numeric), 0) INTO v_bonus FROM jsonb_array_elements(v_p.effects) e WHERE e ? 'bonus';
  RETURN v_val + v_bonus;
END;
$function$;

-- rpg_act: beats instead of one-attack-a-turn, and effects a creature puts on itself. In-place edits, anchors checked.
DO $do$
DECLARE v_src text; a text[]; n text[]; i integer;
BEGIN
  v_src := pg_get_functiondef('public.rpg_act'::regproc);
  IF position('turn_beats' IN v_src) > 0 THEN RETURN; END IF;
  a := ARRAY[
    'v_plan jsonb := ''[]''::jsonb; v_step jsonb; v_e jsonb; v_n integer;',
    'v_per integer := public.rpg_setting(''attacks_per_turn'')::integer;',
    'SELECT name, is_attack INTO v_stat_name, v_is_attack FROM public.rpg_stat_definitions WHERE key = p_stat_key;',
    'IF v_s.turn_attacks >= v_per THEN RAISE EXCEPTION ''% has already attacked this turn'', v_actor.name; END IF;',
    'IF v_act.kind = ''action'' AND v_s.current_participant_id = p_actor_id AND v_s.turn_attacks >= v_per THEN' || E'\n'
      || '      RAISE EXCEPTION ''% has already taken its action this turn'', v_actor.name;' || E'\n'
      || '    END IF;',
    'UPDATE public.rpg_sessions SET turn_attacks = greatest(turn_attacks, v_per) WHERE id = v_s.id;',
    'IF v_kind = ''action'' AND jsonb_array_length(v_plan) = 0 THEN' || E'\n'
      || '    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)' || E'\n'
      || '    VALUES (v_s.agency_id, v_s.id, v_s.round, ''action'', ''info'', p_actor_id, v_actor.name || '' uses '' || v_act.name || ''.'');',
    'IF v_kind = ''attack'' OR (v_kind = ''action'' AND v_act.kind = ''action'' AND v_s.current_participant_id = p_actor_id) THEN' || E'\n'
      || '    UPDATE public.rpg_sessions SET turn_attacks = turn_attacks + 1 WHERE id = v_s.id;' || E'\n'
      || '  END IF;'];
  n := ARRAY[
    'v_plan jsonb := ''[]''::jsonb; v_step jsonb; v_e jsonb; v_n integer; v_beats integer := 0;',
    'v_per integer := public.rpg_setting(''beats_per_turn'')::integer;',
    'SELECT name, is_attack, beats INTO v_stat_name, v_is_attack, v_beats FROM public.rpg_stat_definitions WHERE key = p_stat_key;',
    'IF v_s.turn_beats + v_beats > v_per THEN RAISE EXCEPTION ''% has % of % beats left this turn and % takes %'', v_actor.name, v_per - v_s.turn_beats, v_per, v_stat_name, v_beats; END IF;',
    'IF v_act.kind IN (''action'', ''bonus_action'') AND v_s.current_participant_id = p_actor_id THEN' || E'\n'
      || '      IF v_s.turn_beats + v_act.beats > v_per THEN' || E'\n'
      || '        RAISE EXCEPTION ''% has % of % beats left this turn and % takes %'', v_actor.name, v_per - v_s.turn_beats, v_per, v_act.name, v_act.beats;' || E'\n'
      || '      END IF;' || E'\n'
      || '      v_beats := v_act.beats;' || E'\n'
      || '    END IF;',
    'UPDATE public.rpg_sessions SET turn_beats = v_per WHERE id = v_s.id;',
    'IF v_kind = ''action'' AND jsonb_array_length(v_plan) = 0 THEN' || E'\n'
      || '    IF v_act.effect->>''on'' = ''self'' THEN' || E'\n'
      || '      PERFORM public.rpg_participant_apply_effect(p_actor_id, v_act.effect->''apply'', v_act.name, v_s.round);' || E'\n'
      || '    END IF;' || E'\n'
      || '    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)' || E'\n'
      || '    VALUES (v_s.agency_id, v_s.id, v_s.round, ''action'', ''info'', p_actor_id, v_actor.name || '' uses '' || v_act.name || ''.''' || E'\n'
      || '            || CASE WHEN v_act.effect->>''on'' = ''self'' THEN '' It is '' || (v_act.effect->''apply''->>''name'') || ''.'' ELSE '''' END);',
    'IF v_beats > 0 AND v_kind IN (''attack'', ''action'') THEN' || E'\n'
      || '    UPDATE public.rpg_sessions SET turn_beats = turn_beats + v_beats WHERE id = v_s.id;' || E'\n'
      || '  END IF;'];
  FOR i IN 1..array_length(a, 1) LOOP
    IF (length(v_src) - length(replace(v_src, a[i], ''))) / length(a[i]) <> 1 THEN RAISE EXCEPTION 'rpg_act anchor % not unique', i; END IF;
    v_src := replace(v_src, a[i], n[i]);
  END LOOP;
  EXECUTE v_src;
END $do$;
-- next turn: the beats come back
DO $do$
DECLARE v_src text; v_a text := 'turn_attacks = 0, updated_at = now()';
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_next_turn'::regproc);
  IF position('turn_beats' IN v_src) > 0 THEN RETURN; END IF;
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN RAISE EXCEPTION 'next_turn anchor not unique'; END IF;
  EXECUTE replace(v_src, v_a, 'turn_attacks = 0, turn_beats = 0, updated_at = now()');
END $do$;
-- state: the beats of the turn, the beats each action and weapon costs
DO $do$
DECLARE v_src text; a text[]; n text[]; i integer;
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_state'::regproc);
  IF position('turn_beats' IN v_src) > 0 THEN RETURN; END IF;
  a := ARRAY['''attacks_per_turn'', public.rpg_setting(''attacks_per_turn''), ''updated_at'', v_s.updated_at',
             '''cooldown_turns'', a.cooldown_turns, ''ready'',',
             'jsonb_build_object(''key'', s->>''key'', ''name'', s->>''name'', ''value'', s->''value'')'];
  n := ARRAY['''turn_beats'', v_s.turn_beats, ''beats_per_turn'', public.rpg_setting(''beats_per_turn''), ''updated_at'', v_s.updated_at',
             '''beats'', a.beats, ''area'', a.area, ''cooldown_turns'', a.cooldown_turns, ''ready'',',
             'jsonb_build_object(''key'', s->>''key'', ''name'', s->>''name'', ''value'', s->''value'', ''beats'', d.beats)'];
  FOR i IN 1..3 LOOP
    IF (length(v_src) - length(replace(v_src, a[i], ''))) / length(a[i]) <> 1 THEN RAISE EXCEPTION 'state anchor % not unique', i; END IF;
    v_src := replace(v_src, a[i], n[i]);
  END LOOP;
  EXECUTE v_src;
END $do$;

CREATE OR REPLACE FUNCTION public.rpg_best_aim(p_actor_id uuid, p_action_id uuid, p_targets uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site aims an action: an area action (Briar Roar, Rending Swipe) and one that only lands an effect go
-- at everyone they score anything on; a single attack goes at the target it scores highest on; an action on the
-- creature itself (Sink Into Soil) needs no target and is worth 10 unless it already has that effect. Returns the
-- targets and the score, 0 with no targets when nothing is worth doing.
DECLARE v_a record; v_dmg boolean; v_t uuid; v_sc numeric; v_best uuid; v_top numeric := 0; v_list uuid[] := '{}'; v_sum numeric := 0;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', 0); END IF;
  IF v_a.effect->>'on' = 'self' THEN
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score',
      CASE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e WHERE p.id = p_actor_id AND e->>'name' = v_a.effect->'apply'->>'name') THEN 0 ELSE 10 END);
  END IF;
  v_dmg := coalesce(v_a.deals_damage, false) AND NOT v_a.area;
  FOREACH v_t IN ARRAY coalesce(p_targets, '{}'::uuid[]) LOOP
    v_sc := public.rpg_action_score(p_actor_id, p_action_id, v_t);
    IF v_dmg THEN
      IF v_sc > v_top THEN v_top := v_sc; v_best := v_t; END IF;
    ELSIF v_sc > 0 THEN
      v_list := v_list || v_t; v_sum := v_sum + v_sc;
    END IF;
  END LOOP;
  IF v_dmg THEN
    RETURN jsonb_build_object('targets', CASE WHEN v_best IS NULL THEN '[]'::jsonb ELSE jsonb_build_array(v_best) END, 'score', v_top);
  END IF;
  RETURN jsonb_build_object('targets', to_jsonb(v_list), 'score', v_sum);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_auto_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The site plays a creature's turn and passes it. A ready lair action is free and goes first when it is worth
-- anything. Then, while beats remain in the turn, it takes the best-scoring ready move that fits the beats left
-- (rpg_best_aim over rpg_action_score, with a little randomness): a quick Claw twice, or Claw and Rootstep, or one
-- heavy Bite. It stops when nothing ready is worth a move. Legendary actions come from the die rolled as other
-- turns end.
DECLARE
  v_s record; v_p record; v_a record; v_targets uuid[]; v_lines jsonb := '[]'::jsonb; v_r jsonb; v_pick jsonb; v_best jsonb; v_top numeric; v_sc numeric;
  v_per integer := public.rpg_setting('beats_per_turn')::integer; v_left integer; v_guard integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master runs a creature''s turn'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = v_s.current_participant_id;
  IF NOT FOUND OR v_p.creature_id IS NULL THEN RAISE EXCEPTION 'it is not a creature''s turn'; END IF;
  SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.character_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
  IF NOT public.rpg_participant_can_act(v_p.id) THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' cannot act this turn.');
  ELSIF coalesce(cardinality(v_targets), 0) = 0 THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' has no one left to attack.');
  ELSE
    v_best := NULL; v_top := 0;
    FOR v_a IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                WHERE a.creature_id = v_p.creature_id AND a.kind = 'lair' AND public.rpg_action_ready(v_p.id, a.id) LOOP
      v_pick := public.rpg_best_aim(v_p.id, v_a.id, v_targets);
      IF (v_pick->>'score')::numeric > v_top THEN v_top := (v_pick->>'score')::numeric; v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets'); END IF;
    END LOOP;
    IF v_best IS NOT NULL THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' uses its lair: ' || (v_best->>'name') || '.');
      v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      v_lines := v_lines || (v_r->'results');
    END IF;
    LOOP
      v_guard := v_guard + 1;
      EXIT WHEN v_guard > 4;
      SELECT turn_beats INTO v_left FROM public.rpg_sessions WHERE id = p_session_id;
      v_left := v_per - v_left;
      EXIT WHEN v_left <= 0;
      SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
       WHERE p.session_id = p_session_id AND p.character_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
      EXIT WHEN coalesce(cardinality(v_targets), 0) = 0;
      v_best := NULL; v_top := 0;
      FOR v_a IN SELECT a.id, a.name, a.beats FROM public.rpg_creature_actions a
                  WHERE a.creature_id = v_p.creature_id AND a.kind IN ('action', 'bonus_action') AND a.beats <= v_left AND public.rpg_action_ready(v_p.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_p.id, v_a.id, v_targets);
        v_sc := (v_pick->>'score')::numeric * (0.85 + random() * 0.3);
        IF v_sc > v_top THEN v_top := v_sc; v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets'); END IF;
      END LOOP;
      EXIT WHEN v_best IS NULL;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || (v_best->>'name') || '.');
      v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      v_lines := v_lines || (v_r->'results');
    END LOOP;
    IF jsonb_array_length(v_lines) = 0 THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' has nothing worth using this turn.');
    END IF;
  END IF;
  PERFORM public.rpg_session_next_turn(p_session_id);
  RETURN jsonb_build_object('kind', 'auto', 'results', v_lines);
END;
$function$;

DO $do$
BEGIN
  IF position('turn_beats' IN pg_get_functiondef('public.rpg_act'::regproc)) = 0 THEN RAISE EXCEPTION 'rpg_act edit did not land'; END IF;
  IF position('turn_beats' IN pg_get_functiondef('public.rpg_session_next_turn'::regproc)) = 0 THEN RAISE EXCEPTION 'next_turn edit did not land'; END IF;
  IF position('turn_beats' IN pg_get_functiondef('public.rpg_session_state'::regproc)) = 0 THEN RAISE EXCEPTION 'state edit did not land'; END IF;
  IF EXISTS (SELECT 1 FROM public.rpg_creature_actions WHERE makes_attacks IS NOT NULL) THEN RAISE EXCEPTION 'a multi-attack wrapper remains'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.rpg_settings WHERE key = 'beats_per_turn') THEN RAISE EXCEPTION 'beats_per_turn missing'; END IF;
  IF NOT (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'rpg\_%' AND p.prorettype <> 'trigger'::regtype AND p.proname <> 'rpg_manual_page_sync') THEN
    RAISE EXCEPTION 'an rpg_ function lost its grant';
  END IF;
END $do$;
