-- roleplaying_unify11a_forest_fire_unseen_innocents
-- Peter 2026-09-30, "Defaults" (1A 2A 3A 4A): the ground can be forest and it can burn; the Bramblemaw sinks only on
-- forest ground and burns while it waits if its square is set alight; on forest ground it is unseen beyond 2 squares;
-- a Judged fighter who strikes at an innocent (good side, has not attacked this fight) or sets forest ground alight is
-- Condemned for the rest of the fight. A Torch object card carries the one action that lights a square. The three
-- Bramblemaw entries that drove nothing now drive these rules; nothing is applied by hand.

-- 1. The board. A square's entry in rpg_sessions.terrain is now an object: {"p": penalty, "forest": true,
--    "burn_until": round}, each key only while it is set (an old bare number was the penalty).
UPDATE public.rpg_sessions s
   SET terrain = (SELECT coalesce(jsonb_object_agg(t.key, CASE WHEN jsonb_typeof(t.value) = 'number' THEN jsonb_build_object('p', t.value) ELSE t.value END), '{}'::jsonb)
                    FROM jsonb_each(s.terrain) t)
 WHERE EXISTS (SELECT 1 FROM jsonb_each(s.terrain) t WHERE jsonb_typeof(t.value) = 'number');

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'burn_rounds', 3, 'Rounds a lit square burns'),
  ('126794dd-25ff-47d2-a436-724499733365', 'burn_cost', 3, 'Extra cost to step into a burning square')
ON CONFLICT (agency_id, key) DO NOTHING;

ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS has_attacked boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.rpg_session_participants.has_attacked IS 'Set by rpg_act on the fighter''s first hostile roll in this fight; an innocent (rpg_judgement) is on the good side and has not attacked.';

CREATE OR REPLACE FUNCTION public.rpg_square_info(p_square jsonb, p_round integer)
 RETURNS TABLE(penalty integer, forest boolean, burning boolean)
 LANGUAGE sql IMMUTABLE
