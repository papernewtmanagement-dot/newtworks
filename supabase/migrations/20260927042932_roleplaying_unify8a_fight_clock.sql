-- Roleplaying unify8a: the fight clock (Peter 2026-09-27 "Defaults" = 1B clock, 2B Speed = (2 × Agility + Perception)
-- ÷ 3, 3B moving and acting together cost the bigger plus half the smaller). Fights run on one clock counted in
-- ticks. Time = base × 2 × speed_even ÷ (speed_even + Speed), rounded, at least 1: a beat is ticks_per_beat (10)
-- ticks at Speed 10; Karen (Speed 1) swings a sword (2 beats) in 36, the Bramblemaw (Speed 7) claws (1 beat) in 12.
-- A turn is a move plus one action; its cost goes on the fighter's next_tick and whoever is next on the clock goes,
-- so turns come out of order. A round is round_ticks (20); energy regains and legendary actions come back per round.
-- Retired: the 2-beat turn (beats_per_turn, turn_beats), movement per beat (move_base, move_agility_divisor,
-- turn_move_left, rpg_move_per_beat), and rpg_session_set_order (the page never called it; the clock sets the order).

ALTER TABLE public.rpg_sessions
  ADD COLUMN IF NOT EXISTS clock integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS turn_move_ticks integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS turn_action_ticks integer NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS next_tick integer;

DELETE FROM public.rpg_settings WHERE key IN ('beats_per_turn', 'move_base', 'move_agility_divisor');
INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'ticks_per_beat', 10, 'Ticks a beat takes at Speed speed_even'),
  ('126794dd-25ff-47d2-a436-724499733365', 'speed_even', 10, 'The Speed at which things take their base time: time = base × 2 × this ÷ (this + Speed), rounded'),
  ('126794dd-25ff-47d2-a436-724499733365', 'round_ticks', 20, 'Ticks in a round; also the most moving one turn holds'),
  ('126794dd-25ff-47d2-a436-724499733365', 'move_ticks', 5, 'Base ticks to step into a square with no movement penalty'),
  ('126794dd-25ff-47d2-a436-724499733365', 'rest_beats', 2, 'Beats Rest or Defend takes')
ON CONFLICT (agency_id, key) DO NOTHING;

INSERT INTO public.rpg_stat_definitions (key, name, abbr, grp, kind, trainable, formula, default_value, sort_order, is_attack, beats, energy_cost, energy_type, template_id)
SELECT 'SP', 'Speed', 'SP', 'derived', 'derived', false, '{"div": 3, "parts": [["AG", 2], ["PR", 1]]}'::jsonb, 0, 156, false, 2, 4, 'physical', c.id
  FROM public.rpg_creatures c WHERE c.key = 'creature'
   AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions WHERE key = 'SP');

