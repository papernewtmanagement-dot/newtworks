-- Roleplaying unify7a: the fight grid (Peter 2026-09-27: "each square has a movement penalty"; defaults 1A 2A 3A).
-- A fight is played on a board of squares, 12 × 12 unless the game master sets 4 to 20 a side. Every square has a
-- movement penalty 0-9 (terrain, keyed "x,y"); stepping into a square costs 1 + its penalty. A beat of movement covers
-- move_base + Agility ÷ move_agility_divisor squares, rounded down (Karen, Agility 1: 1; the Bramblemaw, Agility 7: 3).
-- Movement paid for and not used stays until the turn ends (turn_move_left). Every roll at a target has a reach in
-- squares, the larger gap across or up-down. The Bramblemaw's Rootstep steps, Briar Shift raises the ground, and
-- Forest-Bound Terror ignores movement penalties.

ALTER TABLE public.rpg_sessions
  ADD COLUMN IF NOT EXISTS grid_w integer NOT NULL DEFAULT 12,
  ADD COLUMN IF NOT EXISTS grid_h integer NOT NULL DEFAULT 12,
  ADD COLUMN IF NOT EXISTS terrain jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS turn_move_left integer NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_sessions DROP CONSTRAINT IF EXISTS rpg_sessions_grid_size;
ALTER TABLE public.rpg_sessions ADD CONSTRAINT rpg_sessions_grid_size CHECK (grid_w BETWEEN 4 AND 20 AND grid_h BETWEEN 4 AND 20);
ALTER TABLE public.rpg_session_participants
  ADD COLUMN IF NOT EXISTS pos_x integer,
  ADD COLUMN IF NOT EXISTS pos_y integer;
ALTER TABLE public.rpg_session_participants DROP CONSTRAINT IF EXISTS rpg_session_participants_pos;
ALTER TABLE public.rpg_session_participants ADD CONSTRAINT rpg_session_participants_pos
  CHECK ((pos_x IS NULL) = (pos_y IS NULL) AND coalesce(pos_x, 1) >= 1 AND coalesce(pos_y, 1) >= 1);
ALTER TABLE public.rpg_stat_definitions ADD COLUMN IF NOT EXISTS reach integer NOT NULL DEFAULT 1;
ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_reach;
ALTER TABLE public.rpg_stat_definitions ADD CONSTRAINT rpg_stat_definitions_reach CHECK (reach BETWEEN 1 AND 20);
ALTER TABLE public.rpg_creature_actions ADD COLUMN IF NOT EXISTS reach integer NOT NULL DEFAULT 1;
ALTER TABLE public.rpg_creature_actions DROP CONSTRAINT IF EXISTS rpg_creature_actions_reach;
ALTER TABLE public.rpg_creature_actions ADD CONSTRAINT rpg_creature_actions_reach CHECK (reach BETWEEN 1 AND 20);

UPDATE public.rpg_stat_definitions
   SET reach = CASE WHEN key IN ('spear', 'lance', 'military_fork') THEN 2
                    WHEN key IN ('sling', 'hurling', 'tossing') THEN 6
                    ELSE 12 END
 WHERE key IN ('spear', 'lance', 'military_fork', 'sling', 'hurling', 'tossing', 'crossbow', 'longbow');
UPDATE public.rpg_creature_actions
   SET reach = CASE WHEN name = 'Grasping Roots' THEN 4 ELSE 6 END
 WHERE name IN ('Briar Roar', 'Hunting Screech', 'Lure', 'Living Silence', 'Judging Gaze', 'Grasping Roots', 'Briar Shift');

-- The map-bound entries now run.
UPDATE public.rpg_creature_actions a SET effect = '{"on": "step", "beats": 1}'::jsonb
  FROM public.rpg_creatures c WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Rootstep';
UPDATE public.rpg_creature_actions a SET effect = '{"on": "board", "raise": 2, "radius": 1}'::jsonb
  FROM public.rpg_creatures c WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Briar Shift';
