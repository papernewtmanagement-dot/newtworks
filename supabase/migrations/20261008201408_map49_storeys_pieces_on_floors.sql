-- Roleplaying world map, storeys part 2 (Peter 2026-10-08: stairs on the ground floor lead up to the next floor and so on).
-- A piece now stands on a floor (rpg_session_participants.floor, 0 the ground floor). rpg_stair_ways says where a piece on
-- a stair can go and how long it takes (up 26, down 22 base ticks: Fruin 1971, 0.5 and 0.6 m a second over the 2.2 m run);
-- rpg_act_stair takes it there (in a fight on the turn's moving, on a journey in no time). Up a house the fight board is
-- that floor's plan (rpg_fight_layer gains floor; rpg_fight_squares: boards and stair walked, walls and open air no way in),
-- pieces on other floors are not in the way (rpg_grid_costs) and nothing reaches between floors (rpg_in_reach, rpg_act).
-- rpg_place puts a piece in a fight onto the floor the board shows there; a walk or a cave starts from the ground floor.
-- rpg_session_state and rpg_map_view_block give each piece its floor and the one whose turn it is its stair.

ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS floor integer NOT NULL DEFAULT 0;

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'map_stair_up_ticks', 26, 'Storeys: base ticks to go up a house''s stair at Speed 10 (2.2 m at about 0.5 m a second, Fruin 1971)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_stair_down_ticks', 22, 'Storeys: base ticks to go down a house''s stair at Speed 10 (2.2 m at about 0.6 m a second, Fruin 1971)')
ON CONFLICT (agency_id, key) DO NOTHING;

