-- roleplaying_map3_creatures_fights: world map step 3 (Peter 2026-10-03 03:07, "Defaults" = 1A encounter roll, 2A retire
-- the hand-painted fight board, 3A real weapon reach). Creatures meet the group in their haunts and every fight is
-- played on the real ground of the world map, inside the journey, on the same clock.

ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS haunt_ids uuid[];
COMMENT ON COLUMN public.rpg_creatures.haunt_ids IS 'Creature cards: the place cards (row ids) it haunts. A piece walking inside one of them may meet it (rpg_map_walk).';
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS haunt_ticks integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.rpg_session_participants.haunt_ticks IS 'On a journey: ticks walked inside haunts, counted on so every full hour is one encounter roll.';
COMMENT ON COLUMN public.rpg_session_participants.walk_to_x IS 'On a journey: the world square (counted from 1, like pos_x) the piece was heading for when its walking day ran out.';

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'encounter_chance', 15, 'Each hour a piece walks in a haunt, a d100 at or under this brings a creature (Peter 2026-10-03, 1A)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'encounter_squares', 10, 'How many squares away a creature appears when met (10 = 37 feet)')
ON CONFLICT (agency_id, key) DO NOTHING;

-- Haunts, drafted from each card's lore and haunts line for Peter to correct.
UPDATE public.rpg_creatures c SET haunt_ids = q.ids
  FROM (SELECT v.name, ARRAY(SELECT p.id FROM public.rpg_creatures p
                              WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND p.key = ANY (v.keys) ORDER BY p.sort_order) AS ids
          FROM (VALUES ('Bramblemaw', ARRAY['bramblemaw_lair', 'old_forest', 'cursed_road', 'abandoned_borderlands']),
                       ('Ashwing Harrier', ARRAY['burnt_hills']),
                       ('Mossback Elder', ARRAY['mossback_valley']),
                       ('Gloam Wisp', ARRAY['the_fog']),
                       ('Thornfield Boar', ARRAY['thornfields'])) AS v(name, keys)) q
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.name = q.name AND c.place_w IS NULL;

-- Weapon reach at real size (3A): a square is 3 ft 8 in. The old cap of 20 squares was the biggest board; the board is the world now,
-- so the cap goes to 1,000 squares (about 1,200 yards).
ALTER TABLE public.rpg_stat_definitions DROP CONSTRAINT IF EXISTS rpg_stat_definitions_reach, ADD CONSTRAINT rpg_stat_definitions_reach CHECK (reach >= 1 AND reach <= 1000);
ALTER TABLE public.rpg_creature_actions DROP CONSTRAINT IF EXISTS rpg_creature_actions_reach, ADD CONSTRAINT rpg_creature_actions_reach CHECK (reach >= 1 AND reach <= 1000);
UPDATE public.rpg_stat_definitions SET reach = v.reach
  FROM (VALUES ('hurling', 8), ('tossing', 8), ('sling', 82), ('crossbow', 164), ('longbow', 164)) AS v(key, reach)
 WHERE rpg_stat_definitions.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rpg_stat_definitions.key = v.key;

