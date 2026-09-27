-- Roleplaying unify6d: Exposed, and the Bramblemaw's Living Silence and Judging Gaze (Peter 2026-09-27, defaults 1A 2A).
-- An effect with "exposed" makes rolls to land a blow on its bearer (against Evade Enemy or Boots of the Gospel of
-- Peace) face that stat × 1 instead of × 2: "all" for every attacker, "source" for the one who put it on.
-- Living Silence (lair, 4 spiritual): rolls its Living Silence against each character's Listen × 2; those it beats
-- are Silenced (exposed to all) until the next round. Judging Gaze (bonus action, 1 beat, 3 spiritual): rolls its
-- Judging Gaze against one target's Courage × 2; if it lands the target is Judged (exposed to the Bramblemaw) until
-- the Bramblemaw's next turn starts. Two new card skills built like Grasping Roots.

CREATE OR REPLACE FUNCTION public.rpg_participant_exposed(p_target uuid, p_attacker uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Is this target exposed to this attacker: an effect on them with exposed 'all' (Silenced), or exposed 'source' put on
-- by this attacker (Judged). An exposed target defends at × 1 against blows (rpg_act).
SELECT EXISTS (SELECT 1 FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.id = p_target
                  AND (e->>'exposed' = 'all' OR (e->>'exposed' = 'source' AND e->>'source_id' = p_attacker::text)));
$function$;
REVOKE ALL ON FUNCTION public.rpg_participant_exposed(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_participant_exposed(uuid, uuid) TO service_role;

INSERT INTO public.rpg_stat_definitions (key, name, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, template_id)
SELECT v.key, v.name, 'fighting', 'derived', true, v.formula::jsonb, 0, v.sort_order, false, 2, 4, 'physical', c.id
  FROM public.rpg_creatures c,
       (VALUES ('living_silence', 'Living Silence', '{"div": 4, "parts": [["CG", 1], ["FO", 2], ["PR", 1]]}', 821),
               ('judging_gaze', 'Judging Gaze', '{"div": 4, "parts": [["CG", 1], ["FO", 1], ["PR", 2]]}', 822)) AS v(key, name, formula, sort_order)
 WHERE c.key = 'bramblemaw';

CREATE OR REPLACE FUNCTION public.rpg_action_text(p_action_id uuid, p_skill numeric DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One plain line for what a card's action does, built only from its row: the beats it takes on the creature's own
-- turn (actions only; a turn has beats_per_turn), its energy, the skill it rolls against which stat × the opponent
-- multiplier, whether it does damage, and its effect. With p_skill (a fight) the line carries the creature's number:
-- "1 beat · 3 physical energy · Rolls its Claw 10 against the target's Evade Enemy × 2 and does damage. A hit also
-- rolls its Strength against the target's Strength × 2; if that lands, the target is Knocked down and cannot act
-- until their turn starts." A revival rule (a trait whose effect is on 'zero') gets its own line: "At 0 vitality it
-- is Sunk and cannot act or be reached; after 2 rounds it rises with 1 vitality. A character ends it for good by
-- rolling Healing (Spiritual) against its Fascination with Evil × 2 (Sanctified)." Other traits get no line.
-- An effect that exposes (Silenced, Judged) says who faces the target at × 1: every attacker, or the creature itself.
DECLARE
  a        public.rpg_creature_actions%ROWTYPE;
  v_names  jsonb;
  v_m      text := trim_scale(public.rpg_setting('opponent_will_multiplier'))::text;
  v_per    numeric := public.rpg_setting('beats_per_turn');
  v_parts  text[] := '{}';
  v_fx     jsonb;
  v_ap     jsonb;
  v_fxt    text;
  v_line   text;
BEGIN
  SELECT * INTO a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND OR (a.kind = 'trait' AND a.effect->>'on' IS DISTINCT FROM 'zero') THEN RETURN NULL; END IF;
  SELECT jsonb_object_agg(d.key, d.name) INTO v_names
    FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  IF a.effect->>'on' = 'zero' THEN
    RETURN 'At 0 vitality it is ' || (a.effect->'apply'->>'name') || ' and cannot act or be reached; after '
        || (a.effect->'apply'->>'rounds') || ' rounds it rises with ' || coalesce(a.effect->'apply'->>'revive', '1') || ' vitality.'
        || CASE WHEN a.effect ? 'ended_by' THEN ' A character ends it for good by rolling '
             || coalesce(v_names->>(a.effect->'ended_by'->>'skill_key'), a.effect->'ended_by'->>'skill_key') || ' against its '
             || coalesce(v_names->>(a.effect->'ended_by'->>'against'), a.effect->'ended_by'->>'against') || ' × ' || v_m
             || ' (' || (a.effect->'ended_by'->>'name') || ').' ELSE '' END;
  END IF;

  IF a.kind IN ('action', 'bonus_action') AND coalesce(a.beats, 0) > 0 THEN
    v_parts := v_parts || (a.beats || CASE WHEN a.beats = 1 THEN ' beat' ELSE ' beats' END
                           || CASE WHEN a.beats >= v_per THEN ' (the whole turn)' ELSE '' END);
  END IF;
  IF coalesce(a.energy_cost, 0) > 0 THEN
    v_parts := v_parts || (a.energy_cost || ' ' || a.energy_type || ' energy');
  END IF;
  IF a.skill_key IS NOT NULL THEN
    v_parts := v_parts || ('Rolls its ' || coalesce(v_names->>a.skill_key, a.skill_key)
                           || coalesce(' ' || trim_scale(p_skill)::text, '')
                           || ' against ' || CASE WHEN a.area THEN 'each target''s ' ELSE 'the target''s ' END
                           || coalesce(v_names->>a.against, a.against) || ' × ' || v_m
                           || CASE WHEN a.deals_damage THEN ' and does damage' ELSE '' END);
  END IF;
  v_line := array_to_string(v_parts, ' · ');

  v_fx := a.effect;
  IF v_fx IS NOT NULL AND v_fx ? 'apply' THEN
    v_ap := v_fx->'apply';
    IF v_fx->>'on' = 'self' THEN
      v_fxt := 'It is ' || (v_ap->>'name')
            || coalesce(' (' || (SELECT string_agg(coalesce(v_names->>b.k, b.k) || ' +' || b.v, ', ')
                                   FROM jsonb_each_text(v_ap->'bonus') AS b(k, v)) || ')', '')
            || CASE v_ap->>'clear' WHEN 'turn_start' THEN ' until its next turn starts'
                                   WHEN 'round' THEN ' until the next round' ELSE '' END;
    ELSE
      v_fxt := CASE
                 WHEN v_fx->>'on' = 'hit' AND v_fx ? 'contest' THEN
                   'A hit also rolls its ' || coalesce(v_names->>(v_fx->'contest'->>'skill_key'), v_fx->'contest'->>'skill_key')
                   || ' against the target''s ' || coalesce(v_names->>(v_fx->'contest'->>'against'), v_fx->'contest'->>'against')
                   || ' × ' || v_m || '; if that lands, the target is '
                 WHEN v_fx->>'on' = 'hit' THEN 'A hit also leaves the target '
                 WHEN a.area THEN 'Those it beats are '
                 ELSE 'If it beats the target, they are '
               END
            || (v_ap->>'name')
            || CASE WHEN coalesce((v_ap->>'cannot_act')::boolean, false) THEN ' and cannot act' ELSE '' END
            || CASE v_ap->>'clear'
                 WHEN 'turn_start' THEN ' until their turn starts'
                 WHEN 'round' THEN ' until the next round'
                 WHEN 'source_turn' THEN ' until its next turn starts'
                 WHEN 'check' THEN ': on each of their turns they roll '
                                   || coalesce(v_names->>(v_ap->>'check_stat'), v_ap->>'check_stat')
                                   || ' against ' || trim_scale((v_ap->>'check_difficulty')::numeric)::text || ' to shake it off'
                                   || CASE WHEN v_ap->>'on_fail' = 'no_attack' THEN ', and if that fails they cannot attack that turn' ELSE '' END
                 ELSE '' END
            || CASE v_ap->>'exposed'
                 WHEN 'all' THEN ', and every attacker faces their Evade Enemy × 1'
                 WHEN 'source' THEN ', and its own attacks face their Evade Enemy × 1'
                 ELSE '' END;
    END IF;
    v_line := CASE WHEN v_line = '' THEN v_fxt ELSE v_line || '. ' || v_fxt END;
  END IF;
  RETURN nullif(v_line, '') || CASE WHEN nullif(v_line, '') IS NULL THEN '' ELSE '.' END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one in turn order; after the last one a new round begins at the top.
-- In setup this starts the fight at round 1. As a turn ends, every other creature with legendary actions left
-- rolls a six-sided die: on 4 or more it spends one on its best ready move it can afford (rpg_best_aim; Rending
-- Swipe: one swipe at the character it scores highest on). A new round frees anyone Held from an earlier round. At
-- the start of someone's turn they get up from Knocked down and their energy regains. A creature out of the fight
-- (dead, or waiting under its card's revival rule: rpg_participant_out) gets no turn. When a new round begins, a
-- creature whose revival wait is over rises with the vitality its card gives (the Bramblemaw: Sunk in round 5,
-- rises with 1 when round 7 begins). When someone's turn starts, what they put on others until then (clear
-- 'source_turn': the Bramblemaw's Judged) comes off.
-- A creature's legendary actions come back at its turn start (Bramblemaw: 3). The game master can pass any turn; a
-- player can end a character's turn, never a creature's.
DECLARE
  v_s record; v_cur_id uuid; v_cur_order integer; v_cur_created timestamptz; v_cur_creature uuid;
  v_next_id uuid; v_round integer; v_new_round boolean := false; v_next record; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_pick jsonb; v_best jsonb; v_top numeric;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT id, turn_order, created_at, creature_id INTO v_cur_id, v_cur_order, v_cur_created, v_cur_creature
    FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur_id IS NULL OR v_cur_creature IS NOT NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;

  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    PERFORM set_config('rpg.engine', 'on', true);
    SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
    FOR v_a IN SELECT p.id, p.name, p.legendary_left, p.creature_id FROM public.rpg_session_participants p
                WHERE p.session_id = p_session_id AND p.creature_id IS NOT NULL AND p.id <> v_cur_id AND p.legendary_left > 0
                  AND public.rpg_participant_can_act(p.id) LOOP
      v_best := NULL; v_top := 0;
      FOR v_la IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                   WHERE a.creature_id = v_a.creature_id AND a.kind = 'legendary' AND a.legendary_cost <= v_a.legendary_left
                     AND public.rpg_action_ready(v_a.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_a.id, v_la.id, v_tg);
        IF (v_pick->>'score')::numeric > v_top THEN
          v_top := (v_pick->>'score')::numeric; v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets');
        END IF;
      END LOOP;
      CONTINUE WHEN v_best IS NULL;
      v_d6 := floor(random() * 6)::integer + 1;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'legendary', 'info', v_a.id,
              v_a.name || ' rolls a six-sided die to react: ' || v_d6 || '. ' || CASE WHEN v_d6 >= 4 THEN 'It uses ' || (v_best->>'name') || '.' ELSE 'It holds back.' END);
      IF v_d6 >= 4 THEN
        PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      END IF;
    END LOOP;
  END IF;

  v_round := greatest(v_s.round, 1);
  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    SELECT id INTO v_next_id FROM public.rpg_session_participants
     WHERE session_id = p_session_id AND (turn_order, created_at) > (v_cur_order, v_cur_created)
       AND NOT public.rpg_participant_out(id)
     ORDER BY turn_order, created_at LIMIT 1;
  END IF;
  IF v_next_id IS NULL THEN
    SELECT id INTO v_next_id FROM public.rpg_session_participants WHERE session_id = p_session_id
       AND NOT public.rpg_participant_out(id)
     ORDER BY turn_order, created_at LIMIT 1;
    IF v_next_id IS NULL THEN RAISE EXCEPTION 'add someone to the fight first'; END IF;
    IF v_s.status = 'active' THEN v_round := v_s.round + 1; v_new_round := true; END IF;
  END IF;
  UPDATE public.rpg_sessions SET status = 'active', round = v_round, current_participant_id = v_next_id,
         turn_attacks = 0, turn_beats = 0, updated_at = now()
   WHERE id = p_session_id;
  IF v_s.status = 'setup' THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'start', 'info', 'The fight begins. Round 1.');
  ELSIF v_new_round THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'round', 'info', 'Round ' || v_round || ' begins.');
    FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'round' AND (e->>'round')::integer < v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
       WHERE p.id = v_a.id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
    END LOOP;
    FOR v_a IN SELECT p.id, p.name, p.character_id, e AS eff FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
                WHERE p.session_id = p_session_id AND e->>'clear' = 'revive' AND (e->>'until_round')::integer <= v_round LOOP
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
       WHERE p.id = v_a.id;
      UPDATE public.rpg_characters c
         SET vitality_damage = greatest((public.rpg_participant_vitality(v_a.id)->>'max')::integer - coalesce((v_a.eff->>'revive')::integer, 1), 0)
       WHERE c.id = v_a.character_id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id,
              v_a.name || ' rises with ' || coalesce((v_a.eff->>'revive')::integer, 1) || ' vitality.');
    END LOOP;
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  FOR v_a IN SELECT e->>'name' AS ename FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
     WHERE p.id = v_next_id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_next_id, v_next.name || ' gets up. No longer ' || v_a.ename || '.');
  END LOOP;
  FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
              WHERE p.session_id = p_session_id AND e->>'clear' = 'source_turn' AND e->>'source_id' = v_next_id::text LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE z->>'name' <> v_a.ename)
     WHERE p.id = v_a.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
  END LOOP;
  UPDATE public.rpg_session_participants
     SET energy_used_physical = greatest(energy_used_physical - coalesce(public.rpg_participant_value(id, 'PER'), 0)::integer, 0),
         energy_used_spiritual = greatest(energy_used_spiritual - coalesce(public.rpg_participant_value(id, 'SER'), 0)::integer, 0),
         legendary_left = CASE WHEN creature_id IS NOT NULL THEN coalesce((SELECT legendary_per_round FROM public.rpg_creatures WHERE id = v_next.creature_id), 0) ELSE legendary_left END
   WHERE id = v_next_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'current_participant_id', v_next_id);