DROP FUNCTION IF EXISTS public.rpg_fight_layer(uuid, integer, integer);
CREATE OR REPLACE FUNCTION public.rpg_fight_layer(p_session_id uuid, p_x integer, p_y integer)
 RETURNS TABLE(under_at text, under_to text, under_done double precision, floor integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a fight's board at a square (world squares from 1, as pieces stand) is under the ground, and where (step
-- 12d3), the one home of that: as the piece of the journey nearest that square stands (rpg_square_gap; a creature
-- first, then the turn order, on a tie). under_at, under_to, under_done are its place under the ground (nothing on the
-- surface). A fight happens where its fighters are: a creature met under the ground stands where the one who met it is.
-- floor (storeys step) = the floor of a house that piece stands on (0 the ground floor).
SELECT p.under_at, p.under_to, p.under_done, p.floor
  FROM public.rpg_session_participants p
 WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL
 ORDER BY public.rpg_square_gap(p.pos_x, p.pos_y, p_x, p_y), (p.creature_id IS NOT NULL) DESC, p.turn_order, p.created_at
 LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.rpg_fight_layer(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_fight_layer(uuid, integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean, lie text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ground of a block of squares in a fight, the one way: the world map under them (rpg_map_costs on the battle
-- grid: the percent of time each square adds to cross it, and forest; deep water is swum, at its own percent (step
-- 7b); the sea and water too rough to swim no entry, the sea flag), with what the
-- fight itself has done to a square on top (rpg_sessions.terrain read through rpg_square_info: a penalty there, from
-- Briar Shift, takes the place of the ground's; forest there adds to it; fire burns for burn_rounds). Squares are world
-- squares counted from 1, as pieces stand. A fight off the map has no board: only what the fight did.
-- Under the ground (step 12d3; rpg_fight_layer: where the piece nearest the middle of the block stands) the ground is
-- the battle grid under the ground instead (rpg_map_under_squares of the passages round that piece,
-- rpg_map_under_layer): the floor's percent, and solid rock or a column of stone no way in (the sea flag: no entry).
-- lie (step 14f-battle): what lies on the square (rpg_map_costs, rpg_map_lie): a boulder no way in (the sea flag), a log
-- (cover: rpg_cover).
-- Up a house (storeys step; rpg_fight_layer: the floor of the piece nearest the middle of the block) the squares are
-- that floor's plan (rpg_map_building_squares): its boards and its stair walked at +0%, its walls and the open air
-- outside them no way in (the sea flag).
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     la AS MATERIALIZED (SELECT l.under_at, l.under_to, coalesce(l.floor, 0) AS floor FROM s CROSS JOIN LATERAL public.rpg_fight_layer(p_session_id, p_x0 + p_w / 2, p_y0 + p_h / 2) l
                          WHERE s.on_map),
     ly AS MATERIALIZED (SELECT la.under_at, la.under_to FROM la WHERE la.under_at IS NOT NULL),
     -- (storeys step) up a house: the floor's plan
     fl AS MATERIALIZED (SELECT b.x + 1 AS x, b.y + 1 AS y, b.part
                           FROM la CROSS JOIN LATERAL public.rpg_map_building_squares(7, p_x0 - 1, p_y0 - 1, p_w, p_h, true) b
                          WHERE la.under_at IS NULL AND la.floor > 0 AND b.floor = la.floor),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.penalty, c.forest, c.lie
                          FROM s CROSS JOIN LATERAL public.rpg_map_costs(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c
                         WHERE s.on_map AND NOT EXISTS (SELECT 1 FROM ly) AND NOT EXISTS (SELECT 1 FROM la WHERE la.under_at IS NULL AND la.floor > 0)),
     u AS MATERIALIZED (SELECT q.x + 1 AS x, q.y + 1 AS y, q.pct
                          FROM ly CROSS JOIN LATERAL public.rpg_map_under_squares(p_x0 - 1, p_y0 - 1, p_w, p_h, public.rpg_map_under_layer(ly.under_at, ly.under_to)) q),
     z AS (SELECT EXISTS (SELECT 1 FROM ly) AS under, coalesce((SELECT la.floor FROM la WHERE la.under_at IS NULL), 0) > 0 AS up)
SELECT g.x, g.y,
       CASE WHEN z.up THEN CASE WHEN fq.part IN ('floor', 'stair') THEN coalesce(i.penalty, 0) END
            WHEN z.under THEN CASE WHEN u.pct IS NULL THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE u.pct END
            WHEN m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL) OR m.lie = 'boulder' THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(m.penalty, i.penalty) END,
       CASE WHEN z.up THEN false ELSE coalesce(m.forest, false) OR i.forest END, i.burning,
       CASE WHEN z.up THEN fq.part IS NULL OR fq.part NOT IN ('floor', 'stair') WHEN z.under THEN u.pct IS NULL ELSE coalesce(m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL) OR m.lie = 'boulder', false) END,
       CASE WHEN NOT z.under AND NOT z.up THEN m.lie END
  FROM s CROSS JOIN z CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
  LEFT JOIN u ON u.x = g.x AND u.y = g.y
  LEFT JOIN fl fq ON fq.x = g.x AND fq.y = g.y
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_grid_costs(p_participant_id uuid, p_budget integer)
 RETURNS TABLE(x integer, y integer, cost integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What it costs this fighter to reach each square within p_budget of path cost from where they stand, in hundredths of
-- a plain square. Stepping into a square costs 100 plus the percent of time it adds (just 100 for a creature whose
-- card says the ground never slows it: rpg_participant_ignores_penalty), plus burn_cost (300) while the square burns,
-- for everyone; a diagonal step costs the same as a straight one; nobody steps into the sea or into a square someone
-- takes up on the same floor (rpg_participant_blocks; storeys step: someone on another floor of a house is not in the way). The first step of a turn may always be taken, whatever it costs, by the one whose
-- turn it is before they have moved (a thicket or a mountain square can take longer than a whole turn of moving; that
-- turn then takes that long). The ground is the world map under the fight (rpg_fight_squares), read once for the block
-- round the fighter. Squares nobody can get to are left out. From C3, briars at +260% on D3 cost 360 to enter, and a
-- plain E3 past them 460; burning briars cost 660, and the Bramblemaw pays 400 there.
DECLARE
  v_p record; v_s record; v_b integer := greatest(coalesce(p_budget, 0), 0); x0 integer; y0 integer; w integer; h integer; n integer;
  d integer[]; pen integer[]; fire integer[]; blk boolean[]; v_ign boolean; v_changed boolean; v_big constant integer := 1000000;
  i integer; j integer; cx integer; cy integer; dx integer; dy integer; nx integer; ny integer; c integer; v_q record; v_o record;
  v_burn integer := public.rpg_setting('burn_cost')::integer; v_down integer; v_first boolean; v_r integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL THEN RETURN; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT v_s.on_map THEN RETURN; END IF;
  -- the first step of a turn may always be taken, whatever it costs, by the one whose turn it is before they have moved
  v_first := v_s.current_participant_id IS NOT DISTINCT FROM p_participant_id AND coalesce(v_s.turn_move_ticks, 0) = 0;
  IF v_b = 0 AND NOT v_first THEN RETURN; END IF;
  -- squares, not cost: the block round the fighter reaches as far as the budget goes on plain ground (100 a square)
  v_r := greatest(v_b / 100, 1);
  SELECT l.span / 2 INTO v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  x0 := greatest(v_p.pos_x - v_r, 1); w := least(v_p.pos_x + v_r, v_down * 2) - x0 + 1;
  y0 := greatest(v_p.pos_y - v_r, 1); h := least(v_p.pos_y + v_r, v_down) - y0 + 1;
  n := w * h;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  d := array_fill(v_big, ARRAY[n]); pen := array_fill(0, ARRAY[n]); fire := array_fill(0, ARRAY[n]); blk := array_fill(false, ARRAY[n]);
  FOR v_q IN SELECT * FROM public.rpg_fight_squares(v_s.id, x0, y0, w, h) LOOP
    i := (v_q.y - y0) * w + (v_q.x - x0) + 1;
    IF v_q.sea THEN blk[i] := true; ELSE pen[i] := v_q.penalty; END IF;
    fire[i] := CASE WHEN v_q.burning THEN v_burn ELSE 0 END;
  END LOOP;
  FOR v_o IN SELECT o.pos_x, o.pos_y FROM public.rpg_session_participants o
              WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.floor = v_p.floor AND public.rpg_participant_blocks(o.id) LOOP
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
          c := d[i] + 100 + CASE WHEN v_ign THEN 0 ELSE pen[j] END + fire[j];
          IF c < d[j] AND (c <= v_b OR (v_first AND d[i] = 0)) THEN d[j] := c; v_changed := true; END IF;
        END LOOP;
      END LOOP;
    END LOOP;
    EXIT WHEN NOT v_changed;
  END LOOP;
  RETURN QUERY SELECT x0 + (k - 1) % w, y0 + (k - 1) / w, d[k] FROM generate_subscripts(d, 1) AS k WHERE d[k] < v_big;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_in_reach(p_actor uuid, p_target uuid, p_reach integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a roll reaches its target: the distance (rpg_distance) is at most the reach the target allows (rpg_reach_to:
-- Claw 1 cannot touch Karen 3 squares away; Briar Roar 6 can; a Bramblemaw on forest ground is unseen beyond 2, so a
-- longbow at 5 squares has no target). Someone not on the board is always in reach. (Storeys step) Nothing reaches
-- between two floors of a house: a floor or a ceiling is between them.
SELECT coalesce((SELECT a.floor = t.floor FROM public.rpg_session_participants a, public.rpg_session_participants t
                  WHERE a.id = p_actor AND t.id = p_target AND a.pos_x IS NOT NULL AND t.pos_x IS NOT NULL), true)
   AND coalesce(public.rpg_distance(p_actor, p_target) <= public.rpg_reach_to(p_target, p_reach), true);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_stair_ways(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a piece can go by the stair it stands on (storeys step, Peter 2026-10-08: stairs on the ground floor lead up to
-- the next floor and so on), the one home of it: a house's stair runs through every floor of it (rpg_map_building_squares,
-- part stair), so a piece on a stair square goes up when the stair is there on the floor above, down when it is there
-- on the floor below. {up, down, up_ticks, down_ticks}: the ticks it takes this piece (map_stair_up_ticks 26 and
-- map_stair_down_ticks 22 at Speed 10, rpg_ticks_at); nothing when it is on no stair, under the ground or off the map.
SELECT CASE WHEN w.up OR w.down THEN jsonb_strip_nulls(jsonb_build_object(
         'up', CASE WHEN w.up THEN true END, 'down', CASE WHEN w.down THEN true END,
         'up_ticks', CASE WHEN w.up THEN public.rpg_ticks_at(public.rpg_participant_speed(p.id), public.rpg_setting('map_stair_up_ticks')) END,
         'down_ticks', CASE WHEN w.down THEN public.rpg_ticks_at(public.rpg_participant_speed(p.id), public.rpg_setting('map_stair_down_ticks')) END)) END
  FROM public.rpg_session_participants p
 CROSS JOIN LATERAL (SELECT coalesce(bool_or(b.floor = p.floor), false) AND coalesce(bool_or(b.floor = p.floor + 1), false) AS up,
                            coalesce(bool_or(b.floor = p.floor), false) AND coalesce(bool_or(b.floor = p.floor - 1), false) AS down
                       FROM public.rpg_map_building_squares(7, p.pos_x - 1, p.pos_y - 1, 1, 1, true) b
                      WHERE b.part = 'stair') w
 WHERE p.id = p_participant_id AND p.pos_x IS NOT NULL AND p.under_at IS NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act_stair(p_participant_id uuid, p_dir integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece goes up (p_dir 1) or down (-1) the stair it stands on (storeys step; rpg_stair_ways), onto the same square
-- one floor up or down, where nobody stands. In a fight it is a move on the turn of the one going: up takes
-- map_stair_up_ticks (26) at Speed 10 and down map_stair_down_ticks (22), by their Speed (rpg_ticks_at), on the turn's
-- moving time: walkers on a stair cover about 0.5 m a second up and 0.6 down along the floor (Fruin 1971, Pedestrian
-- Planning and Design), and a stair runs 2.2 m (two squares), so 4.4 and 3.7 seconds. That is more than a turn's 20
-- ticks of moving, so like a thicket it can be the first move of a turn, which then takes longer. On a journey it takes
-- no time and keeps the turn, as going into a cave does. Players move their own characters; the game master moves
-- creatures.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_p record; v_s record; v_w jsonb; v_fight boolean; v_ticks integer; v_to integer; v_who text; v_text text;
  v_words text[] := ARRAY['the ground floor', 'the 2nd floor', 'the 3rd floor', 'the 4th floor', 'the 5th floor'];
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_dir IS NULL OR p_dir NOT IN (1, -1) THEN RAISE EXCEPTION 'up (1) or down (-1)'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not on this journey or in this fight'; END IF;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  v_fight := public.rpg_map_in_fight(p_participant_id);
  IF v_fight THEN
    SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
    IF v_s.status <> 'active' THEN RAISE EXCEPTION 'the fight is not on'; END IF;
    IF v_p.creature_id IS NOT NULL AND NOT v_gm THEN RAISE EXCEPTION 'the game master moves %', v_p.name; END IF;
    IF v_s.current_participant_id IS DISTINCT FROM p_participant_id THEN RAISE EXCEPTION 'it is not %''s turn', v_p.name; END IF;
    IF NOT public.rpg_participant_can_act(p_participant_id) THEN RAISE EXCEPTION '% cannot move right now', v_p.name; END IF;
  ELSE
    PERFORM public.rpg_map_turn(p_participant_id);
    SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  END IF;
  v_w := public.rpg_stair_ways(p_participant_id);
  IF NOT coalesce((v_w ->> CASE WHEN p_dir = 1 THEN 'up' ELSE 'down' END)::boolean, false) THEN
    RAISE EXCEPTION '% is not on a stair that goes %', v_p.name, CASE WHEN p_dir = 1 THEN 'up' ELSE 'down' END;
  END IF;
  v_to := v_p.floor + p_dir;
  SELECT o.name INTO v_who FROM public.rpg_session_participants o
   WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = v_p.pos_x AND o.pos_y = v_p.pos_y AND o.floor = v_to
     AND public.rpg_participant_blocks(o.id) LIMIT 1;
  IF v_who IS NOT NULL THEN RAISE EXCEPTION '% stands at the % of the stair', v_who, CASE WHEN p_dir = 1 THEN 'top' ELSE 'foot' END; END IF;
  IF v_fight THEN
    v_ticks := (v_w ->> CASE WHEN p_dir = 1 THEN 'up_ticks' ELSE 'down_ticks' END)::integer;
    IF coalesce(v_s.turn_move_ticks, 0) > 0 AND v_s.turn_move_ticks + v_ticks > public.rpg_setting('round_ticks') THEN
      RAISE EXCEPTION '% has moved this turn, and the stair takes % ticks: go % it as the first move of a turn', v_p.name, v_ticks, CASE WHEN p_dir = 1 THEN 'up' ELSE 'down' END;
    END IF;
    UPDATE public.rpg_sessions SET turn_move_ticks = turn_move_ticks + v_ticks, updated_at = now() WHERE id = v_s.id;
  ELSE
    UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  END IF;
  UPDATE public.rpg_session_participants SET floor = v_to, walk_to_x = NULL, walk_to_y = NULL WHERE id = p_participant_id;
  v_text := v_p.name || ' goes ' || CASE WHEN p_dir = 1 THEN 'up' ELSE 'down' END || ' the stair to ' || coalesce(v_words[v_to + 1], 'floor ' || (v_to + 1))
            || CASE WHEN v_fight THEN ' (' || v_ticks || ' ticks).' ELSE '.' END;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, CASE WHEN v_fight THEN 'action' ELSE 'move' END, 'info', p_participant_id, v_text);
  RETURN jsonb_build_object('kind', 'move', 'label', 'Stair', 'text', v_text,
                            'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_act(p_actor_id uuid, p_target_ids uuid[] DEFAULT NULL::uuid[], p_stat_key text DEFAULT NULL::text, p_action_id uuid DEFAULT NULL::uuid, p_against text DEFAULT NULL::text, p_difficulty numeric DEFAULT NULL::numeric, p_roll integer DEFAULT NULL::integer, p_effect text DEFAULT NULL::text, p_card uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One move in a fight, by the one whose turn it is. Every roll goes through rpg_roll, from the sheet of the roller.
--   REST / DEFEND (p_stat_key) take the whole turn: Rest gives one more regain; Defend puts "Defending" on you until
--   your next turn so rolls against you face your skill × 3 (rpg_difficulty).
--   Anyone rolls from their own sheet (p_stat_key): a weapon skill at one target is an attack; any stat at targets
--   with p_against rolls against that stat of theirs; with no target it is a check. A creature also uses the actions
--   on its card, each rolling one of its own skills by skill_key (the Bramblemaw's Claw rolls its sheet's Claw 10).
--   A creature is a character made from its card, so its sheet, its Integrity and its energy work like yours.
--   Attacks and actions cost time on the fight clock (rpg_action_ticks; one action a turn) and energy (energy_cost of that energy_type); a move you cannot pay
--   for is refused. Every roll at a target must reach it on the fight grid (rpg_in_reach): Claw 1 square, Briar Roar
--   6, Longbow 12, counted as the larger gap across or up-down; someone not on the board is always in reach. A card
--   action that is not an area action aims at one target. A target hidden by its ground (Forest-Bound Terror on
--   forest: unseen beyond 2 squares) is out of reach past that distance whatever the weapon (rpg_reach_to). Every
--   hostile roll marks the actor as having attacked, and a Judged actor who strikes at an innocent is Condemned
--   (rpg_judgement). A card action may come from a thing the fighter holds (rpg_participant_cards).
--   An attack runs three gates (rule card "Land, Block, Hit"). Land: the skill against the target's evade × 2
--   (rpg_difficulty; evade lowered by rpg_participant_burden). Under the still-target line is a Miss, above it Evaded.
--   Cover (rpg_cover; step 14f-battle): a physical blow is refused at someone behind a boulder, and one that lands on
--   someone behind a fallen log strikes the log (Blocked) when its die is in the lower half of the dice that land.
--   Knowledge (rpg_knows) counts both ways: the actor's Knowing <the target's card> goes into rpg_roll, the target's
--   Knowing <the actor's card> adds to the stat it defends with (evade, block, a contest) before the × 2, and the log
--   names both. p_card is the card a no-target check is about (studying a Bramblemaw).
--   Block: someone holding a shield or weapon blocks with Block + the item's block, × 2; a spiritual attack that
--   lands an effect is blocked by the Shield of Faith. Fail = Blocked; the blocking item takes the blow's damage
--   (rpg_item_damage) and the weapon a fifth of it. Hit: rpg_damage minus what worn armor absorbs (the armor takes
--   that; the weapon a fifth); what is left must clear the target's Integrity. An attack on the heart or the mind (the
--   card's "aim") is absorbed by the armor piece that guards it (rpg_stat_definitions.guards: the Breastplate of
--   Righteousness, the Helmet of Salvation) up to its own value, which wears by that much; only what is left puts
--   the effect on (rpg_armor_state, rpg_armor_wear). A landed effect goes on the target as
--   the card says (Briar Roar → Frightened; a Claw hit → Strength contest → Knocked down). Legendary actions may be
--   used on other turns by the game master or the rules engine (rpg.engine). A check a rule demands (p_effect) comes
--   before an attack. p_roll is a die rolled by hand: a manual critical waits for rpg_act_extra.
DECLARE
  v_gm boolean := public.family_is_parent() OR coalesce(current_setting('rpg.engine', true), '') = 'on';
  v_actor record; v_s record; v_act record; v_use record; v_t record; v_item record; v_actor_card uuid; v_target_card uuid; v_know_def numeric := 0; v_know_txt text := '';
  v_targets uuid[] := coalesce(p_target_ids, '{}'::uuid[]);
  v_kind text; v_key text; v_label text; v_against text; v_against_name text;
  v_damage_ok boolean := false; v_is_attack boolean := false; v_stat_name text; v_spirit_fx boolean := false; v_discipline boolean := false; v_shield jsonb; v_piece jsonb; v_turned boolean := false; v_strength integer;
  v_tid uuid; v_cid uuid; v_rev jsonb; v_ending boolean := false; v_def numeric; v_diff numeric; v_diff_still numeric; v_roll jsonb; v_first jsonb; v_extras integer[]; v_i integer;
  v_dmg integer; v_net integer; v_vit jsonb; v_text text; v_needs integer; v_results jsonb := '[]'::jsonb; v_levelup text;
  v_eff jsonb; v_fx jsonb; v_out jsonb; v_pending boolean; v_tail text; v_who text; v_xtext text;
  v_croll jsonb; v_cdiff numeric;
  v_plan jsonb := '[]'::jsonb; v_step jsonb; v_e jsonb; v_n integer; v_beats integer := 0;
  v_ecost integer := 0; v_etype text := 'physical'; v_energy jsonb; v_defending boolean;
  v_cover text;
  v_blk numeric; v_blocker uuid; v_blocker_name text; v_broll jsonb; v_blocked boolean; v_absorb integer; v_wear jsonb; v_weapon uuid; v_integrity integer; v_bounced boolean; v_reach integer; v_rname text; v_area boolean;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  PERFORM set_config('rpg.move', 'on', true);
  SELECT * INTO v_actor FROM public.rpg_session_participants WHERE id = p_actor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT template_id INTO v_actor_card FROM public.rpg_characters WHERE id = v_actor.character_id;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_actor.session_id FOR UPDATE;
  IF v_s.status = 'setup' THEN RAISE EXCEPTION 'the fight has not started yet'; END IF;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN
    IF NOT (v_gm AND v_actor.creature_id IS NOT NULL AND p_action_id IS NOT NULL
            AND EXISTS (SELECT 1 FROM public.rpg_creature_actions a WHERE a.id = p_action_id AND a.kind = 'legendary')) THEN
      RAISE EXCEPTION 'it is not %''s turn', v_actor.name;
    END IF;
  END IF;
  IF NOT v_gm AND v_actor.creature_id IS NOT NULL THEN RAISE EXCEPTION 'the game master rolls for %', v_actor.name; END IF;
  IF v_actor.character_id IS NULL THEN RAISE EXCEPTION '% has no sheet', v_actor.name; END IF;
  IF NOT v_actor.can_act THEN RAISE EXCEPTION '% cannot act%', v_actor.name, coalesce(': ' || v_actor.status_note, ''); END IF;
  IF (public.rpg_participant_vitality(p_actor_id)->>'left')::integer <= 0 THEN RAISE EXCEPTION '% is down', v_actor.name; END IF;
  SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e WHERE coalesce((e->>'cannot_act')::boolean, false) LIMIT 1;
  IF v_who IS NOT NULL AND p_effect IS DISTINCT FROM v_who THEN RAISE EXCEPTION '% is % and cannot act', v_actor.name, v_who; END IF;
  IF p_actor_id = ANY (v_targets) THEN RAISE EXCEPTION 'choose someone else to aim at'; END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_targets) t(id)
              WHERE NOT EXISTS (SELECT 1 FROM public.rpg_session_participants p WHERE p.id = t.id AND p.session_id = v_s.id)) THEN
    RAISE EXCEPTION 'every target must be in this fight';
  END IF;
  -- Reach on the fight grid: the card action's reach, or the rolled skill's.
  IF p_effect IS NULL AND cardinality(v_targets) > 0 THEN
    IF p_action_id IS NOT NULL THEN
      SELECT reach, name, area INTO v_reach, v_rname, v_area FROM public.rpg_creature_actions WHERE id = p_action_id;
      IF cardinality(v_targets) > 1 AND NOT coalesce(v_area, false) THEN RAISE EXCEPTION '% aims at one target', v_rname; END IF;
    ELSE
      SELECT reach, name INTO v_reach, v_rname FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    END IF;
    FOR v_tid IN SELECT unnest(v_targets) LOOP
      IF NOT public.rpg_in_reach(p_actor_id, v_tid, coalesce(v_reach, 1)) THEN
        -- (storeys step) a floor or a ceiling between them
        IF EXISTS (SELECT 1 FROM public.rpg_session_participants t WHERE t.id = v_tid AND t.pos_x IS NOT NULL AND t.floor IS DISTINCT FROM v_actor.floor) THEN
          RAISE EXCEPTION '% is on another floor: nothing reaches between floors', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid);
        END IF;
        IF public.rpg_reach_to(v_tid, coalesce(v_reach, 1)) < coalesce(v_reach, 1) THEN
          RAISE EXCEPTION '% is unseen in the forest beyond % squares and stands % away', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),
            public.rpg_reach_to(v_tid, coalesce(v_reach, 1)), public.rpg_distance(p_actor_id, v_tid);
        END IF;
        RAISE EXCEPTION '% is % squares away and % reaches %', (SELECT name FROM public.rpg_session_participants WHERE id = v_tid),
          public.rpg_distance(p_actor_id, v_tid), coalesce(v_rname, 'that roll'), coalesce(v_reach, 1);
      END IF;
    END LOOP;
  END IF;
  -- A creature at 0 vitality is out of reach: dead, or waiting under its card's revival rule, when only the roll
  -- that rule names reaches it (Sunk → Healing (Spiritual) against its Fascination with Evil).
  FOR v_tid IN SELECT unnest(v_targets) LOOP
    SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
    CONTINUE WHEN v_t.creature_id IS NULL OR (public.rpg_participant_vitality(v_tid)->>'left')::integer > 0;
    v_rev := NULL;
    SELECT e INTO v_rev FROM jsonb_array_elements(v_t.effects) e WHERE e ? 'ended_by' LIMIT 1;
    IF v_rev IS NULL THEN RAISE EXCEPTION '% is dead', v_t.name; END IF;
    IF p_stat_key IS DISTINCT FROM v_rev->'ended_by'->>'skill_key' OR p_against IS DISTINCT FROM v_rev->'ended_by'->>'against' THEN
      RAISE EXCEPTION '% is %: only % against its % reaches it', v_t.name, v_rev->>'name',
        (SELECT name FROM public.rpg_stat_definitions WHERE key = v_rev->'ended_by'->>'skill_key'),
        (SELECT name FROM public.rpg_stat_definitions WHERE key = v_rev->'ended_by'->>'against');
    END IF;
    v_ending := true;
  END LOOP;
  v_energy := public.rpg_participant_energy(p_actor_id);

  -- Rest and Defend: the whole turn.
  IF p_stat_key IN ('REST', 'DEFEND') THEN
    IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'it is not %''s turn', v_actor.name; END IF;
    IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
    IF p_stat_key = 'REST' THEN
      UPDATE public.rpg_session_participants SET energy_used_physical = greatest(energy_used_physical - (v_energy->'physical'->>'regain')::integer, 0),
             energy_used_spiritual = greatest(energy_used_spiritual - (v_energy->'spiritual'->>'regain')::integer, 0) WHERE id = p_actor_id;
      v_text := v_actor.name || ' rests and regains ' || (v_energy->'physical'->>'regain') || ' physical and ' || (v_energy->'spiritual'->>'regain') || ' spiritual energy.';
    ELSE
      PERFORM public.rpg_participant_apply_effect(p_actor_id, '{"name": "Defending", "cannot_act": false, "clear": "turn_start", "defend": true}'::jsonb, 'Defend', v_s.round);
      v_text := v_actor.name || ' defends: until ' || CASE WHEN v_actor.creature_id IS NULL THEN 'their' ELSE 'its' END || ' next turn, rolls against ' || CASE WHEN v_actor.creature_id IS NULL THEN 'them' ELSE 'it' END || ' face evade × ' || trim_scale(public.rpg_setting('defend_multiplier')) || '.';
    END IF;
    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, public.rpg_setting('rest_beats')), updated_at = now() WHERE id = v_s.id;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_text);
    RETURN jsonb_build_object('kind', lower(p_stat_key), 'label', initcap(lower(p_stat_key)), 'results', jsonb_build_array(jsonb_build_object('outcome', 'info', 'text', v_text)));
  END IF;

  IF p_effect IS NOT NULL THEN
    SELECT e INTO v_eff FROM jsonb_array_elements(v_actor.effects) e WHERE e->>'name' = p_effect AND e->>'clear' = 'check';
    IF v_eff IS NULL THEN RAISE EXCEPTION '% is not % right now', v_actor.name, p_effect; END IF;
    IF (v_eff->>'checked_round')::integer = v_s.round THEN RAISE EXCEPTION '% already tried this turn', v_actor.name; END IF;
    v_kind := 'check'; v_key := v_eff->>'check_stat'; v_targets := '{}';
    SELECT name INTO v_label FROM public.rpg_stat_definitions WHERE key = v_key;
    v_diff := (v_eff->>'check_difficulty')::numeric;
  ELSIF p_action_id IS NULL THEN
    -- Anyone rolling from their own sheet.
    SELECT name, is_attack, beats, energy_cost, energy_type INTO v_stat_name, v_is_attack, v_beats, v_ecost, v_etype FROM public.rpg_stat_definitions WHERE key = p_stat_key;
    IF NOT FOUND THEN RAISE EXCEPTION 'choose a skill'; END IF;
    v_key := p_stat_key; v_label := v_stat_name;
    IF cardinality(v_targets) > 0 AND p_against IS NULL THEN
      IF NOT v_is_attack THEN RAISE EXCEPTION 'choose a weapon skill to attack with'; END IF;
      IF cardinality(v_targets) > 1 THEN RAISE EXCEPTION 'attack one target at a time'; END IF;
      IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
      IF (v_energy->v_etype->>'left')::integer < v_ecost THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      SELECT e->>'name' INTO v_who FROM jsonb_array_elements(v_actor.effects) e
       WHERE e->>'clear' = 'check' AND (e->>'checked_round')::integer IS DISTINCT FROM v_s.round LIMIT 1;
      IF v_who IS NOT NULL THEN RAISE EXCEPTION '% must shake off % first', v_actor.name, v_who; END IF;
      v_kind := 'attack'; v_against := 'EE'; v_damage_ok := true;
      -- the weapon: an unbroken held item whose card is swung with this skill (its object takes a fifth of what it strikes)
      v_weapon := (public.rpg_weapon_bulk(v_actor.character_id, p_stat_key)->>'item_id')::uuid;
    ELSIF cardinality(v_targets) > 0 THEN
      v_kind := 'check'; v_against := p_against;
      IF v_ending THEN
        IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
        IF (v_energy->v_etype->>'left')::integer < coalesce(v_ecost, 0) THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      ELSE
        v_beats := 0; v_ecost := 0;
      END IF;
    ELSE
      v_kind := 'check';
      v_diff := greatest(coalesce(p_difficulty, public.rpg_setting('default_difficulty')), 0);
      -- Prayer and Bible Study in a fight: your own turn's action, paid from spiritual energy (rpg_roll adds the burden to the difficulty)
      SELECT coalesce(d.spirit_discipline, false) INTO v_discipline FROM public.rpg_stat_definitions d WHERE d.key = p_stat_key;
      IF v_discipline THEN
        IF v_s.current_participant_id IS DISTINCT FROM p_actor_id THEN RAISE EXCEPTION 'it is not %''s turn', v_actor.name; END IF;
        IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
        IF (v_energy->v_etype->>'left')::integer < v_ecost THEN RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_etype->>'left', v_etype, v_stat_name, v_ecost; END IF;
      ELSE
        v_beats := 0; v_ecost := 0;
      END IF;
    END IF;
  ELSE
    SELECT * INTO v_act FROM public.rpg_creature_actions WHERE id = p_action_id AND creature_id = ANY (public.rpg_participant_cards(p_actor_id));
    IF NOT FOUND THEN RAISE EXCEPTION 'that action is not on this fighter''s card or on a thing they hold'; END IF;
    IF v_act.kind = 'trait' THEN RAISE EXCEPTION '% is a trait, not an action', v_act.name; END IF;
    IF v_act.kind = 'lair' AND v_actor.lair_round IS NOT DISTINCT FROM v_s.round THEN RAISE EXCEPTION '% has used its lair this round', v_actor.name; END IF;
    IF v_act.kind = 'legendary' AND v_actor.legendary_left < v_act.legendary_cost THEN
      RAISE EXCEPTION '% has % legendary actions left and % costs %', v_actor.name, v_actor.legendary_left, v_act.name, v_act.legendary_cost;
    END IF;
    IF NOT public.rpg_action_ready(p_actor_id, v_act.id) THEN
      RAISE EXCEPTION '% has % % energy left and % costs %', v_actor.name, v_energy->v_act.energy_type->>'left', v_act.energy_type, v_act.name, v_act.energy_cost;
    END IF;
    IF v_act.kind IN ('action', 'bonus_action') AND v_s.current_participant_id = p_actor_id THEN
      IF v_s.turn_action_ticks > 0 THEN RAISE EXCEPTION '% has already acted this turn', v_actor.name; END IF;
      v_beats := v_act.beats;
    END IF;
    v_ecost := v_act.energy_cost; v_etype := v_act.energy_type;
    v_kind := 'action'; v_label := v_act.name;
    IF v_act.skill_key IS NOT NULL THEN
      IF cardinality(v_targets) = 0 THEN RAISE EXCEPTION 'choose who % is aimed at', v_act.name; END IF;
      FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('a', v_act.id, 't', v_tid); END LOOP;
    END IF;
  END IF;
  IF v_kind <> 'action' THEN
    FOREACH v_tid IN ARRAY v_targets LOOP v_plan := v_plan || jsonb_build_object('t', v_tid); END LOOP;
    IF cardinality(v_targets) > 0 THEN
      SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
      IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
    END IF;
  END IF;

  IF v_kind = 'action' AND jsonb_array_length(v_plan) = 0 THEN
    IF v_act.effect->>'on' IN ('step', 'board') THEN RAISE EXCEPTION 'choose a square on the board for %', v_act.name; END IF;
    IF v_act.effect->>'on' = 'self' THEN
      PERFORM public.rpg_participant_apply_effect(p_actor_id, v_act.effect->'apply', v_act.name, v_s.round);
    END IF;
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    VALUES (v_s.agency_id, v_s.id, v_s.round, 'action', 'info', p_actor_id, v_actor.name || ' uses ' || v_act.name || '.'
            || CASE WHEN v_act.effect->>'on' = 'self' THEN ' It is ' || (v_act.effect->'apply'->>'name') || '.' ELSE '' END);
  ELSIF cardinality(v_targets) = 0 THEN
    v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id, p_roll, p_card);
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
    v_tail := coalesce(' ' || nullif(v_first->'discipline'->>'text', ''), '');
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
          UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, 1) WHERE id = v_s.id;
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || ' and cannot attack this turn.';
        ELSE
          v_tail := ' ' || v_actor.name || ' stays ' || p_effect || '.';
        END IF;
      END IF;
    END IF;
    v_xtext := CASE WHEN cardinality(v_extras) > 0 THEN ' Extra roll' || CASE WHEN cardinality(v_extras) > 1 THEN 's ' ELSE ' ' END || array_to_string(v_extras, ' and ') || '.' ELSE '' END;
    v_text := (v_out->>'label') || ': ' || v_actor.name || ' rolls ' || v_label || CASE WHEN coalesce((v_first->'knowledge'->>'value')::numeric, 0) > 0 THEN ' (' || (v_first->'knowledge'->>'name') || ' ' || trim_scale((v_first->'knowledge'->>'value')::numeric) || ')' ELSE '' END || CASE WHEN coalesce((v_first->'place_knowledge'->>'value')::numeric, 0) > 0 THEN ' (' || (v_first->'place_knowledge'->>'name') || ' ' || trim_scale((v_first->'place_knowledge'->>'value')::numeric) || ')' ELSE '' END || ' against ' || trim_scale(v_diff) || CASE WHEN v_discipline AND (v_first->>'difficulty')::numeric > v_diff THEN ' + ' || trim_scale((v_first->>'difficulty')::numeric - v_diff) || ' burden' ELSE '' END
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
        IF v_use.skill_key IS NULL THEN RAISE EXCEPTION '% has no roll on the card', v_use.name; END IF;
        v_key := v_use.skill_key; v_against := v_use.against; v_damage_ok := coalesce(v_use.deals_damage, false); v_fx := v_use.effect;
        v_spirit_fx := v_fx IS NOT NULL AND v_use.energy_type = 'spiritual';
        SELECT name INTO v_against_name FROM public.rpg_stat_definitions WHERE key = v_against;
        IF NOT FOUND THEN RAISE EXCEPTION 'unknown stat %', v_against; END IF;
      END IF;
      SELECT * INTO v_t FROM public.rpg_session_participants WHERE id = v_tid;
      v_defending := EXISTS (SELECT 1 FROM jsonb_array_elements(v_t.effects) e WHERE coalesce((e->>'defend')::boolean, false));
      -- knowledge both ways (rpg_knows): the target's Knowing <the actor's card> adds to what it defends with; the actor's Knowing <the target's card> goes into rpg_roll
      SELECT template_id INTO v_target_card FROM public.rpg_characters WHERE id = v_t.character_id;
      v_know_def := public.rpg_knows(v_t.character_id, v_actor_card);
      -- Gate 1: land. Evade lowered by burden.
      v_def := greatest(coalesce(public.rpg_participant_value(v_tid, v_against), 0)
                        - CASE WHEN v_against IN ('EE', 'BGP') THEN public.rpg_participant_burden(v_tid, CASE WHEN v_against = 'BGP' THEN 'spiritual' ELSE 'physical' END) ELSE 0 END, 0) + v_know_def;
      v_diff := public.rpg_difficulty(v_def, public.rpg_participant_can_act(v_tid) AND NOT (v_against IN ('EE', 'BGP') AND public.rpg_participant_exposed(v_tid, p_actor_id)), v_defending);
      -- The roll that ends a revival rule faces the creature's stat × 2, as if it could act.
      IF v_ending THEN v_diff := public.rpg_difficulty(v_def, true, false); END IF;
      v_diff_still := public.rpg_difficulty(v_def, false);
      -- (step 14f-battle) cover (rpg_cover): no physical blow is aimed at someone behind a boulder from the far side
      v_cover := CASE WHEN v_against = 'EE' THEN public.rpg_cover(p_actor_id, v_tid) END;
      IF v_cover = 'full' THEN
        RAISE EXCEPTION '% is behind a boulder: no blow reaches them from here', v_t.name;
      END IF;
      v_roll := public.rpg_roll(v_actor.character_id, v_key, v_diff, v_label, NULL, v_s.id, p_actor_id,
                                CASE WHEN jsonb_array_length(v_plan) = 1 THEN p_roll END, v_target_card);
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
      -- (step 14f-battle) half cover: a blow that lands on someone behind a fallen log strikes the log when its die is in
      -- the lower half of the dice that land, so half the blows get through, as half the body is open to them
      IF v_cover = 'half' AND v_first->>'result' <> '' AND (v_first->>'roll')::integer - v_needs < (100 - v_needs) / 2.0 THEN
        v_blocked := true; v_net := 0;
        v_tail := ' Struck the fallen log in front of ' || v_t.name || ' (rolled ' || (v_first->>'roll') || ': past half cover a blow needs '
                  || ceil(v_needs + (100 - v_needs) / 2.0)::integer || ').';
      END IF;
      -- Gate 2: block. Someone holding a shield or weapon; the Shield of Faith against a spiritual effect.
      IF v_first->>'result' <> '' AND NOT v_blocked AND v_t.character_id IS NOT NULL AND (v_damage_ok OR v_spirit_fx) THEN
        v_blk := NULL; v_blocker := NULL; v_blocker_name := NULL;
        IF v_damage_ok THEN
          -- the best unbroken thing held: its object's Integrity (Toughness ÷ 5) adds to Block
          SELECT i.id, i.name, (s->>'ig')::numeric INTO v_blocker, v_blocker_name, v_blk FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
           WHERE i.character_id = v_t.character_id AND i.equipped AND NOT i.worn AND NOT (s->>'broken')::boolean
           ORDER BY (s->>'ig')::numeric DESC, i.sort_order LIMIT 1;
          IF v_blocker IS NOT NULL THEN v_blk := coalesce(public.rpg_participant_value(v_tid, 'BLK'), 0) + coalesce(v_blk, 0) + v_know_def; END IF;
        ELSE
          -- the Shield of Faith blocks while it has life left (3 × its value); broken, it blocks nothing until Prayer or Bible Study restore it
          v_shield := public.rpg_armor_state(v_t.character_id, (SELECT d.key FROM public.rpg_stat_definitions d WHERE d.guards = 'block' LIMIT 1));
          IF v_shield IS NULL OR (v_shield->>'broken')::boolean THEN v_blk := NULL; ELSE v_blk := public.rpg_participant_value(v_tid, v_shield->>'key') + v_know_def; END IF;
          v_blocker_name := coalesce(v_shield->>'name', 'Shield of Faith');
        END IF;
        IF v_blk IS NOT NULL THEN
          v_broll := public.rpg_roll(v_actor.character_id, v_key, public.rpg_difficulty(v_blk, public.rpg_participant_can_act(v_tid), v_defending), v_label || ' (block)', NULL, v_s.id, p_actor_id, NULL, v_target_card);
          IF v_broll->>'result' = '' THEN
            v_blocked := true; v_net := 0;
            v_tail := ' Blocked by ' || CASE WHEN v_blocker IS NOT NULL THEN v_t.name || '''s ' || v_blocker_name ELSE v_t.name || '''s Shield of Faith' END
                      || ' (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
            IF v_blocker IS NOT NULL AND v_dmg > 0 THEN
              v_wear := public.rpg_item_damage(v_blocker, v_dmg);
              v_tail := v_tail || ' The ' || v_blocker_name || ' takes ' || v_dmg || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left') || ' left.' END;
              IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_dmg / 5.0)::integer); END IF;
            END IF;
            IF v_blocker IS NULL AND v_spirit_fx THEN
              -- the Shield of Faith takes the attack's strength: the landing die minus what it needed
              v_wear := public.rpg_armor_wear(v_t.character_id, v_shield->>'key', greatest((v_first->>'roll')::integer - v_needs, 0));
              v_tail := v_tail || ' The ' || (v_shield->>'name') || ' takes ' || (v_wear->>'taken')::numeric::integer || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' left.' END;
            END IF;
          ELSE
            v_tail := ' Past the block (rolled ' || (v_broll->>'roll') || ', needs ' || ceil((v_broll->>'needed')::numeric) || ').';
          END IF;
        END IF;
      END IF;
      -- Gate 3: hit. Armor absorbs and takes what it absorbed; the weapon a fifth.
      IF v_dmg > 0 AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        -- worn and unbroken: each absorbs its object's Integrity (Toughness ÷ 5) and takes that much itself
        FOR v_item IN SELECT i.id, i.name, (s->>'ig')::integer AS absorb FROM public.rpg_items i CROSS JOIN LATERAL public.rpg_object_state(i.object_id) s
                       WHERE i.character_id = v_t.character_id AND i.equipped AND i.worn AND (s->>'ig')::integer > 0 AND NOT (s->>'broken')::boolean ORDER BY (s->>'ig')::integer DESC LOOP
          EXIT WHEN v_net <= 0;
          v_absorb := least(v_item.absorb, v_net);
          v_net := v_net - v_absorb;
          v_wear := public.rpg_item_damage(v_item.id, v_absorb);
          v_tail := v_tail || ' ' || v_item.name || ' absorbs ' || v_absorb || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks.' ELSE '.' END;
          IF v_weapon IS NOT NULL THEN PERFORM public.rpg_item_damage(v_weapon, ceil(v_absorb / 5.0)::integer); END IF;
        END LOOP;
      END IF;
      -- Integrity: what is left after armor must clear the target's Integrity (Toughness ÷ 5) or it does nothing.
      v_bounced := false;
      IF v_net > 0 AND NOT v_blocked THEN
        v_integrity := coalesce(public.rpg_participant_value(v_tid, 'IG'), 0)::integer;
        IF v_net <= v_integrity THEN
          v_bounced := true;
          v_tail := v_tail || ' ' || v_net || ' does not get through ' || v_t.name || '''s Integrity of ' || v_integrity || '.';
          v_net := 0;
        END IF;
      END IF;
      IF v_net > 0 THEN v_vit := public.rpg_session_adjust_vitality(v_tid, v_net);
      ELSE v_vit := public.rpg_participant_vitality(v_tid); END IF;
      -- An attack on the heart or the mind (the card's "aim"): the armor piece that guards it absorbs up to its own value
      -- of the attack's strength (the die minus what it needed) and wears by that much; only what is left puts the
      -- effect on. Zaboo's Breastplate 10 against a Briar Roar of strength 23: takes 10, 13 gets through, Frightened;
      -- strength 8: turned aside. Broken, or with no value, it absorbs nothing.
      v_turned := false;
      IF v_kind = 'action' AND v_fx->>'aim' IS NOT NULL AND v_fx->>'on' = 'land' AND v_first->>'result' <> '' AND NOT v_blocked AND v_t.character_id IS NOT NULL THEN
        v_piece := public.rpg_armor_state(v_t.character_id, (SELECT d.key FROM public.rpg_stat_definitions d WHERE d.guards = v_fx->>'aim' LIMIT 1));
        IF v_piece IS NOT NULL AND (v_piece->>'value')::numeric > 0 AND NOT (v_piece->>'broken')::boolean THEN
          v_strength := greatest((v_first->>'roll')::integer - v_needs, 0);
          v_absorb := least(floor((v_piece->>'value')::numeric)::integer, v_strength);
          v_wear := public.rpg_armor_wear(v_t.character_id, v_piece->>'key', v_absorb);
          IF v_strength - v_absorb <= 0 THEN
            v_turned := true;
            v_tail := v_tail || ' ' || v_t.name || '''s ' || (v_piece->>'name') || ' turns it aside'
                      || CASE WHEN v_absorb > 0 THEN ' (takes ' || v_absorb || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks)' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' of ' || (v_wear->>'life')::numeric::integer || ' left)' END ELSE '' END || '.';
          ELSE
            v_tail := v_tail || ' ' || v_t.name || '''s ' || (v_piece->>'name') || ' takes ' || v_absorb
                      || CASE WHEN (v_wear->>'broke')::boolean THEN ' and breaks' ELSE ', ' || (v_wear->>'left')::numeric::integer || ' of ' || (v_wear->>'life')::numeric::integer || ' left' END
                      || '; ' || (v_strength - v_absorb) || ' gets through.';
          END IF;
        END IF;
      END IF;
      v_out := CASE WHEN v_blocked THEN jsonb_build_object('key', 'blocked', 'label', 'Blocked')
                    WHEN v_turned THEN jsonb_build_object('key', 'bounced', 'label', 'Turned aside')
                    WHEN v_bounced THEN jsonb_build_object('key', 'bounced', 'label', 'Bounced off')
                    ELSE public.rpg_outcome((v_first->>'roll')::integer, (v_first->>'needed')::numeric, (v_first->>'critical')::numeric, v_damage_ok, v_net,
                                            (public.rpg_needed(coalesce(v_first->>'skill', '0')::numeric, v_diff_still)->>'needed')::numeric) END;
      v_levelup := CASE WHEN (v_roll->>'level_after')::integer > (v_first->>'level_before')::integer
                        THEN ' ' || v_actor.name || '''s ' || coalesce(v_first->>'stat_name', v_label) || ' goes up to ' || (v_roll->>'level_after') || '!' ELSE '' END;
      -- knowledge in the log: "(Knowing Bramblemaw 3; Bramblemaw 2 knows Human 2)"
      v_know_txt := concat_ws('; ',
        CASE WHEN coalesce((v_first->'knowledge'->>'value')::numeric, 0) > 0 THEN (v_first->'knowledge'->>'name') || ' ' || trim_scale((v_first->'knowledge'->>'value')::numeric) END,
                       CASE WHEN coalesce((v_first->'place_knowledge'->>'value')::numeric, 0) > 0 THEN (v_first->'place_knowledge'->>'name') || ' ' || trim_scale((v_first->'place_knowledge'->>'value')::numeric) END,
        CASE WHEN v_know_def > 0 THEN v_t.name || ' knows ' || (SELECT k.name FROM public.rpg_creatures k WHERE k.id = v_actor_card) || ' ' || trim_scale(v_know_def) END);
      v_know_txt := CASE WHEN v_know_txt <> '' THEN ' (' || v_know_txt || ')' ELSE '' END;
      -- Built with IF, not CASE: PL/pgSQL plans every CASE branch, and v_use is only assigned for a card action.
      IF v_kind = 'attack' THEN
        v_who := v_actor.name || ' attacks ' || v_t.name || ' with ' || v_label
                 || CASE WHEN coalesce((v_first->>'bulk_over')::integer, 0) > 0 THEN ' (bulk ' || (v_first->>'bulk_over') || ' over: rolls as ' || trim_scale((v_first->>'skill')::numeric) || ')' ELSE '' END || v_know_txt;
      ELSIF v_kind = 'action' THEN
        v_who := v_actor.name || '''s ' || v_use.name || CASE WHEN v_use.id <> v_act.id THEN ' (' || v_act.name || ')' ELSE '' END
                 || ' at ' || v_t.name || CASE WHEN v_damage_ok THEN '' ELSE ' (' || v_against_name || ')' END || v_know_txt;
      ELSE
        v_who := v_actor.name || ' rolls ' || v_label || ' against ' || v_t.name || '''s ' || v_against_name || v_know_txt;
      END IF;
      -- Players see a creature's health as a bar only, so the log gives a number left only for characters.
      v_tail := v_tail || CASE WHEN v_net > 0 AND (v_vit->>'left')::integer <= 0 THEN ' ' || v_t.name || ' ' || coalesce(v_vit->>'fell', 'is down') || '.'
                               WHEN v_net > 0 AND v_t.creature_id IS NULL THEN ' ' || v_t.name || ' has ' || (v_vit->>'left') || ' left.'
                               ELSE '' END;
      -- A hostile roll marks the actor as having attacked (no longer an innocent) and, if they are Judged and the target
      -- is an innocent, condemns them (rpg_judgement). A Miss counts: the attempt is the harm.
      IF NOT v_ending AND (v_kind = 'attack' OR (v_kind = 'action' AND (v_damage_ok OR v_fx ? 'apply'))) THEN
        v_tail := v_tail || coalesce(public.rpg_judgement(p_actor_id, v_tid, false), '');
        UPDATE public.rpg_session_participants SET has_attacked = true WHERE id = p_actor_id AND NOT has_attacked;
      END IF;
      IF v_ending AND v_first->>'result' <> '' THEN
        v_rev := NULL;
        SELECT e INTO v_rev FROM jsonb_array_elements(v_t.effects) e WHERE e ? 'ended_by' LIMIT 1;
        UPDATE public.rpg_session_participants p
           SET effects = (SELECT coalesce(jsonb_agg(z), '[]'::jsonb) FROM jsonb_array_elements(p.effects) z WHERE NOT z ? 'ended_by')
                         || jsonb_build_array(jsonb_build_object('name', v_rev->'ended_by'->>'name', 'cannot_act', true, 'source', v_label))
         WHERE p.id = v_tid;
        v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_rev->'ended_by'->>'name') || ' and will not rise.';
      END IF;
      IF v_kind = 'action' AND v_fx IS NOT NULL AND v_first->>'result' <> '' AND NOT v_blocked AND NOT v_bounced AND NOT v_turned AND (v_vit->>'left')::integer > 0 THEN
        IF v_fx->>'on' = 'land' AND NOT v_damage_ok THEN
          PERFORM public.rpg_participant_apply_effect(v_tid, (v_fx->'apply') || jsonb_build_object('source_id', p_actor_id), v_use.name, v_s.round);
          v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name') || '.';
        ELSIF v_fx->>'on' = 'hit' AND v_net > 0 AND v_fx ? 'contest' THEN
          v_cdiff := public.rpg_difficulty(coalesce(public.rpg_participant_value(v_tid, v_fx->'contest'->>'against'), 0) + v_know_def, public.rpg_participant_can_act(v_tid), v_defending);
          v_croll := public.rpg_roll(v_actor.character_id, v_fx->'contest'->>'skill_key', v_cdiff, v_use.name || ' (' || (v_fx->'apply'->>'name') || ')', NULL, v_s.id, p_actor_id, NULL, v_target_card);
          IF v_croll->>'result' <> '' THEN
            PERFORM public.rpg_participant_apply_effect(v_tid, (v_fx->'apply') || jsonb_build_object('source_id', p_actor_id), v_use.name, v_s.round);
            v_tail := v_tail || ' ' || v_t.name || ' is ' || (v_fx->'apply'->>'name');
          ELSE
            v_tail := v_tail || ' ' || v_t.name || ' stays up';
          END IF;
          v_tail := v_tail || ' (' || (v_croll->>'stat_name') || ' ' || trim_scale((v_croll->>'skill')::numeric) || ' against ' || trim_scale(v_cdiff)
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

  IF v_beats > 0 AND (v_kind IN ('attack', 'action') OR v_ending OR v_discipline) THEN
    UPDATE public.rpg_sessions SET turn_action_ticks = public.rpg_action_ticks(p_actor_id, v_beats, CASE WHEN v_kind = 'attack' THEN p_stat_key END) WHERE id = v_s.id;
  END IF;
  IF v_ecost > 0 AND (v_kind IN ('attack', 'action') OR v_ending OR v_discipline) THEN
    IF v_etype = 'spiritual' THEN UPDATE public.rpg_session_participants SET energy_used_spiritual = energy_used_spiritual + v_ecost WHERE id = p_actor_id;
    ELSE UPDATE public.rpg_session_participants SET energy_used_physical = energy_used_physical + v_ecost WHERE id = p_actor_id; END IF;
  END IF;
  IF v_kind = 'action' THEN
    UPDATE public.rpg_session_participants
       SET legendary_left = legendary_left - CASE WHEN v_act.kind = 'legendary' THEN v_act.legendary_cost ELSE 0 END,
           lair_round = CASE WHEN v_act.kind = 'lair' THEN v_s.round ELSE lair_round END
     WHERE id = p_actor_id;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('kind', v_kind, 'label', v_label, 'results', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL::integer, p_y integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a piece on a square of the world map (counted from 1, as pieces stand), or with no square takes
-- it off. Free, any time, but never onto the sea or a square someone takes up; placing a piece forgets where it was
-- heading, and brings it up from under the ground (step 12d2), except a piece in a fight under the ground, which is
-- moved on the battle grid under the ground (step 12d3; rpg_fight_square there: no rock). A fight off the map has no
-- board, so there it can only take someone off. (Storeys step) In a fight the piece goes onto the floor the board shows
-- there (rpg_fight_layer: a floor of a house where the piece nearest it stands up there); else the ground floor.
DECLARE v_p record; v_s record; v_who text; v_keep boolean; v_floor integer := 0;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL, walk_to_x = NULL, walk_to_y = NULL, under_at = NULL, under_to = NULL, under_done = 0, floor = 0
     WHERE id = p_participant_id;
  ELSE
    IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board; meet creatures on a journey'; END IF;
    IF p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
       OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
      RAISE EXCEPTION 'that square is off the map';
    END IF;
    v_keep := v_p.under_at IS NOT NULL AND public.rpg_map_in_fight(p_participant_id);
    IF v_p.under_at IS NULL AND public.rpg_map_in_fight(p_participant_id) THEN
      SELECT coalesce(l.floor, 0) INTO v_floor FROM public.rpg_fight_layer(v_s.id, p_x, p_y) l WHERE l.under_at IS NULL;
      v_floor := coalesce(v_floor, 0);
    END IF;
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN
      RAISE EXCEPTION '%', CASE WHEN v_keep THEN 'that square is solid rock' ELSE 'that square is sea or water too rough to swim' END;
    END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND o.floor = v_floor AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on that square', v_who; END IF;
    UPDATE public.rpg_session_participants
       SET pos_x = p_x, pos_y = p_y, walk_to_x = NULL, walk_to_y = NULL, floor = v_floor,
           under_at = CASE WHEN v_keep THEN under_at END, under_to = CASE WHEN v_keep THEN under_to END, under_done = CASE WHEN v_keep THEN under_done ELSE 0 END
     WHERE id = p_participant_id;
    IF v_p.creature_id IS NULL AND NOT v_keep THEN PERFORM public.rpg_map_trail_add(v_p.character_id, p_x, p_y, p_x, p_y); END IF;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_walk(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece walks toward a world square (p_x, p_y counted from 1, as pieces stand; the map works from 0 inside) on
-- its turn, the whole way in one go: the same movement rule as a fight, at every level (Peter 2026-10-01). Every
-- square entered takes move_ticks (5) at Speed 10 times 1 plus the percent of time it adds (its ground's range,
-- rpg_map_band, at how hard its cell is, rpg_map_hard; a cell coarser than the City grid is the average square of its
-- ground), faster or slower by Speed (rpg_ticks_at: base x 20 / (10 + Speed)). Base time is kept in hundredths of a
-- tick. A tick is 1/6 of a second (Peter 2026-10-03, 1B), so open land (+5% on average) goes at about 2.9 miles an
-- hour at Speed 10.
-- The walk runs straight (rpg_map_line), or along the roads where that is quicker (step 8b, rpg_map_road_path: off a
-- road walking takes 5/3 as long, Tobler 1993): leg by leg from place to place, the ground from rpg_map_route_path,
-- looked at closer where the sea starts. A leg along a road is walked on the road: road ground (rpg_map_band road,
-- +0% to +10%), a mountain road over mountains (pass), the ground of the road card itself along a place card that is a road,
-- the streets in a village, town or city and the ground of an open place it crosses; snow and ice stay snow and ice;
-- where a road meets a river or a lake it crosses it (a bridge, a ford or a ferry), walked as the road; the sea stops
-- it. It stops:
--   at the shore: nobody walks into the sea (2A), nor into water too rough to swim, nor ends a walk in water too deep
--   to wade; the piece stands on the last dry square before it;
--   water too deep to wade is swum (step 7b): each square takes map_swim_pct (170) more time, and every round_ticks (20)
--   in the water the site rolls the swimmer's Swimming (Swimming with Gear with swimming gear on) against the water's
--   pull there (rpg_map_swim_difficulty). A miss puts them under: a round lost, and they roll again; under longer than
--   swim_breath_ticks (180) without breathing water, every tick costs vitality at a full bar per swim_drown_ticks (540).
--   Once in the water they swim on until out of it, past the end of the walking day if need be; if they go down
--   (0 vitality) the walk stops there, in the water. The rolls train the skill like any roll (all their points at once);
--   a mountain cliff is climbed (step 7c): on the battle grid each cliff square (rpg_map_steep, rpg_map_cliff_angle)
--   takes its climb's time (rpg_map_climb) and a Climbing roll (Climbing with Gear with climbing gear on) against its
--   difficulty (a walk read in coarser runs, longer than 72 squares, picks its way round cliffs: the mountain's own time
--   allows for that). A miss is a fall the height of the square ((height / climb_fall_down_m, 15 m) squared of their vitality) and the climb again; if
--   they go down the walk stops at the foot of that cliff. Climbing trains like swimming;
--   when the walking day runs out: a piece walks at most walk_day_hours (8) between camps (day_walk_ticks counts it),
--   then camps camp_hours (16) where it stands. The square it was heading for is kept (walk_to_x, walk_to_y) so the
--   next turn can carry on;
--   one square short of a square another piece stands on;
--   at the end of the roads it looked at, when the square it is heading for lies farther (rpg_map_road_path stop): the
--   square it was heading for is kept, as when the day runs out, and the next turn looks again from there;
--   when a creature is met: every full hour walked inside a haunt (rpg_map_haunters; haunt_ticks carries the part
--   hour on) the site rolls a d100, and at encounter_chance (15) or less a creature of that haunt is met where the
--   hour ran out (Peter 2026-10-03, 1A). It joins the journey encounter_squares (10) away (rpg_map_set_down) and the
--   fight is on, on that ground. A piece in a fight (rpg_map_in_fight) moves on the fight board, not across the map;
--   creatures always do.
-- The end square is checked on the battle grid itself (dry, nobody on it, no house on it), stepping back along the walk
-- if it must. Houses (step 8c) are walked round, along the streets and yards between them: a walk reads a village,
-- town or city as its own ground, and climbing a house is a move on the fight board.
-- The time walked plus any camp is the turn (turn_move_ticks), and the turn passes on (rpg_session_next_turn).
-- Pieces stand on world squares counted from 1 (pos_x = square + 1), like squares on a fight board. A piece under the
-- ground (step 12d2) walks its passages instead (rpg_map_under_walk).
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
  v_hour integer; v_d100 integer; v_new integer[]; v_cell bigint; v_wd double precision; v_wl integer; v_deep integer[]; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid;
  v_wc double precision; v_swim boolean; v_dif numeric; v_rtk integer; v_breath integer; v_drown integer; v_lost numeric; v_need2 numeric;
  v_sw_in boolean := false; v_sw_clock numeric := 0; v_sw_next numeric := 0; v_sw_under integer := 0; v_sw_long integer := 0; v_sw_dips integer := 0;
  v_sw_rolls integer := 0; v_sw_points numeric := 0; v_sw_harmt integer := 0; v_sw_harm integer := 0; v_sw_key text; v_sw_skill numeric; v_sw_gear boolean;
  v_sw_breathes boolean; v_sw_left integer; v_sw_max integer; v_sw_maxdif numeric := 0; v_sw_val numeric;
  v_cliff double precision; v_cl_rise double precision; v_cl_dif numeric; v_cl_key text; v_cl_skill numeric; v_cl_gear boolean;
  v_cl_rolls integer := 0; v_cl_points numeric := 0; v_cl_falls integer := 0; v_cl_harm integer := 0; v_cl_count integer := 0; v_cl_maxdif numeric := 0;
  v_cl_n integer; v_cl_extra numeric; v_cl_try bigint; v_cl_left integer; v_cl_max integer; v_fixed bigint := 0; j integer;
  v_wx integer[]; v_wy integer[]; v_wk integer[]; v_wp uuid[]; v_stop boolean; v_cum integer[]; v_lk integer; v_kind text; v_place uuid;
  v_onroad integer := 0; v_ex integer; v_ey integer; v_house boolean := false; v_nx integer; v_ny integer;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  -- (storeys step) up a house, the way out is down its stair first (rpg_act_stair)
  IF v_p.floor > 0 THEN RAISE EXCEPTION '% is upstairs in a house: come down the stair first', v_p.name; END IF;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  IF v_p.under_at IS NOT NULL THEN RAISE EXCEPTION '% is under the ground: walk its passages, or come up at the mouth of a cave or a mine', v_p.name; END IF;
  SELECT l.span, l.span / 2 INTO v_world, v_down FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_x IS NULL OR p_y IS NULL OR p_x NOT BETWEEN 1 AND v_world OR p_y NOT BETWEEN 1 AND v_down THEN
    RAISE EXCEPTION 'that square is off the map';
  END IF;
  v_sx := v_p.pos_x - 1; v_sy := v_p.pos_y - 1; v_gx := p_x - 1; v_gy := p_y - 1;
  v_haunt := v_p.haunt_ticks;
  v_tph := public.rpg_setting('ticks_per_hour')::integer;
  v_day := public.rpg_setting('walk_day_hours')::integer * v_tph;
  v_camp := public.rpg_setting('camp_hours')::integer * v_tph;
  v_mt := public.rpg_setting('move_ticks')::integer;
  v_even := public.rpg_setting('speed_even');
  v_speed := public.rpg_participant_speed(p_participant_id);
  v_rtk := public.rpg_setting('round_ticks')::integer;
  v_breath := public.rpg_setting('swim_breath_ticks')::integer;
  v_drown := public.rpg_setting('swim_drown_ticks')::integer;
  v_ign := public.rpg_participant_ignores_penalty(p_participant_id);
  -- the way: straight, or along the roads (rpg_map_road_path): its points, how each leg is walked (v_wk[i + 1] for the
  -- leg from point i to point i + 1), and the steps walked before each point
  SELECT array_agg(r.x ORDER BY r.n), array_agg(r.y ORDER BY r.n), array_agg(r.class ORDER BY r.n), array_agg(r.place ORDER BY r.n), coalesce(bool_or(r.stop), false)
    INTO v_wx, v_wy, v_wk, v_wp, v_stop
    FROM public.rpg_map_road_path(v_sx, v_sy, v_gx, v_gy) r;
  SELECT array_agg(q.c ORDER BY q.i) INTO v_cum
    FROM (SELECT g.i, coalesce(sum(l.steps) OVER (ORDER BY g.i), 0)::integer AS c
            FROM generate_series(1, cardinality(v_wx)) AS g(i)
            LEFT JOIN LATERAL public.rpg_map_line(v_wx[g.i - 1], v_wy[g.i - 1], v_wx[g.i], v_wy[g.i]) l ON g.i > 1) q;
  v_steps := v_cum[cardinality(v_cum)];
  -- the rivers too deep to wade in their middles (great rivers and rivers): a coarse grid that only draws them as a
  -- line through a cell looks closer there, like at the sea
  SELECT coalesce(array_agg(k), '{}') INTO v_deep FROM generate_series(2, 5) AS k
   WHERE public.rpg_setting('map_river_' || k || '_depth') >= public.rpg_setting('map_swim_depth');
  IF v_steps = 0 THEN RAISE EXCEPTION '% is already there', v_p.name; END IF;

  -- the most base time what is left of the walking day holds, and so the most steps it could hold on open land
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_basemax := greatest(ceil((v_left + 0.5) * (v_even + v_speed) / (2 * v_even) * 100)::bigint - 1, 0);
  WHILE v_basemax > 0 AND public.rpg_ticks_at(v_speed, v_basemax / 100.0) > v_left LOOP v_basemax := v_basemax - 1; END LOOP;
  v_kmax := least(v_steps::bigint, v_basemax / (v_mt * 100))::integer;

  -- read at the usual grid first; where that grid sees sea, look again closer (a finer grid over just that stretch)
  -- until the battle grid says where the shore is; a stretch that is dry after all is walked and the walk goes on
  v_from := 1; v_cut := v_kmax;
  FOR v_pass IN 1 .. 80 LOOP
    v_why := NULL; v_lvl := 7;
    FOR v_r IN SELECT * FROM public.rpg_map_route_path(v_wx, v_wy, v_cut, v_from) LOOP
      v_lvl := v_r.level;
      -- the cell this run lies in, on the grid the route read, and the percent of time a square of it adds: its
      -- ground's range (rpg_map_band) at how hard the cell is (rpg_map_hard; none coarser than the City grid)
      SELECT s.x + 1, s.y + 1 INTO v_hx, v_hy FROM public.rpg_map_path_at(v_wx, v_wy, v_r.k_from) s;
      v_pen := NULL; v_wd := 0; v_wl := 0; v_wc := 0; v_swim := false;
      SELECT l.cell INTO v_cell FROM public.rpg_map_ladder() l WHERE l.level = v_r.level;
      -- on a leg along a road, the road (step 8b): road ground, also over a river or a lake (its crossing); a mountain
      -- road over mountains; the ground of a road card; the streets of a village, town or city, an open place, snow and
      -- ice and the sea stay what they are
      v_lk := v_wk[v_r.leg + 1]; v_kind := v_r.kind; v_place := v_r.place_id;
      IF v_lk = 4 AND v_kind <> 'sea' THEN v_kind := 'place'; v_place := v_wp[v_r.leg + 1];
      ELSIF v_lk IS NOT NULL AND v_kind = 'mountains' THEN v_kind := 'pass';
      ELSIF v_lk IS NOT NULL AND v_kind NOT IN ('sea', 'ice', 'town', 'place', 'pass') THEN v_kind := 'road';
      END IF;
      -- water: shallow water goes by its depth (rpg_map_wade_pct); a coarse cell a deep river runs through is looked
      -- at closer
      IF v_kind IN ('water', 'deep') OR (v_r.level < 7 AND v_lk IS NULL) THEN
        SELECT w.depth, w.line, w.current INTO v_wd, v_wl, v_wc
          FROM public.rpg_map_flow(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) w;
      END IF;
      IF v_kind = 'water' THEN
        v_pen := public.rpg_map_wade_pct(v_wd);
      ELSIF v_kind = 'deep' AND v_r.level = 7 THEN
        -- water too deep to wade, on the battle grid: swum (step 7b), unless it pulls too hard to swim or the walk
        -- would end in it (then it stops at the water's edge)
        v_dif := public.rpg_map_swim_difficulty(v_wc);
        IF v_dif IS NOT NULL AND v_r.k_to < v_steps THEN v_pen := public.rpg_map_wade_pct(v_wd); v_swim := true; END IF;
      -- a road crosses rivers: only off the road is a deep river looked at closer
      ELSIF NOT (v_r.level < 7 AND abs(coalesce(v_wl, 0)) = ANY (v_deep) AND v_lk IS NULL) THEN
        SELECT public.rpg_map_pct(b.low, b.high, b.thicket, b.share,
                                  (SELECT h.hard FROM public.rpg_map_hard(v_r.level, ((v_hx - 1) / v_cell)::integer, ((v_hy - 1) / v_cell)::integer, 1, 1) h))
          INTO v_pen
          FROM public.rpg_map_band(v_kind, v_place) b;
      END IF;
      -- a cliff on the battle grid: climbed, at the time its climb takes
      v_cliff := NULL;
      IF v_pen IS NOT NULL AND v_kind = 'mountains' AND v_r.level = 7 THEN
        SELECT public.rpg_map_cliff_angle(t.steep) INTO v_cliff FROM public.rpg_map_steep(7, v_hx - 1, v_hy - 1, 1, 1) t;
        IF v_cliff IS NOT NULL THEN SELECT m.pct, m.rise, m.difficulty INTO v_pen, v_cl_rise, v_cl_dif FROM public.rpg_map_climb(v_cliff) m; END IF;
      END IF;
      IF v_pen IS NULL THEN v_why := 'shore'; v_sea_from := v_r.k_from; v_sea_to := v_r.k_to; EXIT; END IF;
      v_b := v_mt * (100 + CASE WHEN v_ign THEN 0 ELSE v_pen END);
      v_n := greatest(least(v_r.k_to - v_r.k_from + 1, ((v_basemax - v_base) / v_b)::integer), 0);
      -- once in the water a swimmer swims on until out of it, past the end of the walking day if need be
      IF v_swim AND v_sw_in THEN v_n := v_r.k_to - v_r.k_from + 1; END IF;
      IF NOT v_swim AND v_n > 0 THEN v_sw_in := false; v_sw_under := 0; END IF;
      IF v_swim AND v_n > 0 THEN
        IF NOT v_sw_in THEN
          v_sw_in := true; v_sw_clock := 0; v_sw_next := v_rtk; v_sw_under := 0;
          IF v_sw_key IS NULL THEN
            -- what they swim with: swimming gear on and Swimming with Gear open, else Swimming; a skill not on the
            -- sheet swims as 0 (only a 100 keeps them up) and trains nothing
            v_sw_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'swim_gear')
                         AND public.rpg_participant_value(p_participant_id, 'swim_gear') IS NOT NULL;
            v_sw_key := CASE WHEN v_sw_gear THEN 'swim_gear' ELSE 'WM' END;
            v_sw_skill := public.rpg_participant_value(p_participant_id, v_sw_key);
            v_sw_breathes := EXISTS (SELECT 1 FROM public.rpg_characters ch
                                      CROSS JOIN LATERAL unnest(public.rpg_template_chain(ch.template_id)) AS t(id)
                                      JOIN public.rpg_creatures c ON c.id = t.id
                                     WHERE ch.id = v_p.character_id AND c.breathes_water);
            v_sw_left := (public.rpg_participant_vitality(p_participant_id)->>'left')::integer;
            v_sw_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
          END IF;
        END IF;
        v_sw_maxdif := greatest(v_sw_maxdif, v_dif);
        v_lost := 0;
        v_sw_clock := v_sw_clock + v_n * v_b / 100.0 * 2 * v_even / (v_even + v_speed);
        WHILE v_sw_clock >= v_sw_next LOOP
          v_d100 := floor(random() * 100)::integer + 1;
          v_need2 := (public.rpg_needed(coalesce(v_sw_skill, 0), v_dif)->>'needed')::numeric;
          v_sw_rolls := v_sw_rolls + 1;
          v_sw_points := v_sw_points + v_d100 * v_need2 / 100;
          IF v_d100 >= v_need2 THEN
            v_sw_under := 0;
          ELSE
            -- under: a round lost, and the breath runs down
            IF v_sw_under = 0 THEN v_sw_dips := v_sw_dips + 1; END IF;
            v_sw_under := v_sw_under + v_rtk; v_sw_long := greatest(v_sw_long, v_sw_under);
            IF NOT v_sw_breathes AND v_sw_under > v_breath THEN v_sw_harmt := v_sw_harmt + least(v_rtk, v_sw_under - v_breath); END IF;
            v_lost := v_lost + v_rtk;
            v_sw_clock := v_sw_clock + v_rtk;
            IF ceil(v_sw_max * v_sw_harmt::numeric / v_drown) >= v_sw_left THEN v_why := 'drown'; END IF;
          END IF;
          v_sw_next := v_sw_next + v_rtk;
          EXIT WHEN v_why = 'drown';
        END LOOP;
        -- the time lost under water, in base time, on this stretch
        v_b := v_b + ceil(v_lost * (v_even + v_speed) / (2 * v_even) * 100 / v_n)::integer;
      END IF;
      -- a cliff on this battle-grid square: climbed
      IF v_n > 0 AND v_cliff IS NOT NULL THEN
        v_cl_n := v_n;
        IF v_cl_n > 0 AND v_cl_key IS NULL THEN
          v_cl_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'climb_gear')
                       AND public.rpg_participant_value(p_participant_id, 'climb_gear') IS NOT NULL;
          v_cl_key := CASE WHEN v_cl_gear THEN 'climb_gear' ELSE 'CL' END;
          v_cl_skill := public.rpg_participant_value(p_participant_id, v_cl_key);
          v_cl_left := (public.rpg_participant_vitality(p_participant_id)->>'left')::integer - v_sw_harm;
          v_cl_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
        END IF;
        v_cl_extra := 0;
        FOR j IN 1 .. coalesce(v_cl_n, 0) LOOP
          v_cl_try := v_b;
          v_cl_count := v_cl_count + 1; v_cl_maxdif := greatest(v_cl_maxdif, v_cl_dif);
          LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_need2 := (public.rpg_needed(coalesce(v_cl_skill, 0), v_cl_dif)->>'needed')::numeric;
            v_cl_rolls := v_cl_rolls + 1;
            v_cl_points := v_cl_points + v_d100 * v_need2 / 100;
            EXIT WHEN v_d100 >= v_need2;
            -- a slip: a fall the height of the square, and the climb again
            v_cl_falls := v_cl_falls + 1;
            v_cl_harm := v_cl_harm + greatest(ceil(v_cl_max * power(v_cl_rise / public.rpg_setting('climb_fall_down_m')::double precision, 2))::integer, 1);
            IF v_cl_harm >= v_cl_left THEN v_why := 'fell'; EXIT; END IF;
            v_cl_extra := v_cl_extra + v_cl_try;
          END LOOP;
          EXIT WHEN v_why = 'fell';
        END LOOP;
        IF v_why = 'fell' THEN
          -- down at the foot of that cliff: the time spent there counts, the squares past it are not walked
          v_fixed := v_fixed + ceil(v_cl_extra)::bigint;
          v_n := 0;
        ELSIF v_n > 0 THEN
          v_b := v_b + ceil(v_cl_extra / v_n)::integer;
        END IF;
      END IF;
      -- every full hour walked inside a haunt is one roll (Peter 2026-10-03, 1A); none in the water
      IF v_n > 0 AND NOT v_swim AND v_why IS DISTINCT FROM 'fell' THEN
        v_cards := public.rpg_map_haunters(v_hx, v_hy);
        IF v_cards IS NOT NULL THEN
          v_t0 := public.rpg_ticks_at(v_speed, v_base / 100.0);
          v_t1 := public.rpg_ticks_at(v_speed, (v_base + v_n::bigint * v_b) / 100.0);
          v_h0 := v_haunt;
          v_haunt := v_haunt + (v_t1 - v_t0);
          -- the hourly rolls (rpg_map_meet_roll)
          SELECT r.rolls, r.hour INTO v_new, v_hour FROM public.rpg_map_meet_roll(v_h0, v_haunt) r;
          v_rolls := v_rolls || v_new;
          IF v_hour IS NOT NULL THEN
              -- met where that hour ran out: the first step whose time reaches it
              v_need := v_hour::bigint * v_tph - v_h0;
              v_n := least(greatest(ceil(v_need * (v_even + v_speed) / (2 * v_even) * 100 / v_b)::integer, 1), v_n);
              v_haunt := v_h0 + public.rpg_ticks_at(v_speed, (v_base + v_n::bigint * v_b) / 100.0) - v_t0;
              v_meet := v_cards[1 + floor(random() * cardinality(v_cards))::integer];
              v_why := 'meet';
          END IF;
        END IF;
      END IF;
      v_rf := v_rf || v_r.k_from; v_rt := v_rt || (v_r.k_from + v_n - 1); v_rb := v_rb || v_b;
      v_base := v_base + v_n::bigint * v_b;
      v_reach := v_r.k_from + v_n - 1;
      EXIT WHEN v_why IN ('meet', 'drown', 'fell');
      IF v_n < v_r.k_to - v_r.k_from + 1 THEN v_why := 'day'; EXIT; END IF;
    END LOOP;
    IF v_why = 'shore' AND v_lvl < 7 THEN
      v_from := v_sea_from; v_cut := v_sea_to;
    ELSIF v_why IS NULL AND v_cut < v_kmax THEN
      v_from := v_cut + 1; v_cut := v_kmax;
    ELSIF v_why IS NULL AND v_sw_in AND v_cut < v_steps THEN
      -- still in the water when the day's steps ran out: swim on, a stretch at a time
      v_from := v_cut + 1; v_cut := least(v_steps, v_cut + 72);
    ELSE
      EXIT;
    END IF;
  END LOOP;
  IF v_why IS NULL AND v_reach < v_steps THEN v_why := 'day'; END IF;
  -- at the end of the roads it looked at, short of where it is heading
  IF v_why IS NULL AND v_stop THEN v_why := 'way'; END IF;

  -- the end square, on the battle grid: the furthest step that is dry and free, in blocks of 12 steps back; someone
  -- who went down in the water stays where they went down
  IF v_why = 'drown' THEN v_k := v_reach; END IF;
  v_hi := v_reach;
  WHILE v_hi >= 1 AND v_hi > v_reach - 144 AND v_k = 0 LOOP
    v_lo := greatest(v_hi - 11, 1);
    WITH sq AS MATERIALIZED (
           SELECT g.k, s.x, s.y FROM generate_series(v_lo, v_hi) AS g(k)
            CROSS JOIN LATERAL public.rpg_map_path_at(v_wx, v_wy, g.k) s),
         ux AS MATERIALIZED (
           -- a block that crosses the east-west edge of the world is kept in one piece
           SELECT sq.k, sq.x, sq.y,
                  sq.x + CASE WHEN max(sq.x) OVER () - min(sq.x) OVER () > 12 AND sq.x < v_world / 2 THEN v_world ELSE 0 END AS ux
             FROM sq),
         bb AS (SELECT min(ux.ux) AS x0, max(ux.ux) AS x1, min(ux.y) AS y0, max(ux.y) AS y1 FROM ux),
         c AS MATERIALIZED (SELECT c.* FROM bb CROSS JOIN LATERAL public.rpg_map_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) c),
         -- the houses there (step 8c), only where a village, town, city or place is, and the landmarks (step 12b2)
         hs AS MATERIALIZED (SELECT b.x, b.y FROM bb CROSS JOIN LATERAL public.rpg_map_building_cells(7, bb.x0, bb.y0, bb.x1 - bb.x0 + 1, bb.y1 - bb.y0 + 1) b
                              WHERE EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))
                                 OR EXISTS (SELECT 1 FROM bb b2 CROSS JOIN LATERAL public.rpg_map_landmark_cells(7, b2.x0, b2.y0, b2.x1 - b2.x0 + 1, b2.y1 - b2.y0 + 1) m))
    SELECT max(ux.k) INTO v_k
      FROM ux JOIN c ON c.x = ux.ux AND c.y = ux.y
     WHERE c.kind NOT IN ('sea', 'deep')
       AND NOT EXISTS (SELECT 1 FROM hs WHERE hs.x = ux.ux AND hs.y = ux.y)
       AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                        WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = ux.x + 1 AND o.pos_y = ux.y + 1
                          AND public.rpg_participant_blocks(o.id));
    v_k := coalesce(v_k, 0);
    v_hi := v_lo - 1;
  END LOOP;

  -- a house where the walk was heading (step 8c): it stops in front of it
  IF v_k > 0 AND v_k < v_reach AND v_why IS DISTINCT FROM 'drown' THEN
    SELECT EXISTS (SELECT 1 FROM public.rpg_map_path_at(v_wx, v_wy, v_reach) s
                    CROSS JOIN LATERAL public.rpg_map_building_cells(7, s.x, s.y, 1, 1) b) INTO v_house;
  END IF;

  v_base := 0;
  FOR i IN 1 .. coalesce(array_length(v_rf, 1), 0) LOOP
    v_base := v_base + greatest(least(v_rt[i], v_k) - v_rf[i] + 1, 0)::bigint * v_rb[i];
  END LOOP;
  v_walk := public.rpg_ticks_at(v_speed, (v_base + v_fixed) / 100.0);
  v_arrived := v_k = v_steps AND NOT v_stop;
  v_camped := coalesce(v_why, '') = 'day' OR (coalesce(v_why, '') NOT IN ('drown', 'fell') AND v_p.day_walk_ticks + v_walk >= v_day);
  IF v_k = 0 AND NOT v_camped THEN
    RAISE EXCEPTION '%', CASE WHEN v_why = 'shore' THEN 'the sea, water too rough to swim, or the water''s edge is in the way' ELSE 'someone, a house or a landmark is in the way' END;
  END IF;

  v_tx := v_sx; v_ty := v_sy;
  IF v_k > 0 THEN SELECT s.x, s.y INTO v_tx, v_ty FROM public.rpg_map_path_at(v_wx, v_wy, v_k) s; END IF;
  -- the end square on the road itself (step 10b): the way along a road is a chain of points 216 squares or so apart
  -- (rpg_map_road_path), so a walk that ends on a leg along a road moves its last square to the nearest square of the
  -- road (rpg_map_road_snap) when that square is dry land (rpg_map_heights), not a river too deep to wade
  -- (rpg_map_flow), not a house and free
  IF v_k > 0 AND coalesce(v_why, '') <> 'drown' THEN
    SELECT v_wk[g.l + 1] INTO v_lk FROM generate_series(1, cardinality(v_wx) - 1) AS g(l) WHERE v_cum[g.l] < v_k AND v_k <= v_cum[g.l + 1] ORDER BY g.l LIMIT 1;
    IF v_lk BETWEEN 1 AND 3 THEN
      SELECT mod(s.x + v_world, v_world)::integer, s.y INTO v_nx, v_ny FROM public.rpg_map_road_snap(v_tx, v_ty) s;
      IF v_nx IS NOT NULL AND (v_nx <> v_tx OR v_ny <> v_ty)
         AND (SELECT h.height FROM public.rpg_map_heights(7, v_nx, v_ny, 1, 1) h) >= public.rpg_setting('map_sea_level')
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_flow(7, v_nx, v_ny, 1, 1) f WHERE f.depth >= public.rpg_setting('map_swim_depth'))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_map_building_cells(7, v_nx, v_ny, 1, 1))
         AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                          WHERE o.session_id = v_sid AND o.id <> p_participant_id AND o.pos_x = v_nx + 1 AND o.pos_y = v_ny + 1
                            AND public.rpg_participant_blocks(o.id)) THEN
        v_tx := v_nx; v_ty := v_ny;
      END IF;
    END IF;
  END IF;
  UPDATE public.rpg_session_participants
     SET pos_x = v_tx + 1, pos_y = v_ty + 1,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END,
         walk_to_x = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_x END,
         walk_to_y = CASE WHEN NOT v_arrived AND (v_camped AND coalesce(v_why, '') = 'day' OR v_why IN ('meet', 'way')) THEN p_y END,
         haunt_ticks = v_haunt
   WHERE id = p_participant_id;
  -- the swim: what drowning cost, and the points every roll paid (die x Needed / 100), all at once
  IF v_sw_rolls > 0 THEN
    v_sw_harm := ceil(v_sw_max * v_sw_harmt::numeric / v_drown)::integer;
    IF v_sw_harm > 0 THEN
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_sw_harm);
    END IF;
    IF v_sw_skill IS NOT NULL AND v_sw_points > 0 THEN
      v_sw_val := (public.rpg_sheet_values(v_p.character_id)->'values'->>v_sw_key)::numeric;
      PERFORM public.rpg_add_skill_points(v_p.character_id, v_sw_key, v_sw_points, v_sw_val);
      PERFORM public.rpg_trickle(v_p.character_id, v_sw_key, v_sw_points, '[]'::jsonb);
    END IF;
  END IF;
  -- the climbs: what the falls cost, and the points every roll paid, all at once
  IF v_cl_rolls > 0 THEN
    IF v_cl_harm > 0 THEN
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_cl_harm);
    END IF;
    IF v_cl_skill IS NOT NULL AND v_cl_points > 0 THEN
      v_sw_val := (public.rpg_sheet_values(v_p.character_id)->'values'->>v_cl_key)::numeric;
      PERFORM public.rpg_add_skill_points(v_p.character_id, v_cl_key, v_cl_points, v_sw_val);
      PERFORM public.rpg_trickle(v_p.character_id, v_cl_key, v_cl_points, '[]'::jsonb);
    END IF;
  END IF;
  -- what the character saw on the way (rpg_map_found reads these stretches)
  -- a stretch a leg of the way, as far as it was walked; and how many runs of those legs were on a road (a road is
  -- walked as a chain of legs, step 10b: one run from where the walk joins it to where it leaves)
  FOR i IN 1 .. cardinality(v_wx) - 1 LOOP
    EXIT WHEN v_cum[i] >= v_k;
    IF v_cum[i + 1] <= v_k THEN v_ex := v_wx[i + 1]; v_ey := v_wy[i + 1]; ELSE v_ex := v_tx; v_ey := v_ty; END IF;
    PERFORM public.rpg_map_trail_add(v_p.character_id, v_wx[i] + 1, v_wy[i] + 1, v_ex + 1, v_ey + 1);
    IF v_wk[i + 1] IS NOT NULL AND (i = 1 OR v_wk[i] IS NULL) THEN v_onroad := v_onroad + 1; END IF;
  END LOOP;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name
         || CASE WHEN v_k > 0 THEN ' walks ' || public.rpg_map_length_text(v_k) || ' in ' || public.rpg_map_duration_text(v_walk)
                                   || CASE WHEN v_onroad > 0 THEN ' along the road' || CASE WHEN v_onroad > 1 THEN 's' ELSE '' END ELSE '' END || '.'
                 ELSE ' has walked all day.' END
         || CASE WHEN v_why = 'way' THEN ' The roads go on: the walk carries on from here next turn.' ELSE '' END
         || CASE WHEN v_why = 'shore' THEN ' The sea, water too rough to swim, or the water''s edge stops the walk.' ELSE '' END
         || CASE WHEN v_house THEN ' A house or a landmark stands where the walk was heading: it stops in front of it.' ELSE '' END
         || CASE WHEN v_sw_rolls > 0 THEN ' Swims deep water: ' || v_sw_rolls || ' Swimming rolls' || CASE WHEN v_sw_gear THEN ' with gear' ELSE '' END
                                          || ' (' || trim_scale(coalesce(v_sw_skill, 0)) || ' against up to ' || trim_scale(v_sw_maxdif) || ')'
                                          || CASE WHEN v_sw_dips > 0 THEN ', under water ' || v_sw_dips || CASE WHEN v_sw_dips = 1 THEN ' time' ELSE ' times' END
                                                  || ', the longest ' || public.rpg_map_duration_text(v_sw_long) ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_sw_harmt > 0 THEN ' Out of breath under water: ' || ceil(v_sw_max * v_sw_harmt::numeric / v_drown) || ' damage.' ELSE '' END
         || CASE WHEN v_why = 'drown' THEN ' Goes down in the water.' ELSE '' END
         || CASE WHEN v_cl_count > 0 THEN ' Climbs ' || v_cl_count || CASE WHEN v_cl_count = 1 THEN ' cliff: ' ELSE ' cliffs: ' END || v_cl_rolls || CASE WHEN v_cl_rolls = 1 THEN ' Climbing roll' ELSE ' Climbing rolls' END
                                          || CASE WHEN v_cl_gear THEN ' with gear' ELSE '' END || ' (' || trim_scale(coalesce(v_cl_skill, 0)) || ' against up to ' || trim_scale(v_cl_maxdif) || ')'
                                          || CASE WHEN v_cl_falls > 0 THEN ', ' || v_cl_falls || CASE WHEN v_cl_falls = 1 THEN ' fall' ELSE ' falls' END || ': ' || v_cl_harm || ' damage' ELSE '' END || '.' ELSE '' END
         || CASE WHEN v_why = 'fell' THEN ' Falls and is down at the foot of a cliff.' ELSE '' END
         || CASE WHEN v_camped THEN ' Camps for ' || public.rpg_map_duration_text(v_camp) || '.' ELSE '' END
         || CASE WHEN v_camped AND NOT v_arrived AND coalesce(v_why, '') = 'day'
                 THEN ' Still ' || public.rpg_map_length_text((SELECT l.steps FROM public.rpg_map_line(v_tx, v_ty, v_gx, v_gy) l)) || ' to go.' ELSE '' END;
  -- a creature met (rpg_map_meet): it joins and the fight is on; the rolls in words (rpg_map_meet_words)
  IF v_why = 'meet' THEN
    v_text := v_text || public.rpg_map_meet_words(v_rolls, true) || ' ' || public.rpg_map_meet(p_participant_id, v_meet, v_walk, v_tx + 1, v_ty + 1);
  ELSE
    v_text := v_text || public.rpg_map_meet_words(v_rolls, false);
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'stopped', v_why, 'camped', v_camped, 'next', v_next);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_enter(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece on its turn goes into the cave or mine it stands at (step 12d2; rpg_map_under_cave_at): it stands at the
-- mouth of its passage (under_at mouth:<site>), under the ground, until it comes up again (rpg_map_under_leave). Going
-- in takes no time and keeps the turn: the walk on is rpg_map_under_walk.
DECLARE v_sid uuid; v_p record; v_c record; v_text text;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  -- (storeys step) up a house, the way out is down its stair first (rpg_act_stair)
  IF v_p.floor > 0 THEN RAISE EXCEPTION '% is upstairs in a house: come down the stair first', v_p.name; END IF;
  IF v_p.under_at IS NOT NULL THEN RAISE EXCEPTION '% is already under the ground', v_p.name; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  SELECT * INTO v_c FROM public.rpg_map_under_cave_at(v_p.pos_x, v_p.pos_y);
  IF NOT FOUND THEN RAISE EXCEPTION '% is not at a cave or a mine', v_p.name; END IF;
  UPDATE public.rpg_session_participants SET under_at = 'mouth:' || v_c.id, under_to = NULL, under_done = 0, walk_to_x = NULL, walk_to_y = NULL
   WHERE id = p_participant_id;
  UPDATE public.rpg_characters SET map_under = map_under || jsonb_build_array('n:mouth:' || v_c.id)
   WHERE id = v_p.character_id AND NOT is_npc AND session_id IS NULL AND NOT map_under ? ('n:mouth:' || v_c.id);
  v_text := v_p.name || ' goes into ' || v_c.name || '.';
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_sid;
  RETURN jsonb_build_object('text', v_text);
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
-- is, at least 13 squares a side and up to 24 to take in the fighters near them, the percent of time each square adds
-- (nothing for sea), forest and fire (rpg_fight_squares), its column and row names (rpg_square_name, within its own
-- battle grid), and for each fighter whether they stand on it and how far they are from its middle; under the ground
-- (step 12d3; rpg_fight_layer, as rpg_fight_squares reads it) where (under: rpg_map_under_where) and what each square is
-- (parts: floor, rubble, pool, column, shaft from rpg_map_under_squares, nothing for rock; its sea flag is rock); burn_rounds and
-- burn_cost for the words; where everyone stands, each weapon's and action's
-- reach, and the squares the one whose turn it is can still reach this turn ('moves', with the path cost in hundredths of a plain square and the ticks).
-- (Storeys step) Each fighter's floor; up a house the board is that floor (floor, and parts: wall, inner, floor, stair,
-- nothing for the open air; rpg_fight_squares), and 'stair' says where the one whose turn it is can go by a stair.
-- The fight clock: the tick now, each fighter's Speed and next tick (ticks_away: how soon they act; the list runs in
-- that order), each weapon's and action's ticks for that fighter (Karen's sword 36), and what the turn so far costs
-- (turn_cost: moving 13 and acting 27 is 33).
DECLARE
  v_gm boolean := public.family_is_parent();
  v_s record; v_p record; v_sheet jsonb; v_c record; v_vit jsonb; v_item jsonb; v_parts jsonb := '[]'::jsonb; v_vals jsonb; v_rev jsonb;
  v_board jsonb; v_cx integer; v_cy integer; v_bx0 integer; v_by0 integer; v_bw integer; v_bh integer; v_down integer; v_ly record;
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
                 'pos_x', v_p.pos_x, 'pos_y', v_p.pos_y, 'floor', v_p.floor, 'speed', public.rpg_participant_speed(v_p.id), 'next_tick', v_p.next_tick, 'ticks_away', v_p.next_tick - v_s.clock) || v_item);
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
    SELECT * INTO v_ly FROM public.rpg_fight_layer(p_session_id, v_bx0 + v_bw / 2, v_by0 + v_bh / 2);
    -- (storeys step) up a house: which floor, and what each square is on it (wall, inner, floor, stair; nothing for the
    -- open air outside its walls)
    IF v_ly.under_at IS NULL AND coalesce(v_ly.floor, 0) > 0 THEN
      v_board := v_board || jsonb_build_object('floor', v_ly.floor,
                   'parts', (SELECT jsonb_agg(q.part ORDER BY gy, gx)
                               FROM generate_series(v_by0, v_by0 + v_bh - 1) gy CROSS JOIN generate_series(v_bx0, v_bx0 + v_bw - 1) gx
                               LEFT JOIN public.rpg_map_building_squares(7, v_bx0 - 1, v_by0 - 1, v_bw, v_bh, true) q
                                 ON q.x + 1 = gx AND q.y + 1 = gy AND q.floor = v_ly.floor));
    END IF;
    IF v_ly.under_at IS NOT NULL THEN
      v_board := v_board || jsonb_build_object(
                   'under', public.rpg_map_under_where(v_ly.under_at, v_ly.under_to, v_ly.under_done),
                   'parts', (SELECT jsonb_agg(q.part ORDER BY gy, gx)
                               FROM generate_series(v_by0, v_by0 + v_bh - 1) gy CROSS JOIN generate_series(v_bx0, v_bx0 + v_bw - 1) gx
                               LEFT JOIN public.rpg_map_under_squares(v_bx0 - 1, v_by0 - 1, v_bw, v_bh, public.rpg_map_under_layer(v_ly.under_at, v_ly.under_to)) q
                                 ON q.x + 1 = gx AND q.y + 1 = gy));
    END IF;
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
    -- (storeys step) the stair the one whose turn it is stands on: up, down and the ticks each takes (rpg_stair_ways)
    'stair', CASE WHEN v_s.current_participant_id IS NOT NULL AND v_s.status = 'active' THEN public.rpg_stair_ways(v_s.current_participant_id) END,
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