CREATE OR REPLACE FUNCTION public.rpg_ticks_at(p_speed numeric, p_base numeric)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How many ticks something with a base time takes at a Speed: base × 2 × speed_even ÷ (speed_even + Speed), rounded,
-- at least 1 (nothing for a base of 0). A sword swing (20 base) takes 20 at Speed 10, 36 at Speed 1 (20 × 20 ÷ 11),
-- 10 at Speed 30.
SELECT CASE WHEN coalesce(p_base, 0) <= 0 THEN 0
            ELSE greatest(round(p_base * 2 * s.e / (s.e + greatest(coalesce(p_speed, 0), 0)))::integer, 1) END
  FROM (SELECT public.rpg_setting('speed_even') AS e) s;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_speed(p_participant_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A fighter's Speed from their own sheet (Speed = (2 × Agility + Perception) ÷ 3: Karen 1, Zaboo 5, the Bramblemaw 7).
SELECT greatest(coalesce(public.rpg_participant_value(p_participant_id, 'SP'), 0), 0);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_action_ticks(p_participant_id uuid, p_beats numeric)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ticks an action of so many beats takes this fighter (rpg_ticks_at of beats × ticks_per_beat): the Bramblemaw's Claw
-- (1 beat) 12, its Bite (2 beats) 24; Karen's sword (2 beats) 36.
SELECT public.rpg_ticks_at(public.rpg_participant_speed(p_participant_id), coalesce(p_beats, 0) * public.rpg_setting('ticks_per_beat'));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_turn_cost(p_move integer, p_action integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- What a turn costs on the fight clock: moving and acting together cost the bigger plus half the smaller, rounded down
-- (Zaboo walks 13 ticks and swings 27: 27 + 6 = 33).
SELECT greatest(coalesce(p_move, 0), coalesce(p_action, 0)) + least(coalesce(p_move, 0), coalesce(p_action, 0)) / 2;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_step_budget(p_beats integer)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
-- How far a step action goes, in path cost (each square 1 + its movement penalty): beats × ticks_per_beat ÷ move_ticks,
-- rounded down. Rootstep (1 beat): 10 ÷ 5 = 2.
SELECT floor(greatest(coalesce(p_beats, 1), 0) * public.rpg_setting('ticks_per_beat') / public.rpg_setting('move_ticks'))::integer;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_budget(p_participant_id uuid, p_used integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The most path cost this fighter can still walk this turn, when a turn holds round_ticks (20) ticks of moving and
-- p_used are spent: each unit of path costs move_ticks (5) at their Speed. Karen (Speed 1): 2; Zaboo (Speed 5): 3;
-- the Bramblemaw (Speed 7): 3.
DECLARE
  v_sp numeric := public.rpg_participant_speed(p_participant_id);
  v_left integer := public.rpg_setting('round_ticks')::integer - coalesce(p_used, 0);
  v_mt numeric := public.rpg_setting('move_ticks');
  v_c integer := 0;
BEGIN
  WHILE v_c < 400 AND public.rpg_ticks_at(v_sp, (v_c + 1) * v_mt) <= v_left LOOP v_c := v_c + 1; END LOOP;
  RETURN v_c;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_options(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares the one whose turn it is can still move to this turn, with the path cost and the ticks it takes: each
-- unit of path costs move_ticks (5) at their Speed (rpg_ticks_at), and a turn holds round_ticks (20) ticks of moving.
-- Zaboo (Speed 5) reaches squares costing up to 3 (20 ticks); Karen (Speed 1) up to 2 (18 ticks).
DECLARE v_p record; v_s record; v_sp numeric; v_left integer; v_mt numeric;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF v_s.status <> 'active' OR v_s.current_participant_id IS DISTINCT FROM v_p.id OR NOT public.rpg_participant_can_act(v_p.id) THEN
    RETURN '[]'::jsonb;
  END IF;
  v_sp := public.rpg_participant_speed(v_p.id);
  v_mt := public.rpg_setting('move_ticks');
  v_left := public.rpg_setting('round_ticks')::integer - v_s.turn_move_ticks;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('x', g.x, 'y', g.y, 'cost', g.cost, 'ticks', t.ticks) ORDER BY g.y, g.x), '[]'::jsonb)
            FROM public.rpg_grid_costs(v_p.id) g
            CROSS JOIN LATERAL (SELECT public.rpg_ticks_at(v_sp, g.cost * v_mt) AS ticks) t
           WHERE g.cost > 0 AND t.ticks <= v_left);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act_square(p_actor_id uuid, p_x integer, p_y integer, p_action_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A move on the board. With no action it is a walk by the one whose turn it is: the path cost (rpg_grid_costs) × 
-- move_ticks at their Speed goes on the turn's moving time, and a turn holds round_ticks (20) of it (Zaboo, Speed 5,
-- walks 2 plain squares in 13 ticks; Karen, Speed 1, in 18). With a card action that works on a square: a step
-- (Rootstep: up to rpg_step_budget of path, 2, as a legendary action on someone else's turn, using no time) or a
-- board action (Briar Shift: every square within 1 of a square in its reach gets 2 more movement penalty, up to 9).
-- Players move their own characters; the game master moves creatures.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_actor record; v_s record; v_act record; v_akind text; v_aname text; v_on text;
  v_rt integer := public.rpg_setting('round_ticks')::integer; v_cost integer; v_ticks integer; v_budget integer;
  v_text text; v_sq text := public.rpg_square_name(p_x, p_y);
  v_terrain jsonb; v_raise integer; v_r integer; v_x integer; v_y integer; v_energy jsonb; v_dist integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_s.grid_w OR p_y NOT BETWEEN 1 AND v_s.grid_h THEN
    RAISE EXCEPTION 'that square is off the board';
  END IF;
  IF v_actor.creature_id IS NOT NULL AND NOT v_gm THEN RAISE EXCEPTION 'the game master moves %', v_actor.name; END IF;
  IF p_action_id IS NOT NULL THEN
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;
    v_akind := v_act.kind; v_aname := v_act.name; v_on := v_act.effect->>'on';
    IF v_on IS DISTINCT FROM 'step' AND v_on IS DISTINCT FROM 'board' THEN RAISE EXCEPTION '% is not aimed at a square', v_aname; END IF;
    IF v_akind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_aname, v_act.legendary_cost;
    END IF;
    IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN
      v_energy := public.rpg_participant_energy(p_actor_id);
      RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_act.energy_type->>'left', v_act.energy_type, v_aname, v_act.energy_cost;
    END IF;
  END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_actor_id AND NOT (v_gm AND v_akind IS NOT DISTINCT FROM 'legendary') THEN
    RAISE EXCEPTION 'it is not %''s turn', v_actor.name;
  END IF;
  IF NOT public.rpg_participant_can_act(p_actor_id) THEN RAISE EXCEPTION '% cannot move right now', v_actor.name; END IF;

  IF v_on IS NULL OR v_on = 'step' THEN
    IF v_actor.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the board yet; the game master places them first', v_actor.name; END IF;
    IF v_actor.pos_x = p_x AND v_actor.pos_y = p_y THEN RAISE EXCEPTION '% is already on %', v_actor.name, v_sq; END IF;
    SELECT g.cost INTO v_cost FROM public.rpg_grid_costs(p_actor_id) g WHERE g.x = p_x AND g.y = p_y;
    IF v_cost IS NULL THEN RAISE EXCEPTION '% cannot get to %: someone is in the way', v_actor.name, v_sq; END IF;
    IF v_on IS NULL THEN
      v_ticks := public.rpg_ticks_at(public.rpg_participant_speed(p_actor_id), v_cost * public.rpg_setting('move_ticks'));
      IF v_s.turn_move_ticks + v_ticks > v_rt THEN
        RAISE EXCEPTION '% has % ticks of moving left this turn, and % takes %', v_actor.name, v_rt - v_s.turn_move_ticks, v_sq, v_ticks;
      END IF;
      UPDATE public.rpg_sessions SET turn_move_ticks = turn_move_ticks + v_ticks, updated_at = now() WHERE id = v_s.id;
      v_text := v_actor.name || ' moves to ' || v_sq || ' (costs ' || v_cost || ', ' || v_ticks || ' ticks).';
    ELSE
      v_budget := public.rpg_step_budget(coalesce((v_act.effect->>'beats')::integer, 1));
      IF v_cost > v_budget THEN
        RAISE EXCEPTION '% goes as far as % with %, and % costs % to reach', v_actor.name, v_budget, v_aname, v_sq, v_cost;
      END IF;
      v_text := v_actor.name || ' uses ' || v_aname || ' and moves to ' || v_sq || ' (costs ' || v_cost || ').';
    END IF;
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y WHERE id = p_actor_id;
  ELSE
    IF v_actor.pos_x IS NOT NULL THEN
      v_dist := greatest(abs(v_actor.pos_x - p_x), abs(v_actor.pos_y - p_y));
      IF v_dist > v_act.reach THEN RAISE EXCEPTION '% is % squares away and % reaches %', v_sq, v_dist, v_aname, v_act.reach; END IF;
    END IF;
    v_raise := coalesce((v_act.effect->>'raise')::integer, 1);
    v_r := coalesce((v_act.effect->>'radius')::integer, 0);
    v_terrain := v_s.terrain;
    FOR v_x IN greatest(p_x - v_r, 1)..least(p_x + v_r, v_s.grid_w) LOOP
      FOR v_y IN greatest(p_y - v_r, 1)..least(p_y + v_r, v_s.grid_h) LOOP
        v_terrain := v_terrain || jsonb_build_object(v_x || ',' || v_y, least(coalesce((v_terrain->>(v_x || ',' || v_y))::integer, 0) + v_raise, 9));
      END LOOP;
    END LOOP;
    UPDATE public.rpg_sessions SET terrain = v_terrain, updated_at = now() WHERE id = v_s.id;
    v_text := v_actor.name || ' uses ' || v_aname || ': the ground around ' || v_sq || ' gets harder to cross (movement penalty +' || v_raise || ').';
  END IF;

  IF p_action_id IS NOT NULL THEN
    IF v_act.energy_cost > 0 THEN
      IF v_act.energy_type = 'spiritual' THEN
        UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_act.energy_cost WHERE id = p_actor_id;
      ELSE
        UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_act.energy_cost WHERE id = p_actor_id;
      END IF;
    END IF;
    IF v_akind = 'legendary' THEN
      UPDATE public.rpg_session_participants SET legendary_left = legendary_left - v_act.legendary_cost WHERE id = p_actor_id;
    END IF;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_text);
  RETURN jsonb_build_object('kind', 'move', 'label', coalesce(v_aname, 'Move'),
                            'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_best_aim(p_actor_id uuid, p_action_id uuid, p_targets uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site aims an action. Only targets in the action's reach count (rpg_in_reach: Claw 1 square, Briar Roar
-- 6). An area action (Briar Roar, Rending Swipe) goes at everyone in reach it scores anything on; any other goes at
-- the one target it scores highest on (Claw, Judging Gaze). An action on the creature itself (Sink Into Soil) needs
-- no target and is worth 10 unless it already has that effect. A step (Rootstep, up to rpg_step_budget: 2) is worth 8
-- when no character is next to it and it can get closer (rpg_step_target); a board action (Briar Shift) is worth 5 at
-- the square of the nearest character in its reach who is not next to it and whose ground is not already hard
-- (penalty under 4). Returns the targets, the score, and for a step or board action the square; 0 with no targets
-- when nothing is worth doing.
DECLARE v_a record; v_t uuid; v_sc numeric; v_best uuid; v_top numeric := 0; v_list uuid[] := '{}'; v_sum numeric := 0; v_sq jsonb;
BEGIN
  SELECT * INTO v_a FROM public.rpg_creature_actions WHERE id = p_action_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', 0); END IF;
  IF v_a.effect->>'on' = 'self' THEN
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score',
      CASE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e WHERE p.id = p_actor_id AND e->>'name' = v_a.effect->'apply'->>'name') THEN 0 ELSE 10 END);
  END IF;
  IF v_a.effect->>'on' = 'step' THEN
    v_sq := public.rpg_step_target(p_actor_id, public.rpg_step_budget(coalesce((v_a.effect->>'beats')::integer, 1)));
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', CASE WHEN v_sq IS NULL THEN 0 ELSE 8 END, 'square', v_sq);
  END IF;
  IF v_a.effect->>'on' = 'board' THEN
    SELECT jsonb_build_object('x', p.pos_x, 'y', p.pos_y) INTO v_sq
      FROM unnest(coalesce(p_targets, '{}'::uuid[])) AS t(id)
      JOIN public.rpg_session_participants p ON p.id = t.id
      JOIN public.rpg_sessions s ON s.id = p.session_id
     WHERE p.pos_x IS NOT NULL AND public.rpg_distance(p_actor_id, p.id) BETWEEN 2 AND v_a.reach
       AND coalesce((s.terrain->>(p.pos_x || ',' || p.pos_y))::integer, 0) < 4
     ORDER BY public.rpg_distance(p_actor_id, p.id), p.pos_y, p.pos_x LIMIT 1;
    RETURN jsonb_build_object('targets', '[]'::jsonb, 'score', CASE WHEN v_sq IS NULL THEN 0 ELSE 5 END, 'square', v_sq);
  END IF;
  FOREACH v_t IN ARRAY coalesce(p_targets, '{}'::uuid[]) LOOP
    CONTINUE WHEN NOT public.rpg_in_reach(p_actor_id, v_t, v_a.reach);
    v_sc := public.rpg_action_score(p_actor_id, p_action_id, v_t);
    IF NOT v_a.area THEN
      IF v_sc > v_top THEN v_top := v_sc; v_best := v_t; END IF;
    ELSIF v_sc > 0 THEN
      v_list := v_list || v_t; v_sum := v_sum + v_sc;
    END IF;
  END LOOP;
  IF NOT v_a.area THEN
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
-- anything (Briar Shift goes on a square). Then its one action for the turn: the best-scoring ready move that reaches
-- someone (rpg_best_aim over rpg_action_score, with a little randomness). When nothing in reach is worth it, it walks
-- toward the nearest character as far as the turn's moving allows (rpg_move_budget, rpg_step_target) and looks again:
-- the Bramblemaw (Speed 7) walks 3 squares for 18 ticks and claws for 12, so the turn costs 18 + 6 = 24 ticks. With
-- nothing to do at all it rests. Legendary actions come from the die rolled as other turns end. A creature aims at the
-- characters in the fight, not at other creatures.
DECLARE
  v_s record; v_p record; v_a record; v_targets uuid[]; v_lines jsonb := '[]'::jsonb; v_r jsonb; v_pick jsonb; v_best jsonb; v_top numeric; v_sc numeric;
  v_step jsonb; v_try integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master runs a creature''s turn'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND OR v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = v_s.current_participant_id;
  IF NOT FOUND OR v_p.creature_id IS NULL THEN RAISE EXCEPTION 'it is not a creature''s turn'; END IF;
  SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
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
      IF (v_pick->>'score')::numeric > v_top THEN
        v_top := (v_pick->>'score')::numeric;
        v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets', 'square', v_pick->'square');
      END IF;
    END LOOP;
    IF v_best IS NOT NULL THEN
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' uses its lair: ' || (v_best->>'name') || '.');
      IF jsonb_typeof(v_best->'square') = 'object' THEN
        v_r := public.rpg_act_square(v_p.id, (v_best->'square'->>'x')::integer, (v_best->'square'->>'y')::integer, (v_best->>'id')::uuid);
      ELSE
        v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
      END IF;
      v_lines := v_lines || (v_r->'results');
    END IF;
    FOR v_try IN 1..2 LOOP
      SELECT array_agg(p.id) INTO v_targets FROM public.rpg_session_participants p
       WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
      EXIT WHEN coalesce(cardinality(v_targets), 0) = 0;
      EXIT WHEN (SELECT turn_action_ticks FROM public.rpg_sessions WHERE id = p_session_id) > 0;
      v_best := NULL; v_top := 0;
      FOR v_a IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                  WHERE a.creature_id = v_p.creature_id AND a.kind IN ('action', 'bonus_action') AND public.rpg_action_ready(v_p.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_p.id, v_a.id, v_targets);
        v_sc := (v_pick->>'score')::numeric * (0.85 + random() * 0.3);
        IF v_sc > v_top THEN v_top := v_sc; v_best := jsonb_build_object('id', v_a.id, 'name', v_a.name, 'targets', v_pick->'targets'); END IF;
      END LOOP;
      IF v_best IS NOT NULL THEN
        INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
        VALUES (v_s.agency_id, p_session_id, v_s.round, 'action', 'info', v_p.id, v_p.name || ' chooses ' || (v_best->>'name') || '.');
        v_r := public.rpg_act(v_p.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
        v_lines := v_lines || (v_r->'results');
        EXIT;
      END IF;
      EXIT WHEN v_try = 2;
      v_step := public.rpg_step_target(v_p.id, public.rpg_move_budget(v_p.id, (SELECT turn_move_ticks FROM public.rpg_sessions WHERE id = p_session_id)));
      EXIT WHEN v_step IS NULL;
      v_r := public.rpg_act_square(v_p.id, (v_step->>'x')::integer, (v_step->>'y')::integer);
      v_lines := v_lines || (v_r->'results');
    END LOOP;
    IF jsonb_array_length(v_lines) = 0 THEN
      v_r := public.rpg_act(v_p.id, NULL, 'REST');
      v_lines := v_lines || (v_r->'results');
    END IF;
  END IF;
  PERFORM public.rpg_session_next_turn(p_session_id);
  RETURN jsonb_build_object('kind', 'auto', 'results', v_lines);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_session_next_turn(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Ends the current turn and starts the next one on the fight clock. The turn's time is charged to the one who took it:
-- moving and acting together cost the bigger plus half the smaller (rpg_turn_cost: Zaboo walks 13 ticks and swings 27,
-- 27 + 6 = 33), or one beat of waiting when they did neither. Then whoever is next on the clock goes, the faster one on
-- a tie (Speed), then the Agility order they joined in (turn_order), so a quick fighter can act twice before a slow one
-- acts once (the Bramblemaw claws every 12 ticks, Karen swings every 36). In setup this starts the fight: everyone's
-- first turn comes one beat in (Speed 7: tick 12; Speed 1: tick 18). A new round begins every round_ticks (20): it
-- frees anyone Held from an earlier round, raises a creature whose revival wait is over (the Bramblemaw: Sunk in round
-- 5, rises with 1 when round 7 begins), gives everyone their energy regain once for each round passed, and gives
-- creatures back their legendary actions (Bramblemaw: 3). As a turn ends, every other creature with legendary actions
-- left rolls a six-sided die: on 4 or more it spends one on its best ready move it can afford (rpg_best_aim; Rending
-- Swipe: one swipe at the character it scores highest on; Rootstep: a step toward the nearest character). At the start
-- of someone's turn they get up from Knocked down, what they put on others until then (clear 'source_turn': Judged)
-- comes off, and a check they tried on an earlier turn (Frightened) is due again. A creature out of the fight (dead,
-- or waiting under its card's revival rule: rpg_participant_out) gets no turn. The game master can pass any turn; a
-- player can end a character's turn, never a creature's.
DECLARE
  v_s record; v_cur record; v_next_id uuid; v_next record; v_a record; v_la record;
  v_d6 integer; v_tg uuid[]; v_pick jsonb; v_best jsonb; v_top numeric; v_cost integer; v_mv integer; v_ac integer;
  v_rt integer := public.rpg_setting('round_ticks')::integer; v_clock integer; v_round integer; v_rounds integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  SELECT * INTO v_cur FROM public.rpg_session_participants WHERE id = v_s.current_participant_id AND session_id = p_session_id;
  IF NOT public.family_is_parent() THEN
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the game master starts the fight'; END IF;
    IF v_cur.id IS NULL OR v_cur.creature_id IS NOT NULL THEN RAISE EXCEPTION 'the game master ends this turn'; END IF;
  END IF;
  PERFORM set_config('rpg.engine', 'on', true);

  IF v_s.status = 'active' AND v_cur.id IS NOT NULL THEN
    SELECT array_agg(p.id) INTO v_tg FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.creature_id IS NULL AND (public.rpg_participant_vitality(p.id)->>'left')::integer > 0;
    FOR v_a IN SELECT p.id, p.name, p.legendary_left, p.creature_id FROM public.rpg_session_participants p
                WHERE p.session_id = p_session_id AND p.creature_id IS NOT NULL AND p.id <> v_cur.id AND p.legendary_left > 0
                  AND public.rpg_participant_can_act(p.id) LOOP
      v_best := NULL; v_top := 0;
      FOR v_la IN SELECT a.id, a.name FROM public.rpg_creature_actions a
                   WHERE a.creature_id = v_a.creature_id AND a.kind = 'legendary' AND a.legendary_cost <= v_a.legendary_left
                     AND public.rpg_action_ready(v_a.id, a.id) LOOP
        v_pick := public.rpg_best_aim(v_a.id, v_la.id, v_tg);
        IF (v_pick->>'score')::numeric > v_top THEN
          v_top := (v_pick->>'score')::numeric;
          v_best := jsonb_build_object('id', v_la.id, 'name', v_la.name, 'targets', v_pick->'targets', 'square', v_pick->'square');
        END IF;
      END LOOP;
      CONTINUE WHEN v_best IS NULL;
      v_d6 := floor(random() * 6)::integer + 1;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, p_session_id, v_s.round, 'legendary', 'info', v_a.id,
              v_a.name || ' rolls a six-sided die to react: ' || v_d6 || '. ' || CASE WHEN v_d6 >= 4 THEN 'It uses ' || (v_best->>'name') || '.' ELSE 'It holds back.' END);
      IF v_d6 >= 4 THEN
        IF jsonb_typeof(v_best->'square') = 'object' THEN
          PERFORM public.rpg_act_square(v_a.id, (v_best->'square'->>'x')::integer, (v_best->'square'->>'y')::integer, (v_best->>'id')::uuid);
        ELSE
          PERFORM public.rpg_act(v_a.id, ARRAY(SELECT jsonb_array_elements_text(v_best->'targets'))::uuid[], NULL, (v_best->>'id')::uuid);
        END IF;
      END IF;
    END LOOP;
    SELECT turn_move_ticks, turn_action_ticks INTO v_mv, v_ac FROM public.rpg_sessions WHERE id = p_session_id;
    v_cost := public.rpg_turn_cost(v_mv, v_ac);
    IF v_cost = 0 THEN v_cost := public.rpg_action_ticks(v_cur.id, 1); END IF;
    UPDATE public.rpg_session_participants SET next_tick = v_s.clock + v_cost WHERE id = v_cur.id;
  ELSIF v_s.status = 'setup' THEN
    UPDATE public.rpg_session_participants SET next_tick = public.rpg_action_ticks(id, 1) WHERE session_id = p_session_id;
  END IF;

  SELECT p.id INTO v_next_id FROM public.rpg_session_participants p
   WHERE p.session_id = p_session_id AND NOT public.rpg_participant_out(p.id)
   ORDER BY coalesce(p.next_tick, v_s.clock), public.rpg_participant_speed(p.id) DESC, p.turn_order, p.created_at LIMIT 1;
  IF v_next_id IS NULL THEN RAISE EXCEPTION 'add someone to the fight first'; END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  v_clock := greatest(coalesce(v_next.next_tick, v_s.clock), v_s.clock);
  IF v_s.status = 'setup' THEN
    v_round := 1;
  ELSE
    v_round := greatest(v_clock / v_rt + 1, v_s.round);
    v_rounds := v_round - v_s.round;
  END IF;
  UPDATE public.rpg_sessions SET status = 'active', round = v_round, clock = v_clock, current_participant_id = v_next_id,
         turn_move_ticks = 0, turn_action_ticks = 0, updated_at = now()
   WHERE id = p_session_id;
  IF v_s.status = 'setup' THEN
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'start', 'info', 'The fight begins. Round 1.');
  ELSIF v_rounds > 0 THEN
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
    UPDATE public.rpg_session_participants
       SET energy_used_physical = greatest(energy_used_physical - v_rounds * coalesce(public.rpg_participant_value(id, 'PER'), 0)::integer, 0),
           energy_used_spiritual = greatest(energy_used_spiritual - v_rounds * coalesce(public.rpg_participant_value(id, 'SER'), 0)::integer, 0),
           legendary_left = CASE WHEN creature_id IS NOT NULL
                                 THEN coalesce((SELECT c.legendary_per_round FROM public.rpg_creatures c WHERE c.id = creature_id), 0)
                                 ELSE legendary_left END
     WHERE session_id = p_session_id;
  END IF;
  SELECT * INTO v_next FROM public.rpg_session_participants WHERE id = v_next_id;
  FOR v_a IN SELECT e->>'name' AS ename, coalesce((e->>'cannot_act')::boolean, false) AS held FROM jsonb_array_elements(v_next.effects) e WHERE e->>'clear' = 'turn_start' LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> v_a.ename)
     WHERE p.id = v_next_id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_next_id, v_next.name || CASE WHEN v_a.held THEN ' gets up. No longer ' ELSE ' is no longer ' END || v_a.ename || '.');
  END LOOP;
  UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e - 'checked_round'), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e)
   WHERE p.id = v_next_id AND EXISTS (SELECT 1 FROM jsonb_array_elements(p.effects) e WHERE e ? 'checked_round');
  FOR v_a IN SELECT p.id, p.name, e->>'name' AS ename FROM public.rpg_session_participants p, jsonb_array_elements(p.effects) e
              WHERE p.session_id = p_session_id AND e->>'clear' = 'source_turn' AND e->>'source_id' = v_next_id::text LOOP
    UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE z->>'name' <> v_a.ename)
     WHERE p.id = v_a.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, p_session_id, v_round, 'effect', 'info', v_a.id, v_a.name || ' is no longer ' || v_a.ename || '.');
  END LOOP;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, p_session_id, v_round, 'turn', 'info', v_next_id, v_next.name || '''s turn.');
  RETURN jsonb_build_object('round', v_round, 'clock', v_clock, 'current_participant_id', v_next_id);
END;
$function$;

