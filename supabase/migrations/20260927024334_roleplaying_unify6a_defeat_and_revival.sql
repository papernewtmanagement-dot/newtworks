-- Roleplaying unify6a: what happens at 0 vitality (Peter 2026-09-27, defaults 1A 2A 3A).
-- A character at 0 is down (cannot act, hit at stat × 1) and never dies. A creature at 0 dies, unless its card has a
-- revival rule: a trait whose effect is {"on": "zero", "apply": {name, cannot_act, clear 'revive', rounds, revive},
-- "ended_by": {skill_key, against, name}}. The Bramblemaw's Rooted Resilience: at 0 it is Sunk, out of reach and out of
-- the turn order; when round +2 begins it rises with 1 vitality; a character who lands Healing (Spiritual) against its
-- Fascination with Evil × 2 ends it for good (Sanctified), and then it is dead. Every time it drops to 0 again it sinks
-- again, until it is sanctified.

CREATE OR REPLACE FUNCTION public.rpg_participant_out(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A creature at 0 vitality is out of the fight: dead, or waiting under its card's revival rule. It gets no turn and
-- nobody can attack it. A character at 0 is only down, never out.
SELECT p.creature_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer <= 0
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;
REVOKE ALL ON FUNCTION public.rpg_participant_out(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_participant_out(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_session_adjust_vitality(p_participant_id uuid, p_delta integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Damage (+) or healing (−) for anyone in a fight, carried on their character through rpg_adjust_vitality. Damage
-- stops at 0 left, healing stops at full. Karen 41, hit for 94 → 0 left, down. A Bramblemaw 149, hit for 30 → 119.
-- Only the game master changes it by hand; a player's attack changes it through rpg_act (rpg.move).
-- When a creature drops to 0 its card decides: a revival rule (an effect on 'zero') puts that effect on it unless it
-- has already been ended for good (the Bramblemaw is Sunk until round + 2), otherwise it dies. The returned vitality
-- then carries 'fell' ("is Sunk until round 7" / "dies") for the log. Healing a creature back above 0 lifts the wait.
DECLARE v_p record; v_v jsonb; v_after jsonb; v_delta integer; v_rule_name text; v_rule jsonb; v_round integer; v_eff jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF NOT (public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on' OR coalesce(current_setting('rpg.move', true), '') = 'on') THEN
    RAISE EXCEPTION 'only the game master changes vitality in a fight';
  END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  v_v := public.rpg_participant_vitality(p_participant_id);
  v_delta := CASE WHEN coalesce(p_delta, 0) > 0 THEN least(p_delta, (v_v->>'left')::integer)
                  ELSE greatest(coalesce(p_delta, 0), -(v_v->>'damage')::integer) END;
  IF v_delta <> 0 THEN PERFORM public.rpg_adjust_vitality(v_p.character_id, v_delta); END IF;
  v_after := public.rpg_participant_vitality(p_participant_id);
  IF v_p.creature_id IS NOT NULL AND (v_v->>'left')::integer > 0 AND (v_after->>'left')::integer <= 0 THEN
    SELECT a.name, a.effect INTO v_rule_name, v_rule FROM public.rpg_creature_actions a
     WHERE a.creature_id = v_p.creature_id AND a.effect->>'on' = 'zero' ORDER BY a.sort_order LIMIT 1;
    IF v_rule IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_p.effects) e WHERE e->>'name' = v_rule->'ended_by'->>'name') THEN
      SELECT round INTO v_round FROM public.rpg_sessions WHERE id = v_p.session_id;
      v_eff := (v_rule->'apply') || jsonb_build_object('until_round', coalesce(v_round, 1) + coalesce((v_rule->'apply'->>'rounds')::integer, 1),
                                                    'ended_by', v_rule->'ended_by', 'source', v_rule_name);
      UPDATE public.rpg_session_participants SET effects = effects || jsonb_build_array(v_eff) WHERE id = p_participant_id;
      v_after := v_after || jsonb_build_object('fell', 'is ' || (v_eff->>'name') || ' until round ' || (v_eff->>'until_round'));
    ELSE
      v_after := v_after || jsonb_build_object('fell', 'dies');
    END IF;
  ELSIF v_p.creature_id IS NOT NULL AND (v_after->>'left')::integer > 0 THEN
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
     WHERE p.id = p_participant_id AND EXISTS (SELECT 1 FROM jsonb_array_elements(p.effects) z WHERE z ? 'ended_by');
  END IF;
  RETURN v_after;
END;
$function$;

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
                 WHEN 'check' THEN ': on each of their turns they roll '
                                   || coalesce(v_names->>(v_ap->>'check_stat'), v_ap->>'check_stat')
                                   || ' against ' || trim_scale((v_ap->>'check_difficulty')::numeric)::text || ' to shake it off'
                                   || CASE WHEN v_ap->>'on_fail' = 'no_attack' THEN ', and if that fails they cannot attack that turn' ELSE '' END
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
-- rises with 1 when round 7 begins).
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

CREATE OR REPLACE FUNCTION public.rpg_session_state(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Everything the Play tab shows for one fight in one read: the fight, everyone in turn order with their effects and
-- whether they can act, a character's pending check (Frightened → Courage against 8, needs 54), the last 60 log
-- lines with their outcome keys. A creature's numbers come from the sheet it was made with; players get creatures
-- without numbers and no game-master lists. The game master gets each creature's stats (its own card's skills
-- first) and, on every action, the number it rolls (the Bramblemaw's Claw: 10) and one line of what it does
-- (rpg_action_text, the same line the creature card shows). Everyone sees whether a creature is out: 'out' is Dead,
-- or its revival rule's name (Sunk), and 'revival' says when it rises and which roll ends it for good.
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb; v_vals jsonb; v_rev jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY turn_order, created_at LOOP
    IF v_p.creature_id IS NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'energy_cost', d.energy_cost, 'energy_type', d.energy_type)
                                    ORDER BY (s->>'value')::numeric DESC, s->>'name'), '[]'::jsonb)
                      FROM jsonb_array_elements(v_sheet->'stats') s
                      JOIN public.rpg_stat_definitions d ON d.key = s->>'key' AND d.is_attack),
        'pending_check', (SELECT jsonb_build_object('name', e->>'name', 'stat', e->>'check_stat', 'stat_name', d.name,
                            'difficulty', (e->>'check_difficulty')::numeric,
                            'skill', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                            'needed', public.rpg_needed((SELECT (s->>'value')::numeric FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = e->>'check_stat'),
                                                        (e->>'check_difficulty')::numeric)->'needed')
                            FROM jsonb_array_elements(v_p.effects) e JOIN public.rpg_stat_definitions d ON d.key = e->>'check_stat'
                           WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1));
    ELSE
      SELECT * INTO v_c FROM public.rpg_creatures WHERE id = v_p.creature_id;
      v_vit := public.rpg_participant_vitality(v_p.id);
      v_item := jsonb_build_object('kind', 'creature', 'creature_id', v_p.creature_id, 'color', v_c.color,
        'vitality_share', CASE WHEN (v_vit->>'max')::numeric > 0 THEN round((v_vit->>'left')::numeric / (v_vit->>'max')::numeric, 3) END);
      v_rev := NULL;
      SELECT e INTO v_rev FROM jsonb_array_elements(v_p.effects) e WHERE e ? 'ended_by' LIMIT 1;
      v_item := v_item || jsonb_build_object(
        'out', CASE WHEN (v_vit->>'left')::integer <= 0 THEN coalesce(v_rev->>'name', 'Dead') END,
        'revival', CASE WHEN v_rev IS NOT NULL THEN jsonb_build_object(
            'name', v_rev->>'name', 'rises_round', (v_rev->>'until_round')::integer, 'ends_as', v_rev->'ended_by'->>'name',
            'skill_key', v_rev->'ended_by'->>'skill_key',
            'skill_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = v_rev->'ended_by'->>'skill_key'),
            'against', v_rev->'ended_by'->>'against',
            'against_name', (SELECT d.name FROM public.rpg_stat_definitions d WHERE d.key = v_rev->'ended_by'->>'against')) END);
      IF v_gm THEN
        v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
        v_vals := (SELECT coalesce(jsonb_object_agg(s->>'key', s->'value'), '{}'::jsonb) FROM jsonb_array_elements(v_sheet->'stats') s);
        v_item := v_item || jsonb_build_object(
          'vitality_max', (v_vit->>'max')::integer, 'vitality_left', (v_vit->>'left')::integer,
          'legendary_left', v_p.legendary_left, 'legendary_per_round', v_c.legendary_per_round, 'agility', v_vals->'AG',
          'skills', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'own', d.template_id = v_p.creature_id)
                                     ORDER BY (d.template_id IS DISTINCT FROM v_p.creature_id), o), '[]'::jsonb)
                       FROM jsonb_array_elements(v_sheet->'stats') WITH ORDINALITY AS t(s, o)
                       JOIN public.rpg_stat_definitions d ON d.key = s->>'key'),
          'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill_key', coalesce(u.skill_key, a.skill_key),
                          'skill', v_vals->coalesce(u.skill_key, a.skill_key),
                          'line', public.rpg_action_text(coalesce(u.id, a.id), (v_vals->>coalesce(u.skill_key, a.skill_key))::numeric),
                          'beats', a.beats, 'ready', a.ready,
                          'usable', (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(a.makes_attacks, '[]'::jsonb)) e) <= 1)
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3 WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM (SELECT x.*, public.rpg_action_ready(v_p.id, x.id) AS ready FROM public.rpg_creature_actions x
                               WHERE x.creature_id = v_p.creature_id AND x.kind <> 'trait') a
                        LEFT JOIN public.rpg_creature_actions u ON u.creature_id = a.creature_id AND u.name = a.makes_attacks->0->>'action'
                              AND jsonb_array_length(coalesce(a.makes_attacks, '[]'::jsonb)) = 1));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note, 'can_act_now', public.rpg_participant_can_act(v_p.id),
                 'effects', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'cannot_act', coalesce((e->>'cannot_act')::boolean, false), 'source', e->>'source')), '[]'::jsonb)
                               FROM jsonb_array_elements(v_p.effects) e),
                 'energy', public.rpg_participant_energy(v_p.id), 'is_current', coalesce(v_p.id = v_s.current_participant_id, false)) || v_item);
  END LOOP;
  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'turn_attacks', v_s.turn_attacks,
                 'turn_beats', v_s.turn_beats, 'beats_per_turn', public.rpg_setting('beats_per_turn'), 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'outcome', e.outcome, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND c.session_id IS NULL
                          AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c
                       WHERE c.is_active AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.creature_id = c.id AND a.kind <> 'trait'))) END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_creature_actions_skill_check()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- An action can only use stats its card has: a shared one, or one that belongs to the card or a card above it
