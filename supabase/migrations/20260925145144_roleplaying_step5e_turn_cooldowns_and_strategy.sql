-- Roleplaying step 5e: cooldowns in turns and a strategic chooser (Peter 2026-09-25).
-- Every creature action has cooldown_turns: after use it is back once the creature has begun that many more of its
-- own turns (Claw 1: the next turn; Briar Roar 3). recharge_state now holds {action id: turn count it is ready at}
-- and turns_taken counts each participant's turns. A creature makes one attack a turn, so a printed Multiattack
-- (more than one attack) is not used in play. The site chooses a creature's move by score: rpg_action_score
-- (chance to land × damage, plus effects, plus finishing a weak target), rpg_best_aim (where to point it), and
-- rpg_session_auto_turn / the legendary die pick the best ready move. Effects stay rule-driven; the manual
-- can-act switch leaves the screen.

ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS cooldown_turns integer NOT NULL DEFAULT 1;
COMMENT ON COLUMN public.rpg_creature_actions.cooldown_turns IS 'Turns of the creature''s own before the action is ready again after use: 1 = back next turn, 3 = back three turns later.';
UPDATE public.rpg_creature_actions SET cooldown_turns = CASE recharge_min WHEN 2 THEN 1 WHEN 3 THEN 2 WHEN 4 THEN 3 WHEN 5 THEN 3 WHEN 6 THEN 4 ELSE 1 END
 WHERE kind <> 'trait' AND cooldown_turns = 1 AND recharge_min IS NOT NULL AND recharge_min > 2;
UPDATE public.rpg_creature_actions SET description = replace(description, 'Recharges on a 5 or 6.', 'Three turns to come back.') WHERE name = 'Hunting Screech' AND description LIKE '%Recharges on a 5 or 6.%';
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS turns_taken integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.rpg_session_participants.recharge_state IS '{action id: the turns_taken count at which that action is ready again}';
UPDATE public.rpg_session_participants SET recharge_state = '{}'::jsonb WHERE recharge_state <> '{}'::jsonb;
UPDATE public.rpg_rules
   SET body = replace(body,
     E'\n\nA creature''s actions cool down. After it uses one, that action is spent until a six-sided die rolled at the start of its next turn comes up its number or more: Multiattack on 2 or more, Briar Roar on 5 or more. A creature takes one main action a turn. Its legendary actions come from a roll too: at the end of anyone else''s turn the site rolls a six-sided die for it, and on 4 or more it spends one (Rending Swipe: one Claw), up to its number a round.',
     E'\n\nA creature''s actions cool down. After it uses one, that action comes back after its cooldown in turns: Claw on its next turn, Briar Roar three turns later. A creature makes one attack a turn; a printed Multiattack is not used. Its legendary actions come from a roll: at the end of anyone else''s turn the site rolls a six-sided die for it, and on 4 or more it spends one on its best ready move (Rending Swipe: one Claw), up to its number a round.')
 WHERE key = 'turn_order';

