-- Roleplaying world map step 14f-battle (Peter 2026-10-08 18:52, 1A: more detail on the battle grid, things lying on the
-- ground by terrain that also count in a fight). rpg_map_lie is the one rule of what lies on a battle grid square: a boulder
-- on hills (2 in 100) and mountains (6 in 100), nobody steps into it, full cover; a fallen log in forest, pine forest and
-- jungle (3 in 100, Harmon et al. 1986), +100% time, half cover; reeds at a river's or a lake's edge, drawn only.
-- rpg_map_costs reads it (new column lie) for the percent; rpg_fight_squares and rpg_fight_square pass it on (a boulder no
-- way in); rpg_cover reads the square beside a target on the way to the attacker; rpg_act refuses a physical blow past a
-- boulder and sends a landed blow into a log when its die is in the lower half of the dice that land; rpg_map_view_block
-- gives each battle grid square its lie for the Maps tab. Rule cards Moving and Land, Block, Hit gain a passage each.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'map_boulder_hills_share', 2, 'Battle grid (step 14f-battle): boulders on hills, in 100 squares (no way through; full cover)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_boulder_mountains_share', 6, 'Battle grid (step 14f-battle): boulders on mountains, in 100 squares (no way through; full cover)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_log_share', 3, 'Battle grid (step 14f-battle): fallen logs in forest, pine forest and jungle, in 100 squares (a few in 100 of a forest floor, Harmon et al. 1986)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_log_penalty', 100, 'Battle grid (step 14f-battle): percent of time a fallen log adds to its square (+100%: climbed over, twice as long)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_shore_reed_share', 50, 'Battle grid (step 14f-battle): reeds on dry squares at the edge of a river or a lake, in 100 (drawn only)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_lie(p_kind text, p_shore boolean, p_x integer, p_y integer)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What lies on one square of the battle grid (step 14f-battle, Peter 2026-10-08 18:52, 1A), the one home of it, by its
-- ground and one fixed d100 of the square (rpg_map_roll, layer 1801), so nothing is stored:
--   boulder  hills (map_boulder_hills_share, 2 in 100 squares) and mountains (map_boulder_mountains_share, 6): a rock
--            higher than a person. Nobody walks into it, and a fighter just behind one from the attacker is in full
--            cover (rpg_cover).
--   log      forest, pine forest and jungle (map_log_share, 3 in 100: fallen trunks cover a few in 100 of the floor of
--            a forest, Harmon et al. 1986, Ecology of coarse woody debris in temperate ecosystems). It adds
--            map_log_penalty (+100%) to the time the square takes, and a fighter just behind one from the attacker is
--            in half cover (rpg_cover).
--   reeds    dry ground at the edge of a river or a lake (p_shore), unless desert or snow and ice (map_shore_reed_share,
--            50 in 100). Drawn only.
-- rpg_map_costs reads it for every battle grid square it may lie on (not a road, a town, a place, a building or a cliff).
SELECT CASE
         WHEN p_kind = 'hills' AND r.d <= s.bh THEN 'boulder'
         WHEN p_kind = 'mountains' AND r.d <= s.bm THEN 'boulder'
         WHEN p_kind IN ('forest', 'pine', 'jungle') AND r.d <= s.lg THEN 'log'
         WHEN p_shore AND p_kind NOT IN ('desert', 'ice', 'sea', 'water', 'deep') AND r.d > 100 - s.rd THEN 'reeds'
       END
  FROM (SELECT public.rpg_map_roll((SELECT st.value FROM public.rpg_settings st WHERE st.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st.key = 'map_seed')::integer,
                                   1801, p_x, p_y) AS d) r
 CROSS JOIN (SELECT max(st.value) FILTER (WHERE st.key = 'map_boulder_hills_share') AS bh,
                    max(st.value) FILTER (WHERE st.key = 'map_boulder_mountains_share') AS bm,
                    max(st.value) FILTER (WHERE st.key = 'map_log_share') AS lg,
                    max(st.value) FILTER (WHERE st.key = 'map_shore_reed_share') AS rd
               FROM public.rpg_settings st WHERE st.agency_id = '126794dd-25ff-47d2-a436-724499733365') s;
$function$;