AS $function$
-- One square of the board read the one way: its movement penalty (0 when unset), whether it is forest, and whether it
-- burns now (burn_until is the round the fire is out: lit in round 5 for 3 rounds it burns in 5, 6 and 7). Read by
-- rpg_grid_costs, rpg_participant_ground, rpg_best_aim, rpg_act_square and rpg_session_state; written by rpg_square_set.
SELECT coalesce((p_square->>'p')::integer, 0), coalesce((p_square->>'forest')::boolean, false),
       coalesce((p_square->>'burn_until')::integer, 0) > coalesce(p_round, 0);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_square_set(p_session_id uuid, p_x integer, p_y integer, p_penalty integer DEFAULT NULL::integer, p_forest boolean DEFAULT NULL::boolean, p_burn_until integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- The one writer of a square's entry in rpg_sessions.terrain. Each argument given replaces that part (null leaves it
-- alone): a penalty of 0, forest false or a burn_until at or before this round clear theirs, and an entry with nothing
-- left is dropped. Internal: rpg_set_square and rpg_set_ground (the game master painting), rpg_act_square (Briar
-- Shift) and rpg_ignite (fire).
DECLARE v_k text := p_x || ',' || p_y; v_e jsonb; v_s record;
BEGIN
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_s.grid_w OR p_y NOT BETWEEN 1 AND v_s.grid_h THEN RAISE EXCEPTION 'that square is off the board'; END IF;
  v_e := coalesce(v_s.terrain->v_k, '{}'::jsonb);
  IF p_penalty IS NOT NULL THEN v_e := CASE WHEN p_penalty > 0 THEN v_e || jsonb_build_object('p', p_penalty) ELSE v_e - 'p' END; END IF;
  IF p_forest IS NOT NULL THEN v_e := CASE WHEN p_forest THEN v_e || jsonb_build_object('forest', true) ELSE v_e - 'forest' END; END IF;
  IF p_burn_until IS NOT NULL THEN v_e := v_e || jsonb_build_object('burn_until', p_burn_until); END IF;
  IF coalesce((v_e->>'burn_until')::integer, 0) <= coalesce(v_s.round, 0) THEN v_e := v_e - 'burn_until'; END IF;
  UPDATE public.rpg_sessions
     SET terrain = CASE WHEN v_e = '{}'::jsonb THEN terrain - v_k ELSE terrain || jsonb_build_object(v_k, v_e) END, updated_at = now()
   WHERE id = p_session_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_square_set(uuid, integer, integer, integer, boolean, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_square_set(uuid, integer, integer, integer, boolean, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_participant_ground(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- The ground a fighter stands on: {penalty, forest, burning, off}. Off the board counts as forest and never burns.
-- Read by rpg_session_adjust_vitality (where a revival rule works), rpg_reach_to (unseen) and rpg_burn_out (fire).
SELECT CASE WHEN p.pos_x IS NULL THEN jsonb_build_object('penalty', 0, 'forest', true, 'burning', false, 'off', true)
            ELSE jsonb_build_object('penalty', i.penalty, 'forest', i.forest, 'burning', i.burning, 'off', false) END
  FROM public.rpg_session_participants p
  JOIN public.rpg_sessions s ON s.id = p.session_id
  CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(p.pos_x || ',' || p.pos_y), s.round) i
 WHERE p.id = p_participant_id;
$function$;
REVOKE ALL ON FUNCTION public.rpg_participant_ground(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_participant_ground(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_reach_to(p_target uuid, p_reach integer)
 RETURNS integer
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- How far a roll may be from this target and still reach it: the roll's own reach, shortened when the target's card has
-- a trait that hides it on the ground it stands on ({"unseen": {"where": "forest", "beyond": 2}}: the Bramblemaw on a
-- forest square cannot be aimed at from more than 2 squares away, longbow (12) or not). Read by rpg_in_reach and rpg_act.
SELECT least(p_reach, (SELECT min((a.effect->'unseen'->>'beyond')::integer)
                         FROM public.rpg_session_participants p
                         JOIN public.rpg_creature_actions a ON a.creature_id = p.creature_id
                        WHERE p.id = p_target AND a.kind = 'trait' AND a.effect ? 'unseen'
                          AND coalesce((public.rpg_participant_ground(p.id)->>(a.effect->'unseen'->>'where'))::boolean, false)));
$function$;
REVOKE ALL ON FUNCTION public.rpg_reach_to(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_reach_to(uuid, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_in_reach(p_actor uuid, p_target uuid, p_reach integer)
 RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- Whether a roll reaches its target: the distance (rpg_distance) is at most the reach the target allows (rpg_reach_to:
-- Claw 1 cannot touch Karen 3 squares away; Briar Roar 6 can; a Bramblemaw on forest ground is unseen beyond 2, so a
-- longbow at 5 squares has no target). Someone not on the board is always in reach.
SELECT coalesce(public.rpg_distance(p_actor, p_target) <= public.rpg_reach_to(p_target, p_reach), true);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_cards(p_participant_id uuid)
 RETURNS uuid[]
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- The cards whose actions this fighter may use: its own card (a creature), and the card of every unbroken thing held
-- in the hand (a Torch: Light the ground). One rulebook: an object's card carries actions the way a creature's does.
-- Read by rpg_act and rpg_act_square.
SELECT array_remove(ARRAY[p.creature_id]
                    || coalesce((SELECT array_agg(o.template_id) FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
                                  WHERE i.character_id = p.character_id AND i.equipped AND NOT i.worn
                                    AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean), '{}'::uuid[]), NULL)
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;
REVOKE ALL ON FUNCTION public.rpg_participant_cards(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_participant_cards(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_burn_out(p_participant_id uuid)
 RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- A creature waiting at 0 under its card's revival rule burns when its square is burning and the rule names what fire
-- makes it ({"fire": {"name": "Burned"}}): the wait is swapped for that, it will not rise, and it is dead. Returns the
-- log tail, or null when nothing burns. Internal: rpg_ignite (the moment a square is set alight).
DECLARE v_p record; v_rev jsonb; v_rule jsonb; v_name text;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.creature_id IS NULL THEN RETURN NULL; END IF;
  SELECT e INTO v_rev FROM jsonb_array_elements(v_p.effects) e WHERE e ? 'ended_by' LIMIT 1;
  IF v_rev IS NULL THEN RETURN NULL; END IF;
  IF NOT coalesce((public.rpg_participant_ground(p_participant_id)->>'burning')::boolean, false) THEN RETURN NULL; END IF;
  SELECT a.effect INTO v_rule FROM public.rpg_creature_actions a WHERE a.creature_id = v_p.creature_id AND a.effect->>'on' = 'zero' ORDER BY a.sort_order LIMIT 1;
  v_name := v_rule->'fire'->>'name';
  IF v_name IS NULL THEN RETURN NULL; END IF;
  UPDATE public.rpg_session_participants p
     SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
                   || jsonb_build_array(jsonb_build_object('name', v_name, 'cannot_act', true, 'source', 'fire'))
   WHERE p.id = p_participant_id;
  RETURN ' ' || v_p.name || ' burns in the fire and is ' || v_name || '. It will not rise.';
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_burn_out(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_burn_out(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_ignite(p_session_id uuid, p_x integer, p_y integer)
 RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- Sets one square alight for burn_rounds (3) rounds and burns whoever waits there under a revival rule that fire ends
-- (rpg_burn_out: a Sunk Bramblemaw). Returns the log tail. Internal: rpg_act_square (a Torch) and rpg_set_ground.
DECLARE v_s record; v_until integer; v_text text; v_p record;
BEGIN
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  v_until := coalesce(v_s.round, 1) + public.rpg_setting('burn_rounds')::integer;
  PERFORM public.rpg_square_set(p_session_id, p_x, p_y, NULL, NULL, v_until);
  v_text := ' ' || public.rpg_square_name(p_x, p_y) || ' burns until round ' || v_until || '.';
  FOR v_p IN SELECT p.id FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.pos_x = p_x AND p.pos_y = p_y LOOP
    v_text := v_text || coalesce(public.rpg_burn_out(v_p.id), '');
  END LOOP;
  RETURN v_text;
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_ignite(uuid, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_ignite(uuid, integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_judgement(p_actor_id uuid, p_target_id uuid, p_harmed_tree boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- Judging Gaze's watch. An effect on the actor that carries "on_harm" (Judged) turns into that block (Condemned:
-- exposed to its source, clear 'fight' so nothing takes it off) when the actor harms an innocent: a target on the good
-- side (rpg_sheet_values side) who has not attacked anyone in this fight (has_attacked), or forest ground set alight
-- (a tree). Returns the log tail, or null. Internal: rpg_act (every hostile roll) and rpg_act_square (a Torch).
DECLARE v_a record; v_t record; v_e jsonb; v_new jsonb; v_round integer; v_innocent boolean := coalesce(p_harmed_tree, false);
BEGIN
  SELECT * INTO v_a FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT e INTO v_e FROM jsonb_array_elements(v_a.effects) e WHERE jsonb_typeof(e->'on_harm') = 'object' LIMIT 1;
  IF v_e IS NULL THEN RETURN NULL; END IF;
  IF NOT v_innocent AND p_target_id IS NOT NULL THEN
    SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = p_target_id;
    v_innocent := FOUND AND v_t.character_id IS NOT NULL AND NOT v_t.has_attacked AND (public.rpg_sheet_values(v_t.character_id)->>'side') = 'good';
  END IF;
  IF NOT v_innocent THEN RETURN NULL; END IF;
  SELECT round INTO v_round FROM public.rpg_sessions WHERE id = v_a.session_id;
  v_new := (v_e->'on_harm') || jsonb_build_object('source', v_e->>'source', 'source_id', v_e->>'source_id', 'round', v_round);
  UPDATE public.rpg_session_participants p
     SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE z->>'name' NOT IN (v_e->>'name', v_new->>'name'))
                   || jsonb_build_array(v_new)
   WHERE p.id = p_actor_id;
  RETURN ' ' || v_a.name || CASE WHEN p_harmed_tree THEN ' harms the forest' ELSE ' strikes at an innocent, ' || v_t.name || ',' END
         || ' under the ' || coalesce(v_e->>'source', 'gaze') || ' and is ' || (v_new->>'name') || ' for the rest of the fight.';
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_judgement(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_judgement(uuid, uuid, boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_set_square(p_session_id uuid, p_x integer, p_y integer, p_penalty integer)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- The game master sets one square's movement penalty, 0 to 9 (briars at 2: stepping in costs 3), through the one
-- writer of a square (rpg_square_set). Forest and fire are rpg_set_ground.
DECLARE v_s record;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master shapes the ground'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_penalty IS NULL OR p_penalty NOT BETWEEN 0 AND 9 THEN RAISE EXCEPTION 'a movement penalty is 0 to 9'; END IF;
  PERFORM public.rpg_square_set(p_session_id, p_x, p_y, p_penalty);
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_set_ground(p_session_id uuid, p_x integer, p_y integer, p_forest boolean DEFAULT NULL::boolean, p_burning boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $function$
-- The game master paints one square's ground: forest on or off, fire on (it burns for burn_rounds rounds and burns a
-- creature waiting there under a rule fire ends: rpg_ignite) or out. The movement penalty is rpg_set_square. Both go
-- through the one writer of a square (rpg_square_set).
DECLARE v_s record; v_text text := '';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master shapes the ground'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_forest IS NOT NULL THEN PERFORM public.rpg_square_set(p_session_id, p_x, p_y, NULL, p_forest, NULL); END IF;
  IF p_burning IS TRUE THEN
    v_text := public.rpg_ignite(p_session_id, p_x, p_y);
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'effect', 'info', 'The game master sets ' || public.rpg_square_name(p_x, p_y) || ' alight.' || v_text);
  ELSIF p_burning IS FALSE THEN
    PERFORM public.rpg_square_set(p_session_id, p_x, p_y, NULL, NULL, 0);
  END IF;
  RETURN jsonb_build_object('ok', true, 'text', v_text);
END;
$function$;
REVOKE ALL ON FUNCTION public.rpg_set_ground(uuid, integer, integer, boolean, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_set_ground(uuid, integer, integer, boolean, boolean) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $function$
-- What it costs this fighter to reach each square of the board from where they stand. Stepping into a square costs
-- 1 + its movement penalty (just 1 for a creature whose card says penalties never slow it: Forest-Bound Terror), plus
-- burn_cost (3) while the square burns, for everyone; a diagonal step costs the same as a straight one; nobody steps
-- into a square someone takes up (rpg_participant_blocks). Squares nobody can get to are left out. From C3, briars of
-- penalty 2 on D3 cost 3 to enter, and E3 past them costs 4; burning briars cost 6, and the Bramblemaw pays 4 there.
DECLARE
  v_p record; v_s record; w integer; h integer; n integer; d integer[]; pen integer[]; fire integer[]; blk boolean[];
  v_ign boolean; v_changed boolean; v_big constant integer := 1000000; i integer; j integer; cx integer; cy integer;
  dx integer; dy integer; nx integer; ny integer; c integer; v_k text; v_v jsonb; v_o record; v_i record;
  v_burn integer := public.rpg_setting('burn_cost')::integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  w := v_s.grid_w; h := v_s.grid_h; n := w * h;
  IF v_p.pos_x > w OR v_p.pos_y > h THEN RETURN; END IF;
  v_ign := EXISTS (SELECT 1 FROM public.rpg_creature_actions a
                    WHERE a.creature_id = v_p.creature_id AND a.kind = 'trait' AND a.effect->>'on' = 'move'
                      AND coalesce((a.effect->>'ignore_penalty')::boolean, false));
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); fire := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_k, v_v IN SELECT t.key, t.value FROM jsonb_each(v_s.terrain) t LOOP
    cx := split_part(v_k, ',', 1)::integer; cy := split_part(v_k, ',', 2)::integer;
    IF cx BETWEEN 1 AND w AND cy BETWEEN 1 AND h THEN
      SELECT * INTO v_i FROM public.rpg_square_info(v_v, v_s.round);
      pen[(cy - 1) * w + cx] := v_i.penalty;
      fire[(cy - 1) * w + cx] := CASE WHEN v_i.burning THEN v_burn ELSE 0 END;
    END IF;
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
          c := d[i] + 1 + CASE WHEN v_ign THEN 0 ELSE pen[j] END + fire[j];
          IF c < d[j] THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT (k - 1) % w + 1, (k - 1) / w + 1, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$;

-- 2. Anchored patches on the functions the rules touch.
CREATE FUNCTION pg_temp.rep(p_def text, p_old text, p_new text, p_label text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE n integer := (length(p_def) - length(replace(p_def, p_old, ''))) / length(p_old);
BEGIN
  IF n <> 1 THEN RAISE EXCEPTION 'anchor % found % times', p_label, n; END IF;
  RETURN replace(p_def, p_old, p_new);
END $f$;

DO $do$
DECLARE v text; v_src text;
BEGIN
  -- rpg_act: last changed by anchors, so patched by anchors again; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_act';
  IF v_src NOT LIKE '%rpg_participant_cards%' THEN
    IF md5(v_src) <> '378f364dd60b48df5b5e5bd77ae3a51c' THEN RAISE EXCEPTION 'rpg_act body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_act(uuid,uuid[],text,uuid,text,numeric,integer,text)'::regprocedure);
    v := pg_temp.rep(v, $a$--   action that is not an area action aims at one target.$a$,
$b$--   action that is not an area action aims at one target. A target hidden by its ground (Forest-Bound Terror on
--   forest: unseen beyond 2 squares) is out of reach past that distance whatever the weapon (rpg_reach_to). Every
--   hostile roll marks the actor as having attacked, and a Judged actor who strikes at an innocent is Condemned
--   (rpg_judgement). A card action may come from a thing the fighter holds (rpg_participant_cards).$b$, 'act header');
    v := pg_temp.rep(v, $a$    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;$a$,
$b$    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = ANY (public.rpg_participant_cards(p_actor_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this fighter''s card or on a thing they hold'; END IF;$b$, 'act card lookup');
    v := pg_temp.rep(v, $a$      IF NOT public.rpg_in_reach(p_actor_id, v_tid, coalesce(v_reach, 1)) THEN
        RAISE EXCEPTION '% is % squares away and % reaches %', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),$a$,
$b$      IF NOT public.rpg_in_reach(p_actor_id, v_tid, coalesce(v_reach, 1)) THEN
        IF public.rpg_reach_to(v_tid, coalesce(v_reach, 1)) < coalesce(v_reach, 1) THEN
          RAISE EXCEPTION '% is unseen in the forest beyond % squares and stands % away', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),
            public.rpg_reach_to(v_tid, coalesce(v_reach, 1)), public.rpg_distance(p_actor_id, v_tid);
        END IF;
        RAISE EXCEPTION '% is % squares away and % reaches %', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),$b$, 'act reach message');
    v := pg_temp.rep(v, $a$      IF v_ending AND v_first->>'result' <> '' THEN$a$,
$b$      -- A hostile roll marks the actor as having attacked (no longer an innocent) and, if they are Judged and the target
      -- is an innocent, condemns them (rpg_judgement). A Miss counts: the attempt is the harm.
      IF NOT v_ending AND (v_kind = 'attack' OR (v_kind = 'action' AND (v_damage_ok OR v_fx ? 'apply'))) THEN
        v_tail := v_tail || coalesce(public.rpg_judgement(p_actor_id, v_tid, false), '');
        UPDATE public.rpg_session_participants SET has_attacked = true WHERE id = p_actor_id AND NOT has_attacked;
      END IF;
      IF v_ending AND v_first->>'result' <> '' THEN$b$, 'act innocents');
    EXECUTE v;
  END IF;

  -- rpg_act_square: last changed by anchors, so patched by anchors again; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_act_square';
  IF v_src NOT LIKE '%rpg_ignite%' THEN
    IF md5(v_src) <> '98ca48f5129dfe5328f273a40bb8230f' THEN RAISE EXCEPTION 'rpg_act_square body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_act_square(uuid,integer,integer,uuid)'::regprocedure);
    v := pg_temp.rep(v, $a$-- Players move their own characters; the game master moves creatures.$a$,
$b$-- A thing held in the hand lends its card's square actions (a Torch: Light the ground sets a square alight for
-- burn_rounds rounds as the turn's action, rpg_ignite; on forest ground that is a tree harmed, rpg_judgement); one
-- use of the thing is spent when it counts uses. Players move their own characters; the game master moves creatures.$b$, 'square header');
    v := pg_temp.rep(v, $a$  v_terrain jsonb; v_raise integer; v_r integer; v_x integer; v_y integer; v_energy jsonb; v_dist integer;$a$,
$b$  v_raise integer; v_r integer; v_x integer; v_y integer; v_energy jsonb; v_dist integer; v_item record; v_forest boolean; v_pen integer;$b$, 'square declare');
    v := pg_temp.rep(v, $a$    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = v_actor.creature_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this creature''s card'; END IF;$a$,
$b$    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = ANY (public.rpg_participant_cards(p_actor_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this fighter''s card or on a thing they hold'; END IF;
    IF v_act.creature_id IS DISTINCT FROM v_actor.creature_id THEN
      -- the action comes from a thing held in the hand: the first unbroken one of that card
      SELECT i.id, i.name, i.uses_left INTO v_item FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
       WHERE i.character_id = v_actor.character_id AND i.equipped AND NOT i.worn AND o.template_id = v_act.creature_id
         AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean
       ORDER BY i.sort_order LIMIT 1;
      IF v_item.id IS NULL THEN RAISE EXCEPTION '% is not holding anything that can %', v_actor.name, v_act.name; END IF;
    END IF;$b$, 'square card lookup');
    v := pg_temp.rep(v, $a$    IF v_akind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;$a$,
$b$    IF v_akind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;
    IF v_akind IN ('action', 'bonus_action') AND v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;$b$, 'square action gate');
    v := pg_temp.rep(v, $a$    v_raise := coalesce((v_act.effect->>'raise')::integer, 1);
    v_r := coalesce((v_act.effect->>'radius')::integer, 0);
    v_terrain := v_s.terrain;
    FOR v_x IN greatest(p_x - v_r, 1)..least(p_x + v_r, v_s.grid_w) LOOP
      FOR v_y IN greatest(p_y - v_r, 1)..least(p_y + v_r, v_s.grid_h) LOOP
        v_terrain := v_terrain || jsonb_build_object(v_x || ',' || v_y, least(coalesce((v_terrain->>(v_x || ',' || v_y))::integer, 0) + v_raise, 9));
      END LOOP;
    END LOOP;
    UPDATE public.rpg_sessions SET terrain = v_terrain, updated_at = now() WHERE id = v_s.id;
    v_text := v_actor.name || ' uses ' || v_aname || ': the ground around ' || v_sq || ' gets harder to cross (movement penalty +' || v_raise || ').';$a$,
$b$    IF coalesce((v_act.effect->>'burn')::boolean, false) THEN
      -- fire: the square burns for burn_rounds (rpg_ignite); forest ground set alight is a tree harmed (rpg_judgement)
      SELECT i.forest INTO v_forest FROM public.rpg_square_info(v_s.terrain->(p_x || ',' || p_y), v_s.round) i;
      v_text := v_actor.name || ' lights ' || v_sq || ' with ' || coalesce(v_item.name, v_aname) || '.' || public.rpg_ignite(v_s.id, p_x, p_y);
      IF v_forest THEN v_text := v_text || coalesce(public.rpg_judgement(p_actor_id, NULL, true), ''); END IF;
    ELSE
      v_raise := coalesce((v_act.effect->>'raise')::integer, 1);
      v_r := coalesce((v_act.effect->>'radius')::integer, 0);
      FOR v_x IN greatest(p_x - v_r, 1)..least(p_x + v_r, v_s.grid_w) LOOP
        FOR v_y IN greatest(p_y - v_r, 1)..least(p_y + v_r, v_s.grid_h) LOOP
          SELECT i.penalty INTO v_pen FROM public.rpg_square_info(v_s.terrain->(v_x || ',' || v_y), v_s.round) i;
          PERFORM public.rpg_square_set(v_s.id, v_x, v_y, least(v_pen + v_raise, 9));
        END LOOP;
      END LOOP;
      v_text := v_actor.name || ' uses ' || v_aname || ': the ground around ' || v_sq || ' gets harder to cross (movement penalty +' || v_raise || ').';
    END IF;$b$, 'square board branch');
    v := pg_temp.rep(v, $a$  IF p_action_id IS NOT NULL THEN
    IF v_act.energy_cost > 0 THEN$a$,
$b$  IF p_action_id IS NOT NULL THEN
    IF v_akind IN ('action', 'bonus_action') AND coalesce(v_act.beats, 0) > 0 THEN
      UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_act.beats) WHERE id = v_s.id;
    END IF;
    IF v_item.id IS NOT NULL AND v_item.uses_left IS NOT NULL THEN PERFORM public.rpg_item_use(v_item.id); END IF;
    IF v_act.energy_cost > 0 THEN$b$, 'square ticks and uses');
    EXECUTE v;
  END IF;

  -- rpg_session_adjust_vitality: last changed by anchors, so patched by anchors again; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_session_adjust_vitality';
  IF v_src NOT LIKE '%rpg_participant_ground%' THEN
    IF md5(v_src) <> '5c5d4a03ce777ac3daa9d424d19c04b7' THEN RAISE EXCEPTION 'rpg_session_adjust_vitality body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_session_adjust_vitality(uuid,integer)'::regprocedure);
    v := pg_temp.rep(v, $a$-- has already been ended for good (the Bramblemaw is Sunk until round + 2), otherwise it dies.$a$,
$b$-- has already been ended for good (the Bramblemaw is Sunk until round + 2), otherwise it dies. A rule may name the
-- ground it works on ("where": forest for Rooted Resilience; off the board counts as forest), and a burning square
-- never keeps it: anywhere else, or in fire, it dies.$b$, 'vitality header');
    v := pg_temp.rep(v, $a$DECLARE v_p record; v_v jsonb; v_after jsonb; v_delta integer; v_rule_name text; v_rule jsonb; v_round integer; v_eff jsonb;$a$,
$b$DECLARE v_p record; v_v jsonb; v_after jsonb; v_delta integer; v_rule_name text; v_rule jsonb; v_round integer; v_eff jsonb; v_ground jsonb; v_ok boolean;$b$, 'vitality declare');
    v := pg_temp.rep(v, $a$    IF v_rule IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_p.effects) e WHERE e->>'name' = v_rule->'ended_by'->>'name') THEN$a$,
$b$    v_ground := public.rpg_participant_ground(p_participant_id);
    v_ok := v_rule IS NOT NULL AND (v_rule->>'where' IS NULL OR coalesce((v_ground->>(v_rule->>'where'))::boolean, false)) AND NOT (v_ground->>'burning')::boolean;
    IF v_ok AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_p.effects) e WHERE e->>'name' = v_rule->'ended_by'->>'name') THEN$b$, 'vitality ground');
    v := pg_temp.rep(v, $a$      v_after := v_after || jsonb_build_object('fell', 'dies');$a$,
$b$      v_after := v_after || jsonb_build_object('fell', 'dies' || CASE WHEN v_rule IS NOT NULL AND NOT v_ok AND (v_ground->>'burning')::boolean THEN ' in the fire'
                                                                     WHEN v_rule IS NOT NULL AND NOT v_ok THEN ' with no ' || (v_rule->>'where') || ' to sink into'
                                                                     ELSE '' END);$b$, 'vitality dies text');
    EXECUTE v;
  END IF;

  -- rpg_best_aim: last changed by anchors, so patched by anchors again; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_best_aim';
  IF v_src NOT LIKE '%rpg_square_info%' THEN
    IF md5(v_src) <> 'c79b6fed2795105987c9d8c74e82c288' THEN RAISE EXCEPTION 'rpg_best_aim body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_best_aim(uuid,uuid,uuid[])'::regprocedure);
    v := pg_temp.rep(v, $a$       AND coalesce((s.terrain->>(p.pos_x || ',' || p.pos_y))::integer, 0) < 4$a$,
$b$       AND (SELECT i.penalty FROM public.rpg_square_info(s.terrain->(p.pos_x || ',' || p.pos_y), s.round) i) < 4$b$, 'aim penalty');
    EXECUTE v;
  END IF;

  -- rpg_session_state: last changed by anchors, so patched by anchors again; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_session_state';
  IF v_src NOT LIKE '%rpg_square_info%' THEN
    IF md5(v_src) <> '051faaf43d5580fdf71ee24e148b830b' THEN RAISE EXCEPTION 'rpg_session_state body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_session_state(uuid)'::regprocedure);
    v := pg_temp.rep(v, $a$-- The board: its size, each square's movement penalty (terrain), where everyone stands, each weapon's and action's$a$,
$b$-- The board: its size, each square's movement penalty, forest and fire (terrain, read through rpg_square_info; burn_rounds
-- and burn_cost for the painter's words), where everyone stands, each weapon's and action's$b$, 'state header');
    v := pg_temp.rep(v, $a$                 'terrain', v_s.terrain,$a$,
$b$                 'terrain', (SELECT coalesce(jsonb_object_agg(t.key, jsonb_build_object('p', i.penalty, 'forest', i.forest, 'burning', i.burning)), '{}'::jsonb)
                               FROM jsonb_each(v_s.terrain) t CROSS JOIN LATERAL public.rpg_square_info(t.value, v_s.round) i),
                 'burn_rounds', public.rpg_setting('burn_rounds'), 'burn_cost', public.rpg_setting('burn_cost'),$b$, 'state terrain');
    v := pg_temp.rep(v, $a$        'pending_check', (SELECT jsonb_build_object('name', e->>'name', 'stat', e->>'check_stat', 'stat_name', d.name,$a$,
$b$        'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'item', i.name, 'line', public.rpg_action_text(a.id),
                                              'beats', a.beats, 'ticks', CASE WHEN a.kind IN ('action', 'bonus_action') THEN public.rpg_action_ticks(v_p.id, a.beats) END,
                                              'reach', a.reach, 'square', coalesce(a.effect->>'on' IN ('step', 'board'), false)) ORDER BY i.sort_order, a.sort_order), '[]'::jsonb)
                      FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
                      JOIN public.rpg_creature_actions a ON a.creature_id = o.template_id AND a.kind <> 'trait'
                     WHERE i.character_id = v_p.character_id AND i.equipped AND NOT i.worn AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean),
        'pending_check', (SELECT jsonb_build_object('name', e->>'name', 'stat', e->>'check_stat', 'stat_name', d.name,$b$, 'state item actions');
    EXECUTE v;
  END IF;

  -- rpg_action_text: last changed by anchors, so patched by anchors again; its md5 is checked first.
  SELECT p.prosrc INTO v_src FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_action_text';
  IF v_src NOT LIKE '%on_harm%' THEN
    IF md5(v_src) <> '592a8961a0d97ea441c1fd8f2fdbc227' THEN RAISE EXCEPTION 'rpg_action_text body drifted (md5 %), patch by hand', md5(v_src); END IF;
    v := pg_get_functiondef('public.rpg_action_text(uuid,numeric)'::regprocedure);
    v := pg_temp.rep(v, $a$    RETURN 'At 0 vitality it is ' || (a.effect->'apply'->>'name') || ' and cannot act or be reached; after '
        || (a.effect->'apply'->>'rounds') || ' rounds it rises with ' || coalesce(a.effect->'apply'->>'revive', '1') || ' vitality.'$a$,
$b$    RETURN 'At 0 vitality' || CASE WHEN a.effect ? 'where' THEN ' on ' || (a.effect->>'where') || ' ground (off the board counts)' ELSE '' END
        || ' it is ' || (a.effect->'apply'->>'name') || ' and cannot act or be reached; after '
        || (a.effect->'apply'->>'rounds') || ' rounds it rises with ' || coalesce(a.effect->'apply'->>'revive', '1') || ' vitality.'
        || CASE WHEN a.effect ? 'where' THEN ' Anywhere else it dies.' ELSE '' END
        || CASE WHEN a.effect ? 'fire' THEN ' Its square set alight while it waits burns it: it is ' || (a.effect->'fire'->>'name') || ' and will not rise.' ELSE '' END$b$, 'text zero line');
    v := pg_temp.rep(v, $a$    RETURN CASE WHEN coalesce((a.effect->>'ignore_penalty')::boolean, false)
                THEN 'Movement penalties never slow it: every square costs it 1 to step into.' END;$a$,
$b$    RETURN nullif(concat_ws(' ',
      CASE WHEN coalesce((a.effect->>'ignore_penalty')::boolean, false) THEN 'Movement penalties never slow it: every square costs it 1 to step into (fire still does).' END,
      CASE WHEN a.effect ? 'unseen' THEN 'On ' || (a.effect->'unseen'->>'where') || ' ground it is unseen beyond ' || (a.effect->'unseen'->>'beyond')
                                        || ' squares: no roll reaches it from farther away, whatever its reach.' END), '');$b$, 'text move line');
    v := pg_temp.rep(v, $a$  IF a.effect->>'on' = 'board' THEN
    v_parts := v_parts || ('Every square within ' || coalesce(a.effect->>'radius', '0') || ' of a square in reach gets '
                           || coalesce(a.effect->>'raise', '1') || ' more movement penalty, up to 9');
  END IF;$a$,
$b$  IF a.effect->>'on' = 'board' AND coalesce((a.effect->>'burn')::boolean, false) THEN
    v_parts := v_parts || ('Sets a square in reach alight for ' || trim_scale(public.rpg_setting('burn_rounds'))::text || ' rounds: it costs '
                           || trim_scale(public.rpg_setting('burn_cost'))::text || ' more to step into, and a creature waiting there under a rule fire ends burns');
  ELSIF a.effect->>'on' = 'board' THEN
    v_parts := v_parts || ('Every square within ' || coalesce(a.effect->>'radius', '0') || ' of a square in reach gets '
                           || coalesce(a.effect->>'raise', '1') || ' more movement penalty, up to 9');
  END IF;$b$, 'text board line');
    v := pg_temp.rep(v, $a$                 WHEN 'source' THEN ', and its own attacks face their Evade Enemy × 1'
                 ELSE '' END;$a$,
$b$                 WHEN 'source' THEN ', and its own attacks face their Evade Enemy × 1'
                 ELSE '' END
            || CASE WHEN jsonb_typeof(v_ap->'on_harm') = 'object'
                    THEN '. If they attack an innocent (someone on the good side who has not attacked in this fight) or set forest ground alight while '
                         || (v_ap->>'name') || ', they are ' || (v_ap->'on_harm'->>'name') || ' for the rest of the fight'
                         || CASE v_ap->'on_harm'->>'exposed' WHEN 'source' THEN ': its own attacks face their Evade Enemy × 1' WHEN 'all' THEN ': every attacker faces their Evade Enemy × 1' ELSE '' END
                    ELSE '' END;$b$, 'text on_harm');
    EXECUTE v;
  END IF;

END $do$;

-- 3. The Bramblemaw's three waiting entries now drive rules; the card's pictures stay pictures.
UPDATE public.rpg_creature_actions SET effect = effect || '{"where": "forest", "fire": {"name": "Burned"}}'::jsonb,
       description = 'Cut down among the trees, it sinks into the soil instead of dying.'
 WHERE creature_id = 'ed646b1f-e7b4-4edc-807b-8b36db6eedbf' AND kind = 'trait' AND name = 'Rooted Resilience';
UPDATE public.rpg_creature_actions SET effect = effect || '{"unseen": {"where": "forest", "beyond": 2}}'::jsonb
 WHERE creature_id = 'ed646b1f-e7b4-4edc-807b-8b36db6eedbf' AND kind = 'trait' AND name = 'Forest-Bound Terror';
UPDATE public.rpg_creature_actions
   SET effect = jsonb_set(effect, '{apply,on_harm}', '{"name": "Condemned", "exposed": "source", "clear": "fight", "cannot_act": false}'::jsonb)
 WHERE creature_id = 'ed646b1f-e7b4-4edc-807b-8b36db6eedbf' AND kind = 'bonus_action' AND name = 'Judging Gaze';

-- 4. The Torch: an Object card whose one action lights a square (the same shape as a creature's card action).
INSERT INTO public.rpg_creatures (key, name, parent_id, blueprint, shown_to_players, sort_order, worn, color)
VALUES ('torch', 'Torch', '0e55221a-403b-490e-9509-062e2113d723', '{"TO": {"divisor": 20}, "WT": 1}'::jsonb, false, 1019, false, '#B5651D')
ON CONFLICT (agency_id, key) DO NOTHING;
INSERT INTO public.rpg_creature_actions (creature_id, kind, name, description, effect, beats, energy_cost, energy_type, reach, area, deals_damage, sort_order)
SELECT c.id, 'action', 'Light the ground', 'Held to the ground, it sets the square alight.', '{"on": "board", "burn": true}'::jsonb, 1, 0, 'physical', 1, false, false, 1
  FROM public.rpg_creatures c WHERE c.key = 'torch'
ON CONFLICT (creature_id, kind, name) DO NOTHING;

-- 5. Rule cards (the admin manual page follows by trigger).
UPDATE public.rpg_rules SET body = body || E'\n\nGround can be forest, and it can burn. The game master paints forest when setting up the board. A Torch held in the hand lights one square in reach as the turn''s action (1 beat); the square burns for 3 rounds, and the game master can set fire or put it out by hand. A burning square costs 3 more to step into, forest or not, for everyone.\n*Briars of penalty 2 that are burning cost 1 + 2 + 3 = 6 to step into. The Bramblemaw ignores the briars but not the fire: 1 + 3 = 4.*'
 WHERE key = 'moving';
UPDATE public.rpg_rules SET body = body || E'\n\nA creature''s card can name where its revival works. The Bramblemaw sinks only on forest ground (off the board counts as forest); anywhere else, or on a burning square, it dies at 0. While it waits, its square set alight burns it: it is Burned and will not rise, the same end as a landed sanctify roll.'
 WHERE key = 'defeat';
UPDATE public.rpg_rules SET body = body || E'\n\nSome creatures are unseen on their own ground. On a forest square the Bramblemaw cannot be aimed at from more than 2 squares away, whatever the weapon''s reach: a longbow reaches 12, but at 5 squares it has no target; at 2 it does.\n\nJudged also watches what you do. An innocent is anyone on the good side (Connection with God ahead of Fascination with Evil) who has not attacked anyone in this fight; a forest square is a tree. A Judged fighter who attacks an innocent, hit or miss, or sets a forest square alight is Condemned for the rest of the fight: the Bramblemaw''s attacks face their Evade Enemy × 1.\n*Zaboo is Judged and swings at a Harrier that has not attacked. From then on the Bramblemaw''s Claw 10 faces Zaboo''s Evade Enemy 5 × 1: difficulty 5, so it needs 100 × 5 ÷ (5 + 10) = 34 instead of 50.*'
 WHERE key = 'exposed';