UPDATE public.rpg_creature_actions a SET effect = '{"on": "move", "ignore_penalty": true}'::jsonb
  FROM public.rpg_creatures c WHERE c.id = a.creature_id AND c.key = 'bramblemaw' AND a.name = 'Forest-Bound Terror';

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'move_base', 1, 'Squares a beat of movement covers before Agility counts'),
  ('126794dd-25ff-47d2-a436-724499733365', 'move_agility_divisor', 3, 'A beat of movement covers move_base + Agility ÷ this squares, rounded down')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_square_name(p_x integer, p_y integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- A square's name: column letter, then row number (x 3, y 5 → C5).
SELECT chr(64 + p_x) || p_y;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_per_beat(p_participant_id uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Squares one beat of movement covers: move_base + Agility ÷ move_agility_divisor, rounded down, at least 1
-- (Karen, Agility 1: 1 + 0 = 1; the Bramblemaw, Agility 7: 1 + 2 = 3).
SELECT greatest((public.rpg_setting('move_base')
       + floor(greatest(coalesce(public.rpg_participant_value(p_participant_id, 'AG'), 0), 0) / public.rpg_setting('move_agility_divisor')))::integer, 1);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_distance(p_a uuid, p_b uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Squares between two fighters: the larger of the gaps across and up-down (C3 to E6: 2 across, 3 down → 3). Null
-- when either is not on the board.
SELECT greatest(abs(a.pos_x - b.pos_x), abs(a.pos_y - b.pos_y))
  FROM public.rpg_session_participants a, public.rpg_session_participants b
 WHERE a.id = p_a AND b.id = p_b;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_in_reach(p_actor uuid, p_target uuid, p_reach integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a roll reaches its target: the distance (rpg_distance) is at most the reach (Claw 1 cannot touch Karen 3
-- squares away; Briar Roar 6 can). Someone not on the board is always in reach.
SELECT coalesce(public.rpg_distance(p_actor, p_target) <= p_reach, true);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_blocks(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether someone takes up their square on the board: anyone on it, except a dead creature. A Sunk creature waiting
-- to rise still holds its square.
SELECT p.pos_x IS NOT NULL
   AND NOT (public.rpg_participant_out(p.id) AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p.effects) e WHERE e ? 'ended_by'))
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it costs this fighter to reach each square of the board from where they stand. Stepping into a square costs
-- 1 + its movement penalty (just 1 for a creature whose card says penalties never slow it: Forest-Bound Terror);
-- a diagonal step costs the same as a straight one; nobody steps into a square someone takes up
-- (rpg_participant_blocks). Squares nobody can get to are left out. From C3, briars of penalty 2 on D3 cost 3 to
-- enter, and E3 past them costs 4.
DECLARE
  v_p record; v_s record; w integer; h integer; n integer; d integer[]; pen integer[]; blk boolean[];
  v_ign boolean; v_changed boolean; v_big constant integer := 1000000; i integer; j integer; cx integer; cy integer;
  dx integer; dy integer; nx integer; ny integer; c integer; v_k text; v_v text; v_o record;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  w := v_s.grid_w; h := v_s.grid_h; n := w * h;
  IF v_p.pos_x > w OR v_p.pos_y > h THEN RETURN; END IF;
  v_ign := EXISTS (SELECT 1 FROM public.rpg_creature_actions a
                    WHERE a.creature_id = v_p.creature_id AND a.kind = 'trait' AND a.effect->>'on' = 'move'
                      AND coalesce((a.effect->>'ignore_penalty')::boolean, false));
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_k, v_v IN SELECT t.key, t.value FROM jsonb_each_text(v_s.terrain) t LOOP
    cx := split_part(v_k, ',', 1)::integer; cy := split_part(v_k, ',', 2)::integer;
    IF cx BETWEEN 1 AND w AND cy BETWEEN 1 AND h THEN pen[(cy - 1) * w + cx] := v_v::integer; END IF;
  END LOOP;
  FOR v_o IN SELECT o.pos_x, o.pos_y FROM public.rpg_session_participants o
              WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND public.rpg_participant_blocks(o.id) LOOP
    IF v_o.pos_x BETWEEN 1 AND w AND v_o.pos_y BETWEEN 1 AND h THEN blk[(v_o.pos_y - 1) * w + v_o.pos_x] := true; END IF;
  END LOOP;
  d[(v_p.pos_y - 1) * w + v_p.pos_x] := 0;
  LOOP
    v_changed := false;
    FOR i IN 1..n LOOP
      CONTINUE WHEN d[i] >= v_big;
      cx := (i - 1) % w + 1; cy := (i - 1) / w + 1;
      FOR dx IN -1..1 LOOP
        FOR dy IN -1..1 LOOP
          nx := cx + dx; ny := cy + dy;
          CONTINUE WHEN (dx = 0 AND dy = 0) OR nx < 1 OR ny < 1 OR nx > w OR ny > h;
          j := (ny - 1) * w + nx;
          CONTINUE WHEN blk[j];
          c := d[i] + 1 + CASE WHEN v_ign THEN 0 ELSE pen[j] END;
          IF c < d[j] THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT (k - 1) % w + 1, (k - 1) / w + 1, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_move_options(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares the one whose turn it is can still move to this turn, with what each costs to reach and the beats that
-- takes: movement already paid for this turn (turn_move_left) goes first, then whole beats of rpg_move_per_beat
-- squares. Karen (1 a beat, both beats left) reaches squares costing 1 or 2; the Bramblemaw (3 a beat) up to 6.
DECLARE v_p record; v_s record; v_step integer; v_left integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN '[]'::jsonb; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF v_s.status <> 'active' OR v_s.current_participant_id IS DISTINCT FROM v_p.id OR NOT public.rpg_participant_can_act(v_p.id) THEN
    RETURN '[]'::jsonb;
  END IF;
  v_step := public.rpg_move_per_beat(v_p.id);
  v_left := public.rpg_setting('beats_per_turn')::integer - v_s.turn_beats;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('x', g.x, 'y', g.y, 'cost', g.cost, 'beats', b.beats) ORDER BY g.y, g.x), '[]'::jsonb)
            FROM public.rpg_grid_costs(v_p.id) g
            CROSS JOIN LATERAL (SELECT ceil(greatest(g.cost - v_s.turn_move_left, 0)::numeric / v_step)::integer AS beats) b
           WHERE g.cost > 0 AND b.beats <= v_left);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_step_target(p_participant_id uuid, p_budget integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site walks a creature: toward the nearest character still standing, as far as p_budget of path cost takes
-- it (rpg_grid_costs). It picks the reachable square closest to any such character, the cheaper one on a tie, and
-- only if that is closer than where it stands; nothing when a character is already next to it. The Bramblemaw on F1
-- with 3 to spend and Karen on F12 goes to F4.
DECLARE v_p record; v_now integer; v_tx integer[]; v_ty integer[];
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL OR coalesce(p_budget, 0) <= 0 THEN RETURN NULL; END IF;
  SELECT array_agg(t.pos_x), array_agg(t.pos_y) INTO v_tx, v_ty
    FROM public.rpg_session_participants t
   WHERE t.session_id = v_p.session_id AND t.creature_id IS NULL AND t.pos_x IS NOT NULL
     AND (public.rpg_participant_vitality(t.id)->>'left')::integer > 0;
  IF v_tx IS NULL THEN RETURN NULL; END IF;
  SELECT min(greatest(abs(tx - v_p.pos_x), abs(ty - v_p.pos_y))) INTO v_now FROM unnest(v_tx, v_ty) AS u(tx, ty);
  IF v_now <= 1 THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('x', g.x, 'y', g.y, 'cost', g.cost)
            FROM public.rpg_grid_costs(p_participant_id) g,
                 LATERAL (SELECT min(greatest(abs(tx - g.x), abs(ty - g.y))) AS dist FROM unnest(v_tx, v_ty) AS u(tx, ty)) m
           WHERE g.cost > 0 AND g.cost <= p_budget AND m.dist < v_now
           ORDER BY m.dist, g.cost, g.y, g.x LIMIT 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act_square(p_actor_id uuid, p_x integer, p_y integer, p_action_id uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A move on the board. With no action it is a walk by the one whose turn it is: what the path costs
-- (rpg_grid_costs) comes first out of movement already paid for this turn, then out of beats of rpg_move_per_beat
-- squares (Karen, 1 a beat, walks to a square costing 2 for 2 beats; the Bramblemaw, 3 a beat, to one costing 3 for
-- 1 beat, with nothing left over). With a card action that works on a square: a step (Rootstep: as far as 1 beat of
-- its movement takes it, as a legendary action on someone else's turn, using no beats) or a board action (Briar
-- Shift: every square within 1 of a square in its reach gets 2 more movement penalty, up to 9). Players move their
-- own characters; the game master moves creatures.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_actor record; v_s record; v_act record; v_akind text; v_aname text; v_on text;
  v_per integer := public.rpg_setting('beats_per_turn')::integer; v_cost integer; v_step integer; v_beats integer := 0;
  v_have integer; v_budget integer; v_text text; v_sq text := public.rpg_square_name(p_x, p_y);
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
    v_step := public.rpg_move_per_beat(p_actor_id);
    IF v_on IS NULL THEN
      v_have := v_s.turn_move_left;
      v_beats := ceil(greatest(v_cost - v_have, 0)::numeric / v_step)::integer;
      IF v_s.turn_beats + v_beats > v_per THEN
        RAISE EXCEPTION '% has % of % beats left, and % costs % to reach: % beats at % a beat',
          v_actor.name, v_per - v_s.turn_beats, v_per, v_sq, v_cost, v_beats, v_step;
      END IF;
      UPDATE public.rpg_sessions SET turn_beats = turn_beats + v_beats, turn_move_left = v_have + v_beats * v_step - v_cost, updated_at = now()
       WHERE id = v_s.id;
      v_text := v_actor.name || ' moves to ' || v_sq || ' (costs ' || v_cost || ', '
             || v_beats || CASE WHEN v_beats = 1 THEN ' beat' ELSE ' beats' END || ').';
    ELSE
      v_budget := v_step * coalesce((v_act.effect->>'beats')::integer, 1);
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

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL, p_y integer DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a fighter on a square, or with no square takes them off the board. Free, any time, but never
-- onto a square someone takes up.
DECLARE v_p record; v_s record; v_who text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL WHERE id = p_participant_id;
  ELSE
    IF p_x NOT BETWEEN 1 AND v_s.grid_w OR p_y NOT BETWEEN 1 AND v_s.grid_h THEN RAISE EXCEPTION 'that square is off the board'; END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on %', v_who, public.rpg_square_name(p_x, p_y); END IF;
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y WHERE id = p_participant_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_place_start(p_session_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master's quick start: everyone not yet on the board goes on it, characters along the bottom row and
-- creatures along the top, from the middle outward (12 across: F, E, G, D, H …).
DECLARE v_s record; v_p record; v_x integer; v_y integer; v_i integer; v_n integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id AND pos_x IS NULL ORDER BY turn_order, created_at LOOP
    v_y := CASE WHEN v_p.creature_id IS NULL THEN v_s.grid_h ELSE 1 END;
    v_x := NULL;
    FOR v_i IN 0..v_s.grid_w LOOP
      v_x := (v_s.grid_w + 1) / 2 + CASE WHEN v_i % 2 = 0 THEN v_i / 2 ELSE -((v_i + 1) / 2) END;
      IF v_x BETWEEN 1 AND v_s.grid_w AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = p_session_id AND o.pos_x = v_x AND o.pos_y = v_y) THEN
        EXIT;
      END IF;
      v_x := NULL;
    END LOOP;
    IF v_x IS NOT NULL THEN
      UPDATE public.rpg_session_participants SET pos_x = v_x, pos_y = v_y WHERE id = v_p.id;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = p_session_id;
  RETURN jsonb_build_object('placed', v_n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_set_square(p_session_id uuid, p_x integer, p_y integer, p_penalty integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master sets one square's movement penalty, 0 to 9 (briars at 2: stepping in costs 3).
DECLARE v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master shapes the ground'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_s.grid_w OR p_y NOT BETWEEN 1 AND v_s.grid_h THEN RAISE EXCEPTION 'that square is off the board'; END IF;
  IF p_penalty IS NULL OR p_penalty NOT BETWEEN 0 AND 9 THEN RAISE EXCEPTION 'a movement penalty is 0 to 9'; END IF;
  UPDATE public.rpg_sessions
     SET terrain = CASE WHEN p_penalty = 0 THEN terrain - (p_x || ',' || p_y) ELSE terrain || jsonb_build_object(p_x || ',' || p_y, p_penalty) END,
         updated_at = now()
   WHERE id = p_session_id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_set_board(p_session_id uuid, p_w integer, p_h integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master sets the board's size, 4 to 20 squares a side. Anyone standing past the new edge comes off the
-- board, and squares past it lose their penalty.
DECLARE v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master sets the board'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_w IS NULL OR p_h IS NULL OR p_w NOT BETWEEN 4 AND 20 OR p_h NOT BETWEEN 4 AND 20 THEN RAISE EXCEPTION 'a board is 4 to 20 squares a side'; END IF;
  UPDATE public.rpg_sessions
     SET grid_w = p_w, grid_h = p_h, updated_at = now(),
         terrain = (SELECT coalesce(jsonb_object_agg(t.key, t.value), '{}'::jsonb) FROM jsonb_each(terrain) t
                     WHERE split_part(t.key, ',', 1)::integer <= p_w AND split_part(t.key, ',', 2)::integer <= p_h)
   WHERE id = p_session_id;
  UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL
   WHERE session_id = p_session_id AND (pos_x > p_w OR pos_y > p_h);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpg_square_name(integer, integer), public.rpg_move_per_beat(uuid), public.rpg_distance(uuid, uuid),
  public.rpg_in_reach(uuid, uuid, integer), public.rpg_participant_blocks(uuid), public.rpg_grid_costs(uuid),
  public.rpg_move_options(uuid), public.rpg_step_target(uuid, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_square_name(integer, integer), public.rpg_move_per_beat(uuid), public.rpg_distance(uuid, uuid),
  public.rpg_in_reach(uuid, uuid, integer), public.rpg_participant_blocks(uuid), public.rpg_grid_costs(uuid),
  public.rpg_move_options(uuid), public.rpg_step_target(uuid, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_act_square(uuid, integer, integer, uuid), public.rpg_place(uuid, integer, integer),
  public.rpg_place_start(uuid), public.rpg_set_square(uuid, integer, integer, integer), public.rpg_set_board(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_act_square(uuid, integer, integer, uuid), public.rpg_place(uuid, integer, integer),
  public.rpg_place_start(uuid), public.rpg_set_square(uuid, integer, integer, integer), public.rpg_set_board(uuid, integer, integer) TO authenticated, service_role;

INSERT INTO public.rpg_rules (key, title, section, sort_order, source, body)
VALUES ('moving', 'The Board and Moving', 'Fights', 44, 'peter',
'A fight is played on a board of squares, 12 across and 12 down unless the game master picks another size (4 to 20 a side). Columns are letters and rows are numbers: C5 is the third column, fifth row.

One beat of movement takes you 1 + your Agility ÷ 3 squares, rounded down.
*Karen, Agility 1: 1 + 0 = 1 square a beat, 2 in a whole turn. The Bramblemaw, Agility 7: 1 + 2 = 3 squares a beat.*

Every square has a movement penalty from 0 to 9. Stepping into a square costs 1 plus its penalty, and a diagonal step costs the same as a straight one. Movement you paid a beat for and did not use stays yours until your turn ends.
*Briars with penalty 2 cost 3 to step into. That is 3 beats for Karen, more than a turn holds, so she goes around. The Bramblemaw crosses in one beat.*

Nobody can step into a square someone stands in. A dead creature does not block; a Sunk one still holds its square.

Every attack and every roll at someone has a reach in squares, counted as the larger of the two gaps, across and up-down. Swords, axes, claws and bites reach 1. Spears, lances and military forks reach 2. Slings, hurling and tossing reach 6. Crossbows and longbows reach 12. A creature''s card gives the reach of each action.
*The Bramblemaw on C3 and Karen on E6 are 2 across and 3 down, so 3 squares apart. Its Claw (reach 1) cannot touch her; its Briar Roar (reach 6) can.*

Someone not on the board is always in reach.');