DROP FUNCTION IF EXISTS public.rpg_fight_square(uuid, integer, integer);
DROP FUNCTION IF EXISTS public.rpg_fight_squares(uuid, integer, integer, integer, integer);
DROP FUNCTION IF EXISTS public.rpg_map_costs(integer, integer, integer, integer, integer);
CREATE OR REPLACE FUNCTION public.rpg_map_costs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[], penalty integer, forest boolean, hard double precision, lie text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A block of cells of any grid with what each costs to cross: the cell as rpg_map_cells gives it, how hard it is inside
-- its ground (rpg_map_hard; nothing on a grid coarser than the City grid), and from those the percent of time it adds
-- (rpg_map_pct on its ground's range, rpg_map_band, read once a ground) and whether it is forest. Shallow water goes by
-- its depth instead (rpg_map_flow, rpg_map_wade_pct), and its hard is how deep it is, up to swimming depth (deep
-- water 1), so deeper water is drawn darker. Deep water is swum (step 7b): map_swim_pct (170), except on the battle
-- grid where it pulls too hard to swim (rpg_map_swim_difficulty: none). penalty = that percent; nothing for the sea and
-- water too rough to swim. On the battle grid a mountain square that is a cliff (rpg_map_steep, rpg_map_cliff_angle;
-- step 7c) is climbed: its percent is the climb's (rpg_map_climb: 60 degrees +2,688%) and its hard is 1, the darkest.
-- A square a house stands on (rpg_map_building_cells; step 8c) is climbed too: its wall's or roof's percent (a wall
-- 2.6 m to the eaves +3,644%, a roof square at 50 degrees +1,818%); the ground under it keeps its kind and how hard it
-- is, and the sea stays the sea. So is a square a landmark stands on (step 12b2): a castle wall 13 m high, sheer.
-- On the battle grid (step 14f-battle) what lies on a square (rpg_map_lie; lie): a boulder no way in (no percent), a
-- fallen log map_log_penalty (+100%) on top of its ground's percent, reeds at a river's or a lake's edge nothing; only on
-- ground of its own, not a road, a town, a place, a building or a cliff.
-- The one way a block of the map is read with its costs: fight boards (rpg_fight_squares) and the Maps tab
-- (rpg_map_view_block).
WITH c AS MATERIALIZED (SELECT * FROM public.rpg_map_cells(p_level, p_x0, p_y0, p_cols, p_rows)),
     h AS MATERIALIZED (SELECT * FROM public.rpg_map_hard(p_level, p_x0, p_y0, p_cols, p_rows)),
     -- the water's depth and pull only when the block holds water shallow enough to wade, or deep water on the battle
     -- grid (deep water is shaded full; on a coarser grid it is the average swim)
     wt AS MATERIALIZED (SELECT w.x, w.y, w.depth, w.current FROM public.rpg_map_flow(p_level, p_x0, p_y0, p_cols, p_rows) w
                          WHERE EXISTS (SELECT 1 FROM c WHERE c.kind = 'water' OR (p_level = 7 AND c.kind = 'deep'))),
     -- cliffs: on the battle grid, only when the block holds mountains
     cl AS MATERIALIZED (SELECT t.x, t.y, m.pct
                           FROM public.rpg_map_steep(p_level, p_x0, p_y0, p_cols, p_rows) t
                          CROSS JOIN LATERAL public.rpg_map_climb(public.rpg_map_cliff_angle(t.steep)) m
                          WHERE p_level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'mountains')),
     -- houses: on the battle grid, only when the block holds the ground of a village, town or city, or of a place, or a
     -- landmark stands on it (step 12b2)
     bd AS MATERIALIZED (SELECT b.x, b.y, b.pct FROM public.rpg_map_building_cells(p_level, p_x0, p_y0, p_cols, p_rows) b
                          WHERE p_level = 7 AND (EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))
                                                 OR EXISTS (SELECT 1 FROM public.rpg_map_landmark_cells(p_level, p_x0, p_y0, p_cols, p_rows)))),
     -- what lies on each square (step 14f-battle): the battle grid only; the shore is dry ground beside a river's or a
     -- lake's water
     li AS MATERIALIZED (
       SELECT c.x, c.y, public.rpg_map_lie(c.kind, EXISTS (SELECT 1 FROM c n WHERE n.kind IN ('water', 'deep') AND abs(n.x - c.x) + abs(n.y - c.y) = 1), c.x, c.y) AS lie
         FROM c
        WHERE p_level = 7 AND c.kind IN ('hills', 'mountains', 'forest', 'pine', 'jungle', 'land', 'plains', 'swamp', 'tundra')),
     lp AS (SELECT s.value::integer AS pen FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_log_penalty'),
     sw AS (SELECT s.value::double precision AS swim FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth'),
     b AS MATERIALIZED (SELECT k.kind, k.place_id, r.low, r.high, r.thicket, r.share, r.forest
                          FROM (SELECT DISTINCT c.kind, c.place_id FROM c) k
                          LEFT JOIN LATERAL public.rpg_map_band(k.kind, k.place_id) r ON true)
SELECT c.x, c.y, c.kind, c.place_id, c.marks,
       CASE WHEN bd.x IS NOT NULL AND c.kind <> 'sea' THEN bd.pct
            WHEN c.kind = 'water' THEN public.rpg_map_wade_pct(wt.depth)
            WHEN c.kind = 'deep' THEN CASE WHEN wt.x IS NOT NULL AND public.rpg_map_swim_difficulty(wt.current) IS NULL THEN NULL
                                           ELSE public.rpg_map_wade_pct(coalesce(wt.depth, sw.swim)) END
            WHEN c.kind = 'mountains' AND cl.x IS NOT NULL THEN cl.pct
            WHEN li.lie = 'boulder' THEN NULL
            ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard) + CASE WHEN li.lie = 'log' THEN lp.pen ELSE 0 END END,
       coalesce(b.forest, false),
       CASE WHEN c.kind IN ('water', 'deep') THEN least(coalesce(wt.depth, sw.swim) / sw.swim, 1)
            WHEN c.kind = 'mountains' AND cl.x IS NOT NULL THEN 1 ELSE h.hard END,
       CASE WHEN bd.x IS NULL AND cl.x IS NULL AND c.place_id IS NULL THEN li.lie END
  FROM c
 CROSS JOIN sw
 CROSS JOIN lp
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
  LEFT JOIN cl ON cl.x = c.x AND cl.y = c.y
  LEFT JOIN bd ON bd.x = c.x AND bd.y = c.y
  LEFT JOIN li ON li.x = c.x AND li.y = c.y AND bd.x IS NULL AND cl.x IS NULL AND c.place_id IS NULL
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
$function$;

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
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     ly AS MATERIALIZED (SELECT l.under_at, l.under_to FROM s CROSS JOIN LATERAL public.rpg_fight_layer(p_session_id, p_x0 + p_w / 2, p_y0 + p_h / 2) l
                          WHERE s.on_map AND l.under_at IS NOT NULL),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.penalty, c.forest, c.lie
                          FROM s CROSS JOIN LATERAL public.rpg_map_costs(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map AND NOT EXISTS (SELECT 1 FROM ly)),
     u AS MATERIALIZED (SELECT q.x + 1 AS x, q.y + 1 AS y, q.pct
                          FROM ly CROSS JOIN LATERAL public.rpg_map_under_squares(p_x0 - 1, p_y0 - 1, p_w, p_h, public.rpg_map_under_layer(ly.under_at, ly.under_to)) q),
     z AS (SELECT EXISTS (SELECT 1 FROM ly) AS under)
SELECT g.x, g.y,
       CASE WHEN z.under THEN CASE WHEN u.pct IS NULL THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE u.pct END
            WHEN m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL) OR m.lie = 'boulder' THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(m.penalty, i.penalty) END,
       coalesce(m.forest, false) OR i.forest, i.burning,
       CASE WHEN z.under THEN u.pct IS NULL ELSE coalesce(m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL) OR m.lie = 'boulder', false) END,
       CASE WHEN NOT z.under THEN m.lie END
  FROM s CROSS JOIN z CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
  LEFT JOIN u ON u.x = g.x AND u.y = g.y
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_square(p_session_id uuid, p_x integer, p_y integer)
 RETURNS TABLE(penalty integer, forest boolean, burning boolean, sea boolean, lie text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- One square of a fight: rpg_fight_squares for a block of one.
SELECT f.penalty, f.forest, f.burning, f.sea, f.lie FROM public.rpg_fight_squares(p_session_id, p_x, p_y, 1, 1) f;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_cover(p_attacker uuid, p_target uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cover a target has from an attacker on the fight grid (step 14f-battle, Peter 2026-10-08 18:52, 1A), the one
-- home of it: what lies on the square right beside the target on the way to the attacker, the first square the
-- straight line from the target to the attacker passes (target C3, attacker H5: 5 across and 2 down, so one across
-- and 2/5 of one down, rounded: D3), read on the world map under the fight (rpg_fight_square, rpg_map_lie):
-- 'full' behind a boulder, 'half' behind a fallen log, null otherwise. Only from two squares or more away: a blow
-- from the square beside reaches over. Read by rpg_act: a physical blow cannot be aimed past full cover, and a blow
-- that lands on half cover strikes the log when its die is in the lower half of the dice that land.
SELECT CASE (SELECT f.lie FROM public.rpg_sessions s
              CROSS JOIN LATERAL public.rpg_fight_square(s.id, t.pos_x + round(sign(a.pos_x - t.pos_x) * least(abs(a.pos_x - t.pos_x)::numeric / greatest(abs(a.pos_x - t.pos_x), abs(a.pos_y - t.pos_y)), 1))::integer,
                                                       t.pos_y + round(sign(a.pos_y - t.pos_y) * least(abs(a.pos_y - t.pos_y)::numeric / greatest(abs(a.pos_x - t.pos_x), abs(a.pos_y - t.pos_y)), 1))::integer) f
             WHERE s.id = t.session_id)
         WHEN 'boulder' THEN 'full' WHEN 'log' THEN 'half' END
  FROM public.rpg_session_participants a, public.rpg_session_participants t
 WHERE a.id = p_attacker AND t.id = p_target AND a.pos_x IS NOT NULL AND t.pos_x IS NOT NULL
   AND public.rpg_square_gap(a.pos_x, a.pos_y, t.pos_x, t.pos_y) >= 2;
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
-- a village's lanes stay earth.
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
       ft AS MATERIALIZED (SELECT DISTINCT ON (f.x, f.y) f.x, f.y, f.part, f.house
                             FROM (SELECT f.x, f.y, f.part, NULL::text AS house FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                                    WHERE v_l.level = 7 AND f.angle IS NULL
                                   UNION ALL
                                   SELECT b.x, b.y, b.part, b.id FROM public.rpg_map_building_squares(v_l.level, v_x0, v_y0, v_cols, v_rows) b
                                    WHERE v_l.level = 7 AND b.angle IS NULL AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('town', 'place'))) f
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
         (SELECT jsonb_agg(jsonb_build_array(ls.id, ls.rank, ls.kind, ls.x, ls.y, ls.height, ls.across, ls.near)) FROM ls WHERE ls.kind IN ('cave', 'mine'))
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_rsegs, v_rlines, v_lands, v_lmk, v_caves;

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
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

REVOKE ALL ON FUNCTION public.rpg_map_lie(text, boolean, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_lie(text, boolean, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_costs(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_costs(integer, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_fight_squares(uuid, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_fight_squares(uuid, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_fight_square(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_fight_square(uuid, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_cover(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_cover(uuid, uuid) TO service_role;

-- the rule cards Moving and Land, Block, Hit: one passage each, in place
UPDATE public.rpg_rules
   SET body = replace(body, $a$Nobody steps into the sea. A diagonal step costs the same as a straight one.$a$,
                      $a$Nobody steps into the sea. A diagonal step costs the same as a straight one. Things lie on the ground too: about 3 squares in 100 of forest, pine forest and jungle hold a fallen log, +100% more on top of their ground, and about 2 squares in 100 of hills and 6 in 100 of mountains hold a boulder higher than a person, which nobody steps into. Both give cover in a fight (see Land, Block, Hit).$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('Things lie on the ground too' in body) = 0;
UPDATE public.rpg_rules
   SET body = replace(body, $a$*A forest square at +60% takes 5 × 1.6 = 8 base ticks:$a$,
                      $a$*A forest square at +60% with a fallen log on it is +160%: 5 × 2.6 = 13 base ticks at Speed 10. Without the log, a forest square at +60% takes 5 × 1.6 = 8 base ticks:$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('with a fallen log on it is +160%' in body) = 0;
UPDATE public.rpg_rules
   SET body = replace(body, $a$

2. Block:$a$,
                      $a$

Cover: a boulder or a fallen log on the square right beside the target, on the straight way to the attacker, covers them from a blow struck from 2 squares away or more (from the square beside, a blow reaches over). Behind a boulder (full cover) no blow can be aimed at them at all. Behind a log (half cover) a blow that lands strikes the log instead when its die is in the lower half of the dice that land, so only half the landing blows get through, as only half the body is open to them.
*A longbow needing 50 lands on 50 to 100. At someone behind a log, 50 to 74 strike the log, and only 75 or more go on to the Block gate.*

2. Block:$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'attack_gates' AND position('Cover: a boulder or a fallen log' in body) = 0;

SELECT public.rpg_map_cache_clear();
NOTIFY pgrst, 'reload schema';