END;
$function$;

-- rpg_act was last changed by an anchored patch: effects carry who put them on (source_id), and an exposed target
-- defends at × 1 against blows.
DO $$
DECLARE
  v text := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
  a1 text := 'public.rpg_participant_apply_effect(v_tid, v_fx->''apply'', v_use.name, v_s.round)';
  b1 text := 'public.rpg_participant_apply_effect(v_tid, (v_fx->''apply'') || jsonb_build_object(''source_id'', p_actor_id), v_use.name, v_s.round)';
  a2 text := 'v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid), v_defending);';
  b2 text := 'v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid) AND NOT (v_against IN (''EE'', ''BGP'') AND public.rpg_participant_exposed(v_tid, p_actor_id)), v_defending);';
BEGIN
  IF (length(v) - length(replace(v, a1, ''))) / length(a1) <> 2 THEN RAISE EXCEPTION 'rpg_act effect anchor not found twice'; END IF;
  IF (length(v) - length(replace(v, a2, ''))) / length(a2) <> 1 THEN RAISE EXCEPTION 'rpg_act difficulty anchor not found once'; END IF;
  EXECUTE replace(replace(v, a1, b1), a2, b2);
END $$;

-- The two entries now run. Descriptions are the picture only.
UPDATE public.rpg_creature_actions a
   SET skill_key = 'living_silence', against = 'LIS', area = true, deals_damage = false,
       effect = '{"on": "land", "apply": {"name": "Silenced", "clear": "round", "exposed": "all", "cannot_act": false}}'::jsonb,
       description = 'Every sound nearby is muffled.'
  FROM public.rpg_creatures c
 WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Living Silence';
