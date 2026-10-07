-- Roleplaying world map step 12d3 (Peter 2026-10-06: the battle grid under the ground: passages and chambers as
-- squares, creatures met and fought there). No new tables, no drops. One new column, rpg_creatures.haunt_under; eight
-- settings (the floors under the ground); new functions for the squares under the ground, where a piece stands on its
-- passage, the fight board under the ground and meeting creatures there; the surface walk meets creatures through the
-- same functions (nothing it does changes).

ALTER TABLE public.rpg_creatures ADD COLUMN IF NOT EXISTS haunt_under text[] CONSTRAINT rpg_creatures_haunt_under_check CHECK (haunt_under <@ ARRAY['deep', 'cave', 'mine']::text[]);
COMMENT ON COLUMN public.rpg_creatures.haunt_under IS 'The kinds of ground under the ground a creature card is met in (step 12d3): deep (the Deeps), cave (cave country, caves and the squeezes into them), mine (the passage of a mine). rpg_map_under_haunters reads it; nothing = never met under the ground.';

INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', s.key, s.value, s.label
  FROM (VALUES ('map_under_deep_penalty', 10, 'Least percent of time a square of the floor of the Deeps adds (step 12d3; big galleries of sand and fallen rock)'),
               ('map_under_deep_penalty_high', 40, 'Most percent of time a square of the floor of the Deeps adds (step 12d3)'),
               ('map_under_cave_penalty', 100, 'Least percent of time a square of cave floor adds (step 12d3; stooping and scrambling)'),
               ('map_under_cave_penalty_high', 357, 'Most percent of time a square of cave floor adds, its rubble aside (step 12d3; rubble is the thicket, map_thicket_penalty)'),
               ('map_under_mine_penalty', 20, 'Least percent of time a square of a mine floor adds (step 12d3; a cut drift)'),
               ('map_under_mine_penalty_high', 80, 'Most percent of time a square of a mine floor adds (step 12d3)'),
               ('map_under_squeeze_penalty', 300, 'Least percent of time a square of a squeeze adds (step 12d3; crawling on the belly)'),
               ('map_under_squeeze_penalty_high', 500, 'Most percent of time a square of a squeeze adds (step 12d3)')) AS s(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings x WHERE x.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND x.key = s.key);

CREATE OR REPLACE FUNCTION public.rpg_map_under_sizes()
 RETURNS TABLE(what text, skind text, rank integer, w_low double precision, w_high double precision, ground text, pool double precision, col double precision)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- How big the world under the ground is on the battle grid (step 12d3), the one home of those numbers, in metres, each