-- (rpg_template_stat_defs). That holds for the skill it rolls (skill_key), the skill a contest rolls, and every stat
-- an effect gives a bonus to. The Bramblemaw's Claw may roll Claw; the Boar's Gore may not. Sink Into Soil may give
-- Evade Enemy (EE) + 4; a bonus to "defense" is refused, because no sheet has a stat by that name. A revival rule's
-- ending roll (ended_by: the skill a character rolls, the stat the creature resists with) must name real stats: the
-- roller's skill any Creature has, the creature's stat its own card has.
DECLARE v_card uuid; v_name text; v_k text;
BEGIN
  SELECT c.id, c.name INTO v_card, v_name FROM public.rpg_creatures c WHERE c.id = NEW.creature_id;
  IF NEW.skill_key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.skill_key) THEN
    RAISE EXCEPTION '% on the % card cannot roll %: the card does not have that skill', NEW.name, v_name, NEW.skill_key;
  END IF;
  IF NEW.effect->'contest'->>'skill_key' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.effect->'contest'->>'skill_key') THEN
    RAISE EXCEPTION '% on the % card cannot contest with %: the card does not have that stat', NEW.name, v_name, NEW.effect->'contest'->>'skill_key';
  END IF;
  IF NEW.effect ? 'ended_by' THEN
    IF NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.key = NEW.effect->'ended_by'->>'skill_key') THEN
      RAISE EXCEPTION '% on the % card is ended by %, which is not a stat', NEW.name, v_name, NEW.effect->'ended_by'->>'skill_key';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = NEW.effect->'ended_by'->>'against') THEN
      RAISE EXCEPTION '% on the % card is resisted with %, which the card does not have', NEW.name, v_name, NEW.effect->'ended_by'->>'against';
    END IF;
  END IF;
  IF jsonb_typeof(NEW.effect->'apply'->'bonus') = 'object' THEN
    FOR v_k IN SELECT jsonb_object_keys(NEW.effect->'apply'->'bonus') LOOP
      IF NOT EXISTS (SELECT 1 FROM public.rpg_template_stat_defs(v_card) d WHERE d.key = v_k) THEN
        RAISE EXCEPTION '% on the % card gives a bonus to %, which the card does not have', NEW.name, v_name, v_k;
      END IF;
    END LOOP;
  END IF;
  RETURN NEW;