CREATE OR REPLACE FUNCTION public.rpg_action_ready(p_participant_id uuid, p_action_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether an action has cooled down: after use it is back once the creature has begun cooldown_turns more of its
-- own turns (Claw: the next turn; Briar Roar: three turns later).
SELECT NOT (p.recharge_state ? p_action_id::text) OR (p.recharge_state->>p_action_id::text)::integer <= p.turns_taken
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_action_score(p_actor_id uuid, p_action_id uuid, p_target_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How much one action at one target is worth, in damage points, so the site can choose a creature's move:
-- chance to land × average damage (die minus Needed, over the hits), plus what its effect is worth on that target
-- (a hold or knockdown 25, a fright or trance 12; half that when a contest roll must land too; nothing if they
-- already have it or already cannot act), plus 15 when an average hit would finish them.
-- Claw 10 at Karen (Evade Enemy 5, can act → difficulty 10 → needs 50): 51% × 25 = 12.8, plus half a knockdown.
DECLARE
  v_a record; v_u record; v_t record; v_def numeric; v_diff numeric; v_needed numeric; v_p numeric; v_avg numeric;
  v_left integer; v_score numeric := 0; v_fx jsonb; v_can boolean;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  IF jsonb_typeof(v_a.makes_attacks) = 'array' AND jsonb_array_length(v_a.makes_attacks) = 1 AND coalesce((v_a.makes_attacks->0->>'count')::integer, 1) = 1 THEN
    SELECT * INTO v_u FROM public.rpg_creature_actions WHERE creature_id = v_a.creature_id AND name = v_a.makes_attacks->0->>'action' LIMIT 1;
    IF NOT FOUND THEN RETURN 0; END IF;
  ELSE
    v_u := v_a;
  END IF;
  IF v_u.skill IS NULL OR v_u.against IS NULL THEN RETURN 0; END IF;
  SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = p_target_id;
  IF NOT FOUND THEN RETURN 0; END IF;
  v_left := (public.rpg_participant_vitality(p_target_id)->>'left')::integer;
  IF v_left <= 0 THEN RETURN 0; END IF;
  v_can := public.rpg_participant_can_act(p_target_id);
  v_def := coalesce(public.rpg_participant_value(p_target_id, v_u.against), 0);
  v_diff := public.rpg_difficulty(v_def, v_can);
  v_needed := (public.rpg_needed(v_u.skill, v_diff)->>'needed')::numeric;
  v_p := greatest(least((101 - v_needed) / 100, 1), 0);
  IF coalesce(v_u.deals_damage, false) THEN
    v_avg := greatest((100 - v_needed) / 2, 1);
    v_score := v_p * v_avg + CASE WHEN v_avg >= v_left THEN 15 ELSE 0 END;
  END IF;
  v_fx := v_u.effect;
  IF v_fx IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE e->>'name' = v_fx->'apply'->>'name') THEN
    IF coalesce((v_fx->'apply'->>'cannot_act')::boolean, false) THEN
      IF v_can THEN v_score := v_score + v_p * 25 * CASE WHEN v_fx ? 'contest' THEN 0.5 ELSE 1 END; END IF;
    ELSE
      v_score := v_score + v_p * 12 * CASE WHEN v_fx ? 'contest' THEN 0.5 ELSE 1 END;
    END IF;
  END IF;
  RETURN round(v_score, 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_best_aim(p_actor_id uuid, p_action_id uuid, p_targets uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site aims an action: one that does damage goes at the single target it scores highest on; one that
-- only lands an effect (Briar Roar) goes at everyone it scores anything on. Returns the targets and the score,
-- 0 with no targets when no one is worth aiming at.
DECLARE v_a record; v_u record; v_dmg boolean; v_t uuid; v_sc numeric; v_best uuid; v_top numeric := 0; v_list uuid[] := '{}'; v_sum numeric := 0;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', 0); END IF;
  IF jsonb_typeof(v_a.makes_attacks) = 'array' AND jsonb_array_length(v_a.makes_attacks) = 1 THEN
    SELECT * INTO v_u FROM public.rpg_creature_actions WHERE creature_id = v_a.creature_id AND name = v_a.makes_attacks->0->>'action' LIMIT 1;
  ELSE
    v_u := v_a;
  END IF;
  v_dmg := coalesce(v_u.deals_damage, false);
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

-- rpg_act: cooldown by turns, one attack a turn, checked against its anchors and edited in place.
DO $do$
DECLARE v_src text; v_a1 text; v_a2 text; v_n1 text; v_n2 text;
BEGIN
  v_src := pg_get_functiondef('public.rpg_act'::regproc);
  v_a1 := 'IF v_act.recharge_min IS NOT NULL AND v_actor.recharge_state ? v_act.id::text THEN' || E'\n'
       || '      RAISE EXCEPTION ''% is not ready. It comes back on a six-sided die roll of % or more at the start of %''''s turn'',' || E'\n'
       || '        v_act.name, v_act.recharge_min, v_actor.name;' || E'\n'
       || '    END IF;';
  v_n1 := 'IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN' || E'\n'
       || '      RAISE EXCEPTION ''% is not ready. It comes back in % of %''''s turns'', v_act.name,' || E'\n'
       || '        greatest((v_actor.recharge_state->>v_act.id::text)::integer - v_actor.turns_taken, 1), v_actor.name;' || E'\n'
       || '    END IF;' || E'\n'
       || '    IF (SELECT coalesce(sum(greatest(coalesce((e->>''count'')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(v_act.makes_attacks, ''[]''::jsonb)) e) > 1 THEN' || E'\n'
       || '      RAISE EXCEPTION ''% makes one attack a turn; % is not used. Pick one of its attacks'', v_actor.name, v_act.name;' || E'\n'
       || '    END IF;';
  v_a2 := 'recharge_state = CASE WHEN v_act.recharge_min IS NOT NULL' || E'\n'
       || '                                 THEN recharge_state || jsonb_build_object(v_act.id::text, true) ELSE recharge_state END';
  v_n2 := 'recharge_state = recharge_state || jsonb_build_object(v_act.id::text, turns_taken + v_act.cooldown_turns)';
  IF position('rpg_action_ready' IN v_src) > 0 THEN RETURN; END IF;
  IF (length(v_src) - length(replace(v_src, v_a1, ''))) / length(v_a1) <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 1 not unique'; END IF;
  IF (length(v_src) - length(replace(v_src, v_a2, ''))) / length(v_a2) <> 1 THEN RAISE EXCEPTION 'rpg_act anchor 2 not unique'; END IF;
  EXECUTE replace(replace(v_src, v_a1, v_n1), v_a2, v_n2);
END $do$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one in turn order; after the last one a new round begins at the top.
-- In setup this starts the fight at round 1. As a turn ends, every other creature with legendary actions left
-- rolls a six-sided die: on 4 or more it spends one on its best ready move it can afford (rpg_best_aim; Rending
-- Swipe: one Claw at the character it scores highest on). A new round frees anyone Held from an earlier round. At
-- the start of someone's turn they get up from Knocked down and their turn count goes up, which is what brings
-- cooled-down actions back (rpg_action_ready). A creature's legendary actions come back at its turn start
-- (Bramblemaw: 3). The game master can pass any turn; a player can end a character's turn.
DECLARE
  v_s record; v_cur_id uuid; v_cur_order integer; v_cur_created timestamptz; v_cur_char uuid;
  v_next_id uuid; v_round integer; v_new_round boolean := false; v_next record; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_pick jsonb; v_best jsonb; v_top numeric;
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

  IF v_s.status = 'active' AND v_cur_id IS NOT NULL THEN
    PERFORM set_config('rpg.engine', 'on', true);
    SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.character_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
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
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  FOR v_a IN SELECT e->>'name' AS ename FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
     WHERE p.id = v_next_id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_next_id, v_next.name || ' gets up. No longer ' || v_a.ename || '.');
  END LOOP;
  UPDATE public.rpg_session_participants
     SET turns_taken = turns_taken + 1,
         legendary_left = CASE WHEN creature_id IS NOT NULL THEN coalesce((SELECT legendary_per_round FROM public.rpg_creatures WHERE id = v_next.creature_id), 0) ELSE legendary_left END
   WHERE id = v_next_id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'current_participant_id', v_next_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_auto_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The site plays a creature's turn and passes it. Among the actions that are ready it takes the best-scoring move
-- (rpg_action_score through rpg_best_aim: chance to land × damage, plus effects, plus finishing a weak target),
-- with a little randomness so it is not the same move every time. A ready lair action is free and goes first when
-- it is worth anything. One main action a turn; a printed Multiattack is not used. Legendary actions come from the
-- die rolled as other turns end.
DECLARE
  v_s record; v_p record; v_a record; v_targets uuid[]; v_lines jsonb := '[]'::jsonb; v_r jsonb; v_pick jsonb; v_best jsonb; v_top numeric; v_sc numeric;
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
      SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
       WHERE p.session_id = p_session_id AND p.character_id IS NOT NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
    END IF;
    v_best := NULL; v_top := 0;
    FOR v_a IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                WHERE a.creature_id = v_p.creature_id AND a.kind = 'action' AND public.rpg_action_ready(v_p.id, a.id)
                  AND (SELECT coalesce(sum(greatest(coalesce((e->>'count')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(a.makes_attacks, '[]'::jsonb)) e) <= 1 LOOP
      v_pick := public.rpg_best_aim(v_p.id, v_a.id, v_targets);
      v_sc := (v_pick->>'score')::numeric * (0.85 + random() * 0.3);
      IF v_sc > v_top THEN v_top := v_sc; v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets'); END IF;
    END LOOP;
    IF v_best IS NOT NULL AND coalesce(cardinality(v_targets), 0) > 0 THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || (v_best->>'name') || '.');
      v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      v_lines := v_lines || (v_r->'results');
    ELSE
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' has nothing worth using this turn.');
    END IF;
  END IF;
  PERFORM public.rpg_session_next_turn(p_session_id);
  RETURN jsonb_build_object('kind', 'auto', 'results', v_lines);
END;
$function$;

-- rpg_session_state: each action carries ready / back_in / usable instead of the old die fields.
DO $do$
DECLARE v_src text; v_anchor text; v_new text;
BEGIN
  v_src := pg_get_functiondef('public.rpg_session_state'::regproc);
  IF position('''back_in''' IN v_src) > 0 THEN RETURN; END IF;
  v_anchor := '''recharge_min'', a.recharge_min, ''spent'', v_p.recharge_state ? a.id::text, ''legendary_cost'', a.legendary_cost,' || E'\n'
           || '                          ''several'', jsonb_array_length(coalesce(a.makes_attacks, ''[]''::jsonb)) > 1 OR coalesce((a.makes_attacks->0->>''count'')::integer, 1) > 1)';
  v_new := '''cooldown_turns'', a.cooldown_turns, ''ready'', public.rpg_action_ready(v_p.id, a.id), ''spent'', NOT public.rpg_action_ready(v_p.id, a.id),' || E'\n'
        || '                          ''back_in'', greatest(coalesce((v_p.recharge_state->>a.id::text)::integer, 0) - v_p.turns_taken, 0), ''legendary_cost'', a.legendary_cost,' || E'\n'
        || '                          ''parts'', (SELECT string_agg((e->>''count'') || '' × '' || (e->>''action''), '', '') FROM jsonb_array_elements(coalesce(a.makes_attacks, ''[]''::jsonb)) e),' || E'\n'
        || '                          ''usable'', (SELECT coalesce(sum(greatest(coalesce((e->>''count'')::integer, 1), 1)), 0) FROM jsonb_array_elements(coalesce(a.makes_attacks, ''[]''::jsonb)) e) <= 1)';
  IF (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor) <> 1 THEN RAISE EXCEPTION 'rpg_session_state anchor not unique'; END IF;
  EXECUTE replace(v_src, v_anchor, v_new);
END $do$;

GRANT EXECUTE ON FUNCTION public.rpg_action_ready(uuid, uuid), public.rpg_action_score(uuid, uuid, uuid), public.rpg_best_aim(uuid, uuid, uuid[]) TO authenticated;
DO $do$
BEGIN
  IF position('rpg_action_ready' IN pg_get_functiondef('public.rpg_act'::regproc)) = 0 THEN RAISE EXCEPTION 'rpg_act edit did not land'; END IF;
  IF position('''back_in''' IN pg_get_functiondef('public.rpg_session_state'::regproc)) = 0 THEN RAISE EXCEPTION 'state edit did not land'; END IF;
  IF NOT (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE')) FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.proname LIKE 'rpg\_%' AND p.prorettype <> 'trigger'::regtype AND p.proname <> 'rpg_manual_page_sync') THEN
    RAISE EXCEPTION 'an rpg_ function lost its grant';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname IN ('rpg_act', 'rpg_session_state', 'rpg_session_next_turn', 'rpg_session_auto_turn')) <> 4 THEN RAISE EXCEPTION 'overloads appeared'; END IF;
END $do$;