-- as many small as large between the two (a doubling scale): w_low to w_high = how wide a passage runs, or how far
-- across a room is; ground = the kind of ground its floor is (rpg_map_grounds: its range of percent, rpg_map_band;
-- a shaft has none, it is climbed); pool = the share of its floor under shallow water; col = the share of its floor
-- where a column of stone stands (no way through). From Earth's caves and mines, the Deeps amplified (Peter
-- 2026-10-06 20:08): trunk passages of big caves run 10 to 30 m wide (Mammoth Cave), the biggest 150 m (Son Doong);
-- cavers crawl and stoop through passages of 1 to 8 m; a squeeze is under a metre; a hand-cut mine drift is 2 to 3.5 m,
-- a modern one 3 to 5 m; shafts 3 to 8 m across. Rooms: chambers of 12 to 120 m (most cave rooms), the largest on
-- Earth 600 by 415 m (Sarawak Chamber) and 1,220 by 191 m (Carlsbad's Big Room), so the great halls of the Deeps are
-- 300 to 1,500 m across; the far end of a great cave 30 to 100 m, of a cave 8 to 30 m, of a hollow 3 to 8 m; mine
-- workings end in a stope of 6 to 20 m; a small mine ends at its face (no room).
-- what: deep (a passage of the Deeps), cave (of cave country), join and delve (where a cave or mine breaks through:
-- a squeeze), shaft, own (the own passage of a cave or a mine, by skind and rank), hall (a great hall), chamber (of
-- cave country), end (the far end of a cave or a mine, by skind and rank).
SELECT * FROM (VALUES
  ('deep',    NULL,   NULL, 15.0,   90.0,   'under_deep',    0.05, 0.005),
  ('cave',    NULL,   NULL, 1.5,    8.0,    'under_cave',    0.08, 0.02),
  ('join',    NULL,   NULL, 0.7,    1.5,    'under_squeeze', 0.0,  0.0),
  ('delve',   NULL,   NULL, 0.7,    1.5,    'under_squeeze', 0.0,  0.0),
  ('shaft',   NULL,   NULL, 3.0,    8.0,    NULL,            0.0,  0.0),
  ('own',     'cave', 4,    8.0,    40.0,   'under_cave',    0.06, 0.02),
  ('own',     'cave', 5,    2.0,    8.0,    'under_cave',    0.08, 0.02),
  ('own',     'cave', 6,    1.0,    3.0,    'under_cave',    0.05, 0.0),
  ('own',     'mine', 4,    3.0,    5.0,    'under_mine',    0.04, 0.0),
  ('own',     'mine', 5,    2.0,    3.5,    'under_mine',    0.03, 0.0),
  ('hall',    NULL,   NULL, 300.0,  1500.0, 'under_deep',    0.06, 0.01),
  ('chamber', NULL,   NULL, 12.0,   120.0,  'under_cave',    0.08, 0.02),
  ('end',     'cave', 4,    30.0,   100.0,  'under_cave',    0.08, 0.02),
  ('end',     'cave', 5,    8.0,    30.0,   'under_cave',    0.08, 0.02),
  ('end',     'cave', 6,    3.0,    8.0,    'under_cave',    0.05, 0.0),
  ('end',     'mine', 4,    6.0,    20.0,   'under_mine',    0.04, 0.0)
) AS s(what, skind, rank, w_low, w_high, ground, pool, col);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_site_rank(p_id text)
 RETURNS integer
 LANGUAGE sql
 STABLE
AS $function$
-- The rank (4 to 6) of the landmark site of a cave or a mine, from its id alone (mark-<w6>-<y6>) without reading the
-- ground (step 12d3): the rank whose square leads its picks down to that rank-6 square and is not picked by the square
-- above it (rpg_map_landmark_site). The one home of it: rpg_map_under_site reads it, and so does the size of a passage.
-- Nothing for anything that is not a site id.
SELECT min(rk)
  FROM (SELECT substring(p_id FROM '^mark-(\d+)-\d+$')::bigint AS w6, substring(p_id FROM '^mark-\d+-(\d+)$')::bigint AS y6) s
 CROSS JOIN public.rpg_map_landmark_lattice() t
 CROSS JOIN generate_series(4, 6) AS rk
 CROSS JOIN LATERAL public.rpg_map_landmark_site(rk, floor(s.w6::double precision / 12 ^ (6 - rk))::bigint, floor(s.y6::double precision / 12 ^ (6 - rk))::bigint,
                                                 t.seed, t.l6, t.jit, t.a6) st
 WHERE NOT st.picked AND st.w6 = s.w6 AND st.y6 = s.y6;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_size(p_kind text, p_skind text, p_node text)
 RETURNS TABLE(w_low double precision, w_high double precision, ground text, pool double precision, col double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- The size row (rpg_map_under_sizes) of one passage (p_kind as rpg_map_under_edges gives it; for the own passage of a
-- cave or a mine p_skind and either end, p_node, give its rank) or of one room (p_kind room, p_node the node: a great
-- hall deep-..., a chamber cave-..., the far end of a cave or mine end:<site>; the mouth of a cave has no room).
SELECT z.w_low, z.w_high, z.ground, z.pool, z.col
  FROM (SELECT CASE WHEN p_kind = 'own' OR (p_kind = 'room' AND p_node LIKE 'end:%')
                    THEN public.rpg_map_under_site_rank(split_part(p_node, ':', 2)) END AS rk) r
  JOIN public.rpg_map_under_sizes() z
    ON (p_kind NOT IN ('room', 'own') AND z.what = p_kind)
    OR (p_kind = 'own' AND z.what = 'own' AND z.skind = p_skind AND z.rank = r.rk)
    OR (p_kind = 'room' AND p_node LIKE 'deep-%' AND z.what = 'hall')
    OR (p_kind = 'room' AND p_node LIKE 'cave-%' AND z.what = 'chamber')
    OR (p_kind = 'room' AND p_node LIKE 'end:%' AND z.what = 'end' AND z.skind = p_skind AND z.rank = r.rk);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_hash(p_key text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- A steady whole number for a passage or a node of the world under the ground (step 12d3): md5 of its key, the first 7
-- hex digits, so rpg_map_roll can roll for it like a point of the map.
SELECT ('x' || substr(md5(p_key), 1, 7))::bit(28)::integer;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_swing(p_key text, p_w_low double precision, p_w_high double precision, p_us double precision[], p_len double precision)
 RETURNS TABLE(i integer, off double precision, half double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- How a passage winds and how wide it is (step 12d3), the one home of that sum, at each point p_us (squares from its
-- first end, node a) of a passage p_len squares long. Knots every 5 of its widths (at least 4 m; a meander's bend runs
-- 10 to 14 widths in rivers and cave streams alike, Leopold and Wolman 1960), each with its own swing to one side, up
-- to 0.8 of its middle width (layer 1750), and its own width between p_w_low and p_w_high on a doubling scale (layer
-- 1751), rolled for the passage (rpg_map_under_hash of p_key, a|b) and the knot; smooth between knots. The swing dies
-- away over the first and last knot so the passage meets its rooms in the middle. off = squares to the side of the
-- passage's curve (toward the side its bend swings to), half = half its width in squares, at least 0.75 so a squeeze
-- is still a square wide; i = which of p_us. Each knot is rolled once however many points ask.
WITH g AS (SELECT t.seed, t.sq, sqrt(p_w_low * p_w_high) AS wm, public.rpg_map_under_hash(p_key) AS h,
                  greatest(4.0, 5 * sqrt(p_w_low * p_w_high)) / t.sq AS k
             FROM public.rpg_map_under_lattice() t),
     p AS (SELECT q.i::integer AS i, q.u, floor(greatest(q.u, 0) / g.k)::integer AS n, greatest(q.u, 0) / g.k - floor(greatest(q.u, 0) / g.k) AS f
             FROM unnest(p_us) WITH ORDINALITY AS q(u, i) CROSS JOIN g),
     kn AS (SELECT n.n, (public.rpg_map_roll(g.seed, 1750, g.h, n.n) - 50.5) / 49.5 AS o,
                   p_w_low * power(p_w_high / p_w_low, (public.rpg_map_roll(g.seed, 1751, g.h, n.n) - 0.5) / 100) AS w
              FROM (SELECT DISTINCT p.n FROM p UNION SELECT DISTINCT p.n + 1 FROM p) n CROSS JOIN g)
SELECT p.i,
       0.8 * g.wm / g.sq * least(1.0, greatest(p.u, 0) / g.k, greatest(p_len - p.u, 0) / g.k) * (k0.o + (k1.o - k0.o) * p.f * p.f * (3 - 2 * p.f)),
       greatest(0.75, (k0.w + (k1.w - k0.w) * p.f * p.f * (3 - 2 * p.f)) / 2 / g.sq)
  FROM p CROSS JOIN g
  JOIN kn k0 ON k0.n = p.n
  JOIN kn k1 ON k1.n = p.n + 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_curve(p_ax double precision, p_ay double precision, p_bx double precision, p_by double precision, p_bend double precision, p_t double precision)
 RETURNS TABLE(x double precision, y double precision, nx double precision, ny double precision, len double precision, cx double precision, cy double precision)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- A passage of the world under the ground as the map draws it (step 12d; MapUnder in Roleplaying.jsx), the one home
-- of the curve in SQL (step 12d3): one quadratic curve from a to b whose middle point is pulled to one side by p_bend x a
-- quarter of its length. At p_t (0 at a, 1 at b): x, y = the point, nx, ny = the unit sideways direction (the side a
-- positive bend swings to), len = its length in squares (the chord plus two thirds of the square of the swing; a walk
-- measures it so, rpg_map_under_ways), cx, cy = the middle point it is pulled toward (rpg_map_under_squares draws the
-- curve from it).
WITH c AS (SELECT p_bx - p_ax AS dx, p_by - p_ay AS dy, p_bend * 0.25 AS k),
     q AS (SELECT c.*, (p_ax + p_bx) / 2 - c.dy * c.k AS cx, (p_ay + p_by) / 2 + c.dx * c.k AS cy FROM c),
     d AS (SELECT q.*, 2 * (1 - p_t) * (q.cx - p_ax) + 2 * p_t * (p_bx - q.cx) AS tx, 2 * (1 - p_t) * (q.cy - p_ay) + 2 * p_t * (p_by - q.cy) AS ty FROM q)
SELECT power(1 - p_t, 2) * p_ax + 2 * p_t * (1 - p_t) * d.cx + p_t * p_t * p_bx,
       power(1 - p_t, 2) * p_ay + 2 * p_t * (1 - p_t) * d.cy + p_t * p_t * p_by,
       CASE WHEN d.tx = 0 AND d.ty = 0 THEN 0 ELSE -d.ty / sqrt(d.tx * d.tx + d.ty * d.ty) END,
       CASE WHEN d.tx = 0 AND d.ty = 0 THEN 0 ELSE d.tx / sqrt(d.tx * d.tx + d.ty * d.ty) END,
       sqrt(d.dx * d.dx + d.dy * d.dy) * (1 + power(d.k, 2) * 2 / 3), d.cx, d.cy
  FROM d;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_spot(p_kind text, p_a text, p_b text, p_ax bigint, p_ay bigint, p_bx bigint, p_by bigint, p_bend double precision, p_skind text, p_t double precision)
 RETURNS TABLE(x double precision, y double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- Where a piece stands partway along a passage (step 12d3): p_t of the way from a to b along the passage's curve
-- (rpg_map_under_curve), to one side by how it winds there (rpg_map_under_swing), in world squares; the square it is on
-- is floor(x), floor(y). A shaft stands straight (no winding). So a piece in a passage is always in it on the battle
-- grid (rpg_map_under_squares).
SELECT c.x + c.nx * coalesce(s.off, 0), c.y + c.ny * coalesce(s.off, 0)
  FROM public.rpg_map_under_curve(p_ax, p_ay, p_bx, p_by, p_bend, least(greatest(p_t, 0), 1)) c
  LEFT JOIN LATERAL public.rpg_map_under_size(p_kind, p_skind, CASE WHEN p_a LIKE 'mouth:%' OR p_a LIKE 'end:%' THEN p_a ELSE p_b END) z ON p_kind <> 'shaft'
  LEFT JOIN LATERAL public.rpg_map_under_swing(p_a || '|' || p_b, z.w_low, z.w_high, ARRAY[c.len * least(greatest(p_t, 0), 1)], c.len) s ON z.w_low IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_patch(p_layer integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_step integer)
 RETURNS TABLE(x integer, y integer, v double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- A fixed-seed number from 0 to 1 for each square of a block of the world under the ground (step 12d3; world squares
-- from 0) that runs in patches: one point in each square of a lattice p_step squares apart, set anywhere in it, and
-- every square takes the roll of the point nearest it (rpg_map_roll part 17, layers p_layer the roll, p_layer + 100
-- and p_layer + 200 where the point lies; the column counted round the world). So a patch is a ragged blob a few
-- squares across, and v is spread evenly from 0 to 1 (each patch its own d100), as rpg_map_pct reads how hard a square is.
WITH t AS (SELECT u.seed, (u.span / p_step)::bigint AS w FROM public.rpg_map_under_lattice() u),
     k AS MATERIALIZED (
       SELECT gi, gj, gi * p_step + p_step * (public.rpg_map_roll(t.seed, p_layer + 100, q.wi, gj) - 0.5) / 100.0 AS px,
              gj * p_step + p_step * (public.rpg_map_roll(t.seed, p_layer + 200, q.wi, gj) - 0.5) / 100.0 AS py,
              (public.rpg_map_roll(t.seed, p_layer, q.wi, gj) - 0.5) / 100.0 AS r
         FROM t
        CROSS JOIN generate_series(floor(p_x0::double precision / p_step)::bigint - 1, floor((p_x0 + p_cols)::double precision / p_step)::bigint + 1) AS gi
        CROSS JOIN generate_series(floor(p_y0::double precision / p_step)::integer - 1, floor((p_y0 + p_rows)::double precision / p_step)::integer + 1) AS gj
        CROSS JOIN LATERAL (SELECT mod(mod(gi, t.w) + t.w, t.w)::integer AS wi) q)
SELECT sx, sy,
       (SELECT k.r FROM k WHERE k.gi BETWEEN floor(sx::double precision / p_step)::bigint - 1 AND floor(sx::double precision / p_step)::bigint + 1
                            AND k.gj BETWEEN floor(sy::double precision / p_step)::integer - 1 AND floor(sy::double precision / p_step)::integer + 1
         ORDER BY power(sx + 0.5 - k.px, 2) + power(sy + 0.5 - k.py, 2) LIMIT 1)
  FROM generate_series(p_x0, p_x0 + p_cols - 1) AS sx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS sy;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_squares(p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_ways jsonb)
 RETURNS TABLE(x integer, y integer, part text, ground text, pct integer, hard double precision, water double precision, down double precision, way text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The battle grid under the ground (step 12d3; Peter 2026-10-06: passages and chambers as squares, creatures met and
-- fought there), the one home of it: the open squares of a block (world squares from 0, as rpg_map_costs counts) that
-- the passages p_ways (rows of rpg_map_under_edges as json objects: kind, a, b, ax, ay, bx, by, ad, bd, bend, skind)
-- and the rooms at their ends run through. Every other square is solid rock (no row): no way in.
--   A passage follows its curve (rpg_map_under_curve, as the map draws it), winding to the side and widening and
--   narrowing as it goes (rpg_map_under_swing), as wide as its kind makes it (rpg_map_under_sizes: a passage of the
--   Deeps 15 to 90 m, of cave country 1.5 to 8 m, a squeeze 0.7 to 1.5 m, a mine drift 2 to 5 m, the own passage of a
--   cave by its rank); a shaft runs straight, 3 to 8 m across, and every square of it is climbed at its slope
--   (rpg_map_climb). A room is a ragged round at a great hall (300 to 1,500 m across), a chamber of cave country (12
--   to 120 m) or the far end of a cave or a mine, its edge in and out by up to a quarter (layer 1753, eight knots round);
--   the mouth of a cave has none (the passage starts at the cave on the surface).
--   Each open square: its ground (rpg_map_grounds under_deep, under_cave, under_mine, under_squeeze) and how hard it is
--   inside that ground's range (rpg_map_under_patch: patches about three squares across, layer 1761), its percent from
--   that (rpg_map_pct; the hardest share of cave floor is rubble, the thicket of rpg_map_band); round pools, one at a point
--   of a lattice 8 squares apart by a roll (layer 1762) at 3.8 times the share of floor its kind gives (pool: a pool
--   averages about 17 squares, a lattice square 64), set anywhere in its lattice square (1764, 1765), 1.2 to 3.5 squares
--   from middle to edge (1766), 0.9 m deep in the middle to 0.1 m at the edge (waded, rpg_map_wade_pct); a column of
--   stone (no way through) on the share col of squares (layer 1763), never on the line down the middle of a passage or
--   the middle of a room, so a piece walking it is never in stone.
-- part = floor, rubble, pool, column (pct none: no way in) or shaft; water = metres deep (pools); down = metres below
-- (as the node it belongs to counts: a great hall and its passages below the sea, the rest below the ground); way = the
-- passage (a|b) or the room (its node).
DECLARE
  t record; e record; z record; nd record;
  v_n integer := p_cols * p_rows;
  v_way text[] := array_fill(NULL::text, ARRAY[p_cols * p_rows]);
  v_room boolean[] := array_fill(false, ARRAY[p_cols * p_rows]);
  v_gr text[] := array_fill(NULL::text, ARRAY[p_cols * p_rows]);
  v_dn double precision[] := array_fill(NULL::double precision, ARRAY[p_cols * p_rows]);
  v_mid boolean[] := array_fill(false, ARRAY[p_cols * p_rows]);
  v_pool double precision[] := array_fill(0::double precision, ARRAY[p_cols * p_rows]);
  v_col double precision[] := array_fill(0::double precision, ARRAY[p_cols * p_rows]);
  v_cl integer[] := array_fill(NULL::integer, ARRAY[p_cols * p_rows]);
  v_cx double precision := p_x0 + p_cols / 2.0; v_cy double precision := p_y0 + p_rows / 2.0;
  v_diag double precision := sqrt(p_cols * p_cols + p_rows * p_rows) / 2.0;
  v_sh bigint; v_ax double precision; v_ay double precision; v_bx double precision; v_by double precision; v_qx double precision; v_qy double precision;
  v_len double precision; v_l2 double precision; v_reach double precision; tt double precision; tc double precision;
  px double precision; py double precision; dx double precision; dy double precision; ddx double precision; ddy double precision;
  f double precision; fd double precision; v_nx double precision; v_ny double precision; v_v double precision;
  v_half double precision; v_dist double precision; v_ang double precision; v_r double precision;
  v_k integer; v_kf double precision; v_key text; v_climb integer; i integer; j integer; q integer; it integer;
  v_shaft boolean; v_nodes jsonb := '[]'::jsonb; s record;
  v_qi integer[]; v_qu double precision[]; v_qv double precision[]; v_qt double precision[]; v_qpx double precision[]; v_qpy double precision[];
  v_qnx double precision[]; v_qny double precision[];
BEGIN
  SELECT * INTO t FROM public.rpg_map_under_lattice();
  -- the passages
  FOR e IN SELECT r.* FROM jsonb_to_recordset(coalesce(p_ways, '[]'::jsonb))
                    AS r(kind text, a text, b text, ax bigint, ay bigint, bx bigint, "by" bigint, ad double precision, bd double precision, bend double precision, skind text)
  LOOP
    -- counted round the world the way the block counts
    v_sh := round((v_cx - (e.ax + e.bx) / 2.0) / t.span)::bigint * t.span;
    v_ax := e.ax + v_sh; v_ay := e.ay; v_bx := e.bx + v_sh; v_by := e."by";
    IF e.kind = 'hall' THEN
      v_nodes := v_nodes || jsonb_build_object('n', e.a, 'x', v_ax, 'y', v_ay, 'd', e.ad, 'sk', NULL);
      CONTINUE;
    END IF;
    IF e.a NOT LIKE 'mouth:%' THEN v_nodes := v_nodes || jsonb_build_object('n', e.a, 'x', v_ax, 'y', v_ay, 'd', e.ad, 'sk', e.skind); END IF;
    IF e.b NOT LIKE 'mouth:%' THEN v_nodes := v_nodes || jsonb_build_object('n', e.b, 'x', v_bx, 'y', v_by, 'd', e.bd, 'sk', e.skind); END IF;
    SELECT * INTO z FROM public.rpg_map_under_size(e.kind, e.skind, CASE WHEN e.a LIKE 'mouth:%' OR e.a LIKE 'end:%' THEN e.a ELSE e.b END);
    CONTINUE WHEN NOT FOUND;
    v_shaft := e.kind = 'shaft';
    v_key := e.a || '|' || e.b;
    -- the point the curve is pulled toward and its length (rpg_map_under_curve)
    SELECT c.cx, c.cy, c.len INTO v_qx, v_qy, v_len FROM public.rpg_map_under_curve(v_ax, v_ay, v_bx, v_by, e.bend, 0) c;
    v_l2 := power(v_bx - v_ax, 2) + power(v_by - v_ay, 2);
    v_reach := z.w_high / 2 / t.sq + CASE WHEN v_shaft THEN 0 ELSE 0.8 * sqrt(z.w_low * z.w_high) / t.sq END + v_diag + 2;
    -- the point of the curve nearest the middle of the block (Newton's method from the straight line)
    tc := CASE WHEN v_l2 = 0 THEN 0 ELSE least(greatest(((v_cx - v_ax) * (v_bx - v_ax) + (v_cy - v_ay) * (v_by - v_ay)) / v_l2, 0), 1) END;
    FOR it IN 1 .. 8 LOOP
      px := power(1 - tc, 2) * v_ax + 2 * tc * (1 - tc) * v_qx + tc * tc * v_bx; py := power(1 - tc, 2) * v_ay + 2 * tc * (1 - tc) * v_qy + tc * tc * v_by;
      dx := 2 * (1 - tc) * (v_qx - v_ax) + 2 * tc * (v_bx - v_qx); dy := 2 * (1 - tc) * (v_qy - v_ay) + 2 * tc * (v_by - v_qy);
      ddx := 2 * (v_ax - 2 * v_qx + v_bx); ddy := 2 * (v_ay - 2 * v_qy + v_by);
      f := (px - v_cx) * dx + (py - v_cy) * dy; fd := dx * dx + dy * dy + (px - v_cx) * ddx + (py - v_cy) * ddy;
      EXIT WHEN fd <= 0;
      tc := least(greatest(tc - f / fd, 0), 1);
    END LOOP;
    px := power(1 - tc, 2) * v_ax + 2 * tc * (1 - tc) * v_qx + tc * tc * v_bx; py := power(1 - tc, 2) * v_ay + 2 * tc * (1 - tc) * v_qy + tc * tc * v_by;
    CONTINUE WHEN sqrt(power(px - v_cx, 2) + power(py - v_cy, 2)) > v_reach;
    -- a shaft is one width all the way, climbed at its slope
    IF v_shaft THEN
      v_half := greatest(0.75, z.w_low * power(z.w_high / z.w_low, (public.rpg_map_roll(t.seed, 1751, public.rpg_map_under_hash(v_key), 0) - 0.5) / 100) / 2 / t.sq);
      SELECT c.pct INTO v_climb FROM public.rpg_map_climb(least(degrees(atan2(abs(e.bd - e.ad), greatest(sqrt(v_l2) * t.sq, 0.001))), 85)) c;
    END IF;
    -- each square near enough: the nearest point of the curve (a step along it from the block's nearest point, then
    -- Newton's method), how far to the side of the curve it is, and how far along
    v_qi := '{}'; v_qu := '{}'; v_qv := '{}'; v_qt := '{}'; v_qpx := '{}'; v_qpy := '{}'; v_qnx := '{}'; v_qny := '{}';
    FOR j IN 0 .. p_rows - 1 LOOP
      FOR i IN 0 .. p_cols - 1 LOOP
        q := j * p_cols + i + 1;
        dx := 2 * (1 - tc) * (v_qx - v_ax) + 2 * tc * (v_bx - v_qx); dy := 2 * (1 - tc) * (v_qy - v_ay) + 2 * tc * (v_by - v_qy);
        tt := CASE WHEN dx = 0 AND dy = 0 THEN tc
                   ELSE least(greatest(tc + ((p_x0 + i + 0.5 - px) * dx + (p_y0 + j + 0.5 - py) * dy) / (dx * dx + dy * dy), 0), 1) END;
        FOR it IN 1 .. 3 LOOP
          f := power(1 - tt, 2) * v_ax + 2 * tt * (1 - tt) * v_qx + tt * tt * v_bx - (p_x0 + i + 0.5);
          fd := power(1 - tt, 2) * v_ay + 2 * tt * (1 - tt) * v_qy + tt * tt * v_by - (p_y0 + j + 0.5);
          dx := 2 * (1 - tt) * (v_qx - v_ax) + 2 * tt * (v_bx - v_qx); dy := 2 * (1 - tt) * (v_qy - v_ay) + 2 * tt * (v_by - v_qy);
          ddx := dx * dx + dy * dy + f * 2 * (v_ax - 2 * v_qx + v_bx) + fd * 2 * (v_ay - 2 * v_qy + v_by);
          EXIT WHEN ddx <= 0;
          tt := least(greatest(tt - (f * dx + fd * dy) / ddx, 0), 1);
        END LOOP;
        f := power(1 - tt, 2) * v_ax + 2 * tt * (1 - tt) * v_qx + tt * tt * v_bx; fd := power(1 - tt, 2) * v_ay + 2 * tt * (1 - tt) * v_qy + tt * tt * v_by;
        dx := 2 * (1 - tt) * (v_qx - v_ax) + 2 * tt * (v_bx - v_qx); dy := 2 * (1 - tt) * (v_qy - v_ay) + 2 * tt * (v_by - v_qy);
        IF dx = 0 AND dy = 0 THEN v_nx := 0; v_ny := 0;
        ELSE v_nx := -dy / sqrt(dx * dx + dy * dy); v_ny := dx / sqrt(dx * dx + dy * dy); END IF;
        v_v := (p_x0 + i + 0.5 - f) * v_nx + (p_y0 + j + 0.5 - fd) * v_ny;
        CONTINUE WHEN sqrt(power(p_x0 + i + 0.5 - f, 2) + power(p_y0 + j + 0.5 - fd, 2)) > v_reach - v_diag;
        v_qi := v_qi || q; v_qu := v_qu || tt * v_len; v_qv := v_qv || v_v; v_qt := v_qt || tt;
        v_qpx := v_qpx || f; v_qpy := v_qpy || fd; v_qnx := v_qnx || v_nx; v_qny := v_qny || v_ny;
      END LOOP;
    END LOOP;
    CONTINUE WHEN cardinality(v_qi) = 0;
    -- how the passage winds and how wide it is at each of them (rpg_map_under_swing, one call), and whether the square is in it
    FOR s IN SELECT w.i, CASE WHEN v_shaft THEN 0 ELSE w.off END AS off, CASE WHEN v_shaft THEN v_half ELSE w.half END AS half
               FROM public.rpg_map_under_swing(v_key, z.w_low, z.w_high, v_qu, v_len) w
    LOOP
      q := v_qi[s.i]; tt := v_qt[s.i];
      CONTINUE WHEN v_room[q];
      i := mod(q - 1, p_cols); j := (q - 1) / p_cols;
      v_dist := CASE WHEN tt <= 0 OR tt >= 1
                     THEN sqrt(power(p_x0 + i + 0.5 - v_qpx[s.i] - v_qnx[s.i] * s.off, 2) + power(p_y0 + j + 0.5 - v_qpy[s.i] - v_qny[s.i] * s.off, 2))
                     ELSE abs(v_qv[s.i] - s.off) END;
      CONTINUE WHEN v_dist > s.half;
      IF v_way[q] IS NULL OR v_dist < 0.75 THEN
        v_way[q] := v_key; v_gr[q] := z.ground; v_dn[q] := e.ad + (e.bd - e.ad) * tt;
        v_pool[q] := z.pool; v_col[q] := z.col; v_cl[q] := CASE WHEN v_shaft THEN v_climb END;
      END IF;
      IF v_dist < 0.75 THEN v_mid[q] := true; END IF;
    END LOOP;
  END LOOP;
  -- the rooms at the nodes
  FOR nd IN SELECT DISTINCT ON (o->>'n') o->>'n' AS n, (o->>'x')::double precision AS x, (o->>'y')::double precision AS y,
                   (o->>'d')::double precision AS d, o->>'sk' AS sk
              FROM jsonb_array_elements(v_nodes) o ORDER BY o->>'n', (o->>'sk') NULLS LAST
  LOOP
    SELECT * INTO z FROM public.rpg_map_under_size('room', nd.sk, nd.n);
    CONTINUE WHEN NOT FOUND;
    v_k := public.rpg_map_under_hash(nd.n);
    v_r := z.w_low * power(z.w_high / z.w_low, (public.rpg_map_roll(t.seed, 1752, v_k, 0) - 0.5) / 100) / 2 / t.sq;
    CONTINUE WHEN sqrt(power(nd.x + 0.5 - v_cx, 2) + power(nd.y + 0.5 - v_cy, 2)) > 1.25 * v_r + v_diag + 1;
    FOR j IN 0 .. p_rows - 1 LOOP
      FOR i IN 0 .. p_cols - 1 LOOP
        q := j * p_cols + i + 1;
        v_dist := sqrt(power(p_x0 + i - nd.x, 2) + power(p_y0 + j - nd.y, 2));
        CONTINUE WHEN v_dist > 1.25 * v_r + 0.5;
        -- its ragged edge: eight knots round, each 0.75 to 1.25 of its middle size, smooth between
        v_ang := (atan2(p_y0 + j - nd.y, p_x0 + i - nd.x) + pi()) / (2 * pi()) * 8;
        v_kf := v_ang - floor(v_ang); it := floor(v_ang)::integer;
        v_half := v_r * (0.75 + 0.5 * ((public.rpg_map_roll(t.seed, 1753, v_k, mod(it, 8)) - 0.5) / 100
                         + ((public.rpg_map_roll(t.seed, 1753, v_k, mod(it + 1, 8)) - 0.5) / 100 - (public.rpg_map_roll(t.seed, 1753, v_k, mod(it, 8)) - 0.5) / 100)
                           * v_kf * v_kf * (3 - 2 * v_kf)));
        CONTINUE WHEN v_dist > greatest(v_half, 1.5);
        v_way[q] := nd.n; v_room[q] := true; v_gr[q] := z.ground; v_dn[q] := nd.d; v_pool[q] := z.pool; v_col[q] := z.col; v_cl[q] := NULL;
        IF v_dist < 1 THEN v_mid[q] := true; END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN QUERY
  WITH sq AS (
         SELECT p_x0 + mod(g.k - 1, p_cols) AS sx, p_y0 + (g.k - 1) / p_cols AS sy, v_way[g.k] AS w, v_gr[g.k] AS gr, v_dn[g.k] AS dn,
                v_mid[g.k] AS mid, v_pool[g.k] AS pl, v_col[g.k] AS cl, v_cl[g.k] AS climb
           FROM generate_series(1, v_n) AS g(k) WHERE v_way[g.k] IS NOT NULL),
       b AS (SELECT DISTINCT ON (sq.gr) sq.gr, r.low, r.high, r.thicket, r.share
               FROM sq LEFT JOIN LATERAL public.rpg_map_band(sq.gr, NULL) r ON true WHERE sq.gr IS NOT NULL),
       n1 AS MATERIALIZED (SELECT * FROM public.rpg_map_under_patch(1761, p_x0, p_y0, p_cols, p_rows, 3)),
       pd AS MATERIALIZED (
         SELECT gi * 8 + 8 * (public.rpg_map_roll(t.seed, 1764, w.wi, gj) - 0.5) / 100.0 AS px,
                gj * 8 + 8 * (public.rpg_map_roll(t.seed, 1765, w.wi, gj) - 0.5) / 100.0 AS py,
                1.2 + 2.3 * (public.rpg_map_roll(t.seed, 1766, w.wi, gj) - 0.5) / 100.0 AS r,
                public.rpg_map_roll(t.seed, 1762, w.wi, gj) AS pr
           FROM generate_series(floor((p_x0 - 4) / 8.0)::bigint, floor((p_x0 + p_cols + 4) / 8.0)::bigint) AS gi
          CROSS JOIN generate_series(floor((p_y0 - 4) / 8.0)::integer, floor((p_y0 + p_rows + 4) / 8.0)::integer) AS gj
          CROSS JOIN LATERAL (SELECT mod(mod(gi, t.span / 8) + t.span / 8, t.span / 8)::integer AS wi) w
          WHERE EXISTS (SELECT 1 FROM sq WHERE sq.pl > 0)),
       f AS (SELECT sq.*, n1.v AS hd,
                    CASE WHEN sq.pl > 0 THEN (SELECT min(sqrt(power(sq.sx + 0.5 - pd.px, 2) + power(sq.sy + 0.5 - pd.py, 2)) / pd.r) FROM pd
                                               WHERE pd.pr <= sq.pl * 380 AND abs(pd.px - sq.sx) < 4 AND abs(pd.py - sq.sy) < 4) END AS pn,
                    sq.cl > 0 AND NOT sq.mid AND public.rpg_map_roll(t.seed, 1763, mod(mod(sq.sx, t.span) + t.span, t.span)::integer, sq.sy) <= round(sq.cl * 1000) / 10.0 AS stone
               FROM sq JOIN n1 ON n1.x = sq.sx AND n1.y = sq.sy)
  SELECT f.sx, f.sy,
         CASE WHEN f.climb IS NOT NULL OR f.gr IS NULL THEN 'shaft' WHEN f.stone THEN 'column' WHEN f.pn < 1 THEN 'pool'
              WHEN b.thicket IS NOT NULL AND f.hd >= 1 - b.share THEN 'rubble' ELSE 'floor' END,
         f.gr,
         CASE WHEN f.climb IS NOT NULL OR f.gr IS NULL THEN f.climb WHEN f.stone THEN NULL
              WHEN f.pn < 1 THEN public.rpg_map_wade_pct(0.1 + 0.8 * (1 - f.pn))
              ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, f.hd) END,
         f.hd,
         CASE WHEN f.climb IS NULL AND NOT f.stone AND f.pn < 1 THEN round((0.1 + 0.8 * (1 - f.pn))::numeric, 2)::double precision END,
         f.dn, f.w
    FROM f LEFT JOIN b ON b.gr = f.gr
   ORDER BY f.sy, f.sx;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_near(p_node text, p_find boolean, p_also text)
 RETURNS TABLE(kind text, a text, b text, ax bigint, ay bigint, bx bigint, by bigint, ad double precision, bd double precision, bend double precision, name text, near boolean, skind text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The passages of a node of the world under the ground (step 12d3 moved them out of rpg_map_under_ways, so the battle
-- grid under the ground reads the same ones with their curves: rpg_map_under_layer), the one home of them: every passage
-- of it (rows of rpg_map_under_edges), read over just enough of the world: round a great hall the halls next to it and
-- the chamber over it; round a chamber the chambers next to it and the great hall whose shaft comes up into it; at the
-- mouth or the end of the passage of a cave or a mine that passage and where its end breaks through. The ways up from
-- a chamber or a great hall into the passage of a cave or a mine are hidden: listed once the group knows them
-- (rpg_map_under_known: walked or found), or p_find (a search, rpg_map_under_search: rpg_map_under_ends over the
-- chamber's or the hall's lattice square), or p_also (that one node, end:<site>, when a walk heads there).
DECLARE
  t record; v_n record; v_box bigint[]; v_cbox bigint[]; v_sites jsonb := '[]'::jsonb; v_deep boolean := true; v_cell bigint[];
BEGIN
  SELECT * INTO t FROM public.rpg_map_under_lattice();
  SELECT * INTO v_n FROM public.rpg_map_under_node(p_node);
  IF NOT FOUND THEN RETURN; END IF;
  IF p_node LIKE 'deep-%' OR p_node LIKE 'cave-%' THEN
    -- the caves and mines known (or asked for) to break into it
    SELECT coalesce(jsonb_agg(n.site), '[]'::jsonb) INTO v_sites
      FROM (SELECT DISTINCT substr(q.k, length(p_node) + 6) AS sid FROM public.rpg_map_under_known() q WHERE q.k LIKE p_node || '|end:%'
            UNION SELECT substr(p_also, 5) WHERE p_also LIKE 'end:%') s
     CROSS JOIN LATERAL public.rpg_map_under_node('end:' || s.sid) n;
  END IF;
  IF p_node LIKE 'deep-%' THEN
    v_box := ARRAY[v_n.x - t.ds, v_n.y - t.ds, v_n.x + t.ds, v_n.y + t.ds];
    v_cbox := ARRAY[floor(v_n.x::double precision / t.cs)::bigint * t.cs, floor(v_n.y::double precision / t.cs)::bigint * t.cs,
                    floor(v_n.x::double precision / t.cs)::bigint * t.cs + t.cs, floor(v_n.y::double precision / t.cs)::bigint * t.cs + t.cs];
    v_cell := ARRAY[floor(v_n.x::double precision / t.ds)::bigint * t.ds, floor(v_n.y::double precision / t.ds)::bigint * t.ds,
                    floor(v_n.x::double precision / t.ds)::bigint * t.ds + t.ds, floor(v_n.y::double precision / t.ds)::bigint * t.ds + t.ds];
    IF p_find THEN v_sites := v_sites || public.rpg_map_under_ends(v_cell, ARRAY[4], 'delve'); END IF;
  ELSIF p_node LIKE 'cave-%' THEN
    v_box := ARRAY[v_n.x - t.cs, v_n.y - t.cs, v_n.x + t.cs, v_n.y + t.cs];
    v_cbox := v_box;
    v_cell := ARRAY[floor(v_n.x::double precision / t.cs)::bigint * t.cs, floor(v_n.y::double precision / t.cs)::bigint * t.cs,
                    floor(v_n.x::double precision / t.cs)::bigint * t.cs + t.cs, floor(v_n.y::double precision / t.cs)::bigint * t.cs + t.cs];
    IF p_find THEN v_sites := v_sites || public.rpg_map_under_ends(v_cell, ARRAY[4, 5], 'join'); END IF;
  ELSE
    v_box := ARRAY[v_n.x - 1, v_n.y - 1, v_n.x + 2, v_n.y + 2];
    v_sites := jsonb_build_array(v_n.site);
    SELECT ARRAY[floor(o.ex::double precision / t.cs)::bigint * t.cs, floor(o.ey::double precision / t.cs)::bigint * t.cs,
                 floor(o.ex::double precision / t.cs)::bigint * t.cs + t.cs, floor(o.ey::double precision / t.cs)::bigint * t.cs + t.cs]
      INTO v_cbox
      FROM public.rpg_map_under_own(v_n.site ->> 0, (v_n.site ->> 1)::integer, v_n.site ->> 2, (v_n.site ->> 3)::bigint, (v_n.site ->> 4)::bigint) o;
  END IF;
  RETURN QUERY
  SELECT u.* FROM public.rpg_map_under_edges(v_box, v_deep, v_cbox, v_sites) u
   WHERE u.kind <> 'hall' AND (u.a = p_node OR u.b = p_node);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.rpg_map_under_layer(p_at text, p_to text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The passages round where a piece under the ground is (step 12d3), as rpg_map_under_squares takes them: every passage
-- of the node it stands at (rpg_map_under_near: the hidden ways up only once known), and when it is partway along a
-- passage (p_to) every passage of the node it is heading for too. So its battle grid shows the passage it is in, the
-- room at its end and the ways that leave that room, and nothing else of the world under the ground. Kept for the
-- transaction (rpg.ulayer, by the two nodes) so a fight that reads one square at a time reads the passages once.
DECLARE v_all jsonb; v_key text := coalesce(p_at, '') || '|' || coalesce(p_to, ''); v_out jsonb;
BEGIN
  IF p_at IS NULL THEN RETURN '[]'::jsonb; END IF;
  v_all := coalesce(nullif(current_setting('rpg.ulayer', true), ''), '{}')::jsonb;
  IF v_all ? v_key THEN RETURN v_all -> v_key; END IF;
  SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object('kind', u.kind, 'a', u.a, 'b', u.b, 'ax', u.ax, 'ay', u.ay, 'bx', u.bx, 'by', u.by,
                                                        'ad', u.ad, 'bd', u.bd, 'bend', u.bend, 'skind', u.skind)), '[]'::jsonb)
    INTO v_out
    FROM unnest(ARRAY[p_at, p_to]) AS n(node)
   CROSS JOIN LATERAL public.rpg_map_under_near(n.node, false, CASE WHEN n.node = p_at THEN p_to ELSE p_at END) u
   WHERE n.node IS NOT NULL;
  PERFORM set_config('rpg.ulayer', (v_all || jsonb_build_object(v_key, v_out))::text, true);
  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_fight_layer(p_session_id uuid, p_x integer, p_y integer)
 RETURNS TABLE(under_at text, under_to text, under_done double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a fight's board at a square (world squares from 1, as pieces stand) is under the ground, and where (step
-- 12d3), the one home of that: as the piece of the journey nearest that square stands (rpg_square_gap; a creature
-- first, then the turn order, on a tie). under_at, under_to, under_done are its place under the ground (nothing on the
-- surface). A fight happens where its fighters are: a creature met under the ground stands where the one who met it is.
SELECT p.under_at, p.under_to, p.under_done
  FROM public.rpg_session_participants p
 WHERE p.session_id = p_session_id AND p.pos_x IS NOT NULL
 ORDER BY public.rpg_square_gap(p.pos_x, p.pos_y, p_x, p_y), (p.creature_id IS NOT NULL) DESC, p.turn_order, p.created_at
 LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_haunters(p_kind text, p_skind text)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The creature cards met in a passage under the ground (step 12d3), the way rpg_map_haunters finds those of a square of
-- the surface: every card whose haunt_under holds the kind of ground below the passage is in: deep (a passage or a
-- shaft of the Deeps), mine (the own passage of a mine), else cave (cave country, the own passage of a cave, and the
-- squeezes where a cave or a mine breaks through). Nothing when no card does.
SELECT array_agg(c.id ORDER BY c.id)
  FROM public.rpg_creatures c
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active
   AND c.haunt_under @> ARRAY[CASE WHEN p_kind IN ('deep', 'shaft') THEN 'deep' WHEN p_kind = 'own' AND p_skind = 'mine' THEN 'mine' ELSE 'cave' END];
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_meet_roll(p_h0 bigint, p_h1 bigint)
 RETURNS TABLE(rolls integer[], hour integer)
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The hourly roll for meeting a creature (Peter 2026-10-03, 1A), the one home of it (step 12d3 moved it out of
-- rpg_map_walk so a walk under the ground rolls the same way): a piece has spent p_h0 ticks in haunts and now p_h1; for
-- every full hour passed between (ticks_per_hour) the site rolls a d100, and at encounter_chance (15) or less a creature
-- is met: hour = which hour that was (counted from the first in a haunt), and no more rolls are made. rolls = every roll.
DECLARE v_tph integer := public.rpg_setting('ticks_per_hour')::integer; v_chance integer := public.rpg_setting('encounter_chance')::integer;
        v_h integer; v_d integer;
BEGIN
  rolls := '{}';
  FOR v_h IN (p_h0 / v_tph)::integer + 1 .. (p_h1 / v_tph)::integer LOOP
    v_d := floor(random() * 100)::integer + 1;
    rolls := rolls || v_d;
    IF v_d <= v_chance THEN hour := v_h; EXIT; END IF;
  END LOOP;
  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_meet_words(p_rolls integer[], p_met boolean)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What the hourly rolls for meeting a creature say in the log (step 12d3, the words rpg_map_walk wrote, so every walk
-- says them the same way): when one met, the last roll; else every roll; nothing when none was rolled.
SELECT CASE WHEN coalesce(cardinality(p_rolls), 0) = 0 THEN ''
            WHEN p_met THEN ' An hour in a haunt: the site rolls ' || p_rolls[cardinality(p_rolls)] || ', ' || public.rpg_setting('encounter_chance')::integer || ' or less meets a creature.'
            ELSE ' Hours in a haunt: the site rolls ' || array_to_string(p_rolls, ', ') || ' (' || public.rpg_setting('encounter_chance')::integer || ' or less meets a creature).' END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_meet(p_participant_id uuid, p_card uuid, p_walk integer, p_x integer, p_y integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A creature of card p_card is met by a piece on its walk (step 12d3 moved this out of rpg_map_walk so a walk under the
-- ground meets creatures the same way): it joins the journey (rpg_session_add), under the ground where the piece is
-- when the piece is there, and is set down encounter_squares (10) from p_x, p_y (rpg_map_set_down); both see each
-- other when the walk stops, so each first acts one beat after that moment (p_walk ticks into the turn), and the fight
-- is on. Returns its name and how far away it is.
DECLARE v_p record; v_cp uuid; v_gap integer; v_name text;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  PERFORM set_config('rpg.engine', 'on', true);
  v_cp := public.rpg_session_add(v_p.session_id, NULL, p_card);
  IF v_p.under_at IS NOT NULL THEN
    UPDATE public.rpg_session_participants SET under_at = v_p.under_at, under_to = v_p.under_to, under_done = v_p.under_done WHERE id = v_cp;
  END IF;
  PERFORM public.rpg_map_set_down(v_cp, p_x, p_y, public.rpg_setting('encounter_squares')::integer);
  UPDATE public.rpg_session_participants
     SET next_tick = (SELECT s.clock FROM public.rpg_sessions s WHERE s.id = v_p.session_id) + p_walk + public.rpg_action_ticks(v_cp, 1)
   WHERE id = v_cp;
  UPDATE public.rpg_sessions SET turn_move_ticks = p_walk + public.rpg_action_ticks(p_participant_id, 1) WHERE id = v_p.session_id;
  SELECT c.name, public.rpg_square_gap(p_x, p_y, c.pos_x, c.pos_y) INTO v_name, v_gap FROM public.rpg_session_participants c WHERE c.id = v_cp;
  RETURN v_name || CASE WHEN v_gap IS NULL THEN ' is here!' ELSE ' appears ' || public.rpg_map_length_text(v_gap) || ' away!' END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_grounds()
 RETURNS TABLE(kind text, name text, ch text, penalty_key text, forest boolean)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- Every kind of unnamed ground on the world map, the one list of them (Peter 2026-10-03: more climates; rivers and
-- lakes; villages, towns and cities, step 8; roads, step 8b: a road, and a road over mountains, whose range is that of
-- mountains kept to map_road_keep, rpg_map_band; the floors under the ground, step 12d3: of the Deeps +10% to +40%, of a
-- cave +100% to +357% with rubble +400% for one square in eight, of a mine +20% to +80%, a squeeze +300% to +500%, so
-- their average squares are the times a walk under the ground takes, 25, 250, 50 and 400), in the order the key lists them: its name in words, its letter on a grid drawn fine (rpg_map_view_block
-- detail; the page reads the same letters, MAP_GROUNDS in Roleplaying.jsx), the setting that holds the least percent
-- of time a square of it adds to cross it (the most is the same key with _high; rpg_map_band; water goes by its depth,
-- rpg_map_wade_pct; deep water is swum, step 7b; the sea = no walking in), and whether it is forest (it has trees: it burns and
-- hides like forest).
SELECT g.kind, g.name, g.ch, g.penalty_key, g.forest
  FROM (VALUES (1, 'sea', 'Sea', '~', NULL, false),
               (2, 'land', 'Open land', '.', 'map_land_penalty', false),
               (3, 'plains', 'Grassy plains', 'g', 'map_plains_penalty', false),
               (4, 'forest', 'Forest', 't', 'map_forest_penalty', true),
               (5, 'pine', 'Pine forest', 'p', 'map_pine_penalty', true),
               (6, 'jungle', 'Jungle', 'j', 'map_jungle_penalty', true),
               (7, 'hills', 'Hills', 'h', 'map_hills_penalty', false),
               (8, 'mountains', 'Mountains', 'm', 'map_mountain_penalty', false),
               (9, 'desert', 'Desert', 'd', 'map_desert_penalty', false),
               (10, 'tundra', 'Tundra', 'u', 'map_tundra_penalty', false),
               (11, 'ice', 'Snow and ice', 'i', 'map_ice_penalty', false),
               (12, 'swamp', 'Swamp', 's', 'map_swamp_penalty', false),
               (13, 'water', 'Shallow water', 'w', NULL, false),
               (14, 'deep', 'Deep water', 'k', NULL, false),
               (15, 'town', 'Village, town or city', 'n', 'map_town_penalty', false),
               (16, 'road', 'Road', 'r', 'map_road_penalty', false),
               (17, 'pass', 'Mountain road', 'a', NULL, false),
               (18, 'under_deep', 'Floor of the Deeps', 'D', 'map_under_deep_penalty', false),
               (19, 'under_cave', 'Cave floor', 'C', 'map_under_cave_penalty', false),
               (20, 'under_mine', 'Mine floor', 'M', 'map_under_mine_penalty', false),
               (21, 'under_squeeze', 'Squeeze', 'Q', 'map_under_squeeze_penalty', false)) AS g(n, kind, name, ch, penalty_key, forest)
 ORDER BY g.n;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_band(p_kind text, p_place uuid DEFAULT NULL::uuid)
 RETURNS TABLE(low integer, high integer, thicket integer, share double precision, forest boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The range of a kind of ground, the one home of it (Peter 2026-10-03 22:05, 1B: it must match reality): the least
-- and the most percent of time a square of it adds to cross it, and for forest its thickets. Unnamed ground reads the
-- settings rpg_map_grounds names (forest 20 to 150, thickets 400 for one square in eight; cave floor 100 to 357, its
-- rubble the same 400 for one square in eight, step 12d3); a place reads its card
-- (place_penalty to place_penalty_high), and a place that is forest has thickets too unless its range already reaches
-- them (Bramblemaw's Lair is all thicket, 400). Shallow water runs from a trickle to just short of swimming
-- (rpg_map_wade_pct: 10 to 190); a square of it goes by its depth, not by a roll. A road over mountains (pass, step 8b)
-- keeps map_road_keep (3/5) of the time of mountains: walking off a path takes 5/3 as long as on one (Tobler 1993), so
-- mountains of +200% to +500% (3 to 6 times the time) are +80% to +260% on their roads. thicket = the percent of a thicket,
-- nothing when it has none; share = how many of its squares are thicket (0 when none). The sea, deep water (swum, not
-- walked: rpg_map_wade_pct), or a place that only names the land, has no row.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     t AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_thicket_penalty')::integer AS pct,
                  (SELECT st.value FROM st WHERE st.key = 'map_thicket_share')::double precision AS share),
     b AS (SELECT c.place_penalty AS low, coalesce(c.place_penalty_high, c.place_penalty) AS high,
                  coalesce(c.place_forest, false) AS forest, coalesce(c.place_forest, false) AS thick
             FROM public.rpg_creatures c
            WHERE p_kind = 'place' AND c.id = p_place AND c.place_penalty IS NOT NULL
           UNION ALL
           SELECT (SELECT st.value FROM st WHERE st.key = g.penalty_key)::integer,
                  (SELECT st.value FROM st WHERE st.key = g.penalty_key || '_high')::integer,
                  g.forest, g.kind IN ('forest', 'pine', 'under_cave')
             FROM public.rpg_map_grounds() g
            WHERE g.kind = p_kind AND g.penalty_key IS NOT NULL
           UNION ALL
           SELECT public.rpg_map_wade_pct(0), public.rpg_map_wade_pct((SELECT st.value FROM st WHERE st.key = 'map_swim_depth')::double precision - 0.001), false, false
            WHERE p_kind = 'water'
           UNION ALL
           SELECT round((SELECT st.value FROM st WHERE st.key = 'map_road_keep') * (100 + (SELECT st.value FROM st WHERE st.key = 'map_mountain_penalty')) - 100)::integer,
                  round((SELECT st.value FROM st WHERE st.key = 'map_road_keep') * (100 + (SELECT st.value FROM st WHERE st.key = 'map_mountain_penalty_high')) - 100)::integer,
                  false, false
            WHERE p_kind = 'pass')
SELECT b.low, b.high,
       CASE WHEN b.thick AND b.high < t.pct THEN t.pct END,
       CASE WHEN b.thick AND b.high < t.pct THEN t.share ELSE 0 END,
       b.forest
  FROM b CROSS JOIN t;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_site(p_id text)
 RETURNS TABLE(id text, rank integer, kind text, name text, x bigint, y bigint, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cave or mine at a site (step 12d2), found by its id alone (mark-<w6>-<y6>): the site of the rank whose rank-6
-- square that is (rpg_map_under_site_rank, step 12d3), and what stands there (rpg_map_landmarks at the grid of its rank, one
-- cell), when it is a cave or a mine. Its column is counted round the world.
SELECT m.id, m.rank, m.kind, m.name, m.x, m.y, m.height, m.across
  FROM (SELECT split_part(p_id, '-', 2)::bigint AS w6, split_part(p_id, '-', 3)::bigint AS y6, public.rpg_map_under_site_rank(p_id) AS rk) s
 CROSS JOIN public.rpg_map_landmark_lattice() t
 CROSS JOIN LATERAL public.rpg_map_landmark_site(s.rk, floor(s.w6::double precision / 12 ^ (6 - s.rk))::bigint, floor(s.y6::double precision / 12 ^ (6 - s.rk))::bigint,
                                                 t.seed, t.l6, t.jit, t.a6) st
  JOIN public.rpg_map_ladder() l ON l.level = s.rk
 CROSS JOIN LATERAL public.rpg_map_landmarks(s.rk, floor(st.x::double precision / l.cell)::integer, floor(st.y::double precision / l.cell)::integer, 1, 1, NULL) m
 WHERE m.id = p_id AND m.kind IN ('cave', 'mine');
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_ways(p_node text, p_find boolean, p_also text)
 RETURNS TABLE(to_node text, kind text, skind text, up boolean, metres double precision, base numeric, to_x bigint, to_y bigint, to_depth double precision, to_sea boolean, to_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ways on from a node of the world under the ground (step 12d2), the one home of them: every passage of it
-- (rpg_map_under_near, step 12d3: read over just enough of the world, the hidden ways up only once known, searched for
-- with p_find, or the one p_also a walk heads to) to the node at its other end.
-- metres = how far the passage runs: along its curve (rpg_map_under_curve: the chord, plus two thirds of the square of
-- its swing, a share of a quarter of its length) and down or up the difference in depth (a shaft straight up or down); up = it climbs.
-- base = its time at Speed 10 in ticks: every square of it takes move_ticks (5) and its percent more, the average
-- square of the ground its floor is (rpg_map_under_size, rpg_map_band, rpg_map_pct; step 12d3, the same squares its
-- battle grid has): the Deeps +25%, cave country and the passage of a cave +250% (a share of it rubble), the galleries
-- of a mine +50%, a squeeze where a cave or mine breaks through to cave country or the Deeps +400%; a shaft is climbed
-- at map_climb_rate (300 m an hour) up or down. to_* = the node at the other end
-- (rpg_map_under_node).
DECLARE
  t record;
BEGIN
  SELECT * INTO t FROM public.rpg_map_under_lattice();
  RETURN QUERY
  WITH e AS (
         SELECT u.*, u.a = p_node AS fwd FROM public.rpg_map_under_near(p_node, p_find, p_also) u),
       w AS (
         SELECT DISTINCT ON (CASE WHEN e.fwd THEN e.b ELSE e.a END)
                CASE WHEN e.fwd THEN e.b ELSE e.a END AS nb, e.kind AS k, e.skind AS sk,
                CASE WHEN e.fwd THEN e.bd - e.ad ELSE e.ad - e.bd END AS dd,
                (SELECT c.len FROM public.rpg_map_under_curve(e.ax, e.ay, e.bx, e.by, e.bend, 0) c) * t.sq AS flat
           FROM e ORDER BY CASE WHEN e.fwd THEN e.b ELSE e.a END, e.kind)
  SELECT w.nb, w.k, w.sk,
         -- a great hall lies below the level of the sea, the rest below the ground: going from a hall up into cave
         -- country, or from a passage end down to a hall, is a shaft either way
         CASE WHEN w.k = 'shaft' THEN p_node LIKE 'deep-%' WHEN w.k = 'delve' THEN p_node LIKE 'deep-%' ELSE w.dd < 0 END,
         CASE WHEN w.k = 'shaft' THEN abs(w.dd) ELSE sqrt(power(w.flat, 2) + power(w.dd, 2)) END,
         CASE WHEN w.k = 'shaft'
              THEN abs(w.dd) / public.rpg_setting('map_climb_rate') * public.rpg_setting('ticks_per_hour')
              ELSE sqrt(power(w.flat, 2) + power(w.dd, 2)) / t.sq * public.rpg_setting('move_ticks')
                   * (1 + (SELECT public.rpg_map_pct(r.low, r.high, r.thicket, r.share, NULL)
                             FROM public.rpg_map_under_size(w.k, w.sk, p_node) z
                            CROSS JOIN LATERAL public.rpg_map_band(z.ground, NULL) r) / 100.0) END::numeric,
         m.x, m.y, m.depth, m.sea, m.name
    FROM w CROSS JOIN LATERAL public.rpg_map_under_node(w.nb) m;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_in_fight(p_participant_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Whether a piece on a journey is in a fight: a creature still in it (not dead, not waiting to rise) stands within
-- the longest reach of it (rpg_fight_reach: 164 squares), on the same side of the ground: both under it or both on it
-- (step 12d3). A creature is always in its own fight.
SELECT p.pos_x IS NOT NULL AND (p.creature_id IS NOT NULL OR EXISTS (
         SELECT 1 FROM public.rpg_session_participants c
          WHERE c.session_id = p.session_id AND c.id <> p.id AND c.creature_id IS NOT NULL AND c.pos_x IS NOT NULL
            AND NOT public.rpg_participant_out(c.id) AND (c.under_at IS NULL) = (p.under_at IS NULL)
            AND public.rpg_square_gap(p.pos_x, p.pos_y, c.pos_x, c.pos_y) <= public.rpg_fight_reach()))
  FROM public.rpg_session_participants p WHERE p.id = p_participant_id;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_set_down(p_participant_id uuid, p_x integer, p_y integer, p_squares integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Puts a newly met creature on the map p_squares away from a square (world squares from 1): one of the eight ways at
-- random, on ground nobody stands on, never in the sea, in water too deep to wade (rpg_map_swim) or on a house
-- (rpg_map_building_cells; step 8c); nearer if no way is
-- free that far. Under the ground (step 12d3) only the battle grid under the ground counts (rpg_fight_square: no rock,
-- no column of stone). Returns whether it found a square.
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
      CONTINUE WHEN v_p.under_at IS NULL AND EXISTS (SELECT 1 FROM public.rpg_map_swim(v_x, v_y));
      CONTINUE WHEN v_p.under_at IS NULL AND EXISTS (SELECT 1 FROM public.rpg_map_building_cells(7, v_x - 1, v_y - 1, 1, 1));
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
-- Under the ground (step 12d3) nothing on the surface is climbed: the walls of the battle grid under the ground are
-- solid rock (no way in), and a shaft is crossed at its climbing time.
-- Returns {made, text}, or nothing when the square is not a cliff and nothing built stands on it.
DECLARE
  v_p record; v_s record; v_c record; v_key text; v_skill numeric; v_r jsonb; v_nc jsonb; v_roll integer; v_made boolean;
  v_text text; v_gear boolean; v_harm integer := 0; v_roll_id uuid; v_out text; v_max integer;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.character_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT coalesce(v_s.on_map, false) OR v_p.under_at IS NOT NULL THEN RETURN NULL; END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_fight_squares(p_session_id uuid, p_x0 integer, p_y0 integer, p_w integer, p_h integer)
 RETURNS TABLE(x integer, y integer, penalty integer, forest boolean, burning boolean, sea boolean)
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
WITH s AS (SELECT t.terrain, t.round, t.on_map FROM public.rpg_sessions t WHERE t.id = p_session_id),
     ly AS MATERIALIZED (SELECT l.under_at, l.under_to FROM s CROSS JOIN LATERAL public.rpg_fight_layer(p_session_id, p_x0 + p_w / 2, p_y0 + p_h / 2) l
                          WHERE s.on_map AND l.under_at IS NOT NULL),
     m AS MATERIALIZED (SELECT c.x + 1 AS x, c.y + 1 AS y, c.kind, c.penalty, c.forest
                          FROM s CROSS JOIN LATERAL public.rpg_map_costs(7, p_x0 - 1, p_y0 - 1, p_w, p_h) c WHERE s.on_map AND NOT EXISTS (SELECT 1 FROM ly)),
     u AS MATERIALIZED (SELECT q.x + 1 AS x, q.y + 1 AS y, q.pct
                          FROM ly CROSS JOIN LATERAL public.rpg_map_under_squares(p_x0 - 1, p_y0 - 1, p_w, p_h, public.rpg_map_under_layer(ly.under_at, ly.under_to)) q),
     z AS (SELECT EXISTS (SELECT 1 FROM ly) AS under)
SELECT g.x, g.y,
       CASE WHEN z.under THEN CASE WHEN u.pct IS NULL THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE u.pct END
            WHEN m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL) THEN NULL WHEN s.terrain ? (g.x || ',' || g.y) AND (s.terrain->(g.x || ',' || g.y)) ? 'p' THEN i.penalty ELSE coalesce(m.penalty, i.penalty) END,
       coalesce(m.forest, false) OR i.forest, i.burning,
       CASE WHEN z.under THEN u.pct IS NULL ELSE coalesce(m.kind = 'sea' OR (m.kind = 'deep' AND m.penalty IS NULL), false) END
  FROM s CROSS JOIN z CROSS JOIN generate_series(p_x0, p_x0 + p_w - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_h - 1) AS gy(y)
 CROSS JOIN LATERAL (SELECT gx.x, gy.y) g
  LEFT JOIN m ON m.x = g.x AND m.y = g.y
  LEFT JOIN u ON u.x = g.x AND u.y = g.y
 CROSS JOIN LATERAL public.rpg_square_info(s.terrain->(g.x || ',' || g.y), s.round) i;
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
-- board, so there it can only take someone off.
DECLARE v_p record; v_s record; v_who text; v_keep boolean;
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'only the game master places fighters'; END IF;
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'not in this fight'; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id FOR UPDATE;
  IF v_s.status = 'ended' THEN RAISE EXCEPTION 'that fight is over'; END IF;
  IF p_x IS NULL OR p_y IS NULL THEN
    UPDATE public.rpg_session_participants SET pos_x = NULL, pos_y = NULL, walk_to_x = NULL, walk_to_y = NULL, under_at = NULL, under_to = NULL, under_done = 0
     WHERE id = p_participant_id;
  ELSE
    IF NOT v_s.on_map THEN RAISE EXCEPTION 'this fight is off the map, so it has no board; meet creatures on a journey'; END IF;
    IF p_x NOT BETWEEN 1 AND (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)
       OR p_y NOT BETWEEN 1 AND (SELECT l.span / 2 FROM public.rpg_map_ladder() l WHERE l.level = 1) THEN
      RAISE EXCEPTION 'that square is off the map';
    END IF;
    v_keep := v_p.under_at IS NOT NULL AND public.rpg_map_in_fight(p_participant_id);
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN
      RAISE EXCEPTION '%', CASE WHEN v_keep THEN 'that square is solid rock' ELSE 'that square is sea or water too rough to swim' END;
    END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on that square', v_who; END IF;
    UPDATE public.rpg_session_participants
       SET pos_x = p_x, pos_y = p_y, walk_to_x = NULL, walk_to_y = NULL,
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

CREATE OR REPLACE FUNCTION public.rpg_map_under_walk(p_participant_id uuid, p_to text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece under the ground walks one passage on its turn (step 12d2; Peter 2026-10-06 1A): from the node it stands at
-- to the node p_to at the other end of one of its ways (rpg_map_under_ways), or on along the passage it is partway
-- down (p_to its far end), or back (p_to the node it set off from). Its time is the way's base time for what is left
-- of the passage at the piece's Speed (rpg_ticks_at): the Deeps are big galleries (+25%), cave country and the passage
-- of a cave are crawled and scrambled (+250%: cavers make about 1 km an hour, a walker about 4.7), the galleries of a
-- mine are cut (+50%), a break-through is squeezed (+400%), a shaft is climbed at 300 m an hour up or down. The walking
-- day holds it as on the surface (walk_day_hours, 8): when the day runs out partway, the piece camps (camp_hours, 16)
-- in the passage, the part walked kept (under_done), and walks on next turn. Over its passage it stands on the square
-- under which it is (pos_x, pos_y): on the passage's own winding line (rpg_map_under_spot, step 12d3), so on the
-- battle grid under the ground it stands in the passage. Creatures are met under the ground as on the surface (step
-- 12d3): every full hour walked in a passage whose kind of ground a creature card haunts (rpg_map_under_haunters;
-- haunt_ticks carries the part hour on) the site rolls a d100 (rpg_map_meet_roll), and at encounter_chance (15) or
-- less one is met where that hour ran out: the walk stops there, partway along the passage, the creature joins there
-- (rpg_map_meet) and the fight is on, on the battle grid under the ground. What a player character walked the group
-- knows (map_under: the passage and the nodes at its ends, rpg_map_under_known). The time is the turn, and the turn
-- passes on.
DECLARE
  v_sid uuid; v_p record; v_w record; v_from text; v_to text; v_done double precision; v_left integer; v_need integer;
  v_walk integer; v_m double precision; v_camped boolean := false; v_arrived boolean; v_speed numeric; v_tph integer;
  v_day integer; v_camp integer; v_f double precision; v_x bigint; v_y bigint; v_span bigint; v_text text; v_next jsonb; v_key text;
  v_cards uuid[]; v_rolls integer[] := '{}'; v_hour integer; v_meet uuid; v_haunt bigint;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.under_at IS NULL THEN RAISE EXCEPTION '% is not under the ground', v_p.name; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  IF v_p.under_to IS NOT NULL THEN
    IF p_to = v_p.under_to THEN v_from := v_p.under_at; v_to := v_p.under_to; v_done := v_p.under_done;
    ELSIF p_to = v_p.under_at THEN v_from := v_p.under_to; v_to := v_p.under_at; v_done := NULL;
    ELSE RAISE EXCEPTION '% is partway along a passage: go on or go back', v_p.name;
    END IF;
  ELSE
    v_from := v_p.under_at; v_to := p_to; v_done := 0;
  END IF;
  SELECT * INTO v_w FROM public.rpg_map_under_ways(v_from, false, v_to) w WHERE w.to_node = v_to LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'no passage leads there from here'; END IF;
  IF v_done IS NULL THEN v_done := greatest(v_w.metres - v_p.under_done, 0); END IF;
  v_tph := public.rpg_setting('ticks_per_hour')::integer;
  v_day := public.rpg_setting('walk_day_hours')::integer * v_tph;
  v_camp := public.rpg_setting('camp_hours')::integer * v_tph;
  v_speed := public.rpg_participant_speed(p_participant_id);
  v_left := greatest(v_day - v_p.day_walk_ticks, 0);
  v_need := public.rpg_ticks_at(v_speed, (v_w.base * greatest(v_w.metres - v_done, 0) / greatest(v_w.metres, 0.001))::numeric);
  IF v_need <= v_left THEN
    v_walk := v_need; v_m := v_w.metres; v_arrived := true;
  ELSE
    v_walk := v_left; v_m := v_done + (v_w.metres - v_done) * v_left / greatest(v_need, 1); v_arrived := false; v_camped := true;
  END IF;
  -- a creature met: the hourly rolls over the time walked in a haunt; the walk stops where that hour ran out
  v_haunt := v_p.haunt_ticks;
  v_cards := public.rpg_map_under_haunters(v_w.kind, v_w.skind);
  IF v_cards IS NOT NULL AND v_walk > 0 THEN
    SELECT r.rolls, r.hour INTO v_rolls, v_hour FROM public.rpg_map_meet_roll(v_p.haunt_ticks, v_p.haunt_ticks + v_walk) r;
    IF v_hour IS NOT NULL THEN
      v_need := (v_hour::bigint * v_tph - v_p.haunt_ticks)::integer;
      v_m := v_done + (v_m - v_done) * v_need / v_walk;
      v_walk := v_need; v_arrived := false; v_camped := false;
      v_meet := v_cards[1 + floor(random() * cardinality(v_cards))::integer];
    END IF;
    v_haunt := v_p.haunt_ticks + v_walk;
  END IF;
  -- where it stands: the square of its spot on the passage (rpg_map_under_spot), or the node it came to
  v_f := CASE WHEN v_w.metres > 0 THEN v_m / v_w.metres ELSE 1 END;
  IF v_arrived THEN
    v_x := v_w.to_x; v_y := v_w.to_y;
  ELSE
    SELECT floor(s.x)::bigint, floor(s.y)::bigint INTO v_x, v_y
      FROM public.rpg_map_under_near(v_from, false, v_to) e
     CROSS JOIN LATERAL public.rpg_map_under_spot(e.kind, e.a, e.b, e.ax, e.ay, e.bx, e.by, e.bend, e.skind, CASE WHEN e.a = v_from THEN v_f ELSE 1 - v_f END) s
     WHERE (e.a = v_from AND e.b = v_to) OR (e.b = v_from AND e.a = v_to)
     LIMIT 1;
  END IF;
  SELECT l.span INTO v_span FROM public.rpg_map_ladder() l WHERE l.level = 1;
  UPDATE public.rpg_session_participants
     SET under_at = CASE WHEN v_arrived THEN v_to ELSE v_from END, under_to = CASE WHEN v_arrived THEN NULL ELSE v_to END,
         under_done = CASE WHEN v_arrived THEN 0 ELSE v_m END,
         pos_x = (mod(mod(v_x, v_span) + v_span, v_span) + 1)::integer, pos_y = (greatest(v_y, 0) + 1)::integer,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END, walk_to_x = NULL, walk_to_y = NULL,
         haunt_ticks = v_haunt
   WHERE id = p_participant_id;
  -- what the group knows of it
  v_key := least(v_from, v_to) || '|' || greatest(v_from, v_to);
  UPDATE public.rpg_characters
     SET map_under = map_under || (SELECT coalesce(jsonb_agg(k), '[]'::jsonb) FROM unnest(ARRAY[v_key, 'n:' || v_from] || CASE WHEN v_arrived THEN ARRAY['n:' || v_to] ELSE '{}'::text[] END) AS k
                                   WHERE NOT map_under ? k)
   WHERE id = v_p.character_id AND v_p.creature_id IS NULL AND NOT is_npc AND session_id IS NULL;
  UPDATE public.rpg_sessions
     SET turn_move_ticks = v_walk + CASE WHEN v_camped THEN v_camp ELSE 0 END, turn_action_ticks = 0, updated_at = now()
   WHERE id = v_sid;
  v_text := v_p.name || CASE WHEN v_walk > 0 THEN ' goes ' || public.rpg_map_length_text(round((v_m - v_done) / (SELECT u.sq FROM public.rpg_map_under_lattice() u))::numeric)
                                                  || CASE WHEN v_w.kind = 'shaft' OR v_w.kind = 'delve' THEN CASE WHEN v_w.up THEN ' up' ELSE ' down' END ELSE '' END
                                                  || ' in ' || public.rpg_map_duration_text(v_walk) ELSE ' has walked all day' END
         || CASE WHEN v_arrived THEN ', to ' || v_w.to_name || ', ' || to_char(round(v_w.to_depth / 0.3048), 'FM999,999') || ' feet '
                                     || CASE WHEN v_w.to_sea THEN 'below the sea' ELSE 'down' END || '.'
                 ELSE ' toward ' || v_w.to_name || CASE WHEN v_camped THEN ', and camps in the passage for ' || public.rpg_map_duration_text(v_camp) ELSE '' END || '. '
                      || public.rpg_map_length_text(round((v_w.metres - v_m) / (SELECT u.sq FROM public.rpg_map_under_lattice() u))::numeric) || ' to go.' END;
  -- a creature met (rpg_map_meet): it joins where the piece stands and the fight is on; the rolls in words
  IF v_meet IS NOT NULL THEN
    v_text := v_text || public.rpg_map_meet_words(v_rolls, true) || ' ' || public.rpg_map_meet(p_participant_id, v_meet, v_walk, (mod(mod(v_x, v_span) + v_span, v_span) + 1)::integer, (greatest(v_y, 0) + 1)::integer);
  ELSE
    v_text := v_text || public.rpg_map_meet_words(v_rolls, false);
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'camped', v_camped, 'stopped', CASE WHEN v_meet IS NOT NULL THEN 'meet' END, 'next', v_next);
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
    SELECT * INTO v_ly FROM public.rpg_fight_layer(p_session_id, v_bx0 + v_bw / 2, v_by0 + v_bh / 2);
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

CREATE OR REPLACE FUNCTION public.rpg_map_underground(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer, p_sites jsonb, p_all boolean)
 RETURNS TABLE(kind text, a text, b text, ax bigint, ay bigint, bx bigint, by bigint, ad double precision, bd double precision, bend double precision, name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The world under the ground a block of a grid shows (step 12d): the passages of rpg_map_underground's one home,
-- rpg_map_under_edges (step 12d2 moved them there so a walk reads them too), over the block: the Deeps from the
-- Continent grid down, cave country from the Country grid down, the caves and mines of p_sites (from rpg_map_landmarks,
-- as [id, rank, kind, x, y, height, across, near]) from the Region grid down. p_all = the whole of it (the game
-- master); else the own passage of a cave or mine found or known (near), and every passage and great hall the group has
-- walked or stood in (rpg_map_under_known). The battle grid (step 12d3) reads all three, over the block grown by the
-- most a great hall reaches (850 squares: 1,500 m across, a quarter more at its ragged edge), so a hall or a wide
-- passage whose middle lies off the block still shows on it (rpg_map_under_squares).
WITH kn AS MATERIALIZED (SELECT k.k FROM public.rpg_map_under_known() k WHERE NOT p_all),
     t AS (SELECT ARRAY[p_x0::bigint * l.cell - g.pad, p_y0::bigint * l.cell - g.pad, (p_x0 + p_cols)::bigint * l.cell + g.pad, (p_y0 + p_rows)::bigint * l.cell + g.pad] AS box
             FROM public.rpg_map_ladder() l CROSS JOIN (SELECT CASE WHEN p_level = 7 THEN 850 ELSE 0 END AS pad) g WHERE l.level = p_level),
     u AS (SELECT e.* FROM t
            CROSS JOIN LATERAL public.rpg_map_under_edges(t.box, p_level BETWEEN 2 AND 7 AND (p_all OR EXISTS (SELECT 1 FROM kn)),
                                                          CASE WHEN p_level BETWEEN 3 AND 7 AND (p_all OR EXISTS (SELECT 1 FROM kn)) THEN t.box END,
                                                          CASE WHEN p_level BETWEEN 4 AND 7 THEN p_sites END) e)
SELECT u.kind, u.a, u.b, u.ax, u.ay, u.bx, u.by, u.ad, u.bd, u.bend, u.name
  FROM u
 WHERE p_all OR (u.kind = 'own' AND u.near)
    OR EXISTS (SELECT 1 FROM kn WHERE kn.k = CASE WHEN u.kind = 'hall' THEN 'n:' || u.a ELSE least(u.a, u.b) || '|' || greatest(u.a, u.b) END);
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
-- of its length to one side)]; halls = the great halls of the Deeps in the block, each [name, x, y, metres down]. The
-- game master sees all of it; the kids login only the own passage of a cave or mine in a cell found or known.
-- On the battle grid (step 12d3) under = the battle grid under the ground instead: squares = every open square under the
-- block (rpg_map_under_squares), each [column, row (from the top-left corner of the block), part (floor, rubble, pool,
-- column, shaft), percent of time it adds (none: no way in), water metres deep, feet down], of the passages and rooms
-- of the Deeps and cave country under the block (rpg_map_underground) and of those round each piece under the ground
-- within 40 squares of it (rpg_map_under_layer: so the passage of a cave or a mine shows where a piece is in it);
-- every other square under it is solid rock. The kids login sees those the group knows, and those round its own pieces.
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
  v_caves     jsonb;
  v_under     jsonb;
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
       -- the battle grid: the squares of a place to go into walked like the ground (step 12c), one each
       ft AS MATERIALIZED (SELECT DISTINCT ON (f.x, f.y) f.x, f.y, f.part FROM public.rpg_map_landmark_cells(v_l.level, v_x0, v_y0, v_cols, v_rows) f
                            WHERE v_l.level = 7 AND f.angle IS NULL ORDER BY f.x, f.y, f.part),
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
                hb.id AS house, hb.part, hb.rise AS climb_rise, hb.angle AS climb_angle, hb.difficulty AS climb_dif, ft.part AS feature,
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
                   -- a square of a place to go into walked like the ground (step 12c): floor, hearth, altar or mouth
                   'feature', CASE WHEN cl.seen AND cl.part IS NULL THEN cl.feature END,
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
         (SELECT jsonb_agg(jsonb_build_object('id', ls.id, 'x', ls.x, 'y', ls.y)) FROM ls WHERE ls.shown),
         -- the caves and mines of the grid, for the world under the ground (step 12d)
         (SELECT jsonb_agg(jsonb_build_array(ls.id, ls.rank, ls.kind, ls.x, ls.y, ls.height, ls.across, ls.near)) FROM ls WHERE ls.kind IN ('cave', 'mine'))
    INTO v_cells, v_towns, v_kinds, v_shown, v_hseen, v_rivs, v_lands, v_lmk, v_caves;

  -- the world under the ground (step 12d): its passages and its great halls
  IF v_l.level BETWEEN 2 AND 6 THEN
    SELECT jsonb_build_object(
             'lines', coalesce(jsonb_agg(jsonb_build_array(u.kind, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell,
                                                           (u.bx - v_gx0) * 1000 / v_l.cell, (u.by - v_gy0) * 1000 / v_l.cell,
                                                           round(u.ad)::integer, round(u.bd)::integer, round(u.bend * 100)::integer)) FILTER (WHERE u.kind <> 'hall'), '[]'::jsonb),
             'halls', coalesce(jsonb_agg(jsonb_build_array(u.name, (u.ax - v_gx0) * 1000 / v_l.cell, (u.ay - v_gy0) * 1000 / v_l.cell, round(u.ad)::integer)
                                         ORDER BY u.name) FILTER (WHERE u.kind = 'hall'), '[]'::jsonb))
      INTO v_under
      FROM public.rpg_map_underground(v_l.level, v_x0, v_y0, v_cols, v_rows, v_caves, v_gm) u;
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
    'under', v_under,
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

REVOKE ALL ON FUNCTION public.rpg_map_under_sizes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_sizes() TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_site_rank(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_site_rank(text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_size(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_size(text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_hash(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_hash(text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_swing(text, double precision, double precision, double precision[], double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_swing(text, double precision, double precision, double precision[], double precision) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_curve(double precision, double precision, double precision, double precision, double precision, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_curve(double precision, double precision, double precision, double precision, double precision, double precision) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_spot(text, text, text, bigint, bigint, bigint, bigint, double precision, text, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_spot(text, text, text, bigint, bigint, bigint, bigint, double precision, text, double precision) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_patch(integer, integer, integer, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_patch(integer, integer, integer, integer, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_squares(integer, integer, integer, integer, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_squares(integer, integer, integer, integer, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_near(text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_near(text, boolean, text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_layer(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_layer(text, text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_fight_layer(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_fight_layer(uuid, integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_haunters(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_haunters(text, text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_meet_roll(bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_meet_roll(bigint, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_meet_words(integer[], boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_meet_words(integer[], boolean) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_meet(uuid, uuid, integer, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_meet(uuid, uuid, integer, integer, integer) TO service_role;

UPDATE public.rpg_rules
   SET body = replace(body,
'*At Speed 10 the 2,440-foot passage of Storm Grotto takes about 32 minutes, and the 1.26-mile squeeze from its far end into cave country about 2 hours 6 minutes.*',
'*At Speed 10 the 2,440-foot passage of Storm Grotto takes about 32 minutes, and the 1.26-mile squeeze from its far end into cave country about 2 hours 6 minutes.*

Under the ground there is a battle grid too, square for square like the one on the surface. A passage winds, widens and narrows as it goes: a passage of the Deeps is 50 to 300 feet wide, a cave passage 5 to 26 feet, a mine gallery 7 to 16 feet, a squeeze 2 to 5 feet (never less than a square). Chambers of cave country are 40 to 400 feet across, the great halls of the Deeps 1,000 to 4,900 feet. Everything else is solid rock: no way in. Floors cost time like ground on the surface: the Deeps +10% to +40%, cave floor +100% to +357% with fallen rock (+400%) on one square in eight, mine floor +20% to +80%, a squeeze +300% to +500%; a pool is waded by its depth, a column of stone is no way through, a shaft is climbed. Creatures are met under the ground the same way as in their haunts on the surface: every hour walked in a passage where a creature lives, a roll of 15 or less meets one, and the fight is on, on the battle grid under the ground.
*The average square of a floor is what a walk under the ground takes: cave floor is 0.875 x (100 + 357) / 2 + 0.125 x 400 = 250%, so at Speed 10 a square of it takes 5 x 3.5 = 17.5 ticks, about 3 seconds.*')
 WHERE key = 'world_map' AND agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND position('Under the ground there is a battle grid too' IN body) = 0;

