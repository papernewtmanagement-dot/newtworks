-- roleplaying map step 12b2: landmarks on the battle grid (Peter 2026-10-06 19:15, 1A: next, before 12c). New
-- rpg_map_landmark_what (the kind and sizes a site rolls), rpg_map_landmark_squares (the shapes), rpg_map_landmark_cells
-- (the squares, climbed; kept for the transaction), rpg_map_climb_words; rpg_map_landmark_make (reads _what),
-- rpg_map_landmark_sites (the battle grid: every rank within reach), rpg_map_landmarks (passes over sites that cannot
-- stand or reach), rpg_map_building_cells (houses and landmarks), rpg_map_costs, rpg_map_walk and rpg_map_view_block
-- (read landmark squares where no settlement is), rpg_climb_check (words); rule card world_map. No drops, no table
-- changes, no new settings.

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_what(p_rank integer, p_rolls integer[])
 RETURNS TABLE(kind text, icon text, words text, pattern text, ends text[], grounds jsonb, height double precision, across double precision)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- What the rolls of a landmark site make it, whatever ground it stands on (step 12b2): the one home of that part of
-- rpg_map_landmark_make. The first roll picks the kind by its share of the rank (rpg_map_landmark_kinds: weight); the
-- third and fourth how tall and how wide, steady from the least to the most of its kind, as many small as big on a
-- doubling scale. Whether it stands at all is rpg_map_landmark_make, by the ground; rpg_map_landmarks reads this first
-- to pass over the sites that could never hold one on any ground, or whose footprint cannot reach a battle grid.
SELECT q.kind, q.icon, q.words, q.pattern, q.ends, q.grounds,
       q.h_low * power(q.h_high / q.h_low, (p_rolls[3] - 0.5) / 100),
       q.w_low * power(q.w_high / q.w_low, (p_rolls[4] - 0.5) / 100)
  FROM (SELECT k.*, sum(k.weight) OVER (ORDER BY k.kind, k.icon) AS cum
          FROM public.rpg_map_landmark_kinds() k WHERE k.rank = p_rank) q
 WHERE (p_rolls[1] - 0.5) / 100 < q.cum
 ORDER BY q.cum LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_squares(p_id text, p_kind text, p_rank integer, p_x bigint, p_y bigint, p_height double precision, p_across double precision, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- The squares of a block of the battle grid that one landmark stands on (step 12b2; Peter 2026-10-06: landmarks at
-- every layer, the battle grid too), the one home of their shapes. p_x, p_y = its middle square; p_height and p_across
-- in metres as rpg_map_landmark_make rolled them. Each square: part (what it is), angle (how steep) and rise (the metres
-- a climber goes up); rpg_map_landmark_cells turns them into the Climbing roll and the time.
--   tower: a solid round tower as wide as the landmark, sheer, its full height.
--   castle (a fortress, a castle, a tower house): a square keep in the middle, 15 in 100 of the width each way, no
--     less than 8 m and no more than 25 m (Rochester keep 21 m, a tower house 8 to 12 m), its full height; round it a
--     curtain wall at the edge, 3.5 m thick round a fortress, 2.5 m round a castle, 1.5 m round a tower house (the
--     barmkin), 45 in 100 of the height of the keep (35 in 100 round a tower house), with one gate 4 m wide on the side a
--     roll picks (part 16, layer 1631 at its middle).
--   castle of the City grid (a motte): a round earth mound, its side as steep as its height over its half-width.
--   ruins: narrower than 10 m, one broken wall through the middle, the way a roll points it (layer 1632); wider, the
--     walls of rooms 4 to 15 m across (a third of the width) inside its round edge, each length of wall between two
--     corners standing or fallen by a roll (layers 1634 and 1635: 55 in 100 stand), each standing to 30 to 100 in 100
--     of the full height (layers 1636 and 1637), so a ruined castle or chapel is a few broken rooms and a ruined city
--     whole streets of them.
--   stones (a stone circle): one stone a square every 4 m round its ring, no fewer than 9 (Castlerigg, 30 m across, has
--     38 stones, Long Meg, 100 m, 59), the first where layer 1632 points, each 60 to 100 in 100 of the full height
--     (layer 1633), near sheer (85 degrees).
--   stone (a standing stone): the stone itself, near sheer, its full height.
--   rock (a boulder): a round boulder, 60 degrees, its full height. cairn: a round heap of stones, 35 degrees.
--   peak: none; a lone peak is a mark on the grids above, its ground is the mountain itself.
WITH k AS MATERIALIZED (
       SELECT s.sq, t.seed, w.span AS world, p_across / 2 / s.sq AS r, p_x + 0.5 AS cx, p_y + 0.5 AS cy,
              mod(mod(p_x, w.span) + w.span, w.span)::integer AS wx
         FROM (SELECT v.value::double precision AS sq FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m') s
        CROSS JOIN public.rpg_map_landmark_lattice() t
        CROSS JOIN (SELECT l.span::bigint AS span FROM public.rpg_map_ladder() l WHERE l.level = 1) w
        WHERE p_kind IS DISTINCT FROM 'peak'),
     -- every square of the block its round edge can reach
     g AS (SELECT gx, gy, gx + 0.5 - k.cx AS dx, gy + 0.5 - k.cy AS dy, sqrt(power(gx + 0.5 - k.cx, 2) + power(gy + 0.5 - k.cy, 2)) AS d,
                  (gx - p_x)::integer AS u, (gy - p_y)::integer AS v
             FROM k
            CROSS JOIN LATERAL generate_series(greatest(p_x0::bigint, floor(k.cx - k.r - 1)::bigint), least((p_x0 + p_cols - 1)::bigint, floor(k.cx + k.r + 1)::bigint)) AS gx
            CROSS JOIN LATERAL generate_series(greatest(p_y0::bigint, floor(k.cy - k.r - 1)::bigint, 0), least((p_y0 + p_rows - 1)::bigint, floor(k.cy + k.r + 1)::bigint)) AS gy),
     -- a castle: its keep, its wall and its gate
     cs AS (SELECT greatest(least(p_across * 0.15, 25), 8) / 2 / k.sq AS kh,
                   greatest(CASE p_rank WHEN 2 THEN 3.5 WHEN 3 THEN 2.5 ELSE 1.5 END / k.sq, 1) AS t,
                   CASE WHEN p_rank = 4 THEN 0.35 ELSE 0.45 END AS wall,
                   2 * pi() * (public.rpg_map_roll(k.seed, 1631, k.wx, p_y::integer) - 0.5) / 100 AS gate, 2 / k.sq AS gw
              FROM k WHERE p_kind = 'castle' AND p_rank BETWEEN 2 AND 4),
     -- ruins: the room size in squares, and the way a lone wall points
     rs AS (SELECT greatest(round(least(15, greatest(4, p_across / 3)) / k.sq), 3)::integer AS s,
                   pi() * (public.rpg_map_roll(k.seed, 1632, k.wx, p_y::integer) - 0.5) / 100 AS th
              FROM k WHERE p_kind = 'ruins'),
     sh AS (
       -- tower, standing stone, boulder, cairn: everything within its round edge (at least its middle square)
       SELECT g.gx, g.gy, CASE p_kind WHEN 'tower' THEN 'tower' WHEN 'stone' THEN 'stone' WHEN 'rock' THEN 'boulder' ELSE 'cairn' END AS part,
              CASE p_kind WHEN 'tower' THEN 90 WHEN 'stone' THEN 85 WHEN 'rock' THEN 60 ELSE 35 END::double precision AS angle, p_height AS rise
         FROM g CROSS JOIN k
        WHERE p_kind IN ('tower', 'stone', 'rock', 'cairn') AND g.d <= greatest(k.r, 0.5)
       UNION ALL
       -- a motte: a round mound
       SELECT g.gx, g.gy, 'mound', degrees(atan(p_height / greatest(k.r * k.sq, 1))), p_height
         FROM g CROSS JOIN k
        WHERE p_kind = 'castle' AND p_rank = 5 AND g.d <= greatest(k.r, 0.5)
       UNION ALL
       -- a castle: the keep, then the curtain wall but for its gate
       SELECT g.gx, g.gy, CASE WHEN abs(g.dx) <= cs.kh AND abs(g.dy) <= cs.kh THEN 'keep' ELSE 'curtain' END, 90,
              CASE WHEN abs(g.dx) <= cs.kh AND abs(g.dy) <= cs.kh THEN p_height ELSE p_height * cs.wall END
         FROM g CROSS JOIN k CROSS JOIN cs
        WHERE (abs(g.dx) <= cs.kh AND abs(g.dy) <= cs.kh)
           OR (g.d <= k.r AND g.d > k.r - cs.t
               AND abs(atan2(sin(atan2(g.dy, g.dx) - cs.gate), cos(atan2(g.dy, g.dx) - cs.gate))) * k.r > cs.gw)
       UNION ALL
       -- ruins narrower than 10 m: one broken wall through the middle
       SELECT g.gx, g.gy, 'ruin', 90, p_height
         FROM g CROSS JOIN k CROSS JOIN rs
        WHERE p_across < 10 AND abs(g.dx * sin(rs.th) - g.dy * cos(rs.th)) <= 0.5 AND abs(g.dx * cos(rs.th) + g.dy * sin(rs.th)) <= greatest(k.r, 0.5)
       UNION ALL
       -- wider ruins: the walls of rooms inside its round edge; a corner stands when either wall through it does
       SELECT q.gx, q.gy, 'ruin', 90, max(q.h)
         FROM (SELECT g.gx, g.gy,
                      CASE WHEN mod(mod(g.u, rs.s) + rs.s, rs.s) = 0
                                AND public.rpg_map_roll(k.seed, 1634, mod(mod(g.gx, k.world) + k.world, k.world)::integer, (p_y + floor(g.v::double precision / rs.s) * rs.s)::integer) <= 55
                           THEN p_height * (0.3 + 0.7 * (public.rpg_map_roll(k.seed, 1636, mod(mod(g.gx, k.world) + k.world, k.world)::integer, (p_y + floor(g.v::double precision / rs.s) * rs.s)::integer) - 0.5) / 100) END AS hv,
                      CASE WHEN mod(mod(g.v, rs.s) + rs.s, rs.s) = 0
                                AND public.rpg_map_roll(k.seed, 1635, mod(mod(p_x + floor(g.u::double precision / rs.s)::bigint * rs.s, k.world) + k.world, k.world)::integer, g.gy::integer) <= 55
                           THEN p_height * (0.3 + 0.7 * (public.rpg_map_roll(k.seed, 1637, mod(mod(p_x + floor(g.u::double precision / rs.s)::bigint * rs.s, k.world) + k.world, k.world)::integer, g.gy::integer) - 0.5) / 100) END AS hh
                 FROM g CROSS JOIN k CROSS JOIN rs
                WHERE p_across >= 10 AND g.d <= k.r) z
        CROSS JOIN LATERAL (VALUES (z.gx, z.gy, z.hv), (z.gx, z.gy, z.hh)) AS q(gx, gy, h)
        WHERE q.h IS NOT NULL
        GROUP BY q.gx, q.gy
       UNION ALL
       -- a stone circle: a stone every 4 m round its ring
       SELECT DISTINCT ON (q.gx, q.gy) q.gx, q.gy, 'stone', 85, q.h
         FROM k
        CROSS JOIN LATERAL generate_series(0, greatest(9, round(2 * pi() * k.r * k.sq / 4)::integer) - 1) AS n
        CROSS JOIN LATERAL (SELECT 2 * pi() * (public.rpg_map_roll(k.seed, 1632, k.wx, p_y::integer) - 0.5) / 100 AS a0,
                                   greatest(9, round(2 * pi() * k.r * k.sq / 4)::integer) AS m) c
        CROSS JOIN LATERAL (SELECT floor(k.cx + k.r * cos(c.a0 + 2 * pi() * n / c.m))::bigint AS gx,
                                   floor(k.cy + k.r * sin(c.a0 + 2 * pi() * n / c.m))::bigint AS gy,
                                   p_height * (0.6 + 0.4 * (public.rpg_map_roll(k.seed, 1633, k.wx + n, p_y::integer) - 0.5) / 100) AS h) q
        WHERE p_kind = 'stones' AND q.gx BETWEEN p_x0 AND p_x0 + p_cols - 1 AND q.gy BETWEEN p_y0 AND p_y0 + p_rows - 1)
SELECT sh.gx::integer, sh.gy::integer, p_id, sh.part, sh.angle, sh.rise FROM sh;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid a landmark stands on (step 12b2): the landmarks whose footprint reaches
-- each battle grid of it (rpg_map_landmarks at the battle grid) and their shapes (rpg_map_landmark_squares), each
-- square climbed by the Climbing rule as a wall or a roof is (Peter 2026-10-03 23:12: any steep surface): a wall, a
-- tower, a keep, a standing stone or a boulder climbs its whole height at once (rpg_map_climb_by: a castle wall 13 m,
-- sheer, difficulty 10), the side of a motte or a cairn one square at a time like rock of its slope (rpg_map_climb).
-- Returns what rpg_map_building_cells returns, which reads it with the houses, so the costs, a climb, where a walk
-- ends, where a creature is set down and the Maps tab all see a landmark the way they see a house.
-- One read of the map asks for the same squares again and again (a walk, a fight board, one square at a time), so each
-- battle grid has its squares kept in a setting of the transaction (rpg.lmcells, by "x,y" of the battle grid) and gone
-- when it ends; nothing is stored.
DECLARE
  v_all jsonb;
  v_new jsonb := '{}';
  v_c jsonb;
  g record;
BEGIN
  IF p_level IS DISTINCT FROM 7 THEN RETURN; END IF;
  v_all := coalesce(nullif(current_setting('rpg.lmcells', true), ''), '{}')::jsonb;
  FOR g IN SELECT a AS gx, b AS gy
             FROM generate_series(floor(p_x0::double precision / 12)::integer, floor((p_x0 + p_cols - 1)::double precision / 12)::integer) AS a
            CROSS JOIN generate_series(floor(p_y0::double precision / 12)::integer, floor((p_y0 + p_rows - 1)::double precision / 12)::integer) AS b LOOP
    IF NOT v_all ? (g.gx || ',' || g.gy) THEN
      SELECT coalesce(jsonb_agg(jsonb_build_array(s.x, s.y, s.id, s.part, s.angle, c.rise, c.difficulty, c.pct)), '[]'::jsonb) INTO v_c
        FROM public.rpg_map_landmarks(7, g.gx * 12, g.gy * 12, 12, 12, NULL) l
       CROSS JOIN LATERAL public.rpg_map_landmark_squares(l.id, l.kind, l.rank, l.x, l.y, l.height, l.across, g.gx * 12, g.gy * 12, 12, 12) s
       CROSS JOIN LATERAL (SELECT b.rise, b.difficulty, b.pct FROM public.rpg_map_climb_by(s.angle, s.rise) b WHERE s.part NOT IN ('mound', 'cairn')
                           UNION ALL
                           SELECT b.rise, b.difficulty, b.pct FROM public.rpg_map_climb(s.angle) b WHERE s.part IN ('mound', 'cairn')) c
       WHERE l.kind IS NOT NULL;
      v_new := v_new || jsonb_build_object(g.gx || ',' || g.gy, v_c);
    END IF;
  END LOOP;
  IF v_new <> '{}'::jsonb THEN
    v_all := v_all || v_new;
    PERFORM set_config('rpg.lmcells', v_all::text, true);
  END IF;
  RETURN QUERY
  SELECT (e ->> 0)::integer, (e ->> 1)::integer, e ->> 2, e ->> 3, (e ->> 4)::double precision, (e ->> 5)::double precision, (e ->> 6)::numeric, (e ->> 7)::integer
    FROM generate_series(floor(p_x0::double precision / 12)::integer, floor((p_x0 + p_cols - 1)::double precision / 12)::integer) AS a
   CROSS JOIN generate_series(floor(p_y0::double precision / 12)::integer, floor((p_y0 + p_rows - 1)::double precision / 12)::integer) AS b
   CROSS JOIN LATERAL jsonb_array_elements(v_all -> (a || ',' || b)) AS e
   WHERE (e ->> 0)::integer BETWEEN p_x0 AND p_x0 + p_cols - 1 AND (e ->> 1)::integer BETWEEN p_y0 AND p_y0 + p_rows - 1;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_climb_words(p_part text, p_angle double precision)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- What a steep square is, in words (step 12b2), the one home of them: the wall or the roof of a house (step 8c), the
-- parts of a landmark (rpg_map_landmark_squares), or a cliff (part nothing). Read by the climb on a move
-- (rpg_climb_check) and by the Maps tab (rpg_map_view_block: the climb of each cell).
SELECT CASE p_part WHEN 'wall' THEN 'the wall of a house' WHEN 'roof' THEN 'a ' || round(p_angle) || '-degree roof'
                   WHEN 'keep' THEN 'the keep of a castle' WHEN 'curtain' THEN 'the wall of a castle' WHEN 'tower' THEN 'a stone tower'
                   WHEN 'ruin' THEN 'a ruined wall' WHEN 'stone' THEN 'a standing stone' WHEN 'boulder' THEN 'a boulder'
                   WHEN 'cairn' THEN 'a cairn' WHEN 'mound' THEN 'the side of a motte'
                   ELSE 'a ' || round(p_angle) || '-degree cliff' END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_make(p_rank integer, p_x bigint, p_y bigint, p_rolls integer[], p_ground text)
 RETURNS TABLE(kind text, icon text, words text, name text, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What stands at a landmark site (rpg_map_landmark_sites), the one home of it (step 12b): a landmark of its rank or
-- nothing, what kind, how tall and how wide, and its name. Worked out when asked, never stored.
-- The first roll picks the kind by its share of the rank (rpg_map_landmark_kinds: weight), and the third and fourth how
-- tall and how wide (both rpg_map_landmark_what, step 12b2); the second says whether it
-- stands, under map_landmark_share_<rank> times how readily that kind stands on p_ground, the ground of the cell of the site
-- on the grid of its rank (as a village is decided by its Region cell), so a landmark is the same seen from any grid.
-- Landmarks of ranks 1 to 4 also need dry land on their own square (rpg_map_heights_on at the battle grid), so none
-- stands in a lake or the sea the coarse cell hides. None stands inside a place with ground of its own (a haunt, Old
-- Forest, Haven) or within its own half-width of one. A landmark of ranks 4 to 6 keeps its footprint off the ground of
-- the village, town or city that could grow at a site near it (rpg_map_site: the biggest such a site can hold,
-- rpg_map_town_radius, its edge out by map_town_edge), so it never stands in a street; a peak only by its summit.
-- height and across: steady rolls from the least to the most of its kind, as many small as big on a doubling scale.
-- name: its pattern with {A}, a word of the uplands by where it stands (so no two near each other share one), and {B},
-- one of its endings by a roll (Storm + horn: Stormhorn; The Raven Stones; Bleak Tor).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     -- what its rolls make it, whatever the ground (rpg_map_landmark_what), and whether it stands on this ground
     sz AS MATERIALIZED (
       SELECT p_rank AS rank, wt.kind, wt.icon, wt.words, wt.pattern, wt.ends, wt.height AS h, wt.across AS w,
              (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision AS sq
         FROM public.rpg_map_landmark_what(p_rank, p_rolls) wt
        WHERE (p_rolls[2] - 0.5) / 100 < (SELECT st.value FROM st WHERE st.key = 'map_landmark_share_' || p_rank)::double precision
                                          * coalesce((wt.grounds ->> p_ground)::double precision, 0)),
     -- dry land under the site (ranks 1 to 4)
     dry AS MATERIALIZED (
       SELECT sz.* FROM sz
        WHERE sz.rank > 4
           OR EXISTS (SELECT 1 FROM (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1) w
                       CROSS JOIN LATERAL public.rpg_map_heights_on(7, 1, mod(mod(p_x, w.span) + w.span, w.span)::integer, p_y::integer, 1, 1) h
                       WHERE h.height >= (SELECT st.value FROM st WHERE st.key = 'map_sea_level'))),
     -- off the ground any village, town or city near it could grow on (ranks 4 to 6)
     tw AS MATERIALIZED (
       SELECT dry.*, CASE WHEN dry.kind = 'peak' THEN 0 ELSE dry.w / dry.sq / 2 END AS r
         FROM dry
        WHERE dry.rank < 4
           OR NOT EXISTS (
                SELECT 1
                  FROM public.rpg_map_lattice() t
                 CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_town_edge')::double precision AS edge) e
                 CROSS JOIN LATERAL generate_series(floor(p_x::double precision / t.lv)::bigint - 1, floor(p_x::double precision / t.lv)::bigint + 1) AS a
                 CROSS JOIN LATERAL generate_series(floor(p_y::double precision / t.lv)::bigint - 1, floor(p_y::double precision / t.lv)::bigint + 1) AS b
                 CROSS JOIN LATERAL public.rpg_map_site(a, b, t.seed, t.lv, t.jit, t.nv, t.nt, t.av, t.at, t.ac) s
                 WHERE sqrt(power(s.x - p_x, 2) + power(s.y - p_y, 2))
                       < CASE WHEN dry.kind = 'peak' THEN 0 ELSE dry.w / dry.sq / 2 END
                         + (1 + e.edge) * CASE WHEN s.city THEN greatest(public.rpg_map_town_radius('city', (SELECT st.value FROM st WHERE st.key = 'map_city_people_high')::integer),
                                                                          public.rpg_map_town_radius('great_city', (SELECT st.value FROM st WHERE st.key = 'map_great_city_people_high')::integer))
                                                WHEN s.town THEN public.rpg_map_town_radius('town', (SELECT st.value FROM st WHERE st.key = 'map_town_people_high')::integer)
                                                ELSE public.rpg_map_town_radius('village', (SELECT st.value FROM st WHERE st.key = 'map_village_people_high')::integer) END)),
     nm AS (SELECT tw.*,
                   -- the word by where its square of its rank lies: a column plus 7 times a row, out of 48, so no two squares
                   -- of a rank within 5 of each other either way share one; the land the landmarks of a grid stand on is 6
                   -- squares of their rank across
                   (ARRAY['Grey', 'Black', 'Raven', 'Eagle', 'Storm', 'Cloud', 'Snow', 'Iron', 'High', 'Old', 'White', 'Red',
                          'Wolf', 'Crow', 'Wind', 'Thunder', 'Frost', 'Stag', 'Hawk', 'Dun', 'Bleak', 'Long', 'Gold', 'Star',
                          'Silver', 'Copper', 'Bright', 'Shadow', 'Ember', 'Ash', 'Bear', 'Boar', 'Fox', 'Owl', 'Heron', 'Falcon',
                          'Moon', 'Sun', 'Dawn', 'Dusk', 'Rain', 'Mist', 'Thorn', 'Bramble', 'Holly', 'Oak', 'Elder', 'King'])
                     [1 + mod(mod(q.qx, 48) + 7 * mod(q.qy, 48), 48)] AS a,
                   tw.ends[1 + mod((p_rolls[5] - 1) * 100 + p_rolls[6] - 1, cardinality(tw.ends))] AS b
              FROM tw
             CROSS JOIN LATERAL (SELECT floor(mod(mod(p_x, t.a6 * t.l6) + t.a6 * t.l6, t.a6 * t.l6)::double precision / (t.l6 * 12 ^ (6 - p_rank)))::bigint AS qx,
                                        floor(p_y::double precision / (t.l6 * 12 ^ (6 - p_rank)))::bigint AS qy
                                   FROM public.rpg_map_landmark_lattice() t) q)
SELECT nm.kind, nm.icon, nm.words,
       replace(replace(replace(nm.pattern, '{A}{B}', CASE WHEN lower(right(nm.a, 1)) = left(nm.b, 1) THEN nm.a || substr(nm.b, 2) ELSE nm.a || nm.b END),
                       '{A} {B}', nm.a || ' ' || nm.b), '{A}', nm.a),
       nm.h, nm.w
  FROM nm
 CROSS JOIN (SELECT w.span FROM public.rpg_map_ladder() w WHERE w.level = 1) l
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_creatures c
                    WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.place_w IS NOT NULL AND c.place_penalty IS NOT NULL
                      AND public.rpg_map_covers(p_x + 0.5::double precision, p_y + 0.5::double precision, c.place_x, c.place_y,
                                                ceil(c.place_w + 2 * nm.r)::integer, ceil(c.place_h + 2 * nm.r)::integer, l.span));
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_sites(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, rank integer, x bigint, y bigint, rolls integer[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a landmark could stand on a block of any grid down to the District grid (step 12b), worked out when asked and
-- never stored: the sites of every rank from 1 (the World grid) down to the rank of the grid itself whose spot lies in
-- the block (rpg_map_landmark_site), each with its rank and its rolls (rpg_map_landmark_rolls). A grid of level L
-- shows the landmarks of ranks 1 to L: few on the world, more at each level down (Peter 2026-10-03 17:28). On the
-- battle grid (step 12b2) a block of squares gets the sites of every rank whose landmark could reach into it: the spot
-- within half the width of the widest landmark of its rank (rpg_map_landmark_kinds), and one square, of the block;
-- whether its own footprint reaches is rpg_map_landmarks. id = mark-<column>-<row> of its rank-6 square, the same seen from any block; x, y =
-- the site in world squares from 0, counted the way the block counts. What stands there is rpg_map_landmark_make.
WITH cfg AS MATERIALIZED (
       SELECT t.*, l.cell::bigint AS cell,
              p_x0::bigint * l.cell AS gx0, (p_x0 + p_cols)::bigint * l.cell AS gx1,
              p_y0::bigint * l.cell AS gy0, (p_y0 + p_rows)::bigint * l.cell AS gy1
         FROM public.rpg_map_landmark_lattice() t CROSS JOIN public.rpg_map_ladder() l
        WHERE l.level = p_level AND p_level BETWEEN 1 AND 7),
     -- how far a site of each rank may stand outside the block: on the battle grid half the width of the widest
     -- landmark of its rank, in squares, and one more; on every other grid nothing
     rr AS (SELECT k.rank AS r, CASE WHEN p_level = 7 THEN ceil(max(k.w_high) / 2 / (SELECT v.value FROM public.rpg_settings v
                                                                                       WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m'))::bigint + 1
                                     ELSE 0 END AS reach
              FROM public.rpg_map_landmark_kinds() k WHERE k.rank <= least(p_level, 6) GROUP BY k.rank),
     -- the squares of each rank the block reaches
     sq AS (SELECT rr.r, rr.reach, a, b
              FROM cfg CROSS JOIN rr
             CROSS JOIN LATERAL generate_series(floor((cfg.gx0 - rr.reach)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint,
                                                floor((cfg.gx1 + rr.reach - 1)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint) AS a
             CROSS JOIN LATERAL generate_series(floor(greatest(cfg.gy0 - rr.reach, 0)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint,
                                                floor((least(cfg.gy1 + rr.reach, cfg.down) - 1)::double precision / (cfg.l6 * (12 ^ (6 - rr.r)))::bigint)::bigint) AS b),
     st AS MATERIALIZED (
       SELECT sq.r, sq.reach, s.w6, s.y6, s.x, s.y
         FROM sq CROSS JOIN cfg
        CROSS JOIN LATERAL public.rpg_map_landmark_site(sq.r, sq.a, sq.b, cfg.seed, cfg.l6, cfg.jit, cfg.a6) s
        WHERE NOT s.picked)
SELECT 'mark-' || st.w6 || '-' || st.y6, st.r, st.x, st.y, public.rpg_map_landmark_rolls(st.w6, st.y6, cfg.seed)
  FROM st CROSS JOIN cfg
 WHERE st.x >= cfg.gx0 - st.reach AND st.x < cfg.gx1 + st.reach AND st.y >= cfg.gy0 - st.reach AND st.y < cfg.gy1 + st.reach;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_landmarks(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_kinds jsonb)
 RETURNS TABLE(id text, rank integer, kind text, icon text, words text, name text, x bigint, y bigint, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The landmarks a block of any grid down to the District grid shows (step 12b): its sites (rpg_map_landmark_sites)
-- and what stands at each (rpg_map_landmark_make), the one way they are read. A landmark is decided by the ground of
-- the cell its site stands in on the grid of its rank, and a landmark of the World grid by its Continent cell (a World
-- cell is 2,075 miles across and mostly reads as sea), so the same site holds the same landmark seen from any grid.
-- Those cells are read through rpg_map_kinds, which keeps them for the rest of the transaction. p_kinds = the kinds of
-- the cells of this very block when the caller already has them ("x,y": kind, as rpg_map_cells counts them), so its
-- own grid is not worked out twice; else nothing. kind is nothing where no landmark stands.
-- A site is passed over before any ground is read (step 12b2) when its second roll could not make it stand on any ground
-- (rpg_map_landmark_what: the most readily it stands anywhere), and on the battle grid (level 7) when its footprint,
-- half its width and one square, cannot reach the block; so the battle grid reads ground only for a landmark that may
-- truly stand on it.
WITH s AS MATERIALIZED (
       SELECT t.*, greatest(t.rank, 2) AS dl
         FROM public.rpg_map_landmark_sites(p_level, p_x0, p_y0, p_cols, p_rows) t
        CROSS JOIN LATERAL public.rpg_map_landmark_what(t.rank, t.rolls) w
        CROSS JOIN (SELECT v.value::double precision AS sq FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m') q
        WHERE (t.rolls[2] - 0.5) / 100 < (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_landmark_share_' || t.rank)::double precision
                                         * (SELECT max(e.value::double precision) FROM jsonb_each_text(w.grounds) e)
          AND (p_level < 7
               OR sqrt(power(greatest(p_x0 - t.x, 0, t.x - (p_x0 + p_cols - 1)), 2) + power(greatest(p_y0 - t.y, 0, t.y - (p_y0 + p_rows - 1)), 2))
                  <= w.across / 2 / q.sq + 1)),
     sc AS MATERIALIZED (
       SELECT s.*, floor(s.x::double precision / l.cell)::integer AS cx, floor(s.y::double precision / l.cell)::integer AS cy, l.across::bigint AS across
         FROM s JOIN public.rpg_map_ladder() l ON l.level = s.dl),
     -- the cells of this block, from the caller or read once
     own AS MATERIALIZED (
       SELECT split_part(e.key, ',', 1)::integer AS x, split_part(e.key, ',', 2)::integer AS y, e.value AS kind
         FROM jsonb_each_text(p_kinds) e
       UNION ALL
       SELECT k.x, k.y, k.kind FROM public.rpg_map_kinds(p_level, p_x0, p_y0, p_cols, p_rows) k
        WHERE p_kinds IS NULL AND p_level BETWEEN 2 AND 6 AND EXISTS (SELECT 1 FROM sc WHERE sc.dl = p_level)),
     -- the cells of coarser grids under the sites of coarser ranks, each read once
     far AS MATERIALIZED (
       SELECT d.dl, d.cx, d.cy, k.kind
         FROM (SELECT DISTINCT sc.dl, sc.cx, sc.cy, sc.across FROM sc WHERE sc.dl <> p_level) d
        CROSS JOIN LATERAL public.rpg_map_kinds(d.dl, mod(mod(d.cx, d.across) + d.across, d.across)::integer, d.cy, 1, 1) k)
SELECT sc.id, sc.rank, m.kind, m.icon, m.words, m.name, sc.x, sc.y, m.height, m.across
  FROM sc
  LEFT JOIN own ON sc.dl = p_level AND own.x = sc.cx AND own.y = sc.cy
  LEFT JOIN far ON far.dl = sc.dl AND far.cx = sc.cx AND far.cy = sc.cy
  LEFT JOIN LATERAL public.rpg_map_landmark_make(sc.rank, sc.x, sc.y, sc.rolls, coalesce(own.kind, far.kind)) m ON true;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_building_cells(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, id text, part text, angle double precision, rise double precision, difficulty numeric, pct integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The squares of a block of the battle grid that a house stands on (step 8c; rpg_map_buildings, the one home of where
-- houses stand): every square whose middle lies inside one. The squares along its edge (within one square of it) are
-- its walls, the rest its roof. Each is a steep surface, climbed by the Climbing rule (rpg_map_climb_by, Peter
-- 2026-10-03 23:12: the climbing rule goes for any steep surface, buildings too): a wall is sheer (90 degrees,
-- difficulty 10) and climbs the house's height to the eaves; a roof square climbs like rock of the roof's pitch, one
-- square's worth (rpg_map_climb: thatch at 50 degrees 1.33 m, difficulty 2.5). angle = how steep, rise = metres
-- climbed, difficulty of the Climbing roll, pct = the percent of time it adds to the square. Ground underneath is
-- whatever rpg_map_cells says (the settlement's streets and yards); the house stands on it, the way a cliff is a steep
-- part of the mountains. The costs of a block (rpg_map_costs), the climb on a move (rpg_climb_check), where a walk may
-- end (rpg_map_walk), where a creature is set down (rpg_map_set_down) and the Maps tab all read it.
-- The squares a landmark stands on come with them (step 12b2; rpg_map_landmark_cells): a castle wall, a keep, a tower, a
-- ruined wall, a standing stone, a boulder, a cairn or the side of a motte, each climbed the same way, its id the
-- id of the landmark (mark-<x>-<y>).
WITH h AS MATERIALIZED (
       SELECT b.*, cw.rise AS w_rise, cw.difficulty AS w_dif, cw.pct AS w_pct, cr.rise AS r_rise, cr.difficulty AS r_dif, cr.pct AS r_pct
         FROM public.rpg_map_buildings(p_level, p_x0, p_y0, p_cols, p_rows) b
        CROSS JOIN LATERAL public.rpg_map_climb_by(90, b.eaves) cw
        CROSS JOIN LATERAL public.rpg_map_climb(b.pitch) cr)
SELECT gx, gy, h.id, CASE WHEN q.wall THEN 'wall' ELSE 'roof' END, CASE WHEN q.wall THEN 90 ELSE h.pitch END,
       CASE WHEN q.wall THEN h.w_rise ELSE h.r_rise END, CASE WHEN q.wall THEN h.w_dif ELSE h.r_dif END, CASE WHEN q.wall THEN h.w_pct ELSE h.r_pct END
  FROM h
 CROSS JOIN LATERAL (SELECT h.half_len * abs(h.ux) + h.half_wide * abs(h.uy) AS ex, h.half_len * abs(h.uy) + h.half_wide * abs(h.ux) AS ey) e
 CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(h.cx - e.ex)::integer), least(p_x0 + p_cols - 1, floor(h.cx + e.ex)::integer)) AS gx
 CROSS JOIN LATERAL generate_series(greatest(p_y0, floor(h.cy - e.ey)::integer), least(p_y0 + p_rows - 1, floor(h.cy + e.ey)::integer)) AS gy
 -- the middle of the square, measured along the house and across it
 CROSS JOIN LATERAL (SELECT (gx + 0.5 - h.cx) * h.ux + (gy + 0.5 - h.cy) * h.uy AS a, (gy + 0.5 - h.cy) * h.ux - (gx + 0.5 - h.cx) * h.uy AS b) l
 CROSS JOIN LATERAL (SELECT abs(l.a) > h.half_len - 1 OR abs(l.b) > h.half_wide - 1 AS wall) q
 WHERE abs(l.a) <= h.half_len AND abs(l.b) <= h.half_wide
UNION ALL
SELECT m.x, m.y, m.id, m.part, m.angle, m.rise, m.difficulty, m.pct
  FROM public.rpg_map_landmark_cells(p_level, p_x0, p_y0, p_cols, p_rows) m;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_costs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, kind text, place_id uuid, marks uuid[], penalty integer, forest boolean, hard double precision)
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
            ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, h.hard) END,
       coalesce(b.forest, false),
       CASE WHEN c.kind IN ('water', 'deep') THEN least(coalesce(wt.depth, sw.swim) / sw.swim, 1)
            WHEN c.kind = 'mountains' AND cl.x IS NOT NULL THEN 1 ELSE h.hard END
  FROM c
 CROSS JOIN sw
  LEFT JOIN h ON h.x = c.x AND h.y = c.y
  LEFT JOIN wt ON wt.x = c.x AND wt.y = c.y
  LEFT JOIN cl ON cl.x = c.x AND cl.y = c.y
  LEFT JOIN bd ON bd.x = c.x AND bd.y = c.y
  LEFT JOIN b ON b.kind = c.kind AND b.place_id IS NOT DISTINCT FROM c.place_id
 ORDER BY c.y, c.x;
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
  v_hour integer; v_d100 integer; v_cell bigint; v_wd double precision; v_wl integer; v_deep integer[]; v_rolls integer[] := '{}'; v_need bigint; v_meet uuid; v_chance integer; v_cp uuid; v_gap integer;
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
          FOR v_hour IN (v_h0 / v_tph) + 1 .. (v_haunt / v_tph) LOOP
            v_d100 := floor(random() * 100)::integer + 1;
            v_rolls := v_rolls || v_d100;
            IF v_d100 <= v_chance THEN
              -- met where that hour ran out: the first step whose time reaches it
              v_need := v_hour::bigint * v_tph - v_h0;
              v_n := least(greatest(ceil(v_need * (v_even + v_speed) / (2 * v_even) * 100 / v_b)::integer, 1), v_n);
              v_haunt := v_h0 + public.rpg_ticks_at(v_speed, (v_base + v_n::bigint * v_b) / 100.0) - v_t0;
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
  IF v_why = 'meet' THEN
    PERFORM set_config('rpg.engine', 'on', true);
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

CREATE OR REPLACE FUNCTION public.rpg_climb_check(p_participant_id uuid, p_x integer, p_y integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The climb when someone moves onto a cliff square on the board (Peter 2026-10-03 23:12: how steep it is sets the
-- challenge; climbing gear adds to the climber's own roll; Climbing with Gear is built on Climbing). Called by
-- rpg_act_square before the piece moves; nothing happens off a cliff (no row: the move goes ahead as it is).
-- The roll: Climbing against the cliff's difficulty (rpg_map_cliff: 60 degrees 4.7). With climbing gear (an item worn
-- or held that adds to Climbing with Gear) they roll Climbing with Gear instead, gear and all. Someone with no open
-- Climbing climbs as skill 0: only a 100 gets them up. A creature's roll is made from its sheet without training it; a
-- character's goes through rpg_roll (it trains).
-- Made it: they climb onto the square. Missed: they slip and fall back to where they started, the height of the square
-- (1.94 m at 60 degrees), and lose (height / climb_fall_down_m, 15 m) squared of their Physical Vitality, at least 1:
-- Karen (41) falling 1.94 m loses 1, falling 6.3 m (80 degrees) loses 8. At 0 they are down. The time of the climb is
-- spent either way.
-- The wall or the roof of a house is climbed the same way (step 8c; rpg_map_building_cells): a wall is sheer, 90
-- degrees, difficulty 10, and climbs the house's height to its eaves (a village house 2.6 m: Karen, Climbing 7, needs
-- 59; a slip drops her 2.6 m, 2 damage); a roof square climbs like rock of the roof's pitch.
-- A landmark is climbed the same way (step 12b2; rpg_map_landmark_cells): the wall of a castle, sheer, its height.
-- Returns {made, text}, or nothing when the square is not a cliff and nothing built stands on it.
DECLARE
  v_p record; v_s record; v_c record; v_key text; v_skill numeric; v_r jsonb; v_nc jsonb; v_roll integer; v_made boolean;
  v_text text; v_gear boolean; v_harm integer := 0; v_roll_id uuid; v_out text; v_max integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.character_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT coalesce(v_s.on_map, false) THEN RETURN NULL; END IF;
  -- a house on the square (step 8c): its wall or its roof; else a mountain cliff
  SELECT b.angle, b.rise, b.difficulty, b.pct, b.part INTO v_c FROM public.rpg_map_building_cells(7, p_x - 1, p_y - 1, 1, 1) b;
  IF NOT FOUND THEN
    SELECT k.angle, k.rise, k.difficulty, k.pct, NULL::text AS part INTO v_c FROM public.rpg_map_cliff(p_x, p_y) k;
    IF NOT FOUND THEN RETURN NULL; END IF;
  END IF;
  v_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'climb_gear')
            AND public.rpg_participant_value(p_participant_id, 'climb_gear') IS NOT NULL;
  v_key := CASE WHEN v_gear THEN 'climb_gear' ELSE 'CL' END;
  v_skill := public.rpg_participant_value(p_participant_id, v_key);
  PERFORM set_config('rpg.engine', 'on', true);
  IF v_p.creature_id IS NULL AND v_skill IS NOT NULL THEN
    v_r := public.rpg_roll(v_p.character_id, v_key, v_c.difficulty, CASE WHEN v_c.part = 'wall' THEN 'Climbing a wall' WHEN v_c.part = 'roof' THEN 'Climbing a roof' WHEN v_c.part IS NULL THEN 'Climbing a cliff'
                                                                          ELSE 'Climbing ' || public.rpg_map_climb_words(v_c.part, v_c.angle) END, NULL, v_s.id, p_participant_id);
    v_roll := (v_r->>'roll')::integer; v_nc := jsonb_build_object('needed', v_r->'needed', 'critical', v_r->'critical'); v_roll_id := (v_r->>'roll_id')::uuid;
  ELSE
    v_nc := public.rpg_needed(coalesce(v_skill, 0), v_c.difficulty);
    v_roll := floor(random() * 100)::integer + 1;
  END IF;
  v_made := v_roll >= (v_nc->>'needed')::numeric;
  v_out := public.rpg_outcome(v_roll, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, false, 0)->>'key';
  v_text := v_p.name || ' climbs ' || public.rpg_map_climb_words(v_c.part, v_c.angle)
         || ', ' || trim_scale(round(v_c.rise::numeric, 1)) || ' m ('
         || CASE WHEN v_gear THEN 'Climbing with Gear ' ELSE 'Climbing ' END || trim_scale(coalesce(v_skill, 0)) || ' against ' || trim_scale(v_c.difficulty)
         || '): rolls ' || v_roll || ', needs ' || ceil((v_nc->>'needed')::numeric) || '. ';
  IF v_made THEN
    v_text := v_text || 'Makes it up.';
  ELSE
    v_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
    v_harm := greatest(ceil(v_max * power(v_c.rise / public.rpg_setting('climb_fall_down_m')::double precision, 2))::integer, 1);
    PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_harm);
    v_text := v_text || 'Slips and falls ' || trim_scale(round(v_c.rise::numeric, 1)) || ' m: ' || v_harm || ' damage'
           || CASE WHEN (public.rpg_participant_vitality(p_participant_id)->>'left')::integer <= 0 THEN '. Down.' ELSE '.' END;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, roll_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', v_out, p_participant_id, v_roll_id, v_text);
  RETURN jsonb_build_object('made', v_made, 'harm', v_harm, 'text', v_text);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_view_block(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_place uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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
-- whether the piece is in a fight, rpg_map_in_fight) and the characters that can still join.
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
-- landmarks = the landmarks the read shows (step 12b; rpg_map_landmarks), from the World grid down to the District grid:
-- each grid those of its own rank and every rank above it, few on the world and more each level down (Peter
-- 2026-10-03 17:28), each a mark in the cell its middle stands in (its id among the marks of that cell; a grid drawn
-- fine carries it in the marks of its detail), told as rpg_map_landmark_entry tells it. The kids login sees a
-- landmark when its cell is found or known, or from as far off as it can be made out (rpg_map_landmark_sight) of where
-- a player character walked, since things seen and steered by from far are what landmarks are (Peter 2026-10-06): a
-- landmark seen that way is marked even in a cell not found yet. The battle grid has none here.
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
  v_rivs      jsonb;
  v_lands     jsonb;
  v_lmk       jsonb;
  v_drivs     jsonb;
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
    -- a whole grid: the world, or the grid inside one cell of the grid above
    IF v_cols <> v_l.cols OR v_rows <> v_l.rows OR v_x0 < 0 OR mod(v_x0, v_cols) <> 0 OR mod(v_y0, v_rows) <> 0 THEN
      RAISE EXCEPTION 'that grid is off the map';
    END IF;
    v_x := v_x0 / v_cols;
    v_y := v_y0 / v_rows;
  END IF;
  IF p_place IS NULL AND v_l.level > 1 THEN
    SELECT l.cell, l.across, l.down INTO v_up_cell, v_up_across, v_up_down FROM public.rpg_map_ladder() l WHERE l.level = v_l.level - 1;
    v_moves := jsonb_build_object(
      'west',  v_l.level::text || '-' || mod(v_x - 1 + v_up_across, v_up_across)::text || '-' || v_y::text,
      'east',  v_l.level::text || '-' || mod(v_x + 1, v_up_across)::text || '-' || v_y::text,
      'north', CASE WHEN v_y > 0 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y - 1)::text END,
      'south', CASE WHEN v_y < v_up_down - 1 THEN v_l.level::text || '-' || v_x::text || '-' || (v_y + 1)::text END);
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
       -- the rivers near every cell (rpg_map_rivers), read once: for the lines drawn and for the crossings (step 11),
       -- with a margin round the block where a crossing just outside it may still reach in
       rva AS MATERIALIZED (SELECT r.x, r.y, r.k, r.dist, r.px, r.py, r.inside FROM public.rpg_map_rivers(v_l.level, v_x0 - v_rm, v_ry0, v_cols + 2 * v_rm, v_ry1 - v_ry0) r),
       -- the battle grid: the water under the roads and the fords (step 11), where it has roads or water
       wt AS MATERIALIZED (SELECT w.x, w.y, w.depth FROM public.rpg_map_flow(v_l.level, v_x0, v_y0, v_cols, v_rows) w
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind IN ('road', 'pass'))),
       fd AS MATERIALIZED (SELECT DISTINCT f.x, f.y FROM public.rpg_map_ford_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND EXISTS (SELECT 1 FROM c WHERE c.kind = 'water')),
       cl AS MATERIALIZED (
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
                k.seen, wx.x AS wx, tm.ids AS towns, lmm.ids AS lmarks, CASE WHEN c.kind = 'town' THEN tg.id END AS town,
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif,
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
          CROSS JOIN LATERAL (SELECT v_gm OR v_seen ? (c.x || ',' || c.y) OR kn.x IS NOT NULL AS seen) k
          -- the cell itself counted round the world, for a block that runs past the east or west end
          CROSS JOIN LATERAL (SELECT mod(mod(c.x, v_l.across) + v_l.across, v_l.across) AS x) wx)
  SELECT (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                   'x', cl.x - v_x0 + 1, 'y', cl.y - v_y0 + 1,
                   'name', public.rpg_square_name(cl.x - v_x0 + 1, cl.y - v_y0 + 1),
                   -- a cell of a village, town or city comes as a place, its place the settlement, so it is drawn and
                   -- named like a place with ground
                   'kind', CASE WHEN NOT cl.seen THEN 'unknown' WHEN cl.town IS NOT NULL THEN 'place' ELSE cl.kind END,
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
                   'river', CASE WHEN cl.seen AND cl.line > 0 AND cl.kind NOT IN ('water', 'deep', 'sea')
                                 THEN jsonb_build_array(cl.line, round(cl.px * 1000)::integer, round(cl.py * 1000)::integer) END,
                   -- the battle grid: a bridge over the water, or a ford through it (step 11)
                   'cross', CASE WHEN cl.seen THEN cl.cross END,
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
         -- the landmarks shown (step 12b), biggest first
         (SELECT jsonb_agg(public.rpg_map_landmark_entry(ls.id, ls.rank, ls.kind, ls.icon, ls.words, ls.name, ls.x, ls.y, ls.height, ls.across,
                                                         v_l.level, v_gx0, v_gy0, v_gx1, v_gy1) ORDER BY ls.rank, ls.name)
            FROM ls WHERE ls.shown),
         (SELECT jsonb_agg(jsonb_build_object('id', ls.id, 'x', ls.x, 'y', ls.y)) FROM ls WHERE ls.shown)
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_lands, v_lmk;

  -- the houses of the battle grid (step 8c): every one with a square seen here, drawn whole as far as the grid goes
  IF v_l.level = 7 AND cardinality(v_hseen) > 0 THEN
    SELECT jsonb_agg(jsonb_build_object(
             'id', h.id, 'roof', h.roof,
             'x', round((h.cx - v_gx0) * 1000 / v_l.cell)::integer, 'y', round((h.cy - v_gy0) * 1000 / v_l.cell)::integer,
             'ridge', jsonb_build_array(round(h.ux * 1000)::integer, round(h.uy * 1000)::integer),
             'len', round(2 * h.half_len * 1000 / v_l.cell)::integer, 'wide', round(2 * h.half_wide * 1000 / v_l.cell)::integer,
             'eaves', round(h.eaves::numeric, 1), 'pitch', round(h.pitch)::integer, 'storeys', h.storeys) ORDER BY h.id)
      INTO v_houses
      FROM public.rpg_map_buildings(v_l.level, v_x0, v_y0, v_cols, v_rows) h
     WHERE h.id = ANY (v_hseen);
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
            WHERE v_l.level + 1 = 4 AND t.kind IS NOT NULL),
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
      JOIN public.rpg_settings s ON s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key IN ('map_road_1_width', 'map_road_2_width', 'map_road_3_width');
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
         cx AS (
           SELECT ls.n, ls.class, ls.a, ls.b, ls.u, ls.v, ls.nu, ls.nv, r.k, r.width,
                  r.d - ((ls.u - m.mx) * m.nx + (ls.v - m.my) * m.ny) AS s1, r.d - ((ls.nu - m.mx) * m.nx + (ls.nv - m.my) * m.ny) AS s2
             FROM ls CROSS JOIN g
            CROSS JOIN LATERAL (SELECT q.ox, q.oy FROM (VALUES (1, ls.u, ls.v), (2, ls.nu, ls.nv)) AS q(o, ox, oy)
                                 WHERE EXISTS (SELECT 1 FROM rv WHERE rv.x = g.x0 + floor(q.ox)::integer AND rv.y = g.y0 + floor(q.oy)::integer)
                                 ORDER BY q.o LIMIT 1) f
             JOIN rv r ON r.x = g.x0 + floor(f.ox)::integer AND r.y = g.y0 + floor(f.oy)::integer
            CROSS JOIN LATERAL (SELECT floor(f.ox) + 0.5 AS mx, floor(f.oy) + 0.5 AS my, r.px / r.d AS nx, r.py / r.d AS ny) m
            WHERE ls.nu IS NOT NULL AND EXISTS (SELECT 1 FROM rv)),
         xs AS (
           SELECT cx.*, cx.u + t.t * (cx.nu - cx.u) AS xu, cx.v + t.t * (cx.nv - cx.v) AS xv
             FROM cx CROSS JOIN LATERAL (SELECT cx.s1 / (cx.s1 - cx.s2) AS t) t
            WHERE ((cx.s1 > 0 AND cx.s2 <= 0) OR (cx.s1 <= 0 AND cx.s2 > 0)) AND abs(cx.s1) <= 1 AND abs(cx.s2) <= 1),
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

  RETURN jsonb_build_object(
    'level', v_l.level, 'name', coalesce(v_pname, v_l.name), 'title', v_crumbs -> -1 ->> 'label',
    'view', CASE WHEN p_place IS NOT NULL THEN 'p-' || p_place::text
                 WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_cols, 'rows', v_rows, 'origin', jsonb_build_array(v_x0, v_y0), 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves,
    'cells', coalesce(v_cells, '[]'::jsonb), 'detail', v_detail,
    'places', coalesce(v_places, '[]'::jsonb), 'towns', coalesce(v_towns, '[]'::jsonb), 'roads', coalesce(v_roads, '[]'::jsonb), 'road_width', v_rw,
    'crossings', coalesce(v_cross, '[]'::jsonb),
    'houses', coalesce(v_houses, '[]'::jsonb),
    'landmarks', coalesce(v_lands, '[]'::jsonb),
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

-- the new functions run only inside the map reads (granted like the other map helpers: the service role only)
REVOKE ALL ON FUNCTION public.rpg_map_landmark_what(integer, integer[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_what(integer, integer[]) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_squares(text, text, integer, bigint, bigint, double precision, double precision, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_squares(text, text, integer, bigint, bigint, double precision, double precision, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_landmark_cells(integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_landmark_cells(integer, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_climb_words(text, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_climb_words(text, double precision) TO service_role;

-- the rule card (step 12b2): landmarks on the battle grid
UPDATE public.rpg_rules
   SET body = replace(replace(body,
                'none in the sea or water, on snow and ice, in a street, or inside a place with ground of its own.',
                'none in the sea or water, on snow and ice, in a street, or inside a place with ground of its own. On the battle grid they stand as they are: a castle is a keep inside a curtain wall with one gate, a ruin is the broken walls of its rooms, a stone circle a ring of stones about 4 m apart; their walls, towers, stones and boulders are climbed like the wall of a house (see Climbing), a cairn or the side of a motte like a slope of rock, and a walk goes round them. A lone peak is the mountain itself.'),
                'a peak rising 13,000 feet from about 140 miles.*',
                'a peak rising 13,000 feet from about 140 miles. Karen (Climbing 7) needs 59 to get up the wall of a tower house, 5.4 m and sheer; a slip drops her 5.4 m for 6 damage.*'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position('none in the sea or water, on snow and ice, in a street, or inside a place with ground of its own.' IN body) > 0
   AND position('a peak rising 13,000 feet from about 140 miles.*' IN body) > 0
   AND position('On the battle grid they stand as they are' IN body) = 0;