END;
$function$;

-- rpg_act and rpg_act_extra were last changed by anchored patches, so they are patched the same way; every anchor
-- must be found exactly once or nothing changes.
DO $$
DECLARE
  v text := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
  x text := pg_get_functiondef('public.rpg_act_extra(uuid,integer)'::regprocedure);
  a text[]; b text[]; i integer;
BEGIN
  a := ARRAY[
    'v_tid uuid; v_cid uuid;',
    E'    RAISE EXCEPTION ''every target must be in this fight'';\n  END IF;\n',
    E'      v_kind := ''check''; v_beats := 0; v_ecost := 0; v_against := p_against;\n',
    E'  IF v_beats > 0 AND v_kind IN (''attack'', ''action'') THEN',
    E'  IF v_ecost > 0 AND v_kind IN (''attack'', ''action'') THEN',
    E'      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid), v_defending);\n',
    E'''' || ' ' || ''' || v_t.name || '' is down.''',
    E'ELSE '''' END;\n      IF v_kind = ''action'' AND v_fx IS NOT NULL AND v_first->>''result'' <> '''''
  ];
  b := ARRAY[
    'v_tid uuid; v_cid uuid; v_rev jsonb; v_ending boolean := false;',
    E'    RAISE EXCEPTION ''every target must be in this fight'';\n  END IF;\n'
    || E'  -- A creature at 0 vitality is out of reach: dead, or waiting under its card''s revival rule, when only the roll\n'
    || E'  -- that rule names reaches it (Sunk → Healing (Spiritual) against its Fascination with Evil).\n'
    || E'  FOR v_tid IN SELECT unnest(v_targets) LOOP\n'
    || E'    SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;\n'
    || E'    CONTINUE WHEN v_t.creature_id IS NULL OR (public.rpg_participant_vitality(v_tid)->>''left'')::integer > 0;\n'
    || E'    v_rev := NULL;\n'
    || E'    SELECT e INTO v_rev FROM jsonb_array_elements(v_t.effects) e WHERE e ? ''ended_by'' LIMIT 1;\n'
    || E'    IF v_rev IS NULL THEN RAISE EXCEPTION ''% is dead'', v_t.name; END IF;\n'
    || E'    IF p_stat_key IS DISTINCT FROM v_rev->''ended_by''->>''skill_key'' OR p_against IS DISTINCT FROM v_rev->''ended_by''->>''against'' THEN\n'
    || E'      RAISE EXCEPTION ''% is %: only % against its % reaches it'', v_t.name, v_rev->>''name'',\n'
    || E'        (SELECT name FROM public.rpg_stat_definitions WHERE key = v_rev->''ended_by''->>''skill_key''),\n'
    || E'        (SELECT name FROM public.rpg_stat_definitions WHERE key = v_rev->''ended_by''->>''against'');\n'
    || E'    END IF;\n'
    || E'    v_ending := true;\n'
    || E'  END LOOP;\n',
    E'      v_kind := ''check''; v_against := p_against;\n'
    || E'      IF v_ending THEN\n'
    || E'        IF v_s.turn_beats + coalesce(v_beats, 0) > v_per THEN RAISE EXCEPTION ''% has % of % beats left this turn and % takes %'', v_actor.name, v_per - v_s.turn_beats, v_per, v_stat_name, v_beats; END IF;\n'
    || E'        IF (v_energy->v_etype->>''left'')::integer < coalesce(v_ecost, 0) THEN RAISE EXCEPTION ''% has % % energy left and % costs %'', v_actor.name, v_energy->v_etype->>''left'', v_etype, v_stat_name, v_ecost; END IF;\n'
    || E'      ELSE\n'
    || E'        v_beats := 0; v_ecost := 0;\n'
    || E'      END IF;\n',
    E'  IF v_beats > 0 AND (v_kind IN (''attack'', ''action'') OR v_ending) THEN',
    E'  IF v_ecost > 0 AND (v_kind IN (''attack'', ''action'') OR v_ending) THEN',
    E'      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid), v_defending);\n'
    || E'      -- The roll that ends a revival rule faces the creature''s stat × 2, as if it could act.\n'
    || E'      IF v_ending THEN v_diff := public.rpg_difficulty(v_def, true, false); END IF;\n',
    E'''' || ' ' || ''' || v_t.name || '' '' || coalesce(v_vit->>''fell'', ''is down'') || ''.''',
    E'ELSE '''' END;\n'
    || E'      IF v_ending AND v_first->>''result'' <> '''' THEN\n'
    || E'        v_rev := NULL;\n'
    || E'        SELECT e INTO v_rev FROM jsonb_array_elements(v_t.effects) e WHERE e ? ''ended_by'' LIMIT 1;\n'
    || E'        UPDATE public.rpg_session_participants p\n'
    || E'           SET effects = (SELECT coalesce(jsonb_agg(z), ''[]''::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? ''ended_by'')\n'
    || E'                         || jsonb_build_array(jsonb_build_object(''name'', v_rev->''ended_by''->>''name'', ''cannot_act'', true, ''source'', v_label))\n'
    || E'         WHERE p.id = v_tid;\n'
    || E'        v_tail := v_tail || '' '' || v_t.name || '' is '' || (v_rev->''ended_by''->>''name'') || '' and will not rise.'';\n'
    || E'      END IF;\n'
    || E'      IF v_kind = ''action'' AND v_fx IS NOT NULL AND v_first->>''result'' <> '''''
  ];
  FOR i IN 1 .. array_length(a, 1) LOOP
    IF (length(v) - length(replace(v, a[i], ''))) / length(a[i]) <> 1 THEN
      RAISE EXCEPTION 'rpg_act anchor % not found exactly once', i;
    END IF;
    v := replace(v, a[i], b[i]);
  END LOOP;
  IF (length(x) - length(replace(x, E'THEN '' They are down.'' ELSE', ''))) / length(E'THEN '' They are down.'' ELSE') <> 1 THEN
    RAISE EXCEPTION 'rpg_act_extra anchor not found exactly once';
  END IF;
  x := replace(x, E'THEN '' They are down.'' ELSE', E'THEN coalesce('' It '' || (v_vit->>''fell'') || ''.'', '' They are down.'') ELSE');
  EXECUTE v;
  EXECUTE x;