CREATE OR REPLACE FUNCTION public.rpg_square_name(p_x integer, p_y integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- A square name: column letter, then row number, counted within its own battle grid of 12 by 12 (x 3, y 5: C5;
-- world square 27, 17: C5 of the battle grid it sits in). A grid of the map names its cells the same way.
SELECT chr(64 + ((p_x - 1) % 12 + 12) % 12 + 1) || (((p_y - 1) % 12 + 12) % 12 + 1)::text;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_square_gap(p_x1 integer, p_y1 integer, p_x2 integer, p_y2 integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- Squares between two squares of the world map: the larger of the gaps across and up-down, east to west the shorter
-- way round (the map wraps). C3 to E6: 2 across, 3 down, so 3. The one home of distance on the board.
SELECT greatest(least(abs(p_x1 - p_x2), w.w - abs(p_x1 - p_x2)), abs(p_y1 - p_y2))
  FROM (SELECT l.span AS w FROM public.rpg_map_ladder() l WHERE l.level = 1) w;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of a block of squares in a fight, the one way: the world map under them (rpg_map_cells on the battle
-- grid, its penalty and forest from rpg_map_ground: forest 1, hills 1, mountains 2, the sea no entry), with what the
-- fight itself has done to a square on top (rpg_sessions.terrain read through rpg_square_info: a penalty there, from
-- Briar Shift, takes the place of the ground's; forest there adds to it; fire burns for burn_rounds). Squares are world
-- squares counted from 1, as pieces stand. A fight off the map has no board: only what the fight did.
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.place_id
                          FROM s CROSS JOIN LATERAL public.rpg_map_cells(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map)
SELECT g.x, g.y,
       CASE WHEN m.kind = 'sea' THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(r.penalty, i.penalty) END,
       coalesce(r.forest, false) OR i.forest, i.burning, coalesce(m.kind = 'sea', false)
  FROM s CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
  LEFT JOIN LATERAL public.rpg_map_ground(m.kind, m.place_id) r ON true
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_square(p_session_id uuid, p_x integer, p_y integer)
 RETURNS TABLE(penalty integer, forest boolean, burning boolean, sea boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One square of a fight: rpg_fight_squares for a block of one.
SELECT f.penalty, f.forest, f.burning, f.sea FROM public.rpg_fight_squares(p_session_id, p_x, p_y, 1, 1) f;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_reach()
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The longest reach anything has (a longbow: 164 squares, 600 feet). A piece this close to a creature still in the
-- fight is in the fight: it moves on the fight board, not across the map.
SELECT greatest((SELECT max(d.reach) FROM public.rpg_stat_definitions d WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
                (SELECT max(a.reach) FROM public.rpg_creature_actions a), 1);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_in_fight(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a piece on a journey is in a fight: a creature still in it (not dead, not waiting to rise) stands within
-- the longest reach of it (rpg_fight_reach: 164 squares). A creature is always in its own fight.
SELECT p.pos_x IS NOT NULL AND (p.creature_id IS NOT NULL OR EXISTS (
         SELECT 1 FROM public.rpg_session_participants c
          WHERE c.session_id = p.session_id AND c.id <> p.id AND c.creature_id IS NOT NULL AND c.pos_x IS NOT NULL
            AND NOT public.rpg_participant_out(c.id)
            AND public.rpg_square_gap(p.pos_x, p.pos_y, c.pos_x, c.pos_y) <= public.rpg_fight_reach()))
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_haunters(p_x integer, p_y integer)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The creature cards that haunt a world square (counted from 1): every card whose haunt_ids name a place whose oval
-- covers the square. Nothing when no haunt does.
SELECT array_agg(DISTINCT c.id ORDER BY c.id)
  FROM public.rpg_creatures c
 CROSS JOIN LATERAL unnest(c.haunt_ids) AS h(id)
  JOIN public.rpg_creatures p ON p.id = h.id AND p.is_active AND p.place_w IS NOT NULL
 CROSS JOIN (SELECT l.span AS w FROM public.rpg_map_ladder() l WHERE l.level = 1) w
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
   AND public.rpg_map_covers(p_x - 0.5::double precision, p_y - 0.5::double precision, p.place_x, p.place_y, p.place_w, p.place_h, w.w);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_set_down(p_participant_id uuid, p_x integer, p_y integer, p_squares integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Puts a newly met creature on the map p_squares away from a square (world squares from 1): one of the eight ways at
-- random, on dry ground nobody stands on; nearer if no way is free that far. Returns whether it found a square.
DECLARE v_p record; v_d integer; v_w integer; v_x integer; v_y integer; v_dir record;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  SELECT l.span INTO v_w FROM public.rpg_map_ladder() l WHERE l.level = 1;
  FOR v_d IN REVERSE greatest(p_squares, 1) .. 1 LOOP
    FOR v_dir IN SELECT d.dx, d.dy FROM (VALUES (-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)) AS d(dx, dy) ORDER BY random() LOOP
      v_x := mod(p_x - 1 + v_dir.dx * v_d + v_w, v_w) + 1;
      v_y := p_y + v_dir.dy * v_d;
      CONTINUE WHEN v_y < 1 OR v_y > v_w / 2;
      CONTINUE WHEN (SELECT f.sea FROM public.rpg_fight_square(v_p.session_id, v_x, v_y) f);
      CONTINUE WHEN EXISTS (SELECT 1 FROM public.rpg_session_participants o
                             WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = v_x AND o.pos_y = v_y
                               AND public.rpg_participant_blocks(o.id));
      UPDATE public.rpg_session_participants SET pos_x = v_x, pos_y = v_y WHERE id = p_participant_id;
      RETURN true;
    END LOOP;
  END LOOP;
  RETURN false;
END;
$function$;

-- rpg_grid_costs gains the most path cost to look at (the board is the world now; it looks only that far round the
-- fighter). Its callers are rpg_act_square, rpg_move_options and rpg_step_target, all replaced below to pass it.
DROP FUNCTION IF EXISTS public.rpg_grid_costs(uuid);
CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid, p_budget integer)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it costs this fighter to reach each square within p_budget of path cost from where they stand. Stepping into
-- a square costs 1 + its movement penalty (just 1 for a creature whose card says penalties never slow it:
-- rpg_participant_ignores_penalty), plus burn_cost (3) while the square burns, for everyone; a diagonal step costs
-- the same as a straight one; nobody steps into the sea or into a square someone takes up (rpg_participant_blocks).
-- The ground is the world map under the fight (rpg_fight_squares), read once for the block round the fighter.
-- Squares nobody can get to within the budget are left out. From C3, briars of penalty 2 on D3 cost 3 to enter, and
-- E3 past them costs 4; burning briars cost 6, and the Bramblemaw pays 4 there.
DECLARE
  v_p record; v_s record; v_b integer := greatest(coalesce(p_budget, 0), 0); x0 integer; y0 integer; w integer; h integer; n integer;
  d integer[]; pen integer[]; fire integer[]; blk boolean[]; v_ign boolean; v_changed boolean; v_big constant integer := 1000000;
  i integer; j integer; cx integer; cy integer; dx integer; dy integer; nx integer; ny integer; c integer; v_q record; v_o record;
  v_burn integer := public.rpg_setting('burn_cost')::integer; v_down integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL OR v_b = 0 THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT v_s.on_map THEN RETURN; END IF;
  SELECT l.span / 2 INTO v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  x0 := greatest(v_p.pos_x - v_b, 1); w := least(v_p.pos_x + v_b, v_down * 2) - x0 + 1;
  y0 := greatest(v_p.pos_y - v_b, 1); h := least(v_p.pos_y + v_b, v_down) - y0 + 1;
  n := w * h;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); fire := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_q IN SELECT * FROM public.rpg_fight_squares(v_s.id, x0, y0, w, h) LOOP
    i := (v_q.y - y0) * w + (v_q.x - x0) + 1;
    IF v_q.sea THEN blk[i] := true; ELSE pen[i] := v_q.penalty; END IF;
    fire[i] := CASE WHEN v_q.burning THEN v_burn ELSE 0 END;
  END LOOP;
  FOR v_o IN SELECT o.pos_x, o.pos_y FROM public.rpg_session_participants o
              WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND public.rpg_participant_blocks(o.id) LOOP
    IF v_o.pos_x BETWEEN x0 AND x0 + w - 1 AND v_o.pos_y BETWEEN y0 AND y0 + h - 1 THEN blk[(v_o.pos_y - y0) * w + (v_o.pos_x - x0) + 1] := true; END IF;
  END LOOP;
  d[(v_p.pos_y - y0) * w + (v_p.pos_x - x0) + 1] := 0;
  LOOP
    v_changed := false;
    FOR i IN 1..n LOOP
      CONTINUE WHEN d[i] >= v_big;
      cx := (i - 1) % w; cy := (i - 1) / w;
      FOR dx IN -1..1 LOOP
        FOR dy IN -1..1 LOOP
          nx := cx + dx; ny := cy + dy;
          CONTINUE WHEN (dx = 0 AND dy = 0) OR nx < 0 OR ny < 0 OR nx >= w OR ny >= h;
          j := ny * w + nx + 1;
          CONTINUE WHEN blk[j];
          c := d[i] + 1 + CASE WHEN v_ign THEN 0 ELSE pen[j] END + fire[j];
          IF c < d[j] AND c <= v_b THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT x0 + (k - 1) % w, y0 + (k - 1) / w, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$;

-- Replaced in full:

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL::integer, p_y integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a piece on a square of the world map (counted from 1, as pieces stand), or with no square takes
-- it off. Free, any time, but never onto the sea or a square someone takes up; placing a piece forgets where it was
-- heading. A fight off the map has no board, so there it can only take someone off.
DECLARE v_p record; v_s record; v_who text;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
  ELSE
    IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board; meet creatures on a journey'; END IF;
    IF p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
       OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
      RAISE EXCEPTION 'that square is off the map';
    END IF;
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN RAISE EXCEPTION 'that square is sea'; END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on that square', v_who; END IF;
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

-- rpg_set_square keeps only fire (2A: the ground comes from the map; painting penalty and forest by hand goes). The
-- page calls it by name; no database function calls it (checked 2026-10-03).
DROP FUNCTION IF EXISTS public.rpg_set_square(uuid, integer, integer, integer, boolean, boolean);
CREATE OR REPLACE FUNCTION public.rpg_set_square(p_session_id uuid, p_x integer, p_y integer, p_burning boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master sets a square alight (it burns for burn_rounds rounds and burns a creature waiting there under a
-- rule fire ends: rpg_ignite, with a log line) or puts it out. The ground itself comes from the world map.
DECLARE v_s record; v_text text := '';
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master sets fire by hand'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
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
REVOKE EXECUTE ON FUNCTION public.rpg_set_square(uuid, integer, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpg_set_square(uuid, integer, integer, boolean) TO authenticated, service_role;

-- Changed in place, by exact replacements on the live definitions of 2026-10-03:

CREATE OR REPLACE FUNCTION public.rpg_distance(p_a uuid, p_b uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Squares between two fighters: the larger of the gaps across and up-down (C3 to E6: 2 across, 3 down → 3). Null
-- when either is not on the board.
SELECT public.rpg_square_gap(a.pos_x, a.pos_y, b.pos_x, b.pos_y)
  FROM public.rpg_session_participants a, public.rpg_session_participants b
 WHERE a.id = p_a AND b.id = p_b;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_participant_ground(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground a fighter stands on: {penalty, forest, burning, off}, from the world map under the fight with what the
-- fight did to the square on top (rpg_fight_square). Off the board counts as forest and never burns.
-- Read by rpg_session_adjust_vitality (where a revival rule works), rpg_reach_to (unseen) and rpg_burn_out (fire).
SELECT CASE WHEN p.pos_x IS NULL THEN jsonb_build_object('penalty', 0, 'forest', true, 'burning', false, 'off', true)
            ELSE jsonb_build_object('penalty', i.penalty, 'forest', i.forest, 'burning', i.burning, 'off', false) END
  FROM public.rpg_session_participants p
  JOIN public.rpg_sessions s ON s.id = p.session_id
  LEFT JOIN LATERAL public.rpg_fight_square(s.id, p.pos_x, p.pos_y) i ON true
 WHERE p.id = p_participant_id;
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
            FROM public.rpg_grid_costs(v_p.id, public.rpg_move_budget(v_p.id, v_s.turn_move_ticks)) g
            CROSS JOIN LATERAL (SELECT public.rpg_ticks_at(v_sp, g.cost * v_mt) AS ticks) t
           WHERE g.cost > 0 AND t.ticks <= v_left);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_step_target(p_participant_id uuid, p_budget integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site walks a creature: toward the nearest character still standing, as far as p_budget of path cost takes
-- it (rpg_grid_costs). It picks the reachable square closest to any such character by board distance, then by
-- straight line, then the cheaper one, and only if that is closer than where it stands; nothing when a character is
-- already next to it. The Bramblemaw on E1 with 3 to spend and Zaboo on E8 goes to E4.
DECLARE v_p record; v_now integer; v_tx integer[]; v_ty integer[];
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL OR coalesce(p_budget, 0) <= 0 THEN RETURN NULL; END IF;
  SELECT array_agg(t.pos_x), array_agg(t.pos_y) INTO v_tx, v_ty
    FROM public.rpg_session_participants t
   WHERE t.session_id = v_p.session_id AND t.creature_id IS NULL AND t.pos_x IS NOT NULL
     AND (public.rpg_participant_vitality(t.id)->>'left')::integer > 0;
  IF v_tx IS NULL THEN RETURN NULL; END IF;
  SELECT min(public.rpg_square_gap(tx, ty, v_p.pos_x, v_p.pos_y)) INTO v_now FROM unnest(v_tx, v_ty) AS u(tx, ty);
  IF v_now <= 1 THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('x', g.x, 'y', g.y, 'cost', g.cost)
            FROM public.rpg_grid_costs(p_participant_id, p_budget) g,
                 LATERAL (SELECT min(public.rpg_square_gap(tx, ty, g.x, g.y)) AS dist,
                                 min((tx - g.x) * (tx - g.x) + (ty - g.y) * (ty - g.y)) AS line
                            FROM unnest(v_tx, v_ty) AS u(tx, ty)) m
           WHERE g.cost > 0 AND g.cost <= p_budget AND m.dist < v_now
           ORDER BY m.dist, m.line, g.cost, g.y, g.x LIMIT 1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_best_aim(p_actor_id uuid, p_action_id uuid, p_targets uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the site aims an action. Only targets in the reach of the action count (rpg_in_reach: Claw 1 square, Briar Roar
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
       AND (SELECT f.penalty FROM public.rpg_fight_square(s.id, p.pos_x, p.pos_y) f) < 4
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

CREATE OR REPLACE FUNCTION public.rpg_act_square(p_actor_id uuid, p_x integer, p_y integer, p_action_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A move on the board, which is the world map under the fight (squares counted from 1, as pieces stand; a fight off
-- the map has no board). With no action it is a walk by the one whose turn it is: the path cost (rpg_grid_costs) × 
-- move_ticks at their Speed goes on the turn's moving time, and a turn holds round_ticks (20) of it (Zaboo, Speed 5,
-- walks 2 plain squares in 13 ticks; Karen, Speed 1, in 18). With a card action that works on a square: a step
-- (Rootstep: up to rpg_step_budget of path, 2, as a legendary action on someone else's turn, using no time) or a
-- board action (Briar Shift: every square within 1 of a square in its reach gets 2 more movement penalty, up to 9).
-- A thing held in the hand lends its card's square actions (a Torch: Light the ground sets a square alight for
-- burn_rounds rounds as the turn's action, rpg_ignite; on forest ground that is a tree harmed, rpg_judgement); one
-- use of the thing is spent when it counts uses. Players move their own characters; the game master moves creatures.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_actor record; v_s record; v_act record; v_akind text; v_aname text; v_on text;
  v_rt integer := public.rpg_setting('round_ticks')::integer; v_cost integer; v_ticks integer; v_budget integer;
  v_text text; v_sq text := public.rpg_square_name(p_x, p_y);
  v_raise integer; v_r integer; v_x integer; v_y integer; v_energy jsonb; v_dist integer; v_item record; v_forest boolean; v_pen integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
  IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board'; END IF;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
     OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  IF v_actor.creature_id IS NOT NULL AND NOT v_gm THEN RAISE EXCEPTION 'the game master moves %', v_actor.name; END IF;
  IF p_action_id IS NOT NULL THEN
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = ANY (public.rpg_participant_cards(p_actor_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this fighter''s card or on a thing they hold'; END IF;
    IF v_act.creature_id IS DISTINCT FROM v_actor.creature_id THEN
      -- the action comes from a thing held in the hand: the first unbroken one of that card
      SELECT i.id, i.name, i.uses_left INTO v_item FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
       WHERE i.character_id = v_actor.character_id AND i.equipped AND NOT i.worn AND o.template_id = v_act.creature_id
         AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean
       ORDER BY i.sort_order LIMIT 1;
      IF v_item.id IS NULL THEN RAISE EXCEPTION '% is not holding anything that can %', v_actor.name, v_act.name; END IF;
    END IF;
    v_akind := v_act.kind; v_aname := v_act.name; v_on := v_act.effect->>'on';
    IF v_on IS DISTINCT FROM 'step' AND v_on IS DISTINCT FROM 'board' THEN RAISE EXCEPTION '% is not aimed at a square', v_aname; END IF;
    IF v_akind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;
    IF v_akind IN ('action', 'bonus_action') AND v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
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
    IF v_on IS NULL THEN
      v_budget := public.rpg_move_budget(p_actor_id, v_s.turn_move_ticks);
    ELSE
      v_budget := public.rpg_step_budget(coalesce((v_act.effect->>'beats')::integer, 1));
    END IF;
    SELECT g.cost INTO v_cost FROM public.rpg_grid_costs(p_actor_id, v_budget) g WHERE g.x = p_x AND g.y = p_y;
    IF v_cost IS NULL THEN RAISE EXCEPTION '% cannot get to % this turn: too far, the sea, or someone in the way', v_actor.name, v_sq; END IF;
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
      v_dist := public.rpg_square_gap(v_actor.pos_x, v_actor.pos_y, p_x, p_y);
      IF v_dist > v_act.reach THEN RAISE EXCEPTION '% is % squares away and % reaches %', v_sq, v_dist, v_aname, v_act.reach; END IF;
    END IF;
    IF coalesce((v_act.effect->>'burn')::boolean, false) THEN
      -- fire: the square burns for burn_rounds (rpg_ignite); forest ground set alight is a tree harmed (rpg_judgement)
      SELECT f.forest INTO v_forest FROM public.rpg_fight_square(v_s.id, p_x, p_y) f;
      v_text := v_actor.name || ' lights ' || v_sq || ' with ' || coalesce(v_item.name, v_aname) || '.' || public.rpg_ignite(v_s.id, p_x, p_y);
      IF v_forest THEN v_text := v_text || coalesce(public.rpg_judgement(p_actor_id, NULL, true), ''); END IF;
    ELSE
      v_raise := coalesce((v_act.effect->>'raise')::integer, 1);
      v_r := coalesce((v_act.effect->>'radius')::integer, 0);
      FOR v_x IN greatest(p_x - v_r, 1) .. p_x + v_r LOOP
        FOR v_y IN greatest(p_y - v_r, 1) .. p_y + v_r LOOP
          SELECT f.penalty INTO v_pen FROM public.rpg_fight_square(v_s.id, v_x, v_y) f;
          CONTINUE WHEN v_pen IS NULL;
          PERFORM public.rpg_square_set(v_s.id, v_x, v_y, least(v_pen + v_raise, 9));
        END LOOP;
      END LOOP;
      v_text := v_actor.name || ' uses ' || v_aname || ': the ground around ' || v_sq || ' gets harder to cross (movement penalty +' || v_raise || ').';
    END IF;
  END IF;

  IF p_action_id IS NOT NULL THEN
    IF v_akind IN ('action', 'bonus_action') AND coalesce(v_act.beats, 0) > 0 THEN
      UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_act.beats) WHERE id = v_s.id;
    END IF;
    IF v_item.id IS NOT NULL AND v_item.uses_left IS NOT NULL THEN PERFORM public.rpg_item_use(v_item.id); END IF;
    IF v_act.energy_cost > 0 THEN
      IF v_act.energy_type = 'spiritual' THEN
        UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_act.energy_cost WHERE id = p_actor_id;
      ELSE
        UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_act.energy_cost WHERE id = p_actor_id;
      END IF;
    END IF;
    IF v_akind = 'lair' THEN UPDATE public.rpg_session_participants SET lair_round = v_s.round WHERE id = p_actor_id; END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_square_set(p_session_id uuid, p_x integer, p_y integer, p_penalty integer DEFAULT NULL::integer, p_forest boolean DEFAULT NULL::boolean, p_burn_until integer DEFAULT NULL::integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The one writer of a square's entry in rpg_sessions.terrain (what a fight did to a square of the map: a penalty from
-- Briar Shift in place of the ground's, fire). Each argument given replaces that part (null leaves it
-- alone): a penalty of 0, forest false or a burn_until at or before this round clear theirs, and an entry with nothing
-- left is dropped. Internal: rpg_set_square (the game master painting), rpg_act_square (Briar Shift) and rpg_ignite
-- (fire).
DECLARE v_k text := p_x || ',' || p_y; v_e jsonb; v_s record;
BEGIN
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board'; END IF;
  IF p_x IS NULL OR p_y IS NULL OR p_x < 1 OR p_y < 1 THEN RAISE EXCEPTION 'that square is off the map'; END IF;
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
-- The board (a fight on a journey; off the map there is none): the block of the world map round the one whose turn it
-- is, at least 13 squares a side and up to 24 to take in the fighters near them, the movement penalty of each square
-- (nothing for sea), forest and fire (rpg_fight_squares), its column and row names (rpg_square_name, within its own
-- battle grid), and for each fighter whether they stand on it and how far they are from its middle; burn_rounds and
-- burn_cost for the words; where everyone stands, each weapon's and action's
-- reach, and the squares the one whose turn it is can still reach this turn ('moves', with the path cost and ticks).
-- The fight clock: the tick now, each fighter's Speed and next tick (ticks_away: how soon they act; the list runs in
-- that order), each weapon's and action's ticks for that fighter (Karen's sword 36), and what the turn so far costs
-- (turn_cost: moving 13 and acting 27 is 33).
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb; v_vals jsonb; v_rev jsonb;
  v_board jsonb; v_cx integer; v_cy integer; v_bx0 integer; v_by0 integer; v_bw integer; v_bh integer; v_down integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = p_session_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'fight not found'; END IF;
  FOR v_p IN SELECT * FROM public.rpg_session_participants WHERE session_id = p_session_id ORDER BY next_tick NULLS LAST, turn_order, created_at LOOP
    IF v_p.creature_id IS NULL THEN
      v_sheet := public.rpg_sheet(v_p.character_id, public.rpg_setting('default_difficulty'));
      v_item := jsonb_build_object('kind', 'character', 'character_id', v_p.character_id, 'color', v_sheet->'color',
        'vitality_max', (v_sheet->>'vitality_max')::integer,
        'vitality_left', greatest((v_sheet->>'vitality_left')::integer, 0),
        'agility', (SELECT s->'value' FROM jsonb_array_elements(v_sheet->'stats') s WHERE s->>'key' = 'AG'),
        'weapons', (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s->>'key', 'name', s->>'name', 'value', s->'value', 'beats', d.beats, 'ticks', public.rpg_action_ticks(v_p.id, d.beats, s->>'key'), 'energy_cost', d.energy_cost, 'energy_type', d.energy_type, 'reach', d.reach, 'bulk', s->'bulk')
                                    ORDER BY (s->>'value')::numeric DESC, s->>'name'), '[]'::jsonb)
                      FROM jsonb_array_elements(v_sheet->'stats') s
                      JOIN public.rpg_stat_definitions d ON d.key = s->>'key' AND d.is_attack),
        'actions', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'item', i.name, 'line', public.rpg_action_text(a.id),
                                              'beats', a.beats, 'ticks', CASE WHEN a.kind IN ('action', 'bonus_action') THEN public.rpg_action_ticks(v_p.id, a.beats) END,
                                              'reach', a.reach, 'square', coalesce(a.effect->>'on' IN ('step', 'board'), false)) ORDER BY i.sort_order, a.sort_order), '[]'::jsonb)
                      FROM public.rpg_items i JOIN public.rpg_characters o ON o.id = i.object_id
                      JOIN public.rpg_creature_actions a ON a.creature_id = o.template_id AND a.kind <> 'trait'
                     WHERE i.character_id = v_p.character_id AND i.equipped AND NOT i.worn AND NOT (public.rpg_object_state(i.object_id)->>'broken')::boolean),
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
                          'id', a.id, 'name', a.name, 'kind', a.kind, 'skill_key', a.skill_key,
                          'skill', v_vals->a.skill_key,
                          'line', public.rpg_action_text(a.id, (v_vals->>a.skill_key)::numeric),
                          'beats', a.beats, 'ticks', CASE WHEN a.kind IN ('action', 'bonus_action') THEN public.rpg_action_ticks(v_p.id, a.beats) END, 'ready', a.ready,
                          'reach', a.reach, 'square', coalesce(a.effect->>'on' IN ('step', 'board'), false))
                        ORDER BY CASE a.kind WHEN 'action' THEN 1 WHEN 'bonus_action' THEN 2 WHEN 'reaction' THEN 3 WHEN 'legendary' THEN 4 WHEN 'lair' THEN 5 ELSE 6 END, a.sort_order), '[]'::jsonb)
                        FROM (SELECT x.*, public.rpg_action_ready(v_p.id, x.id) AS ready FROM public.rpg_creature_actions x
                               WHERE x.creature_id = v_p.creature_id AND x.kind <> 'trait') a));
      END IF;
    END IF;
    v_parts := v_parts || jsonb_build_array(jsonb_build_object('id', v_p.id, 'name', v_p.name, 'turn_order', v_p.turn_order,
                 'can_act', v_p.can_act, 'status_note', v_p.status_note, 'can_act_now', public.rpg_participant_can_act(v_p.id),
                 'effects', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', e->>'name', 'cannot_act', coalesce((e->>'cannot_act')::boolean, false), 'source', e->>'source')), '[]'::jsonb)
                               FROM jsonb_array_elements(v_p.effects) e),
                 'energy', public.rpg_participant_energy(v_p.id), 'is_current', coalesce(v_p.id = v_s.current_participant_id, false),
                 'pos_x', v_p.pos_x, 'pos_y', v_p.pos_y, 'speed', public.rpg_participant_speed(v_p.id), 'next_tick', v_p.next_tick, 'ticks_away', v_p.next_tick - v_s.clock) || v_item);
  END LOOP;
  -- the board: centered on the one whose turn it is (or the first fighter on the map), grown to take in the fighters
  -- within 11 squares of that middle, at least 13 and at most 24 squares a side
  IF v_s.on_map THEN
    SELECT p.pos_x, p.pos_y INTO v_cx, v_cy FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL
     ORDER BY (p.id = v_s.current_participant_id) DESC, (p.creature_id IS NOT NULL) DESC, p.turn_order, p.created_at LIMIT 1;
  END IF;
  IF v_cx IS NOT NULL THEN
    SELECT l.span / 2 INTO v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
    SELECT least(min(p.pos_x), v_cx - 6) - 2, least(min(p.pos_y), v_cy - 6) - 2, greatest(max(p.pos_x), v_cx + 6) + 2, greatest(max(p.pos_y), v_cy + 6) + 2
      INTO v_bx0, v_by0, v_bw, v_bh
      FROM public.rpg_session_participants p
     WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL AND public.rpg_square_gap(p.pos_x, p.pos_y, v_cx, v_cy) <= 11;
    v_bx0 := greatest(v_bx0, v_cx - 11, 1); v_by0 := greatest(v_by0, v_cy - 11, 1);
    v_bw := least(v_bw, v_cx + 12) - v_bx0 + 1; v_bh := least(v_bh, v_cy + 12, v_down) - v_by0 + 1;
    SELECT jsonb_build_object('x0', v_bx0, 'y0', v_by0, 'w', v_bw, 'h', v_bh,
             'cols', (SELECT jsonb_agg(left(public.rpg_square_name(gx, 1), 1) ORDER BY gx) FROM generate_series(v_bx0, v_bx0 + v_bw - 1) gx),
             'rows', (SELECT jsonb_agg(substr(public.rpg_square_name(1, gy), 2) ORDER BY gy) FROM generate_series(v_by0, v_by0 + v_bh - 1) gy),
             'squares', jsonb_agg(jsonb_build_array(f.penalty, f.forest, f.burning, f.sea) ORDER BY f.y, f.x))
      INTO v_board
      FROM public.rpg_fight_squares(p_session_id, v_bx0, v_by0, v_bw, v_bh) f;
    v_board := v_board || jsonb_build_object('away', (SELECT coalesce(jsonb_object_agg(p.id, public.rpg_square_gap(p.pos_x, p.pos_y, v_cx, v_cy)), '{}'::jsonb)
                                                         FROM public.rpg_session_participants p
                                                        WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL
                                                          AND NOT (p.pos_x BETWEEN v_bx0 AND v_bx0 + v_bw - 1 AND p.pos_y BETWEEN v_by0 AND v_by0 + v_bh - 1)));
  END IF;

  RETURN jsonb_build_object(
    'session', jsonb_build_object('id', v_s.id, 'name', v_s.name, 'status', v_s.status, 'round', v_s.round,
                 'current_participant_id', v_s.current_participant_id, 'on_map', v_s.on_map, 'board', v_board,
                 'burn_rounds', public.rpg_setting('burn_rounds'), 'burn_cost', public.rpg_setting('burn_cost'),
                 'clock', v_s.clock, 'round_ticks', public.rpg_setting('round_ticks'), 'turn_move_ticks', v_s.turn_move_ticks,
                 'turn_action_ticks', v_s.turn_action_ticks, 'turn_cost', public.rpg_turn_cost(v_s.turn_move_ticks, v_s.turn_action_ticks),
                 'updated_at', v_s.updated_at),
    'is_gm', v_gm,
    'moves', CASE WHEN v_s.current_participant_id IS NULL THEN '[]'::jsonb ELSE public.rpg_move_options(v_s.current_participant_id) END,
    'participants', v_parts,
    'events', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'round', e.round, 'kind', e.kind, 'outcome', e.outcome, 'text', e.text,
                                          'damage', e.damage, 'created_at', e.created_at) ORDER BY e.created_at DESC), '[]'::jsonb)
                 FROM (SELECT * FROM public.rpg_events WHERE session_id = p_session_id ORDER BY created_at DESC LIMIT 60) e),
    'available', CASE WHEN v_gm THEN jsonb_build_object(
        'characters', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name), '[]'::jsonb)
                         FROM public.rpg_characters c
                        WHERE c.is_active AND c.session_id IS NULL AND NOT public.rpg_is_object_card(c.template_id)
                          AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.session_id = p_session_id AND p.character_id = c.id)),
        'creatures', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.sort_order, c.name), '[]'::jsonb)
                        FROM public.rpg_creatures c
                       WHERE c.is_active AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.creature_id = c.id AND a.kind <> 'trait'))) END);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view(p_level integer DEFAULT 1, p_x integer DEFAULT 0, p_y integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab in one read, game master only: one grid of the world map, drawn from the place cards and the map
-- rolls (rpg_map_cells). p_level 1 is the world; a deeper grid is named by its level and by the cell of the grid
-- above that it fills, counted across the whole world: 3, 88, 41 is the Country grid inside cell 88, 41 of the
-- Continent grids.
-- Returns the grid (level, name, title, cols, rows, scale), the way back up (crumbs), the grid next door each way
-- (moves), every cell in reading order (x, y, its name like C5, kind sea / land / forest / hills / mountains /
-- place, place = the card it belongs to, marks = other place cards reaching into it, open = the grid inside it),
-- every place card (name, color, icon = the name of its map symbol, size, ground = its ground in words or nothing
-- when it only names the land, the place it is inside, level = the kind of place it is, view = the grid of its own
-- level around its center, listed = it belongs on this grid's list, spot = where to write its name on this grid:
-- its center from the top-left corner, then its width and height, all four in thousandths of a cell, or nothing
-- when the center is off the grid), list = what this grid lists, the places one level down that reach into it
-- (the world lists continents, a continent countries, a country regions, a region cities, a city districts, a
-- district battle grids; a battle grid lists nothing), within = the continent, country and so on that hold the
-- middle of this grid, biggest first (only places that name the land, the smallest of each kind), grounds = each
-- kind of unnamed ground with its name and, when it has one, its movement penalty in words, and the ladder of
-- grids in words.
-- The world also carries detail: every cell of the Continent grids inside it, 144 across and 72 down, one
-- character a cell (~ sea, . open land, t forest, h hills, m mountains, else the character numbered 256 + the
-- place's spot in detail.places, counted from 0), so the world is drawn as fine as the grids inside it.
-- Each cell also carries to = the world square at its middle (counted from 1, as pieces stand), where a piece walks or is placed when
-- the cell is tapped. journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := coalesce(p_x, 0);
  v_y         integer := coalesce(p_y, 0);
  v_x0        integer := 0;
  v_y0        integer := 0;
  v_gx0       bigint;
  v_gy0       bigint;
  v_gx1       bigint;
  v_gy1       bigint;
  v_up_cell   integer;
  v_up_across integer;
  v_up_down   integer;
  v_dc        integer;
  v_dr        integer;
  v_cells     jsonb;
  v_detail    jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
  v_list      jsonb;
  v_within    jsonb;
  v_grounds   jsonb;
  v_ladder    jsonb;
  v_moves     jsonb;
  v_scale     text;
  v_journey   jsonb;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master sees the map'; END IF;
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = coalesce(p_level, 1);
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF v_l.level = 1 THEN
    IF v_x <> 0 OR v_y <> 0 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  ELSE
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    IF v_x NOT BETWEEN 0 AND v_up_across - 1 OR v_y NOT BETWEEN 0 AND v_up_down - 1 THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
    v_x0 := v_x * v_l.cols;
    v_y0 := v_y * v_l.rows;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;
  -- the corners of this grid in world squares
  v_gx0 := v_x0::bigint * v_l.cell;
  v_gy0 := v_y0::bigint * v_l.cell;
  v_gx1 := (v_x0 + v_l.cols)::bigint * v_l.cell;
  v_gy1 := (v_y0 + v_l.rows)::bigint * v_l.cell;

  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'x', c.x - v_x0 + 1, 'y', c.y - v_y0 + 1,
           'name', public.rpg_square_name(c.x - v_x0 + 1, c.y - v_y0 + 1),
           'kind', c.kind, 'place', c.place_id,
           'marks', CASE WHEN cardinality(c.marks) > 0 THEN to_jsonb(c.marks) END,
           'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || c.x::text || '-' || c.y::text END,
           'to', jsonb_build_array(c.x::bigint * v_l.cell + v_l.cell / 2 + 1, c.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
         ORDER BY c.y, c.x)
    INTO v_cells
    FROM public.rpg_map_cells(v_l.level, v_x0, v_y0, v_l.cols, v_l.rows) c;

  IF v_l.level = 1 THEN
    SELECT l.across, l.down INTO v_dc, v_dr FROM public.rpg_map_ladder() l WHERE l.level = 2;
    WITH d AS MATERIALIZED (SELECT c.x, c.y, c.kind, c.place_id FROM public.rpg_map_cells(2, 0, 0, v_dc, v_dr) c),
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.sort_order, q.name), '{}'::uuid[]) AS ids
                 FROM (SELECT DISTINCT c.id, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id) q),
         ln AS (SELECT d.y, string_agg(CASE d.kind WHEN 'sea' THEN '~' WHEN 'land' THEN '.' WHEN 'forest' THEN 't'
                                                   WHEN 'hills' THEN 'h' WHEN 'mountains' THEN 'm'
                                                   ELSE chr(255 + array_position(u.ids, d.place_id)) END, '' ORDER BY d.x) AS line
                  FROM d CROSS JOIN u
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y))
      INTO v_detail
      FROM ln;
  END IF;

  SELECT jsonb_agg(CASE WHEN l.level = 1 THEN jsonb_build_object('label', l.name, 'view', NULL)
                        ELSE jsonb_build_object(
                          'label', l.name || ' ' || public.rpg_square_name(mod(v_x / (u.cell / v_up_cell), u.cols) + 1, mod(v_y / (u.cell / v_up_cell), u.rows) + 1),
                          'view', l.level::text || '-' || (v_x / (u.cell / v_up_cell))::text || '-' || (v_y / (u.cell / v_up_cell))::text) END
                   ORDER BY l.level)
    INTO v_crumbs
    FROM public.rpg_map_ladder() l LEFT JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
   WHERE l.level <= v_l.level;

  v_scale := public.rpg_map_length_text(v_l.span)
          || CASE WHEN v_l.level = 1 THEN ' around. Each cell is '
                  WHEN v_l.level = v_last THEN ' across. Each square is '
                  ELSE ' across. Each cell is ' END
          || public.rpg_map_length_text(v_l.cell) || '.';

  SELECT jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'color', c.color, 'icon', c.place_icon,
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_ground_text(c.place_forest, c.place_penalty) END,
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', c.lore,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', f.level::text || '-' || (c.place_x / f.span)::text || '-' || (c.place_y / f.span)::text,
           'listed', c.place_level = v_l.level + 1
                     AND public.rpg_map_touches(v_gx0::double precision, v_gy0::double precision, v_gx1::double precision, v_gy1::double precision,
                                                c.place_x, c.place_y, c.place_w, c.place_h, v_world),
           'spot', CASE WHEN s.cx - v_gx0 >= 0 AND s.cx - v_gx0 < v_gx1 - v_gx0 AND c.place_y - v_gy0 >= 0 AND c.place_y - v_gy0 < v_gy1 - v_gy0
                        THEN jsonb_build_array(((s.cx - v_gx0) * 1000 + v_l.cell / 2) / v_l.cell,
                                               ((c.place_y - v_gy0) * 1000 + v_l.cell / 2) / v_l.cell,
                                               (c.place_w::bigint * 1000 + v_l.cell / 2) / v_l.cell,
                                               (c.place_h::bigint * 1000 + v_l.cell / 2) / v_l.cell) END)
         ORDER BY c.sort_order, c.name)
    INTO v_places
    FROM public.rpg_creatures c
    JOIN public.rpg_map_ladder() f ON f.level = c.place_level
   -- its center, as the copy nearest the middle of this grid (the map wraps east to west)
   CROSS JOIN LATERAL (SELECT c.place_x + v_world::bigint * floor(((v_gx0 + v_gx1) / 2.0::double precision - c.place_x) / v_world + 0.5)::bigint AS cx) s
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL;

  SELECT coalesce(jsonb_agg(q.name ORDER BY q.place_level), '[]'::jsonb)
    INTO v_within
    FROM (SELECT DISTINCT ON (c.place_level) c.place_level, c.name
            FROM public.rpg_creatures c
           WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
             AND c.place_penalty IS NULL AND c.place_level <= v_l.level
             AND public.rpg_map_covers((v_gx0 + v_gx1) / 2.0::double precision, (v_gy0 + v_gy1) / 2.0::double precision,
                                       c.place_x, c.place_y, c.place_w, c.place_h, v_world)
           ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1) q;

  SELECT jsonb_strip_nulls(jsonb_build_object(
           'sea', jsonb_build_object('name', 'Sea'),
           'land', jsonb_build_object('name', 'Open land'),
           'forest', jsonb_build_object('name', 'Forest', 'penalty', CASE WHEN g.forest > 0 THEN public.rpg_map_ground_text(false, g.forest) END),
           'hills', jsonb_build_object('name', 'Hills', 'penalty', CASE WHEN g.hills > 0 THEN public.rpg_map_ground_text(false, g.hills) END),
           'mountains', jsonb_build_object('name', 'Mountains', 'penalty', CASE WHEN g.mountains > 0 THEN public.rpg_map_ground_text(false, g.mountains) END)))
    INTO v_grounds
    FROM (SELECT (SELECT r.penalty FROM public.rpg_map_ground('forest') r) AS forest,
                 (SELECT r.penalty FROM public.rpg_map_ground('hills') r) AS hills,
                 (SELECT r.penalty FROM public.rpg_map_ground('mountains') r) AS mountains) g;

  SELECT jsonb_agg(jsonb_build_object('name', l.name, 'line',
           public.rpg_map_length_text(l.span)
           || CASE WHEN l.level = 1 THEN ' around, cells of '
                   WHEN l.level = v_last THEN ' across, squares of '
                   ELSE ' across, cells of ' END
           || public.rpg_map_length_text(l.cell)) ORDER BY l.level)
    INTO v_ladder
    FROM public.rpg_map_ladder() l;

  SELECT jsonb_build_object(
           'id', s.id, 'name', s.name, 'status', s.status, 'time', public.rpg_map_time_text(s.clock),
           'current', s.current_participant_id,
           'log', coalesce((SELECT jsonb_agg(e.text ORDER BY e.created_at DESC)
                              FROM (SELECT e.text, e.created_at FROM public.rpg_events e
                                     WHERE e.session_id = s.id ORDER BY e.created_at DESC LIMIT 6) e), '[]'::jsonb),
           'pieces', coalesce((
             SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                      'id', p.id, 'name', p.name, 'color', coalesce(cr.color, ch.color), 'placed', p.pos_x IS NOT NULL,
                      'creature', p.creature_id IS NOT NULL,
                      'out', CASE WHEN p.creature_id IS NOT NULL AND public.rpg_participant_out(p.id) THEN 'out of the fight' END,
                      'fight', public.rpg_map_in_fight(p.id),
                      'spot', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN jsonb_build_array(((q.sx - v_gx0) * 1000 + 500) / v_l.cell, ((q.sy - v_gy0) * 1000 + 500) / v_l.cell) END,
                      'cell', CASE WHEN q.sx >= v_gx0 AND q.sx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN public.rpg_square_name(((q.sx - v_gx0) / v_l.cell + 1)::integer, ((q.sy - v_gy0) / v_l.cell + 1)::integer) END,
                      'find', CASE WHEN p.pos_x IS NOT NULL AND v_l.level > 1 THEN v_l.level::text || '-' || (q.sx / v_l.span)::text || '-' || (q.sy / v_l.span)::text END,
                      'next', CASE WHEN s.status = 'active' AND p.id IS DISTINCT FROM s.current_participant_id AND p.next_tick IS NOT NULL
                                   THEN public.rpg_map_duration_text(greatest(p.next_tick - s.clock, 0)) END,
                      'day_left', public.rpg_map_duration_text(greatest(d.day - p.day_walk_ticks, 0)),
                      'walk_to', CASE WHEN p.walk_to_x IS NOT NULL THEN jsonb_build_array(p.walk_to_x, p.walk_to_y) END,
                      'to_go', CASE WHEN p.walk_to_x IS NOT NULL AND p.pos_x IS NOT NULL
                                    THEN public.rpg_map_length_text((SELECT w.steps FROM public.rpg_map_line(q.sx::integer, q.sy::integer, p.walk_to_x - 1, p.walk_to_y - 1) w)) END))
                    ORDER BY p.next_tick NULLS LAST, p.turn_order, p.created_at)
               FROM public.rpg_session_participants p
               LEFT JOIN public.rpg_characters ch ON ch.id = p.character_id
               LEFT JOIN public.rpg_creatures cr ON cr.id = p.creature_id
              CROSS JOIN LATERAL (SELECT p.pos_x::bigint - 1 AS sx, p.pos_y::bigint - 1 AS sy) q
              CROSS JOIN (SELECT public.rpg_setting('walk_day_hours')::integer * public.rpg_setting('ticks_per_hour')::integer AS day) d
              WHERE p.session_id = s.id), '[]'::jsonb),
           'can_join', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name)
                                   FROM public.rpg_characters c
                                  WHERE c.is_active AND NOT c.is_npc AND c.session_id IS NULL
                                    AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = s.id AND o.character_id = c.id)), '[]'::jsonb))
    INTO v_journey
    FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended'
   ORDER BY s.created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', v_l.name, 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_l.cols, 'rows', v_l.rows, 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