UPDATE public.rpg_creature_actions a
   SET kind = 'bonus_action', beats = 1, energy_cost = 3, energy_type = 'spiritual',
       skill_key = 'judging_gaze', against = 'CO', area = false, deals_damage = false,
       effect = '{"on": "land", "apply": {"name": "Judged", "clear": "source_turn", "exposed": "source", "cannot_act": false}}'::jsonb,
       description = 'It fixes its glowing eyes on one creature it can see.'
  FROM public.rpg_creatures c
 WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Judging Gaze';

INSERT INTO public.rpg_rules (key, title, section, sort_order, source, body)
VALUES ('exposed', 'Exposed', 'Fights', 46, 'peter',
'Someone Exposed cannot see or hear a blow coming. A roll to land a blow on them faces their Evade Enemy × 1 instead of × 2, the same as someone who cannot act.
*Evade Enemy 5 is difficulty 5 instead of 10, so the Bramblemaw''s Claw 10 needs 100 × 5 ÷ (5 + 10) = 34 instead of 50.*

Silenced (the Bramblemaw''s Living Silence) is exposed to every attacker until the next round. Judged (its Judging Gaze) is exposed to the Bramblemaw alone until its next turn starts.');

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.rpg_participant_exposed(uuid,uuid)', 'EXECUTE') THEN RAISE EXCEPTION 'rpg_participant_exposed must stay internal'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_next_turn(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a fight function lost its grant';
  END IF;
END $$;