END $$;

-- The Bramblemaw's Rooted Resilience now runs; its description is the picture only.
UPDATE public.rpg_creature_actions a
   SET effect = '{"on": "zero", "apply": {"name": "Sunk", "cannot_act": true, "clear": "revive", "rounds": 2, "revive": 1},
                  "ended_by": {"skill_key": "healing_spiritual", "against": "FE", "name": "Sanctified"}}'::jsonb,
       description = 'Cut down, it sinks into the soil instead of dying.'
  FROM public.rpg_creatures c
 WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Rooted Resilience';

INSERT INTO public.rpg_rules (key, title, section, sort_order, source, body)
VALUES ('defeat', 'At 0 Vitality', 'Fights', 47, 'peter',
'At 0 Physical Vitality a character is down: they cannot act, and anyone attacking them needs only their Evade Enemy × 1 instead of × 2. A character never dies. They stay down until healed.
*Karen has Physical Vitality 41. Hit for 45, she is down. An attacker facing her Evade Enemy 5 now faces difficulty 5 instead of 10.*

A creature at 0 Physical Vitality dies, unless its card has a rule that brings it back. Nobody can attack a dead creature, and its turns are skipped.

A creature that comes back is out of reach while it waits. It cannot act or be attacked, and its turns are skipped. When its rounds are up it rises with the vitality its card gives. Only the roll its card names reaches it, and landing that roll ends it for good.
*The Bramblemaw sinks into the soil at 0 vitality and rises with 1 vitality 2 rounds later. To sanctify it, a character rolls Healing (Spiritual) against its Fascination with Evil × 2. Fascination with Evil 12 makes difficulty 24, so a healer with Healing (Spiritual) 6 needs 100 × 24 ÷ (24 + 6) = 80 or more.*');

DO $$
BEGIN
  IF has_function_privilege('authenticated', 'public.rpg_participant_out(uuid)', 'EXECUTE') THEN RAISE EXCEPTION 'rpg_participant_out must stay internal'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.rpg_session_adjust_vitality(uuid,integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.rpg_session_state(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'a fight function lost its grant';
  END IF;
END $$;