CREATE OR REPLACE FUNCTION public.rpg_map_walk(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece walks toward a world square (p_x, p_y counted from 1, as pieces stand; the map works from 0 inside) on
-- its turn, the whole way in one go: the same movement rule as a fight, at every level (Peter 2026-10-01). Every
-- square entered costs 1 plus its movement penalty (rpg_map_ground), move_ticks (5) a point at Speed 10, faster or
-- slower by Speed (rpg_ticks_at: base x 20 / (10 + Speed)). A tick is 1/6 of a second (Peter 2026-10-03, 1B), so open
-- land goes at about 3 miles an hour at Speed 10: 20 miles in 6 h 40 min.
-- The walk runs straight (rpg_map_line, ground from rpg_map_route, looked at closer where the sea starts) and stops:
--   at the shore: nobody walks into the sea (2A); the piece stands on the last dry square before it;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on;
--   when a creature is met: every full hour walked inside a haunt (rpg_map_haunters; haunt_ticks carries the part
--   hour on) the site rolls a d100, and at encounter_chance (15) or less a creature of that haunt is met where the
--   hour ran out (Peter 2026-10-03, 1A). It joins the journey encounter_squares (10) away (rpg_map_set_down) and the
--   fight is on, on that ground. A piece in a fight (rpg_map_in_fight) moves on the fight board, not across the map;
--   creatures always do.
-- The end square is checked on the battle grid itself (dry, nobody on it), stepping back along the walk if it must.
-- The time walked plus any camp is the turn (turn_move_ticks), and the turn passes on (rpg_session_next_turn).
-- Pieces stand on world squares counted from 1 (pos_x = square + 1), like squares on a fight board.
DECLARE
  v_sid uuid; v_p record; v_r record; v_world integer; v_down integer;
  v_tph integer; v_day integer; v_camp integer; v_mt integer; v_even numeric; v_speed numeric; v_ign boolean;
  v_left integer; v_basemax bigint; v_steps integer; v_kmax integer; v_reach integer := 0;
  v_pen integer; v_b integer; v_n integer; v_base bigint := 0; v_why text;
  v_rf integer[] := '{}'; v_rt integer[] := '{}'; v_rb integer[] := '{}';
  v_k integer := 0; v_lo integer; v_hi integer; i integer;
  v_from integer; v_cut integer; v_pass integer; v_lvl integer; v_sea_from integer; v_sea_to integer;
  v_sx integer; v_sy integer; v_tx integer; v_ty integer;
  v_walk integer := 0; v_camped boolean; v_arrived boolean; v_text text; v_next jsonb;
  v_gx integer; v_gy integer; v_hx integer; v_hy integer; v_cards uuid[]; v_t0 integer; v_t1 integer; v_h0 integer; v_haunt integer;
  v_hour integer; v_d100 integer; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid; v_chance integer; v_cp uuid; v_gap integer;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  SELECT l.span, l.span / 2 INTO v_world, v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_world OR p_y NOT BETWEEN 1 AND v_down THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  v_sx := v_p.pos_x - 1; v_sy := v_p.pos_y - 1; v_gx := p_x - 1; v_gy := p_y - 1;
  v_haunt := v_p.haunt_ticks; v_chance := public.rpg_setting('encounter_chance')::integer;
  v_tph := public.rpg_setting('ticks_per_hour')::integer;
  v_day := public.rpg_setting('walk_day_hours')::integer * v_tph;
  v_camp := public.rpg_setting('camp_hours')::integer * v_tph;
  v_mt := public.rpg_setting('move_ticks')::integer;
  v_even := public.rpg_setting('speed_even');
  v_speed := public.rpg_participant_speed(p_participant_id);
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  SELECT l.steps INTO v_steps FROM public.rpg_map_line(v_sx, v_sy, v_gx, v_gy) l;
  IF v_steps = 0 THEN RAISE EXCEPTION '% is already there', v_p.name; END IF;

  -- the most base time what is left of the walking day holds, and so the most steps it could hold on open land
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_basemax := greatest(ceil((v_left + 0.5) * (v_even + v_speed) / (2 * v_even))::bigint - 1, 0);
  WHILE v_basemax > 0 AND public.rpg_ticks_at(v_speed, v_basemax) > v_left LOOP v_basemax := v_basemax - 1; END LOOP;
  v_kmax := least(v_steps::bigint, v_basemax / v_mt)::integer;

  -- read at the usual grid first; where that grid sees sea, look again closer (a finer grid over just that stretch)
  -- until the battle grid says where the shore is; a stretch that is dry after all is walked and the walk goes on
  v_from := 1; v_cut := v_kmax;
  FOR v_pass IN 1 .. 40 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route(v_sx, v_sy, v_gx, v_gy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      SELECT g.penalty INTO v_pen FROM public.rpg_map_ground(v_r.kind, v_r.place_id) g;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (1 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer);
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A)
      IF v_n > 0 THEN
        SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_r.k_from) s;
        v_cards := public.rpg_map_haunters(v_hx, v_hy);
        IF v_cards IS NOT NULL THEN
          v_t0 := public.rpg_ticks_at(v_speed, v_base);
          v_t1 := public.rpg_ticks_at(v_speed, v_base + v_n::bigint * v_b);
          v_h0 := v_haunt;
          v_haunt := v_haunt + (v_t1 - v_t0);
          FOR v_hour IN (v_h0 / v_tph) + 1 .. (v_haunt / v_tph) LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_rolls := v_rolls || v_d100;
            IF v_d100 <= v_chance THEN
              -- met where that hour ran out: the first step whose time reaches it
              v_need := v_hour::bigint * v_tph - v_h0;
              v_n := least(greatest(ceil(v_need * (v_even + v_speed) / (2 * v_even) / v_b)::integer, 1), v_n);
              v_haunt := v_h0 + public.rpg_ticks_at(v_speed, v_base + v_n::bigint * v_b) - v_t0;
              v_meet := v_cards[1 + floor(random() * cardinality(v_cards))::integer];
              v_why := 'meet';
              EXIT;
            END IF;
          END LOOP;
        END IF;
      END IF;
      v_rf := v_rf || v_r.k_from; v_rt := v_rt || (v_r.k_from + v_n - 1); v_rb := v_rb || v_b;
      v_base := v_base + v_n::bigint * v_b;
      v_reach := v_r.k_from + v_n - 1;
      EXIT WHEN v_why = 'meet';
      IF v_n < v_r.k_to - v_r.k_from + 1 THEN v_why := 'day'; EXIT; END IF;
    END LOOP;
    IF v_why = 'shore' AND v_lvl < 7 THEN
      v_from := v_sea_from; v_cut := v_sea_to;
    ELSIF v_why IS NULL AND v_cut < v_kmax THEN
      v_from := v_cut + 1; v_cut := v_kmax;
    ELSE
      EXIT;
    END IF;
  END LOOP;
  IF v_why IS NULL AND v_reach < v_steps THEN v_why := 'day'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, g.k) s),
         ux AS MATERIALIZED (
           -- a block that crosses the east-west edge of the world is kept in one piece
           SELECT sq.k, sq.x, sq.y,
                  sq.x + CASE WHEN max(sq.x) OVER () - min(sq.x) OVER () > 12 AND sq.x < v_world / 2 THEN v_world ELSE 0 END AS ux
             FROM sq),
         bb AS (SELECT min(ux.ux) AS x0, max(ux.ux) AS x1, min(ux.y) AS y0, max(ux.y) AS y1 FROM ux)
    SELECT max(ux.k) INTO v_k
      FROM ux CROSS JOIN bb
      JOIN LATERAL public.rpg_map_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) c ON c.x = ux.ux AND c.y = ux.y
     WHERE c.kind <> 'sea'
       AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                        WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = ux.x + 1 AND o.pos_y = ux.y + 1
                          AND public.rpg_participant_blocks(o.id));
    v_k := coalesce(v_k, 0);
    v_hi := v_lo - 1;
  END LOOP;

  v_base := 0;
  FOR i IN 1 .. coalesce(array_length(v_rf, 1), 0) LOOP
    v_base := v_base + greatest(least(v_rt[i], v_k) - v_rf[i] + 1, 0)::bigint * v_rb[i];
  END LOOP;
  v_walk := public.rpg_ticks_at(v_speed, v_base);
  v_arrived := v_k = v_steps;
  v_camped := coalesce(v_why, '') = 'day' OR v_p.day_walk_ticks + v_walk >= v_day;
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea is in the way' ELSE 'someone is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_line_at(v_sx, v_sy, v_gx, v_gy, v_k) s; END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why = 'meet') THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why = 'meet') THEN p_y END,
         haunt_ticks = v_haunt
   WHERE id = p_participant_id;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk) || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'shore' THEN ' The sea stops the walk.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text(v_steps - v_k) || ' to go.' ELSE '' END;
  IF v_why = 'meet' THEN
    v_cp := public.rpg_session_add(v_sid, NULL, v_meet);
    PERFORM public.rpg_map_set_down(v_cp, v_tx + 1, v_ty + 1, public.rpg_setting('encounter_squares')::integer);
    -- both see each other when the walk stops: each first acts one beat after that moment, as when a fight starts
    UPDATE public.rpg_session_participants
       SET next_tick = (SELECT s.clock FROM public.rpg_sessions s WHERE s.id = v_sid) + v_walk + public.rpg_action_ticks(v_cp, 1)
     WHERE id = v_cp;
    UPDATE public.rpg_sessions SET turn_move_ticks = v_walk + public.rpg_action_ticks(p_participant_id, 1) WHERE id = v_sid;
    SELECT public.rpg_square_gap(v_tx + 1, v_ty + 1, c.pos_x, c.pos_y) INTO v_gap FROM public.rpg_session_participants c WHERE c.id = v_cp;
    v_text := v_text || ' An hour in a haunt: the site rolls ' || v_rolls[cardinality(v_rolls)] || ', ' || v_chance || ' or less meets a creature. '
           || (SELECT c.name FROM public.rpg_session_participants c WHERE c.id = v_cp)
           || CASE WHEN v_gap IS NULL THEN ' is here!' ELSE ' appears ' || public.rpg_map_length_text(v_gap) || ' away!' END;
  ELSIF cardinality(v_rolls) > 0 THEN
    v_text := v_text || ' Hours in a haunt: the site rolls ' || array_to_string(v_rolls, ', ') || ' (' || v_chance || ' or less meets a creature).';
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'stopped', v_why, 'camped', v_camped, 'next', v_next);
END;
$function$;