CREATE OR REPLACE FUNCTION public.rpg_map_view_block(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_place uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Maps tab in one read: one block of cells of one grid of the world map, drawn from the place cards and the map
-- rolls (rpg_map_cells). The page reads it through rpg_map_view (a whole grid: the world, or the grid inside one
-- cell of the grid above) and rpg_map_place_view (a place shown whole, Peter 2026-10-03). p_level = the grid; p_x0,
-- p_y0 = the first cell of the block, counted across the whole world at that level; p_cols, p_rows = cells across
-- and down, at most one grid's worth; p_place = the place card the block shows whole, nothing for a whole grid. The
-- block of a place may run past the east or west end of the world: those cells are the same ground round the world.
-- Returns the grid (level, name = the kind of grid or the place shown whole, title, view = how the page names it:
-- level-x-y for a whole grid, p-<place id> for a place shown whole, cols, rows, origin = the first cell of the block,
-- scale), the way back up (crumbs; for a place shown whole: the world, the lands that hold its middle, then the
-- place), the grid next door each way (moves, whole grids only), every cell in reading order (x, y, its name like
-- C5, kind sea / land / forest / hills / mountains / place, place = the card it belongs to, marks = other place
-- cards reaching into it, open = the grid inside it), every place card (name, color, icon = the name of its map
-- symbol, size, ground = its ground in words or nothing when it only names the land, the place it is inside, level =
-- the kind of place it is, view = where it opens (rpg_map_place_link), listed = it belongs on this grid's list, spot
-- = where to write its name on this grid: its center from the top-left corner, then its width and height, all four
-- in thousandths of a cell, or nothing when the center is off the grid), list = what this grid lists, the places
-- one level down that reach into it (the world lists continents, a continent countries, a country regions, a region
-- cities, a city districts, a district battle grids; a battle grid lists nothing; a place shown whole lists the
-- places one level down from it whose middle lies inside it), within = the continent, country and so on that hold
-- the middle of this grid (for a place shown whole, the lands above it that hold its middle), biggest first (only
-- places that name the land, the smallest of each kind), grounds = each kind of unnamed ground with its name and
-- its range in words (rpg_map_band_text), and the ladder of grids in words.
-- The world and a place shown whole also carry detail: every cell of the grid one level down inside the block (for
-- the world, the Continent grids: 144 across and 72 down), one character a cell (the letter of its ground in
-- rpg_map_grounds: ~ sea, . open land, t forest and so on; else the character numbered 256 + the place's spot in
-- detail.places, counted from 0), so they
-- are drawn as fine as the grids inside them; wrap = the east edge of the drawing meets its west edge (the world
-- only); marks = the smaller places reaching into a cell of the detail, by its "x,y" counted from 0 at the top-left
-- corner, the same as the marks of a cell.
-- Each cell also carries to = the world square at its middle (counted from 1, as pieces stand), where a piece walks or is placed when
-- the cell is tapped; cost = the percent of time a square of it adds to cross it (rpg_map_costs; the average square of
-- its ground on a grid coarser than the City grid); hard = 0 to 9, how far up its ground's range it sits, drawn darker
-- the higher (nothing coarser than the City grid). A grid drawn fine carries hard too, one digit a cell of the detail
-- (- for none). river = the biggest river drawn as a line through a cell too coarse to hold it as water (2 a great
-- river, 3 a river, 4 a stream, 5 a brook; rpg_map_rivers) with the point its line passes nearest the cell's middle,
-- in thousandths of a cell from that middle, so the line is drawn where the river truly runs at every zoom; the detail
-- carries rivers, one digit a cell (0 none), and river_x, river_y, that point as a digit 0 to 9 across the cell.
-- journey = the open journey, if any (a session played on the world map): its clock in words,
-- whose turn it is, its last lines of log, every piece (where it stands on this grid in thousandths of a cell like a
-- place spot, the cell name, the grid of this zoom that holds it, when its next turn comes, what is left of its walking day, the
-- square it is heading for and how far that is; for a creature met in its haunt whether it is out of the fight; and
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join. Under the ground (step
-- 12d2) a piece carries under = where it is in words (rpg_map_under_where); the piece whose turn it is carries ways =
-- its ways on, each [node, words] (rpg_map_under_ways, rpg_map_under_way_words; partway along a passage: on, or back),
-- mouth = it can come up here, search = it can search here for the ways up; on the surface, cave = the name of the cave
-- or mine it stands at and can go into (rpg_map_under_cave_at).
-- towns = the villages, towns and cities the read shows (step 8; rpg_map_towns): the Continent grid its great cities
-- (step 12a), the Country grid its cities and great cities and the Region grid all of them, each a mark in the cell its middle stands in (its id among the marks of that cell); on the City
-- grid and finer the cells of the ground of each (rpg_map_town_cells), which come as kind place with place = its id,
-- so they are drawn and named like a place with ground. A grid drawn fine carries them in its detail the same way.
-- Each is told as rpg_map_town_entry tells it; the Region grid lists its towns, cities and great cities.
-- roads = the roads the read draws (step 8b; rpg_map_roads): highways from the Country grid down, roads and lanes from
-- the Region grid down to the District grid (a place shown whole draws those of the grid of its detail; the battle grid has
-- them as ground of its own, road and mountain road, among its cells). Each piece of road is [size (1 highway, 2 road,
-- 3 lane), x0, y0, x1, y1, x2, y2, ...] in thousandths of a cell from the top-left corner: the points of the wandering
-- line of a stretch (step 10b; rpg_map_road_lines, read at the cell drawn, a point every half cell at least), cut where
-- it leaves the cells that are found and not sea (a road crosses rivers and lakes, by a bridge, a ford or a ferry); the
-- page draws each piece as one smooth line through its points. road_width = how wide each size is, in thousandths of a
-- cell of what is drawn.
-- crossings = where the roads cross the rivers, and the fords off the roads (step 11, Peter 2026-10-04: bridges and
-- fords), from the Region grid down to the District grid, each [kind (1 a bridge, 2 a ford where a road crosses, 3 a
-- planned ford off the roads), river (2 a great river, 3 a river, 4 a stream), road (1 highway, 2 road, 3 lane; 0 for
-- a planned ford), x, y (thousandths of a cell from the top-left corner), angle (degrees, the way across the water,
-- clockwise from east), span (the width of the water there, thousandths of a cell)]: a stretch of road crosses a
-- river by a bridge or a ford as rpg_map_crossing_kind rolls for it, the same at every zoom; a planned ford lies where
-- rpg_map_fords puts it (rivers from the City grid down, streams from the District grid down). The battle grid shows
-- them as ground instead: a cell carries cross = bridge (road ground over water) or ford (knee-deep water a road or a
-- planned ford makes; rpg_map_ford_cells), so the page draws planks or a stony shallow.
-- houses = the houses on the battle grid (step 8c; rpg_map_buildings): each its id, roof (thatch or tile), its middle
-- (x, y in thousandths of a square from the top-left corner), the way its ridge runs ([x, y], thousandths of a step),
-- its length and width (thousandths of a square), its height to the eaves in metres, its roof's pitch in degrees and its
-- storeys. A cell a house stands on carries climb = [wall or roof, metres it climbs, degrees, difficulty of the Climbing
-- roll, what it is in words] (rpg_map_building_cells, rpg_map_climb_words); its cost is the climb's. A landmark stands on
-- the battle grid the same way (step 12b2): each square of its walls, stones or mound carries its climb, part the kind
-- of square (keep, curtain, tower, ruin, stone, boulder, cairn, mound). The kids login sees a house once a cell of it is found.
-- A place to go into stands the same way (step 12c: hut, shrine, cross, outcrop, spoil, palisade, tent), and a square of
-- it walked like the ground carries feature = what it is (floor, hearth, altar, or mouth: the way into a cave or a mine).
-- (step 3) A building is a floor plan on the battle grid (rpg_map_building_squares): its walls and inside walls carry
-- climb (part wall or inner), its doors and floors feature = door, floor (a house or a barn) or flags (a church or the
-- cathedral), walked like the ground. A square of a town or city that a road, its market place, a street or a lane
-- runs over (road ground) carries place = the settlement and paved = 1 (2 the market place), so the page paves it;
-- a village's lanes stay earth. (Storeys step) A house of two storeys or more has its stair (feature stair) on the
-- ground floor, and floors = its upper floors' plans, floor by floor, for the Maps tab's floor switch.
-- landmarks = the landmarks the read shows (step 12b; rpg_map_landmarks), from the World grid down to the District grid:
-- each grid those of its own rank and every rank above it, few on the world and more each level down (Peter
-- 2026-10-03 17:28), each a mark in the cell its middle stands in (its id among the marks of that cell; a grid drawn
-- fine carries it in the marks of its detail), told as rpg_map_landmark_entry tells it. The kids login sees a
-- landmark when its cell is found or known, or from as far off as it can be made out (rpg_map_landmark_sight) of where
-- a player character walked, since things seen and steered by from far are what landmarks are (Peter 2026-10-06): a
-- landmark seen that way is marked even in a cell not found yet. The battle grid has none here.
-- under = the world under the ground (step 12d; rpg_map_underground), from the Continent grid down to the District grid:
-- lines = its passages, each [kind (deep, cave, shaft, own, join, delve), from x, y, to x, y (thousandths of a cell from
-- the top-left corner of the block, either end may lie off it), metres down at each end, bend (hundredths of a quarter
-- of its length to one side), how wide at its middle (thousandths of a cell; step 14a), and (step 14a2) where it is
-- wide enough on the map for its bends to show, its path: points along it, each [x, y, half its width] (thousandths of
-- a cell), as rpg_map_under_trace makes them, so the map draws the passage the battle grid cuts (else null: the map
-- draws its curve), and (step 14b) its stream: [share of its width the water covers (thousandths), metres deep at
-- its middle x 10] or null (rpg_map_under_water)]; the Continent and Country grids carry the Deeps alone (step 14a2);
-- rooms (step 14a) = the room at
-- each node a passage reaches, [x, y, half-width, its eight edge knots, its lake (step 14b: [middle off the room's
-- middle across, down (thousandths of its half-width), its size as a share of the room's (thousandths), its eight edge
-- knots, metres deep x 10]) or null], as rpg_map_under_room and rpg_map_under_water make them; halls = the great halls of the Deeps in the block, each [name, x, y, metres down]. The
-- game master sees all of it; the kids login only the own passage of a cave or mine in a cell found or known.
-- On the battle grid (step 12d3) under = the battle grid under the ground instead: squares = every open square under the
-- block (rpg_map_under_squares), each [column, row (from the top-left corner of the block), part (floor, rubble, pool,
-- column, shaft), percent of time it adds (none: no way in), water metres deep, feet down], of the passages and rooms
-- of the Deeps and cave country under the block (rpg_map_underground) and of those round each piece under the ground
-- within 40 squares of it (rpg_map_under_layer: so the passage of a cave or a mine shows where a piece is in it);
-- every other square under it is solid rock. The kids login sees those the group knows, and those round its own pieces.
-- A battle grid may be read slid half a grid at a time (step 14a2; rpg_map_battle_view): view = s-<first square across>-
-- <first square down> then; slides = the grids half a grid west, east, north and south (null off the map).
-- The kids login sees the same read, cut to what the group has found (Peter 2026-10-03, 2A: within sight of where a
-- piece walked, rpg_map_found) or knows (1A: Knowing a place at 1 or more shows all of it, rpg_map_known_places):
-- other cells come as kind unknown with no place, places and lands only once found or known, a place lore only once
-- known, creatures only within sight of a character, and nothing to add.
-- The page draws these as given and works nothing out itself.
DECLARE
  v_l         record;
  v_last      integer;
  v_world     integer;
  v_x         integer := 0;
  v_y         integer := 0;
  v_x0        integer := p_x0;
  v_y0        integer := p_y0;
  v_cols      integer := p_cols;
  v_rows      integer := p_rows;
  v_gx0       bigint;
  v_gy0       bigint;
  v_gx1       bigint;
  v_gy1       bigint;
  v_up_cell   integer;
  v_up_across integer;
  v_up_down   integer;
  v_sub       integer;
  v_dc        integer;
  v_dr        integer;
  v_list_level integer;
  v_pname     text;
  v_pcx       integer;
  v_pcy       integer;
  v_pw        integer;
  v_ph        integer;
  v_plevel    integer;
  v_cells     jsonb;
  v_detail    jsonb;
  v_crumbs    jsonb;
  v_places    jsonb;
  v_list      jsonb;
  v_within    jsonb;
  v_grounds   jsonb;
  v_ladder    jsonb;
  v_moves     jsonb;
  v_slid      boolean := false;
  v_slides    jsonb;
  v_scale     text;
  v_journey   jsonb;
  v_gm        boolean;
  v_known     uuid[] := '{}';
  v_seen      jsonb := '{}';
  v_towns     jsonb;
  v_dtowns    jsonb;
  v_what      integer;
  v_kinds     jsonb;
  v_dkinds    jsonb;
  v_shown     jsonb;
  v_dshown    jsonb;
  v_roads     jsonb;
  v_rw        jsonb;
  v_houses    jsonb;
  v_hseen     text[];
  v_hlist     jsonb;
  v_hpend     boolean := false;
  v_dcell     jsonb;
  v_rivs      jsonb;
  v_lands     jsonb;
  v_lmk       jsonb;
  v_caves     jsonb;
  v_floors    jsonb;   -- (storeys step) the upper floors of the houses on the battle grid
  v_under     jsonb;
  v_drivs     jsonb;
  v_rsegs     jsonb;   -- step 14c: the traced rivers' pieces near the block, for the crossings
  v_rlines    jsonb;   -- step 14c: the traced rivers' pieces drawn on the grid
  v_cross     jsonb;
  v_rm        integer;
  v_ry0       integer;
  v_ry1       integer;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  v_gm := public.family_is_parent();
  SELECT * INTO v_l FROM public.rpg_map_ladder() l WHERE l.level = p_level;
  IF NOT FOUND THEN RAISE EXCEPTION 'that grid is off the map'; END IF;
  SELECT max(l.level) INTO v_last FROM public.rpg_map_ladder() l;
  SELECT l.span INTO v_world FROM public.rpg_map_ladder() l WHERE l.level = 1;
  IF p_place IS NOT NULL THEN
    SELECT c.name, c.place_x, c.place_y, c.place_w, c.place_h, c.place_level INTO v_pname, v_pcx, v_pcy, v_pw, v_ph, v_plevel
      FROM public.rpg_creatures c
     WHERE c.id = p_place AND c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'that place is not on the map'; END IF;
  END IF;
  -- a block is 1 to one grid's worth of cells each way (on the world grid 12 by 6), starts no more than its own
  -- width west of the first cell of the world, and stays between the north and south edges
  IF v_x0 IS NULL OR v_y0 IS NULL OR v_cols IS NULL OR v_rows IS NULL
     OR v_cols NOT BETWEEN 1 AND v_l.cols OR v_rows NOT BETWEEN 1 AND v_l.rows
     OR v_x0 NOT BETWEEN 1 - v_cols AND v_l.across - 1 OR v_y0 < 0 OR v_y0 + v_rows > v_l.down THEN
    RAISE EXCEPTION 'that grid is off the map';
  END IF;
  v_list_level := coalesce(v_plevel, v_l.level) + 1;
  IF p_place IS NULL THEN
    -- a whole grid: the world, or the grid inside one cell of the grid above; a battle grid may also be slid half a
    -- grid at a time (step 14a2, Peter 2026-10-07 3A: a passage along its edge comes into the middle), never over the
    -- east or west end of the world; v_x, v_y = the grid it is in (slid half way: the grid east or south)
    IF v_cols <> v_l.cols OR v_rows <> v_l.rows OR v_x0 < 0
       OR (v_l.level < v_last AND (mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0))
       OR (v_l.level = v_last AND (mod(v_x0, v_cols / 2) <> 0 OR mod(v_y0, v_rows / 2) <> 0 OR v_x0 + v_cols > v_l.across)) THEN
      RAISE EXCEPTION 'that grid is off the map';
    END IF;
    v_slid := mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0;
    v_x := (v_x0 + v_cols / 2) / v_cols;
    v_y := (v_y0 + v_rows / 2) / v_rows;
  END IF;
  IF p_place IS NULL AND v_l.level > 1 THEN
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
  END IF;
  -- the battle grid slid half a grid each way (step 14a2): a whole grid's name when it lands on one, else s-<x0>-<y0>
  -- (its first square, rpg_map_battle_view)
  IF p_place IS NULL AND v_l.level = v_last THEN
    SELECT jsonb_object_agg(d.k, CASE WHEN d.x < 0 OR d.y < 0 OR d.x + v_cols > v_l.across OR d.y + v_rows > v_l.down THEN NULL
                                      WHEN mod(d.x, v_cols) = 0 AND mod(d.y, v_rows) = 0 THEN v_l.level::text || '-' || (d.x / v_cols)::text || '-' || (d.y / v_rows)::text
                                      ELSE 's-' || d.x::text || '-' || d.y::text END)
      INTO v_slides
      FROM (VALUES ('west', v_x0 - v_cols / 2, v_y0), ('east', v_x0 + v_cols / 2, v_y0),
                   ('north', v_x0, v_y0 - v_rows / 2), ('south', v_x0, v_y0 + v_rows / 2)) AS d(k, x, y);
  END IF;
  -- the corners of this grid in world squares
  v_gx0 := v_x0::bigint * v_l.cell;
  v_gy0 := v_y0::bigint * v_l.cell;
  v_gx1 := (v_x0 + v_cols)::bigint * v_l.cell;
  v_gy1 := (v_y0 + v_rows)::bigint * v_l.cell;

  IF NOT v_gm THEN
    v_known := public.rpg_map_known_places();
    SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen
      FROM public.rpg_map_found(v_l.level, v_x0, v_y0, v_cols, v_rows) f;
  END IF;

  -- the rivers are read a little past the block on the grids that draw crossings (step 11): a bridge over the water
  -- of the District grid may reach three cells in, over the water of the City grid two, a crossing of a line one
  v_rm := CASE WHEN v_l.level = 6 THEN 3 WHEN v_l.level = 5 THEN 2 WHEN v_l.level = 4 THEN 1 ELSE 0 END;
  v_ry0 := greatest(v_y0 - v_rm, 0);
  v_ry1 := least(v_y0 + v_rows + v_rm, v_l.down);
  -- the grids of the block saved the first time they are opened (step 13; rpg_map_cache_fill), so the cells are read
  -- from the saved map from then on
  PERFORM public.rpg_map_cache_fill(v_l.level, v_x0, v_y0, v_cols, v_rows);
  -- (step 3b) a battle grid reads its buildings and street squares from the District grids above it once those are
  -- worked out (rpg_map_district_buildings, saved in the background): each District grid above it already on the saved
  -- map but not worked out yet is asked for here, so the battle grids opened under it next read them
  IF v_l.level = 7 THEN
    PERFORM public.rpg_map_district_buildings((g.gx * g.cols)::integer, (g.gy * g.rows)::integer, g.cols, g.rows)
       FROM (SELECT l.cell::double precision AS c FROM public.rpg_map_ladder() l WHERE l.level = 6) d
      CROSS JOIN LATERAL public.rpg_map_cache_grids(6, floor(v_x0 / d.c)::integer, floor(v_y0 / d.c)::integer,
                                                   (floor((v_x0 + v_cols - 1) / d.c) - floor(v_x0 / d.c) + 1)::integer,
                                                   (floor((v_y0 + v_rows - 1) / d.c) - floor(v_y0 / d.c) + 1)::integer) g
       JOIN public.rpg_map_cache m ON m.level = 6 AND m.gx = g.gx AND m.gy = g.gy
      WHERE NOT coalesce(m.notes ? 'houses', false);
  END IF;
  -- the cells, read once for the villages, towns and cities on them (step 8) and for the picture
  WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level, v_x0, v_y0, v_cols, v_rows)),
       -- the kinds of the cells of a Continent, Country or Region grid, for the villages, towns and cities and the roads on it
       kj AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level IN (2, 3, 4)),
       -- the landmarks of this grid (step 12b): those of its own rank decided by its own cells, those of the ranks above by
       -- the cells of their own grids; none on the battle grid
       lk AS MATERIALIZED (SELECT jsonb_object_agg(c.x || ',' || c.y, c.kind) AS k FROM c WHERE v_l.level BETWEEN 2 AND 6),
       lm AS MATERIALIZED (
         SELECT l.*, floor(l.x::double precision / v_l.cell)::integer AS cx, floor(l.y::double precision / v_l.cell)::integer AS cy,
                public.rpg_map_landmark_sight(l.height) AS sight
           FROM public.rpg_map_landmarks(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT lk.k FROM lk)) l
          WHERE v_l.level <= 6 AND l.kind IS NOT NULL),
       -- the cells the known places hold, for the kids login
       kn AS MATERIALIZED (
         SELECT DISTINCT w.x, w.y
           FROM unnest(v_known) AS n(id)
          CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level, v_x0, v_y0, v_cols, v_rows) w
          WHERE NOT v_gm),
       -- which landmarks the read shows: all for the game master; for the kids login those in a cell found or known, and
       -- those a player character walked within sight of (the larger of the two gaps, as the game counts distance)
       lv AS MATERIALIZED (
         SELECT lm.*, v_gm OR v_seen ? (lm.cx || ',' || lm.cy) OR EXISTS (SELECT 1 FROM kn WHERE kn.x = lm.cx AND kn.y = lm.cy) AS near FROM lm),
       tr AS MATERIALIZED (SELECT t.* FROM public.rpg_map_trails() t WHERE NOT v_gm AND EXISTS (SELECT 1 FROM lv WHERE NOT lv.near)),
       ls AS MATERIALIZED (
         SELECT lv.*, lv.near OR EXISTS (SELECT 1 FROM tr CROSS JOIN LATERAL (SELECT mod(mod(lv.x, v_world) + v_world, v_world) + 1 AS wx) w
                                         WHERE public.rpg_seg_box(tr.x0, tr.y0, tr.x1, tr.y1, w.wx - lv.sight, lv.y + 1 - lv.sight, w.wx + lv.sight, lv.y + 1 + lv.sight)) AS shown
           FROM lv),
       lmm AS (SELECT ls.cx AS x, ls.cy AS y, jsonb_agg(ls.id ORDER BY ls.id) AS ids FROM ls WHERE ls.shown GROUP BY 1, 2),
       -- the villages, towns and cities marked on this grid (the Continent grid its great cities, the Country grid its
       -- cities and great cities, the Region grid all of them),
       -- each decided by the cells of this grid
       tw AS MATERIALIZED (
         SELECT t.* FROM public.rpg_map_towns(v_l.level, v_x0, v_y0, v_cols, v_rows, (SELECT kj.k FROM kj)) t
          WHERE v_l.level IN (2, 3, 4) AND t.kind IS NOT NULL),
       tm AS (SELECT floor(tw.x::double precision / v_l.cell)::integer AS x, floor(tw.y::double precision / v_l.cell)::integer AS y,
                     jsonb_agg(tw.id ORDER BY tw.id) AS ids
                FROM tw GROUP BY 1, 2),
       -- the words for their streets, once
       gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
       -- the City grid and finer: the cells of their ground
       tg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) t WHERE v_l.level >= 5),
       -- the battle grid: the squares a house stands on (step 8c), where a village, town, city or place is
       hb AS MATERIALIZED (SELECT b.* FROM public.rpg_map_building_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) b
                            WHERE v_l.level = 7 AND (EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))
                                                     OR EXISTS (SELECT 1 FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows)))),
       -- the battle grid: the squares of a place to go into walked like the ground (step 12c), one each, and (step 3) the
       -- doors and floors of the buildings, where the block has a building
       -- (storeys step) the floor plans of the buildings, every floor (rpg_map_building_squares), where the block has one
       bsq AS MATERIALIZED (SELECT b.* FROM public.rpg_map_building_squares(v_l.level, v_x0, v_y0, v_cols, v_rows, true) b
                             WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))),
       ft AS MATERIALIZED (SELECT DISTINCT ON (f.x, f.y) f.x, f.y, f.part, f.house
                             FROM (SELECT f.x, f.y, f.part, NULL::text AS house FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                                    WHERE v_l.level = 7 AND f.angle IS NULL
                                   UNION ALL
                                   SELECT b.x, b.y, b.part, b.id FROM bsq b WHERE b.floor = 0 AND b.angle IS NULL) f
                            ORDER BY f.x, f.y, f.part),
       -- the battle grid: the market place's squares (step 3)
       mk AS MATERIALIZED (SELECT s.x, s.y FROM public.rpg_map_street_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) s
                            WHERE v_l.level = 7 AND s.class = 4 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       -- the rivers near every cell (rpg_map_rivers), read once: for the lines drawn and for the crossings (step 11),
       -- with a margin round the block where a crossing just outside it may still reach in
       rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) r),
       -- the rivers drawn as lines, traced (step 14c, rpg_map_river_trace), with the same margin
       rtr AS MATERIALIZED (SELECT t.x, t.y, t.k, t.seg FROM public.rpg_map_river_trace(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) t),
       -- the battle grid: the water under the roads and the fords (step 11), where it has roads or water
       wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_flow(v_l.level, v_x0, v_y0, v_cols, v_rows) w
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       fd AS MATERIALIZED (SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'water')),
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, c.lie, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks,
                CASE WHEN c.kind = 'town' OR (v_l.level = 7 AND c.kind IN ('road', 'pass')) THEN tg.id END AS town,
                -- (step 3) a road, market place, street or lane square of a town, city or great city is paved
                CASE WHEN v_l.level = 7 AND c.kind IN ('road', 'pass') AND tg.kind IN ('town', 'city', 'great_city')
                     THEN CASE WHEN mk.x IS NOT NULL THEN 2 ELSE 1 END END AS paved,
                coalesce(hb.id, ft.house) AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif, ft.part AS feature,
                CASE WHEN c.kind IN ('road', 'pass') AND wt.depth > 0 THEN 'bridge' WHEN c.kind = 'water' AND fd.x IS NOT NULL THEN 'ford' END AS cross
           FROM c
           LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
           LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
           LEFT JOIN fd ON fd.x = c.x AND fd.y = c.y
           LEFT JOIN (SELECT b.x, b.y, b.value FROM public.rpg_map_blend(1, v_l.level, v_x0, v_y0, v_cols, v_rows) b WHERE v_l.level = v_last) bl ON bl.x = c.x AND bl.y = c.y
           LEFT JOIN public.rpg_map_steep(v_l.level, v_x0, v_y0, v_cols, v_rows) st ON st.x = c.x AND st.y = c.y
           LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y
           LEFT JOIN tm ON tm.x = c.x AND tm.y = c.y
           LEFT JOIN lmm ON lmm.x = c.x AND lmm.y = c.y
           LEFT JOIN tg ON tg.x = c.x AND tg.y = c.y
           LEFT JOIN hb ON hb.x = c.x AND hb.y = c.y
           LEFT JOIN ft ON ft.x = c.x AND ft.y = c.y
           LEFT JOIN mk ON mk.x = c.x AND mk.y = c.y
          CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k
          -- the cell itself counted round the world, for a block that runs past the east or west end
          CROSS JOIN LATERAL (SELECT mod(mod(c.x, v_l.across) + v_l.across, v_l.across) AS x) wx)
  SELECT (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'x', cl.x - v_x0 + 1, 'y', cl.y - v_y0 + 1,
                   'name', public.rpg_square_name(cl.x - v_x0 + 1, cl.y - v_y0 + 1),
                   -- a cell of a village, town or city comes as a place, its place the settlement, so it is drawn and
                   -- named like a place with ground
                   'kind', CASE WHEN NOT cl.seen THEN 'unknown' WHEN cl.town IS NOT NULL AND cl.kind = 'town' THEN 'place' ELSE cl.kind END,
                   -- (step 3) a paved square of a town or city: 1 a street, 2 the market place
                   'paved', CASE WHEN cl.seen THEN cl.paved END,
                   'place', CASE WHEN cl.seen THEN coalesce(cl.town, cl.place_id::text) END,
                   -- a landmark seen from far is marked even in a cell not found yet (step 12b)
                   'marks', CASE WHEN (cl.seen AND (cardinality(cl.marks) > 0 OR cl.towns IS NOT NULL)) OR cl.lmarks IS NOT NULL
                                 THEN CASE WHEN cl.seen THEN to_jsonb(cl.marks) || coalesce(cl.towns, '[]'::jsonb) ELSE '[]'::jsonb END || coalesce(cl.lmarks, '[]'::jsonb) END,
                   'cost', CASE WHEN cl.seen THEN cl.penalty END,
                   'hard', CASE WHEN cl.seen AND (cl.penalty IS NOT NULL OR cl.kind = 'deep') AND cl.hard IS NOT NULL THEN least(floor(cl.hard * 10), 9)::integer END,
                   -- the battle grid's mountains and hills: how near the square is to the middle line of its chain, in
                   -- thousandths of a ground roll below it (0 on the line; rpg_map_blend part 1, the roll that makes them), so
                   -- the page can tell which way is uphill and draw the slope (Peter 2026-10-04: a mountain side)
                   'rise', CASE WHEN cl.seen AND cl.kind IN ('mountains', 'hills') AND cl.blend IS NOT NULL THEN round(-abs(cl.blend) * 1000)::integer END,
                   -- the battle grid's cliffs: how steep, in degrees (rpg_map_cliff_angle; step 7c), so the page draws the rock face
                   'cliff', CASE WHEN cl.seen AND cl.kind = 'mountains' THEN round(public.rpg_map_cliff_angle(cl.steep))::integer END,
                   -- a square a house stands on (step 8c): its wall or roof, the metres it climbs, how steep, the difficulty
                   'climb', CASE WHEN cl.seen AND cl.part IS NOT NULL
                                 THEN jsonb_build_array(cl.part, round(cl.climb_rise::numeric, 1), round(cl.climb_angle)::integer, cl.climb_dif,
                                                        public.rpg_map_climb_words(cl.part, cl.climb_angle)) END,
                   -- a square of a place to go into walked like the ground (step 12c): floor, hearth, altar or mouth
                   'feature', CASE WHEN cl.seen AND cl.part IS NULL THEN cl.feature END,
                   'river', CASE WHEN cl.seen AND cl.line > 0 AND cl.kind NOT IN ('water', 'deep', 'sea')
                                 THEN jsonb_build_array(cl.line, round(cl.px * 1000)::integer, round(cl.py * 1000)::integer) END,
                   -- the battle grid: a bridge over the water, or a ford through it (step 11)
                   'cross', CASE WHEN cl.seen THEN cl.cross END,
                   -- the battle grid: what lies on the square (step 14f-battle; rpg_map_lie): boulder, log or reeds
                   'lie', CASE WHEN cl.seen THEN cl.lie END,
                   'open', CASE WHEN v_l.level < v_last THEN (v_l.level + 1)::text || '-' || cl.wx::text || '-' || cl.y::text END,
                   'to', jsonb_build_array(cl.wx::bigint * v_l.cell + v_l.cell / 2 + 1, cl.y::bigint * v_l.cell + v_l.cell / 2 + 1)))
                 ORDER BY cl.y, cl.x)
            FROM cl),
         -- the villages, towns and cities shown: a mark on a cell that is seen, or ground on one
         (SELECT jsonb_agg(public.rpg_map_town_entry(q.id, q.kind, q.name, q.people, q.x, q.y, q.r, v_l.level, v_gx0, v_gy0, v_gx1, v_gy1,
                                                     v_l.level = 4 AND q.kind IN ('town', 'city', 'great_city'), q.ground)
                           ORDER BY q.n, q.name)
            FROM (SELECT tw.id, tw.kind, tw.name, tw.people, tw.x, tw.y, tw.r, array_position(ARRAY['great_city', 'city', 'town', 'village'], tw.kind) AS n, gt.g AS ground
                    FROM tw CROSS JOIN gt JOIN cl ON cl.x = floor(tw.x::double precision / v_l.cell)::integer AND cl.y = floor(tw.y::double precision / v_l.cell)::integer
                   WHERE cl.seen
                  UNION ALL
                  SELECT DISTINCT ON (tg.id) tg.id, tg.kind, tg.name, tg.people, tg.tx, tg.ty, tg.r, array_position(ARRAY['great_city', 'city', 'town', 'village'], tg.kind), gt.g
                    FROM tg CROSS JOIN gt JOIN cl ON cl.x = tg.x AND cl.y = tg.y
                   WHERE cl.seen AND cl.town IS NOT NULL) q),
         -- what grows at the sites of this grid, for its roads
         (SELECT jsonb_object_agg(tw.id, tw.kind) FROM tw),
         -- where a road is drawn (step 8b): found, and not the sea
         (SELECT jsonb_object_agg(cl.x || ',' || cl.y, 1) FROM cl WHERE cl.seen AND cl.kind <> 'sea'),
         -- the houses with a square that is seen (step 8c)
         (SELECT array_agg(DISTINCT cl.house) FROM cl WHERE cl.seen AND cl.house IS NOT NULL),
         -- the rivers near each cell, for the crossings (step 11): size, how far (squares) and which way (cells) the line lies
         (SELECT jsonb_agg(jsonb_build_array(r.x, r.y, r.k, round(r.dist::numeric, 1), round(r.px::numeric, 4), round(r.py::numeric, 4)))
            FROM rva r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4) AND r.dist <= 1.5 * v_l.cell),
         -- the traced pieces of the rivers near the block, for the crossings (step 14c): size, ends in cells of the grid
         (SELECT jsonb_agg(jsonb_build_array(r.k, round(r.seg[1]::numeric, 4), round(r.seg[2]::numeric, 4), round(r.seg[3]::numeric, 4), round(r.seg[4]::numeric, 4)))
            FROM rtr r WHERE v_l.level BETWEEN 4 AND 6 AND r.k IN (2, 3, 4)),
         -- the rivers drawn as lines (step 14c): each piece of a traced line in a cell shown that is not water, its size
         -- and ends in thousandths of a cell from the block's first cell
         (SELECT jsonb_agg(jsonb_build_array(r.k, round((r.seg[1] - v_x0) * 1000)::integer, round((r.seg[2] - v_y0) * 1000)::integer,
                                             round((r.seg[3] - v_x0) * 1000)::integer, round((r.seg[4] - v_y0) * 1000)::integer) ORDER BY r.k, r.x, r.y, r.seg[1], r.seg[2], r.seg[3], r.seg[4])
            FROM rtr r JOIN cl ON cl.x = r.x AND cl.y = r.y
           -- (step 14f1) a great river over the sea too: it runs on into the sea cell it flows into, and the Maps tab clips
           -- every river to the coast it draws, so its mouth meets the shore at every zoom
           WHERE cl.seen AND cl.kind NOT IN ('water', 'deep') AND (cl.kind <> 'sea' OR r.k = 2)),
         -- the landmarks shown (step 12b), biggest first
         (SELECT jsonb_agg(public.rpg_map_landmark_entry(ls.id, ls.rank, ls.kind, ls.icon, ls.words, ls.name, ls.x, ls.y, ls.height, ls.across,
                                                         v_l.level, v_gx0, v_gy0, v_gx1, v_gy1) ORDER BY ls.rank, ls.name)
            FROM ls WHERE ls.shown),
         (SELECT jsonb_agg(jsonb_build_object('id', ls.id, 'x', ls.x, 'y', ls.y)) FROM ls WHERE ls.shown),
         -- the caves and mines of the grid, for the world under the ground (step 12d)
         (SELECT jsonb_agg(jsonb_build_array(ls.id, ls.rank, ls.kind, ls.x, ls.y, ls.height, ls.across, ls.near)) FROM ls WHERE ls.kind IN ('cave', 'mine')),
         -- (storeys step) the upper floors of the houses whose squares are seen: [floor, x, y, part], x and y from the
         -- block's first square as the cells count them
         (SELECT jsonb_agg(jsonb_build_array(b.floor, b.x - v_x0 + 1, b.y - v_y0 + 1, b.part) ORDER BY b.floor, b.y, b.x)
            FROM bsq b JOIN cl ON cl.x = b.x AND cl.y = b.y WHERE b.floor > 0 AND cl.seen)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_rsegs, v_rlines, v_lands, v_lmk, v_caves, v_floors;

  -- the world under the ground (step 12d): its passages and its great halls
  -- (step 14a) each passage also carries how wide it runs at its middle (rpg_map_under_size, in thousandths of a cell),
  -- and rooms = the room at each node a passage reaches (rpg_map_under_room: a great hall, a chamber, the far end of a
  -- cave or a mine), each [x, y, half-width (thousandths of a cell), the eight knots of its edge (thousandths)], so the
  -- map draws tunnels and caves at their true size where that size shows
  IF v_l.level BETWEEN 2 AND 6 THEN
    WITH u AS MATERIALIZED (
           SELECT u.*, (SELECT c ->> 2 FROM jsonb_array_elements(coalesce(v_caves, '[]'::jsonb)) c
                         WHERE c ->> 0 IN (split_part(u.a, ':', 2), split_part(u.b, ':', 2)) LIMIT 1) AS skind
             FROM public.rpg_map_underground(v_l.level, v_x0, v_y0, v_cols, v_rows, v_caves, v_gm) u
            -- (step 14a2, Peter 2026-10-07 2B) the Continent and Country grids show the Deeps alone: the caves, mines and
            -- their shafts show from the Region grid down, where they can be seen
            WHERE v_l.level >= 4 OR u.kind IN ('deep', 'hall')),
         sq AS (SELECT t.sq FROM public.rpg_map_under_lattice() t),
         nd AS (SELECT DISTINCT ON (n.node) n.node, n.x, n.y, n.skind
                  FROM (SELECT u.a AS node, u.ax AS x, u.ay AS y, u.skind FROM u
                        UNION ALL SELECT u.b, u.bx, u.by, u.skind FROM u WHERE u.kind <> 'hall') n
                 WHERE n.node NOT LIKE 'mouth:%'
                 ORDER BY n.node, n.skind NULLS LAST)
    SELECT jsonb_build_object(
             'lines', coalesce((SELECT jsonb_agg(jsonb_build_array(u.kind, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell,
                                                                   (u.bx - v_gx0) * 1000 / v_l.cell, (u.by - v_gy0) * 1000 / v_l.cell,
                                                                   round(u.ad)::integer, round(u.bd)::integer, round(u.bend * 100)::integer,
                                                                   round((SELECT sqrt(z.w_low * z.w_high) FROM public.rpg_map_under_size(u.kind, u.skind,
                                                                            CASE WHEN u.a LIKE 'mouth:%' OR u.a LIKE 'end:%' THEN u.a ELSE u.b END) z)
                                                                         / sq.sq * 1000 / v_l.cell)::integer,
                                                                   (SELECT jsonb_agg(jsonb_build_array(round((r.x - v_gx0) * 1000 / v_l.cell)::integer, round((r.y - v_gy0) * 1000 / v_l.cell)::integer,
                                                                                                       round(r.half * 1000 / v_l.cell)::integer) ORDER BY r.n)
                                                                      FROM public.rpg_map_under_trace(u.kind, u.a, u.b, u.ax, u.ay, u.bx, u.by, u.bend, u.skind,
                                                                                                      v_gx0, v_gy0, v_gx1, v_gy1, (v_gx1 - v_gx0) / 240.0) r),
                                                                   (SELECT jsonb_build_array(round(w.part * 1000)::integer, round(w.depth * 10)::integer)
                                                                      FROM public.rpg_map_under_water(u.kind, u.skind, CASE WHEN u.a LIKE 'mouth:%' OR u.a LIKE 'end:%' THEN u.a ELSE u.b END,
                                                                                                      u.a || '|' || u.b) w WHERE u.kind <> 'shaft')))
                                  FROM u CROSS JOIN sq WHERE u.kind <> 'hall'), '[]'::jsonb),
             'halls', coalesce((SELECT jsonb_agg(jsonb_build_array(u.name, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell, round(u.ad)::integer)
                                               ORDER BY u.name) FROM u WHERE u.kind = 'hall'), '[]'::jsonb),
             'rooms', coalesce((SELECT jsonb_agg(jsonb_build_array((nd.x - v_gx0) * 1000 / v_l.cell, (nd.y - v_gy0) * 1000 / v_l.cell, round(r.r * 1000 / v_l.cell)::integer,
                                                                   (SELECT jsonb_agg(round(k * 1000)::integer) FROM unnest(r.knots) AS k),
                                                                   (SELECT jsonb_build_array(round(w.dx * 1000)::integer, round(w.dy * 1000)::integer, round(w.part * 1000)::integer,
                                                                                             (SELECT jsonb_agg(round(k * 1000)::integer) FROM unnest(w.knots) AS k), round(w.depth * 10)::integer)
                                                                      FROM public.rpg_map_under_water('room', nd.skind, nd.node, nd.node) w)) ORDER BY nd.node)
                                  FROM nd CROSS JOIN LATERAL public.rpg_map_under_room(nd.node, nd.skind) r), '[]'::jsonb))
      INTO v_under;
  END IF;

  -- the battle grid under the ground (step 12d3)
  IF v_l.level = 7 THEN
    SELECT jsonb_build_object('lines', '[]'::jsonb, 'halls', '[]'::jsonb,
             'squares', coalesce(jsonb_agg(jsonb_build_array(q.x - v_x0, q.y - v_y0, q.part, q.pct, q.water, round(q.down / 0.3048)::integer) ORDER BY q.y, q.x), '[]'::jsonb))
      INTO v_under
      FROM public.rpg_map_under_squares(v_x0, v_y0, v_cols, v_rows, (
             SELECT coalesce(jsonb_agg(w.j), '[]'::jsonb) FROM (
               SELECT jsonb_build_object('kind', u.kind, 'a', u.a, 'b', u.b, 'ax', u.ax, 'ay', u.ay, 'bx', u.bx, 'by', u.by, 'ad', u.ad, 'bd', u.bd, 'bend', u.bend) AS j
                 FROM public.rpg_map_underground(7, v_x0, v_y0, v_cols, v_rows, NULL, v_gm) u
               UNION ALL
               SELECT l.j
                 FROM public.rpg_session_participants p
                 JOIN public.rpg_sessions s ON s.id = p.session_id AND s.on_map AND s.status <> 'ended'
                CROSS JOIN LATERAL jsonb_array_elements(public.rpg_map_under_layer(p.under_at, p.under_to)) AS l(j)
                WHERE p.under_at IS NOT NULL AND (v_gm OR p.creature_id IS NULL)
                  AND p.pos_x - 1 BETWEEN v_x0 - 40 AND v_x0 + v_cols + 40 AND p.pos_y - 1 BETWEEN v_y0 - 40 AND v_y0 + v_rows + 40) w)) q;
  END IF;

  -- the houses of the battle grid (step 8c): every one with a square seen here, drawn whole as far as the grid goes
  IF v_l.level = 7 AND cardinality(v_hseen) > 0 THEN
    SELECT jsonb_agg(jsonb_build_object(
             'id', h.id, 'roof', h.roof,
             -- (step 14e) what the building is (its id's first letter: h a house, b a barn, c a church, k a cathedral) and
             -- which of its parts this is (the letter after the dot; none for the first part)
             'use', CASE left(h.id, 1) WHEN 'b' THEN 'barn' WHEN 'c' THEN 'church' WHEN 'k' THEN 'cathedral' ELSE 'house' END,
             'part', nullif(split_part(h.id, '.', 2), ''),
             'x', round((h.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((h.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(h.ux * 1000)::integer, round(h.uy * 1000)::integer),
             'len', round(2 * h.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * h.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(h.eaves::numeric, 1), 'pitch', round(h.pitch)::integer, 'storeys', h.storeys) ORDER BY h.id)
      INTO v_houses
      FROM public.rpg_map_buildings(v_l.level, v_x0, v_y0, v_cols, v_rows) h
     -- every part of a building with a square seen (step 14e)
     WHERE split_part(h.id, '.', 1) IN (SELECT split_part(x, '.', 1) FROM unnest(v_hseen) AS x);
  END IF;

  -- the buildings of the District grid (step 14e, Peter 2026-10-07 21:05: cities need more building variety; the City
  -- and District grids show real buildings): the same buildings as the battle grids under it, saved on the grid's row
  -- of the saved map once worked out in the background (rpg_map_district_buildings; a great city's take longer than a
  -- read may run). Each drawn whole where the kids login has found a cell any part of it stands in; x, y, len and wide
  -- in thousandths of a District cell. Not saved yet: houses_pending, and the Maps tab draws the town symbols and asks
  -- again a few seconds later.
  IF v_l.level = 6 THEN
    v_hlist := public.rpg_map_district_buildings(v_x0, v_y0, v_cols, v_rows);
    v_hpend := v_hlist IS NULL;
  END IF;
  IF v_l.level = 6 AND v_hlist IS NOT NULL THEN
    WITH b AS MATERIALIZED (
           SELECT h.* FROM jsonb_to_recordset(v_hlist) AS h(id text, roof text, cx double precision, cy double precision, ux double precision, uy double precision,
                                                            half_len double precision, half_wide double precision, eaves double precision, pitch double precision, storeys integer)),
         sc AS (SELECT (c.v ->> 'x')::integer AS x, (c.v ->> 'y')::integer AS y FROM jsonb_array_elements(coalesce(v_cells, '[]'::jsonb)) AS c(v)
                 WHERE c.v ->> 'kind' IS DISTINCT FROM 'unknown'),
         sb AS (SELECT DISTINCT split_part(b.id, '.', 1) AS base FROM b
                 WHERE v_gm OR EXISTS (SELECT 1 FROM sc WHERE sc.x = floor((b.cx - v_gx0) / v_l.cell)::integer + 1 AND sc.y = floor((b.cy - v_gy0) / v_l.cell)::integer + 1))
    SELECT jsonb_agg(jsonb_build_object(
             'id', b.id, 'roof', b.roof,
             'use', CASE left(b.id, 1) WHEN 'b' THEN 'barn' WHEN 'c' THEN 'church' WHEN 'k' THEN 'cathedral' ELSE 'house' END,
             'part', nullif(split_part(b.id, '.', 2), ''),
             'x', round((b.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((b.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(b.ux * 1000)::integer, round(b.uy * 1000)::integer),
             'len', round(2 * b.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * b.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(b.eaves::numeric, 1), 'pitch', round(b.pitch)::integer, 'storeys', b.storeys) ORDER BY b.id)
      INTO v_houses
      FROM b WHERE split_part(b.id, '.', 1) IN (SELECT sb.base FROM sb);
  END IF;

  IF v_l.level < v_last AND (v_l.level = 1 OR p_place IS NOT NULL) THEN
    -- drawn fine: every cell of the grid one level down inside the block
    SELECT v_l.cell / l.cell INTO v_sub FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1;
    v_dc := v_cols * v_sub;
    v_dr := v_rows * v_sub;
    IF NOT v_gm THEN
      SELECT coalesce(jsonb_object_agg(f.x || ',' || f.y, true), '{}'::jsonb) INTO v_seen
        FROM public.rpg_map_found(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) f;
    END IF;
    v_rm := CASE WHEN v_l.level + 1 = 6 THEN 3 WHEN v_l.level + 1 = 5 THEN 2 WHEN v_l.level + 1 = 4 THEN 1 ELSE 0 END;
    v_ry0 := greatest(v_y0 * v_sub - v_rm, 0);
    v_ry1 := least(v_y0 * v_sub + v_dr + v_rm, (SELECT l.down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level + 1));
    -- the grids the fine drawing reads, saved the first time (step 13): the World grid draws every Continent grid
    PERFORM public.rpg_map_cache_fill(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr);
    WITH kn AS MATERIALIZED (
           SELECT DISTINCT w.x, w.y
             FROM unnest(v_known) AS n(id)
            CROSS JOIN LATERAL public.rpg_map_within(n.id, v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) w
            WHERE NOT v_gm),
         d0 AS MATERIALIZED (SELECT * FROM public.rpg_map_costs(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr)),
         -- the villages, towns and cities of the detail (step 8). A place shown whole on the Continent or Country grid is
         -- drawn about as far out as a Country grid, so its detail marks the cities, as the Country grid does: a detail
         -- of Country cells decides them by its own cells, a detail of Region cells by the Country cells of the grid
         -- itself. A finer detail shows their ground (dg).
         dt AS MATERIALIZED (
           SELECT t.* FROM public.rpg_map_towns(3, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr, (SELECT jsonb_object_agg(d0.x || ',' || d0.y, d0.kind) FROM d0)) t
            WHERE v_l.level + 1 = 3 AND t.kind IS NOT NULL
           UNION ALL
           SELECT t.* FROM public.rpg_map_towns(3, v_x0, v_y0, v_cols, v_rows, NULL) t
            WHERE v_l.level + 1 = 4 AND t.kind IS NOT NULL
           UNION ALL
           -- the World grid (step 14d4): the greatest cities of the world, kept on its saved row (rpg_map_cache_warm)
           SELECT t.id, t.kind, t.name, t.people, t.x, t.y, t.r, NULL::double precision[]
             FROM public.rpg_map_cache m
            CROSS JOIN LATERAL jsonb_to_recordset(m.notes -> 'cities') AS t(id text, kind text, name text, people integer, x bigint, y bigint, r double precision)
            WHERE v_l.level = 1 AND m.level = 1 AND m.gx = 0 AND m.gy = 0),
         dm AS (SELECT floor(dt.x::double precision / (v_l.cell / v_sub))::integer AS x, floor(dt.y::double precision / (v_l.cell / v_sub))::integer AS y,
                       jsonb_agg(dt.id ORDER BY dt.id) AS ids
                  FROM dt GROUP BY 1, 2),
         gt AS MATERIALIZED (SELECT public.rpg_map_band_text('town', NULL) AS g),
         dg AS MATERIALIZED (SELECT t.* FROM public.rpg_map_town_cells(v_l.level + 1, v_x0 * v_sub, v_y0 * v_sub, v_dc, v_dr) t WHERE v_l.level + 1 >= 5),
         rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level + 1, v_x0 * v_sub - v_rm, v_ry0, v_dc + 2 * v_rm, v_ry1 - v_ry0) r),
         -- the landmarks of the grid (step 12b), each in the cell of the detail its middle stands in
         dlm AS (SELECT floor((e.v ->> 'x')::double precision / (v_l.cell / v_sub))::integer AS x, floor((e.v ->> 'y')::double precision / (v_l.cell / v_sub))::integer AS y,
                        jsonb_agg(e.v -> 'id' ORDER BY e.v ->> 'id') AS ids
                   FROM jsonb_array_elements(coalesce(v_lmk, '[]'::jsonb)) AS e(v) GROUP BY 1, 2),
         d AS MATERIALIZED (
           SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py,
                  dm.ids AS towns, dlm.ids AS lmarks, CASE WHEN c.kind = 'town' THEN dg.id END AS town,
                  v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen
             FROM d0 c
             LEFT JOIN (SELECT DISTINCT ON (r.x, r.y) r.x, r.y, r.k AS line, r.px, r.py FROM rva r WHERE r.inside ORDER BY r.x, r.y, r.k) rv ON rv.x = c.x AND rv.y = c.y
             LEFT JOIN kn ON kn.x = c.x AND kn.y = c.y
             LEFT JOIN dm ON dm.x = c.x AND dm.y = c.y
             LEFT JOIN dg ON dg.x = c.x AND dg.y = c.y
             LEFT JOIN dlm ON dlm.x = c.x AND dlm.y = c.y),
         -- the places drawn in the detail, cards first, then the villages, towns and cities whose ground it shows
         u AS (SELECT coalesce(array_agg(q.id ORDER BY q.o, q.sort_order, q.name), '{}'::text[]) AS ids
                 FROM (SELECT DISTINCT c.id::text AS id, 0 AS o, c.sort_order, c.name
                         FROM d JOIN public.rpg_creatures c ON c.id = d.place_id WHERE d.seen
                       UNION ALL
                       SELECT DISTINCT d.town, 1, 0, d.town FROM d WHERE d.seen AND d.town IS NOT NULL) q),
         ln AS (SELECT d.y, string_agg(CASE WHEN NOT d.seen THEN '?' WHEN d.kind = 'place' THEN chr(255 + array_position(u.ids, d.place_id::text))
                                            WHEN d.town IS NOT NULL THEN chr(255 + array_position(u.ids, d.town))
                                            ELSE g.ch END, '' ORDER BY d.x) AS line,
                       string_agg(CASE WHEN d.seen AND (d.penalty IS NOT NULL OR d.kind = 'deep') AND d.hard IS NOT NULL THEN least(floor(d.hard * 10), 9)::integer::text
                                       ELSE '-' END, '' ORDER BY d.x) AS hard,
                       string_agg(CASE WHEN d.seen AND d.line > 0 AND d.kind NOT IN ('water', 'deep', 'sea') THEN d.line::text ELSE '0' END, '' ORDER BY d.x) AS rivers,
                       string_agg(CASE WHEN d.seen AND d.line > 0 THEN least(9, greatest(0, round((d.px + 0.5) * 9)))::integer::text ELSE '0' END, '' ORDER BY d.x) AS river_x,
                       string_agg(CASE WHEN d.seen AND d.line > 0 THEN least(9, greatest(0, round((d.py + 0.5) * 9)))::integer::text ELSE '0' END, '' ORDER BY d.x) AS river_y
                  FROM d CROSS JOIN u
                  LEFT JOIN public.rpg_map_grounds() g ON g.kind = d.kind
                 GROUP BY d.y)
    SELECT jsonb_build_object('cols', v_dc, 'rows', v_dr, 'wrap', p_place IS NULL, 'places', to_jsonb((SELECT u.ids FROM u)),
                              'cells', jsonb_agg(ln.line ORDER BY ln.y),
                              'hard', CASE WHEN bool_or(ln.hard ~ '[0-9]') THEN jsonb_agg(ln.hard ORDER BY ln.y) END,
                              'rivers', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.rivers ORDER BY ln.y) END,
                              'river_x', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.river_x ORDER BY ln.y) END,
                              'river_y', CASE WHEN bool_or(ln.rivers ~ '[2-5]') THEN jsonb_agg(ln.river_y ORDER BY ln.y) END,
                              'marks', (SELECT jsonb_object_agg((d.x - v_x0 * v_sub)::text || ',' || (d.y - v_y0 * v_sub)::text,
                                                                CASE WHEN d.seen THEN to_jsonb(d.marks) || coalesce(d.towns, '[]'::jsonb) ELSE '[]'::jsonb END || coalesce(d.lmarks, '[]'::jsonb))
                                          FROM d WHERE (d.seen AND (cardinality(d.marks) > 0 OR d.towns IS NOT NULL)) OR d.lmarks IS NOT NULL)),
           -- the villages, towns and cities the detail shows, placed on this grid like a place
           (SELECT jsonb_agg(public.rpg_map_town_entry(q.id, q.kind, q.name, q.people, q.x, q.y, q.r, v_l.level, v_gx0, v_gy0, v_gx1, v_gy1, false, q.ground))
              FROM (SELECT dt.id, dt.kind, dt.name, dt.people, dt.x, dt.y, dt.r, gt.g AS ground
                      FROM dt CROSS JOIN gt JOIN d ON d.x = floor(dt.x::double precision / (v_l.cell / v_sub))::integer AND d.y = floor(dt.y::double precision / (v_l.cell / v_sub))::integer
                     WHERE d.seen
                    UNION ALL
                    SELECT DISTINCT ON (dg.id) dg.id, dg.kind, dg.name, dg.people, dg.tx, dg.ty, dg.r, gt.g
                      FROM dg CROSS JOIN gt JOIN d ON d.x = dg.x AND d.y = dg.y
                     WHERE d.seen AND d.town IS NOT NULL) q),
           (SELECT jsonb_object_agg(dt.id, dt.kind) FROM dt),
           (SELECT jsonb_object_agg(d.x || ',' || d.y, 1) FROM d WHERE d.seen AND d.kind <> 'sea'),
           (SELECT jsonb_agg(jsonb_build_array(r.x, r.y, r.k, round(r.dist::numeric, 1), round(r.px::numeric, 4), round(r.py::numeric, 4)))
              FROM rva r WHERE v_l.level + 1 BETWEEN 4 AND 6 AND r.k IN (2, 3, 4) AND r.dist <= 1.5 * v_l.cell / v_sub)
      INTO v_detail, v_dtowns, v_dkinds, v_dshown, v_drivs
      FROM ln;
  END IF;

  -- a village, town or city both marked on the grid and drawn in its detail is told once
  IF v_dtowns IS NOT NULL THEN
    SELECT jsonb_agg(q.e ORDER BY q.n) INTO v_towns
      FROM (SELECT DISTINCT ON (e.value ->> 'id') e.value AS e, e.n
              FROM jsonb_array_elements(coalesce(v_towns, '[]'::jsonb) || v_dtowns) WITH ORDINALITY AS e(value, n)
             ORDER BY e.value ->> 'id', e.n) q;
  END IF;

  -- the roads drawn (step 8b; rpg_map_roads): highways where cities are marked (the Country grid, or a place shown whole
  -- about as far out), all three from the Region grid down to the District grid; the battle grid has them as ground.
  -- Read on what is drawn (the detail of a place shown whole, else the grid), with what grows at its sites when the
  -- read has it (its cities or towns); a detail of Region cells that marks only cities reads its highways on the grid.
  -- Every stretch whose line may reach the block (step 10b; rpg_map_roads looks that far): its points
  -- (rpg_map_road_lines) make the pieces, cut where they leave the cells shown.
  v_what := CASE WHEN v_detail IS NULL THEN CASE WHEN v_l.level = 3 THEN 1 WHEN v_l.level BETWEEN 4 AND v_last - 1 THEN 7 ELSE 0 END
                 WHEN v_l.level = 1 THEN 0
                 ELSE CASE WHEN v_l.level + 1 IN (3, 4) THEN 1 WHEN v_l.level + 1 BETWEEN 5 AND v_last - 1 THEN 7 ELSE 0 END END;
  IF v_what > 0 THEN
    SELECT jsonb_agg(round(1000 * s.value / q.cell)::integer ORDER BY s.key)
      INTO v_rw
      FROM (SELECT CASE WHEN v_detail IS NULL THEN v_l.cell ELSE v_l.cell / v_sub END::numeric AS cell) q
      JOIN public.rpg_settings s ON s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
       AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width', 'map_road_4_width', 'map_road_5_width', 'map_road_6_width');
    WITH g AS (SELECT CASE WHEN v_detail IS NULL THEN v_l.cell ELSE v_l.cell / v_sub END::double precision AS cell,
                      CASE WHEN v_detail IS NULL THEN v_x0 ELSE v_x0 * v_sub END AS x0, CASE WHEN v_detail IS NULL THEN v_y0 ELSE v_y0 * v_sub END AS y0,
                      CASE WHEN v_detail IS NULL THEN v_cols ELSE v_dc END AS cols, CASE WHEN v_detail IS NULL THEN v_rows ELSE v_dr END AS rows,
                      coalesce(CASE WHEN v_detail IS NULL THEN v_shown ELSE v_dshown END, '{}'::jsonb) AS shown,
                      CASE WHEN v_detail IS NULL THEN 1 ELSE v_sub END AS sub,
                      CASE WHEN v_detail IS NULL THEN v_l.level ELSE v_l.level + 1 END AS level),
         lg AS (SELECT row_number() OVER () AS n, r.*
                  FROM public.rpg_map_roads(CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_l.level ELSE v_l.level + 1 END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_x0 ELSE v_x0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_y0 ELSE v_y0 * v_sub END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_cols ELSE v_dc END,
                                            CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_rows ELSE v_dr END,
                                            v_what, CASE WHEN v_detail IS NULL OR (v_what = 1 AND v_l.level = 3) THEN v_kinds ELSE v_dkinds END, 0) r),
         -- the points of every line at once, in cells of what is drawn from the first cell, and whether each lies in a
         -- cell shown
         la AS (SELECT array_agg(lg.class ORDER BY lg.n) AS class, array_agg(lg.ax ORDER BY lg.n) AS ax, array_agg(lg.ay ORDER BY lg.n) AS ay,
                       array_agg(lg.bx ORDER BY lg.n) AS bx, array_agg(lg.by ORDER BY lg.n) AS by, array_agg(lg.a ORDER BY lg.n) AS a, array_agg(lg.b ORDER BY lg.n) AS b
                  FROM lg HAVING count(*) > 0),
         lp AS MATERIALIZED (
           SELECT p.i AS n, la.class[p.i] AS class, la.a[p.i] AS a, la.b[p.i] AS b, p.n AS i, p.x / g.cell - g.x0 AS u, p.y / g.cell - g.y0 AS v,
                  floor(p.x / g.cell - g.x0) BETWEEN 0 AND g.cols - 1 AND floor(p.y / g.cell - g.y0) BETWEEN 0 AND g.rows - 1
                  AND g.shown ? (floor(p.x / g.cell)::bigint || ',' || floor(p.y / g.cell)::bigint) AS ok
             FROM la CROSS JOIN g
            CROSS JOIN LATERAL public.rpg_map_road_lines(la.class, la.ax, la.ay, la.bx, la.by, la.a, la.b, g.cell) p),
         ls AS (SELECT lp.*, lag(lp.ok) OVER w AS pok, lead(lp.ok) OVER w AS nok,
                       lag(lp.u) OVER w AS pu, lag(lp.v) OVER w AS pv, lead(lp.u) OVER w AS nu, lead(lp.v) OVER w AS nv
                  FROM lp WINDOW w AS (PARTITION BY lp.n ORDER BY lp.i)),
         -- the points shown, in runs that follow on from one another; a run ends at the edge of its last cell shown
         lr AS (SELECT ls.*, sum(CASE WHEN NOT coalesce(ls.pok, false) THEN 1 ELSE 0 END) OVER (PARTITION BY ls.n ORDER BY ls.i) AS run FROM ls WHERE ls.ok),
         pc AS (SELECT lr.n, lr.class, lr.run, 2 * lr.i AS o, lr.u, lr.v FROM lr
                UNION ALL
                SELECT lr.n, lr.class, lr.run, 2 * lr.i + e.d, lr.u + e.t * (e.qu - lr.u), lr.v + e.t * (e.qv - lr.v)
                  FROM lr
                 CROSS JOIN LATERAL (VALUES (-1, lr.pok, lr.pu, lr.pv), (1, lr.nok, lr.nu, lr.nv)) AS q(d, qok, qu, qv)
                 CROSS JOIN g
                 -- where the run ends toward that point (step 12a): it runs on through the cells shown and stops where
                 -- the line first meets a cell not shown or leaves what is drawn (it stopped at the edge of the cell of the last
                 -- point, up to a few cells short where the points lie far apart)
                 CROSS JOIN LATERAL (SELECT q.d, q.qu, q.qv, coalesce(min(s.t0) FILTER (WHERE NOT s.ok), 1) AS t
                                       FROM (SELECT b.t0,
                                                    floor(lr.u + (b.t0 + b.t1) / 2 * (q.qu - lr.u)) BETWEEN 0 AND g.cols - 1
                                                    AND floor(lr.v + (b.t0 + b.t1) / 2 * (q.qv - lr.v)) BETWEEN 0 AND g.rows - 1
                                                    AND g.shown ? ((floor(lr.u + (b.t0 + b.t1) / 2 * (q.qu - lr.u)) + g.x0)::bigint || ',' || (floor(lr.v + (b.t0 + b.t1) / 2 * (q.qv - lr.v)) + g.y0)::bigint) AS ok
                                               FROM (SELECT k.t AS t0, lead(k.t) OVER (ORDER BY k.t) AS t1
                                                       FROM (SELECT 0::double precision AS t
                                                             UNION SELECT (gx - lr.u) / (q.qu - lr.u) FROM generate_series(floor(least(lr.u, q.qu))::integer + 1, floor(greatest(lr.u, q.qu))::integer) AS gx WHERE q.qu <> lr.u
                                                             UNION SELECT (gy - lr.v) / (q.qv - lr.v) FROM generate_series(floor(least(lr.v, q.qv))::integer + 1, floor(greatest(lr.v, q.qv))::integer) AS gy WHERE q.qv <> lr.v
                                                             UNION SELECT 1::double precision) k) b
                                              WHERE b.t1 > b.t0) s) e
                 WHERE q.qu IS NOT NULL AND NOT q.qok),
         -- the crossings (step 11), from the Region grid down to the District grid: where a piece of a road line, from
         -- one point to the next, passes from one side of a river line to the other. The river near each cell is known
         -- from the middle of the cell (rpg_map_rivers: how far the line lies and which way), so within a cell the line
         -- is taken as straight: the signed distance of both points from it, in the frame of the cell the first point
         -- lies in (the second where the first cell has no river near, or its middle sits on the line and gives no
         -- direction); a change of sign is a crossing, at the point between them where the distance is 0, shown when
         -- that point lies in a cell shown. Then the planned fords off the roads (rpg_map_fords): rivers from the City
         -- grid down, streams from the District grid down, in cells shown.
         rv AS MATERIALIZED (
           SELECT (e.v ->> 0)::integer AS x, (e.v ->> 1)::integer AS y, (e.v ->> 2)::integer AS k, (e.v ->> 3)::double precision / g.cell AS d,
                  (e.v ->> 4)::double precision AS px, (e.v ->> 5)::double precision AS py,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || (e.v ->> 2) || '_width')::double precision / g.cell AS width
             FROM g CROSS JOIN jsonb_array_elements(coalesce(CASE WHEN v_detail IS NULL THEN v_rivs ELSE v_drivs END, '[]'::jsonb)) AS e(v)
            WHERE g.level BETWEEN 4 AND 6 AND (e.v ->> 3)::double precision / g.cell >= 0.02),
         -- (step 14c) a river traced as a line crosses a road where a piece of the road meets a piece of the river; the
         -- straight-in-a-cell rule below is kept for rivers that are water on this grid (as wide as its cells), and for a
         -- view drawn from its detail (the world, a place shown whole), whose rivers are not traced
         rvw AS MATERIALIZED (SELECT rv.* FROM rv WHERE rv.width >= 1 OR v_detail IS NOT NULL),
         rs AS MATERIALIZED (
           SELECT (e.v ->> 0)::integer AS k, (e.v ->> 1)::double precision - g.x0 AS x1, (e.v ->> 2)::double precision - g.y0 AS y1,
                  (e.v ->> 3)::double precision - g.x0 AS x2, (e.v ->> 4)::double precision - g.y0 AS y2,
                  floor(((e.v ->> 1)::double precision + (e.v ->> 3)::double precision) / 2 - g.x0)::integer AS cu,
                  floor(((e.v ->> 2)::double precision + (e.v ->> 4)::double precision) / 2 - g.y0)::integer AS cv,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || (e.v ->> 0) || '_width')::double precision / g.cell AS width
             FROM g CROSS JOIN jsonb_array_elements(coalesce(CASE WHEN v_detail IS NULL THEN v_rsegs END, '[]'::jsonb)) AS e(v)
            WHERE g.level BETWEEN 4 AND 6),
         cx AS (
           SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, r.k, r.width,
                  r.d - ((ls.u - m.mx) * m.nx + (ls.v - m.my) * m.ny) AS s1, r.d - ((ls.nu - m.mx) * m.nx + (ls.nv - m.my) * m.ny) AS s2
             FROM ls CROSS JOIN g
            CROSS JOIN LATERAL (SELECT q.ox, q.oy FROM (VALUES (1, ls.u, ls.v), (2, ls.nu, ls.nv)) AS q(o, ox, oy)
                                 WHERE EXISTS (SELECT 1 FROM rvw WHERE rvw.x = g.x0 + floor(q.ox)::integer AND rvw.y = g.y0 + floor(q.oy)::integer)
                                 ORDER BY q.o LIMIT 1) f
             JOIN rvw r ON r.x = g.x0 + floor(f.ox)::integer AND r.y = g.y0 + floor(f.oy)::integer
            CROSS JOIN LATERAL (SELECT floor(f.ox) + 0.5 AS mx, floor(f.oy) + 0.5 AS my, r.px / r.d AS nx, r.py / r.d AS ny) m
            WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rvw)),
         -- the cells each piece of road spans (and a quarter cell round it, where a river piece's middle may lie), to meet the river pieces of those cells
         lc AS (SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, cu, cv
                  FROM ls
                 CROSS JOIN LATERAL generate_series(floor(least(ls.u, ls.nu) - 0.25)::integer, floor(greatest(ls.u, ls.nu) + 0.25)::integer) AS cu
                 CROSS JOIN LATERAL generate_series(floor(least(ls.v, ls.nv) - 0.25)::integer, floor(greatest(ls.v, ls.nv) + 0.25)::integer) AS cv
                 WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rs)),
         xt AS (
           SELECT DISTINCT lc.n, lc.class, lc.a, lc.b, lc.u, lc.v, lc.nu, lc.nv, rs.k, rs.width,
                  lc.u + t.t * (lc.nu - lc.u) AS xu, lc.v + t.t * (lc.nv - lc.v) AS xv
             FROM lc
             JOIN rs ON rs.cu = lc.cu AND rs.cv = lc.cv
            CROSS JOIN LATERAL (SELECT (lc.nu - lc.u) * (rs.y2 - rs.y1) - (lc.nv - lc.v) * (rs.x2 - rs.x1) AS dd) q
            CROSS JOIN LATERAL (SELECT ((rs.x1 - lc.u) * (rs.y2 - rs.y1) - (rs.y1 - lc.v) * (rs.x2 - rs.x1)) / q.dd AS t,
                                       ((rs.x1 - lc.u) * (lc.nv - lc.v) - (rs.y1 - lc.v) * (lc.nu - lc.u)) / q.dd AS s) t
            WHERE q.dd <> 0 AND t.t >= 0 AND t.t < 1 AND t.s >= 0 AND t.s < 1),
         xs AS (
           SELECT cx.class, cx.k, cx.a, cx.b, cx.u, cx.v, cx.nu, cx.nv, cx.width, cx.u + t.t * (cx.nu - cx.u) AS xu, cx.v + t.t * (cx.nv - cx.v) AS xv
             FROM cx CROSS JOIN LATERAL (SELECT cx.s1 / (cx.s1 - cx.s2) AS t) t
            WHERE ((cx.s1 > 0 AND cx.s2 <= 0) OR (cx.s1 <= 0 AND cx.s2 > 0)) AND abs(cx.s1) <= 1 AND abs(cx.s2) <= 1
           UNION ALL
           SELECT xt.class, xt.k, xt.a, xt.b, xt.u, xt.v, xt.nu, xt.nv, xt.width, xt.xu, xt.xv FROM xt),
         pf AS (
           SELECT f.k, f.x / g.cell - g.x0 AS xu, f.y / g.cell - g.y0 AS xv, degrees(atan2(f.ux, -f.uy)) AS angle,
                  (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_' || f.k || '_width')::double precision / g.cell AS width
             FROM g
            CROSS JOIN LATERAL public.rpg_map_fords(g.x0 * g.cell, g.y0 * g.cell, (g.x0 + g.cols) * g.cell, (g.y0 + g.rows) * g.cell,
                                                    CASE WHEN g.level = 5 THEN ARRAY[3] ELSE ARRAY[3, 4] END) f
            WHERE g.level IN (5, 6)
              AND EXISTS (SELECT 1 FROM rv WHERE rv.k IN (3, 4) AND rv.d <= 0.7 AND (rv.k = 3 OR g.level = 6)))
    SELECT (SELECT jsonb_agg(q.piece ORDER BY q.class DESC, q.n, q.run)
              FROM (SELECT pc.n, pc.class, pc.run, jsonb_build_array(pc.class) || jsonb_agg(e.val ORDER BY pc.o, e.i) AS piece
                      FROM pc CROSS JOIN g
                     CROSS JOIN LATERAL (VALUES (1, round(pc.u * 1000 / g.sub)::integer), (2, round(pc.v * 1000 / g.sub)::integer)) AS e(i, val)
                     GROUP BY pc.n, pc.class, pc.run
                    HAVING count(*) >= 4) q),
           (SELECT jsonb_agg(q.e ORDER BY q.o, q.k, q.x, q.y)
              FROM (SELECT 1 AS o, xs.k, xs.xu AS x, xs.xv AS y,
                           jsonb_build_array(public.rpg_map_crossing_kind(xs.class, xs.k, xs.a, xs.b), xs.k, xs.class,
                                             round(xs.xu * 1000 / g.sub)::integer, round(xs.xv * 1000 / g.sub)::integer,
                                             round(degrees(atan2(xs.nv - xs.v, xs.nu - xs.u)))::integer, round(xs.width * 1000 / g.sub)::integer) AS e
                      FROM xs CROSS JOIN g
                     -- in the block, or close enough outside it that its bar (half the water and a little more) reaches
                     -- in; the cell of the block nearest to it must be shown
                     CROSS JOIN LATERAL (SELECT least(greatest(floor(xs.xu)::integer, 0), g.cols - 1) AS cu, least(greatest(floor(xs.xv)::integer, 0), g.rows - 1) AS cv) nc
                     WHERE xs.xu BETWEEN -(xs.width / 2 + 0.3) AND g.cols + xs.width / 2 + 0.3
                       AND xs.xv BETWEEN -(xs.width / 2 + 0.3) AND g.rows + xs.width / 2 + 0.3
                       AND g.shown ? ((g.x0 + nc.cu) || ',' || (g.y0 + nc.cv))
                    UNION ALL
                    SELECT 2, pf.k, pf.xu, pf.xv,
                           jsonb_build_array(3, pf.k, 0, round(pf.xu * 1000 / g.sub)::integer, round(pf.xv * 1000 / g.sub)::integer, round(pf.angle)::integer, round(pf.width * 1000 / g.sub)::integer)
                      FROM pf CROSS JOIN g
                     WHERE floor(pf.xu) BETWEEN 0 AND g.cols - 1 AND floor(pf.xv) BETWEEN 0 AND g.rows - 1
                       AND g.shown ? ((g.x0 + floor(pf.xu)::integer) || ',' || (g.y0 + floor(pf.xv)::integer))) q)
      INTO v_roads, v_cross;
  END IF;

  -- (step 3) the District grid's streets: the market places, streets and lanes inside its towns and cities, saved with
  -- its buildings (rpg_map_district_buildings, notes: streets), drawn among the roads as pieces [4 the market place,
  -- its width, x0, y0, ...] and [5 a street or 6 a lane, x0, y0, ...] in thousandths of a District cell (road_width
  -- carries the width of a street and a lane), cut where they leave the cells the kids login has found
  IF v_l.level = 6 AND v_hlist IS NOT NULL THEN
    WITH sv AS (SELECT m.notes -> 'streets' AS j
                  FROM public.rpg_map_cache_grids(6, v_x0, v_y0, v_cols, v_rows) g
                  JOIN public.rpg_map_cache m ON m.level = 6 AND m.gx = g.gx AND m.gy = g.gy LIMIT 1),
         sl AS (SELECT e.v, e.o, (e.v ->> 0)::integer AS class, (e.v ->> 1)::double precision AS half
                  FROM sv CROSS JOIN LATERAL jsonb_array_elements(coalesce(sv.j, '[]'::jsonb)) WITH ORDINALITY AS e(v, o)),
         sp AS (SELECT sl.o, sl.class, sl.half, k.i, (sl.v ->> (2 * k.i + 2))::double precision AS x, (sl.v ->> (2 * k.i + 3))::double precision AS y
                  FROM sl CROSS JOIN LATERAL generate_series(0, (jsonb_array_length(sl.v) - 2) / 2 - 1) AS k(i)),
         sk AS (SELECT sp.*, v_gm OR coalesce(v_shown, '{}'::jsonb) ? (floor(sp.x / v_l.cell)::bigint || ',' || floor(sp.y / v_l.cell)::bigint) AS ok FROM sp),
         sr AS (SELECT sk.*, sum(CASE WHEN sk.ok THEN 0 ELSE 1 END) OVER (PARTITION BY sk.o ORDER BY sk.i) AS run FROM sk)
    SELECT coalesce(v_roads, '[]'::jsonb) || coalesce(jsonb_agg(q.piece ORDER BY q.class, q.o, q.run), '[]'::jsonb) INTO v_roads
      FROM (SELECT sr.o, sr.class, sr.run,
                   CASE WHEN sr.class = 4 THEN jsonb_build_array(4, round(2 * sr.half * 1000 / v_l.cell)::integer) ELSE jsonb_build_array(sr.class) END
                   || jsonb_agg(v.c ORDER BY sr.i, v.n) AS piece
              FROM sr CROSS JOIN LATERAL (VALUES (1, round((sr.x - v_gx0) * 1000 / v_l.cell)::integer), (2, round((sr.y - v_gy0) * 1000 / v_l.cell)::integer)) AS v(n, c)
             WHERE sr.ok GROUP BY sr.o, sr.class, sr.half, sr.run HAVING count(*) >= 4) q;
  END IF;

  IF p_place IS NULL THEN
    SELECT jsonb_agg(CASE WHEN l.level = 1 THEN jsonb_build_object('label', l.name, 'view', NULL)
                          ELSE jsonb_build_object(
                            'label', l.name || ' ' || public.rpg_square_name(mod(v_x / (u.cell / v_up_cell), u.cols) + 1, mod(v_y / (u.cell / v_up_cell), u.rows) + 1),
                            'view', l.level::text || '-' || (v_x / (u.cell / v_up_cell))::text || '-' || (v_y / (u.cell / v_up_cell))::text) END
                     ORDER BY l.level)
      INTO v_crumbs
      FROM public.rpg_map_ladder() l LEFT JOIN public.rpg_map_ladder() u ON u.level = l.level - 1
     WHERE l.level <= v_l.level;
  ELSE
    -- a place shown whole: the world, the lands that hold its middle (the smallest of each kind, biggest kind first),
    -- then the place
    SELECT jsonb_build_array(jsonb_build_object('label', (SELECT l.name FROM public.rpg_map_ladder() l WHERE l.level = 1), 'view', NULL))
           || coalesce(jsonb_agg(jsonb_build_object('label', q.name, 'view', public.rpg_map_place_link(q.id)) ORDER BY q.place_level), '[]'::jsonb)
           || jsonb_build_array(jsonb_build_object('label', v_pname, 'view', 'p-' || p_place::text))
      INTO v_crumbs
      FROM (SELECT DISTINCT ON (c.place_level) c.id, c.name, c.place_level
              FROM public.rpg_creatures c
             WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
               AND c.place_penalty IS NULL AND c.place_level < v_plevel
               AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id))
               AND public.rpg_map_covers(v_pcx::double precision, v_pcy::double precision, c.place_x, c.place_y, c.place_w, c.place_h, v_world)
             ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;
  END IF;

  v_scale := public.rpg_map_length_text(v_cols::numeric * v_l.cell)
          || CASE WHEN v_l.level = 1 AND p_place IS NULL THEN ' around. Each cell is '
                  WHEN v_l.level = v_last THEN ' across. Each square is '
                  ELSE ' across. Each cell is ' END
          || public.rpg_map_length_text(v_l.cell) || '.';

  SELECT jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'color', c.color, 'icon', c.place_icon,
           'ground', CASE WHEN c.place_penalty IS NOT NULL THEN public.rpg_map_band_text('place', c.id) END,
           'size', CASE WHEN c.place_w = c.place_h THEN public.rpg_map_length_text(c.place_w) || ' across'
                        ELSE public.rpg_map_length_text(c.place_w) || ' by ' || public.rpg_map_length_text(c.place_h) END,
           'about', CASE WHEN v_gm OR c.id = ANY (v_known) THEN c.lore END,
           'inside', (SELECT p.name FROM public.rpg_creatures p WHERE p.id = c.parent_id AND p.place_w IS NOT NULL),
           'level', f.name,
           'view', public.rpg_map_place_link(c.id),
           'listed', c.place_level = v_list_level
                     AND CASE WHEN p_place IS NOT NULL
                              -- a place shown whole lists the places one level down whose middle lies inside it
                              THEN public.rpg_map_covers(c.place_x::double precision, c.place_y::double precision, v_pcx, v_pcy, v_pw, v_ph, v_world)
                              ELSE public.rpg_map_touches(v_gx0::double precision, v_gy0::double precision, v_gx1::double precision, v_gy1::double precision,
                                                          c.place_x, c.place_y, c.place_w, c.place_h, v_world)
                                   -- a place with ground whose natural edge reaches past its oval into this grid
                                   OR (c.place_penalty IS NOT NULL AND EXISTS (SELECT 1 FROM public.rpg_map_within(c.id, v_l.level, v_x0, v_y0, v_cols, v_rows))) END,
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
   WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
     AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id));

  SELECT coalesce(jsonb_agg(q.name ORDER BY q.place_level), '[]'::jsonb)
    INTO v_within
    FROM (SELECT DISTINCT ON (c.place_level) c.place_level, c.name
            FROM public.rpg_creatures c
           WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL
             AND c.place_penalty IS NULL AND c.place_level <= coalesce(v_plevel - 1, v_l.level)
             AND (v_gm OR c.id = ANY (v_known) OR public.rpg_map_place_seen(c.id))
             -- the middle of this grid; for a place shown whole, the middle of the place
             AND public.rpg_map_covers(coalesce(v_pcx, (v_gx0 + v_gx1) / 2.0::double precision), coalesce(v_pcy, (v_gy0 + v_gy1) / 2.0::double precision),
                                       c.place_x, c.place_y, c.place_w, c.place_h, v_world)
           ORDER BY c.place_level, c.place_w::bigint * c.place_h, c.id) q;

  SELECT jsonb_build_object('title', q.title, 'empty', 'No ' || lower(q.title) || ' named here yet.')
    INTO v_list
    FROM (SELECT CASE WHEN l.name LIKE '%y' THEN left(l.name, -1) || 'ies' ELSE l.name || 's' END AS title
            FROM public.rpg_map_ladder() l WHERE l.level = v_list_level) q;

  SELECT jsonb_object_agg(g.kind, jsonb_strip_nulls(jsonb_build_object('name', g.name, 'penalty', public.rpg_map_band_text(g.kind))))
    INTO v_grounds
    FROM public.rpg_map_grounds() g;

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
                      -- under the ground (step 12d2)
                      'under', CASE WHEN p.under_at IS NOT NULL THEN public.rpg_map_under_where(p.under_at, p.under_to, p.under_done) END,
                      'ways', CASE WHEN p.under_at IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN CASE WHEN p.under_to IS NULL
                                             THEN (SELECT jsonb_agg(jsonb_build_array(w.to_node,
                                                                      public.rpg_map_under_way_words(w.kind, w.skind, w.up, w.metres,
                                                                                                     public.rpg_ticks_at(public.rpg_participant_speed(p.id), w.base),
                                                                                                     w.to_name, w.to_depth, w.to_sea))
                                                                    ORDER BY w.metres)
                                                     FROM public.rpg_map_under_ways(p.under_at, false, NULL) w)
                                             ELSE jsonb_build_array(jsonb_build_array(p.under_to, 'Go on to ' || (SELECT n.name FROM public.rpg_map_under_node(p.under_to) n)),
                                                                    jsonb_build_array(p.under_at, 'Go back to ' || (SELECT n.name FROM public.rpg_map_under_node(p.under_at) n))) END END,
                      'mouth', CASE WHEN p.under_at LIKE 'mouth:%' AND p.under_to IS NULL THEN true END,
                      -- (storeys step) the floor of a house it stands on, and the stair it can take on its turn
                      'floor', CASE WHEN p.floor > 0 THEN p.floor END,
                      'stair', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                    THEN public.rpg_stair_ways(p.id) END,
                      'search', CASE WHEN p.under_to IS NULL AND (p.under_at LIKE 'deep-%' OR p.under_at LIKE 'cave-%') THEN true END,
                      'cave', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN (SELECT c.name FROM public.rpg_map_under_cave_at(p.pos_x, p.pos_y) c) END,
                      'spot', CASE WHEN q.bx >= v_gx0 AND q.bx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN jsonb_build_array(((q.bx - v_gx0) * 1000 + 500) / v_l.cell, ((q.sy - v_gy0) * 1000 + 500) / v_l.cell) END,
                      'cell', CASE WHEN q.bx >= v_gx0 AND q.bx < v_gx1 AND q.sy >= v_gy0 AND q.sy < v_gy1
                                   THEN public.rpg_square_name(((q.bx - v_gx0) / v_l.cell + 1)::integer, ((q.sy - v_gy0) / v_l.cell + 1)::integer) END,
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
              -- sx, sy = the square it stands on, counted from 0; bx = that square counted the way this block counts
              -- round the world, for a block that runs past the east or west end
              CROSS JOIN LATERAL (SELECT p.pos_x::bigint - 1 AS sx, p.pos_y::bigint - 1 AS sy,
                                         p.pos_x::bigint - 1 + v_world::bigint * ceil((v_gx0 - p.pos_x::bigint + 1)::numeric / v_world)::bigint AS bx) q
              CROSS JOIN (SELECT public.rpg_setting('walk_day_hours')::integer * public.rpg_setting('ticks_per_hour')::integer AS day) d
              WHERE p.session_id = s.id
                AND (v_gm OR p.creature_id IS NULL
                     OR EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                 WHERE o.session_id = s.id AND o.creature_id IS NULL AND o.pos_x IS NOT NULL AND p.pos_x IS NOT NULL
                                   AND public.rpg_square_gap(o.pos_x, o.pos_y, p.pos_x, p.pos_y) <= public.rpg_setting('sight_squares')))), '[]'::jsonb),
           'can_join', CASE WHEN NOT v_gm THEN '[]'::jsonb ELSE coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) ORDER BY c.name)
                                   FROM public.rpg_characters c
                                  WHERE c.is_active AND NOT c.is_npc AND c.session_id IS NULL
                                    AND NOT EXISTS (SELECT 1 FROM public.rpg_session_participants o
                                                     WHERE o.session_id = s.id AND o.character_id = c.id)), '[]'::jsonb) END)
    INTO v_journey
    FROM public.rpg_sessions s
   WHERE s.on_map AND s.status <> 'ended'
   ORDER BY s.created_at DESC LIMIT 1;

  -- (step 14f2) the rivers inside the cells of the grid above that this read worked out (rpg_map_drain_cell, kept for
  -- the transaction, listed in rpg.dc_new by 'grid:x,y': rivers inside Continent cells, streams inside Country cells and brooks
  -- inside Region cells, step 14f3) are saved on the saved map's row of that grid (notes: rivers, by cell), where it
  -- has one, so the next read finds them there instead of working them out again
  SELECT jsonb_object_agg(u.k, current_setting('rpg.dc_' || replace(replace(u.k, ':', '_'), ',', '_'), true)::jsonb) INTO v_dcell
    FROM unnest(string_to_array(nullif(current_setting('rpg.dc_new', true), ''), ' ')) AS u(k);
  IF v_dcell IS NOT NULL AND v_dcell <> '{}'::jsonb THEN
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('rivers', coalesce(m.notes -> 'rivers', '{}'::jsonb) || n.add)
      FROM (SELECT split_part(e.k, ':', 1)::integer - 1 AS lv, split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx,
                   split_part(e.k, ',', 2)::integer / 12 AS gy, jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_dcell) AS e(k, v) GROUP BY 1, 2, 3) n
     WHERE m.level = n.lv AND m.gx = n.gx AND m.gy = n.gy
       AND NOT coalesce(m.notes -> 'rivers', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
  END IF;

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', coalesce(v_pname, v_l.name), 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN p_place IS NOT NULL THEN 'p-' || p_place::text
                 WHEN v_slid THEN 's-' || v_x0::text || '-' || v_y0::text
                 WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_cols, 'rows', v_rows, 'origin', jsonb_build_array(v_x0, v_y0), 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves, 'slides', v_slides,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'towns', coalesce(v_towns, '[]'::jsonb), 'roads', coalesce(v_roads, '[]'::jsonb), 'road_width', v_rw,
    'crossings', coalesce(v_cross, '[]'::jsonb),
    -- the rivers drawn as lines on the grid (step 14c): [size, x1, y1, x2, y2] in thousandths of a cell from the first cell
    'river_lines', v_rlines,
    'houses', CASE WHEN v_hpend THEN NULL ELSE coalesce(v_houses, '[]'::jsonb) END, 'houses_pending', v_hpend,
    'landmarks', coalesce(v_lands, '[]'::jsonb),
    'under', v_under,
    -- (storeys step) the upper floors of the houses on the battle grid: [floor, x, y, part] (part wall, masonry, inner,
    -- floor or stair; floor 1 is the first floor up)
    'floors', v_floors,
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

REVOKE ALL ON FUNCTION public.rpg_stair_ways(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_stair_ways(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_act_stair(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_act_stair(uuid, integer) TO authenticated, service_role;

-- the rule card Moving: one passage before who blocks a square, in place
UPDATE public.rpg_rules
   SET body = replace(body, $a$Nobody can step into a square someone stands in.$a$,
                      $a$A house of two storeys or more has a stair. Standing on it, going up to the floor above takes 26 base ticks and going down 22 (people on a stair cover about half a metre a second up it and 0.6 down, and a stair runs 2.2 m), more than a turn of moving, so like a thicket it is the first move of a turn. Up there the floorboards and the stair are walked like plain ground; nobody walks through a wall or out into the air. Nothing reaches between two floors: a floor or a ceiling is in the way. On a journey the stair takes no time.
*Zaboo (Speed 5) goes up in 26 × 20 ÷ 15 = 35 ticks, Karen (Speed 1) in 26 × 20 ÷ 11 = 47.*

Nobody can step into a square someone stands in.$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('A house of two storeys or more has a stair' in body) = 0;

NOTIFY pgrst, 'reload schema';