-- 2A: the hand-painted board retires. Nothing in the database calls these two (checked 2026-10-03); the page stops
-- calling them in the same release.
DROP FUNCTION IF EXISTS public.rpg_place_start(uuid);
DROP FUNCTION IF EXISTS public.rpg_set_board(uuid, integer, integer);
DO $guard$
DECLARE v_who text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_who FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prosrc ~ '\m(grid_w|grid_h|rpg_place_start|rpg_set_board)\M';
  IF v_who IS NOT NULL THEN RAISE EXCEPTION 'still reading the old board: %', v_who; END IF;
  SELECT string_agg(p.proname, ', ') INTO v_who FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prosrc ~ 'rpg_grid_costs\(\s*[a-z_]+\s*\)';
  IF v_who IS NOT NULL THEN RAISE EXCEPTION 'still calling rpg_grid_costs without a budget: %', v_who; END IF;
END
$guard$;
ALTER TABLE public.rpg_sessions DROP CONSTRAINT IF EXISTS rpg_sessions_grid_size;
ALTER TABLE public.rpg_sessions DROP COLUMN IF EXISTS grid_w;
ALTER TABLE public.rpg_sessions DROP COLUMN IF EXISTS grid_h;
GRANT EXECUTE ON FUNCTION public.rpg_place(uuid, integer, integer) TO authenticated, service_role;

-- The rule cards (the admin manual page follows by its trigger):
UPDATE public.rpg_rules SET body = replace(replace(replace(replace(body, 'A fight is played on a board of squares, 12 across and 12 down unless the game master picks another size (4 to 20 a side). Columns are letters and rows are numbers: C5 is the third column, fifth row.', 'A fight is played on the world map, on the ground where the fighters stand. The squares are the map''s own, 3 feet 8 inches across, and the board shows the ground round the one whose turn it is. Columns are letters and rows are numbers within each battle grid of 12 by 12: C5 is the third column, fifth row.'), 'Every square has a movement penalty from 0 to 9.', 'Every square has a movement penalty from 0 to 9, from the map: open land 0, forest 1, hills 1, mountains 2. Nobody steps into the sea.'), 'Slings, hurling and tossing reach 6. Crossbows and longbows reach 12.', 'Hurling and tossing reach 8 (30 feet). Slings reach 82 (100 yards). Crossbows and longbows reach 164 (200 yards).'), 'Ground can be forest, and it can burn. The game master paints forest when setting up the board.', 'Ground can be forest, and it can burn. Forest is wherever the map has forest.'), updated_at = now() WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('A fight is played on a board of squares, 12 across and 12 down unless the game master picks another size (4 to 20 a side). Columns are letters and rows are numbers: C5 is the third column, fifth row.' in body) > 0 AND position('Every square has a movement penalty from 0 to 9.' in body) > 0 AND position('Slings, hurling and tossing reach 6. Crossbows and longbows reach 12.' in body) > 0 AND position('Ground can be forest, and it can burn. The game master paints forest when setting up the board.' in body) > 0;
UPDATE public.rpg_rules SET body = replace(body, 'a longbow reaches 12, but at 5 squares it has no target', 'a longbow reaches 164, but at 5 squares it has no target'), updated_at = now() WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'exposed' AND position('a longbow reaches 12, but at 5 squares it has no target' in body) > 0;
UPDATE public.rpg_rules SET body = replace(body, '*At Speed 10, 8 hours of open land is 24 miles.*', '*At Speed 10, 8 hours of open land is 24 miles.*

Creatures live in their haunts. For every full hour a piece walks inside a haunt, the site rolls a d100: on 15 or less a creature of that haunt appears 10 squares (37 feet) away, the walk stops and the fight is on, on that ground.
*Over 8 hours in a haunt that is a fight on about 3 days in 4: the chance of no creature all day is 0.85 multiplied by itself 8 times, 0.27.*

While a creature still in the fight stands within 164 squares (600 feet, a longbow shot), a piece moves on the fight board, a turn at a time, instead of walking the map.'), updated_at = now() WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('*At Speed 10, 8 hours of open land is 24 miles.*' in body) > 0;

