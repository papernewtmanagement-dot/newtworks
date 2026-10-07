-- Step 14b (Peter 2026-10-07 15:38, 1A): water under the ground on every grid. Each passage may carry a stream and each
-- room hold a lake (rpg_map_under_water, its chance the pool share of rpg_map_under_sizes); the battle grid wades and swims
-- them in place of scattered pools; the map draws them; a swim under the ground reads that water (rpg_map_under_swim).
-- No drops, no new tables, no settings; the saved map is unchanged (it holds the land only).

CREATE OR REPLACE FUNCTION public.rpg_map_under_sizes()
 RETURNS TABLE(what text, skind text, rank integer, w_low double precision, w_high double precision, ground text, pool double precision, col double precision)
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- How big the world under the ground is on the battle grid (step 12d3), the one home of those numbers, in metres, each
-- as many small as large between the two (a doubling scale): w_low to w_high = how wide a passage runs, or how far
-- across a room is; ground = the kind of ground its floor is (rpg_map_grounds: its range of percent, rpg_map_band;
-- a shaft has none, it is climbed); pool = the chance it carries a stream (a passage) or holds a lake (a room; step
-- 14b, rpg_map_under_water: Claude's figures from Earth's caves); col = the share of its floor
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
  ('deep',    NULL,   NULL, 15.0,   90.0,   'under_deep',    0.30, 0.005),
  ('cave',    NULL,   NULL, 1.5,    8.0,    'under_cave',    0.35, 0.02),
  ('join',    NULL,   NULL, 0.7,    1.5,    'under_squeeze', 0.0,  0.0),
  ('delve',   NULL,   NULL, 0.7,    1.5,    'under_squeeze', 0.0,  0.0),
  ('shaft',   NULL,   NULL, 3.0,    8.0,    NULL,            0.0,  0.0),
  ('own',     'cave', 4,    8.0,    40.0,   'under_cave',    0.45, 0.02),
  ('own',     'cave', 5,    2.0,    8.0,    'under_cave',    0.40, 0.02),
  ('own',     'cave', 6,    1.0,    3.0,    'under_cave',    0.30, 0.0),
  ('own',     'mine', 4,    3.0,    5.0,    'under_mine',    0.15, 0.0),
  ('own',     'mine', 5,    2.0,    3.5,    'under_mine',    0.15, 0.0),
  ('hall',    NULL,   NULL, 300.0,  1500.0, 'under_deep',    0.35, 0.01),
  ('chamber', NULL,   NULL, 12.0,   120.0,  'under_cave',    0.30, 0.02),
  ('end',     'cave', 4,    30.0,   100.0,  'under_cave',    0.35, 0.02),
  ('end',     'cave', 5,    8.0,    30.0,   'under_cave',    0.30, 0.02),
  ('end',     'cave', 6,    3.0,    8.0,    'under_cave',    0.20, 0.0),
  ('end',     'mine', 4,    6.0,    20.0,   'under_mine',    0.25, 0.0)
) AS s(what, skind, rank, w_low, w_high, ground, pool, col);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_water(p_kind text, p_skind text, p_node text, p_key text)
 RETURNS TABLE(part double precision, depth double precision, current double precision, dx double precision, dy double precision, knots double precision[])
 LANGUAGE sql
 STABLE
AS $function$
-- The water under the ground (step 14b; Peter 2026-10-07: water seen on the battle grid should show on the grids above),
-- the one home of it: whether a passage carries a stream or a room holds a lake, and its shape, decided once for that
-- passage or room so every grid draws the same water and the battle grid wades and swims it. p_kind, p_skind, p_node
-- as rpg_map_under_size takes them (p_kind room for a room); p_key = the passage (a|b) or the room (its node).
-- Its chance is the pool share of its size row (rpg_map_under_sizes, layer 1770 by rpg_map_under_hash of p_key). No row
-- when it is dry.
--   A stream runs down the middle of its passage: part = the share of the passage's width it covers (layer 1771),
--   depth = metres at its middle, shallowing to its edges (1772, on a doubling scale), current = how fast it pulls (m/s,
--   1773). A lake lies in its room: part = its middle size as a share of the room's (1771), depth at its deepest (1772),
--   dx, dy = how far its middle sits from the room's, as shares of the room's size (1774, 1775), knots = its own ragged
--   edge, eight from the west going north as a room's are (1776), current none.
-- Claude's figures from Earth's caves (Peter rules on the look): cave streams mostly ankle to knee deep and walking
-- pace or slower, the river passages of the great caves (Mammoth Cave's Echo River, Son Doong's) deep enough to swim; most
-- chambers dry, many with a lake or a sump, the big ones with lakes many metres deep; a mine drains along a shallow
-- ditch, and a worked-out stope floods deep. The Deeps amplified.
WITH c AS (SELECT CASE WHEN p_kind = 'room' THEN CASE WHEN p_node LIKE 'deep-%' THEN 'hall' WHEN p_node LIKE 'cave-%' THEN 'chamber'
                                                     WHEN p_node LIKE 'end:%' THEN 'end_' || coalesce(p_skind, 'cave') END
                       WHEN p_kind = 'own' THEN 'own_' || coalesce(p_skind, 'cave') ELSE p_kind END AS cls),
     v AS (SELECT * FROM (VALUES
             -- class,      depth low, high, part low, high, current low, high (m/s)
             ('deep',       0.6,  2.5,  0.30, 0.60, 0.3, 1.2),
             ('cave',       0.2,  1.0,  0.40, 0.90, 0.2, 0.8),
             ('own_cave',   0.2,  0.8,  0.40, 0.90, 0.2, 0.6),
             ('own_mine',   0.1,  0.4,  0.30, 0.60, 0.1, 0.3),
             ('hall',       3.0,  15.0, 0.30, 0.70, 0.0, 0.0),
             ('chamber',    1.0,  6.0,  0.35, 0.75, 0.0, 0.0),
             ('end_cave',   1.0,  4.0,  0.40, 0.80, 0.0, 0.0),
             ('end_mine',   2.0,  8.0,  0.50, 0.90, 0.0, 0.0)) AS s(cls, d_low, d_high, p_low, p_high, c_low, c_high)),
     g AS (SELECT t.seed, public.rpg_map_under_hash(p_key) AS h FROM public.rpg_map_under_lattice() t)
SELECT v.p_low + (v.p_high - v.p_low) * (public.rpg_map_roll(g.seed, 1771, g.h, 0) - 0.5) / 100,
       v.d_low * power(v.d_high / v.d_low, (public.rpg_map_roll(g.seed, 1772, g.h, 0) - 0.5) / 100),
       v.c_low + (v.c_high - v.c_low) * (public.rpg_map_roll(g.seed, 1773, g.h, 0) - 0.5) / 100,
       CASE WHEN p_kind = 'room' THEN 0.4 * (public.rpg_map_roll(g.seed, 1774, g.h, 0) - 50.5) / 99 ELSE 0 END,
       CASE WHEN p_kind = 'room' THEN 0.4 * (public.rpg_map_roll(g.seed, 1775, g.h, 0) - 50.5) / 99 ELSE 0 END,
       ARRAY(SELECT (public.rpg_map_roll(g.seed, 1776, g.h, n) - 0.5) / 100 FROM generate_series(0, 7) AS n ORDER BY n)
  FROM c JOIN v ON v.cls = c.cls
 CROSS JOIN g
 CROSS JOIN public.rpg_map_under_size(p_kind, p_skind, p_node) z
 WHERE public.rpg_map_roll(g.seed, 1770, g.h, 0) <= round(z.pool * 100);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_swim(p_x integer, p_y integer, p_at text, p_to text)
 RETURNS TABLE(depth double precision, current double precision, difficulty numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The water a square under the ground holds when it is too deep to wade (step 14b), as rpg_map_swim tells it for the
-- surface: p_x, p_y counted from 1 as pieces stand, under the passage or room p_at (going to p_to) and those round it
-- (rpg_map_under_layer). The depth from the battle grid (rpg_map_under_squares), the pull of the stream it lies in
-- (rpg_map_under_water; a lake is still), the difficulty of a Swimming roll there (rpg_map_swim_difficulty). No row
-- when the square is dry or shallow enough to wade.
SELECT q.water, coalesce(w.current, 0), public.rpg_map_swim_difficulty(coalesce(w.current, 0))
  FROM public.rpg_map_under_squares(p_x - 1, p_y - 1, 1, 1, public.rpg_map_under_layer(p_at, p_to)) q
  LEFT JOIN LATERAL (
         SELECT x.current
           FROM jsonb_array_elements(public.rpg_map_under_layer(p_at, p_to)) e
          CROSS JOIN LATERAL public.rpg_map_under_water(e ->> 'kind', e ->> 'skind',
                               CASE WHEN e ->> 'a' LIKE 'mouth:%' OR e ->> 'a' LIKE 'end:%' THEN e ->> 'a' ELSE e ->> 'b' END, q.way) x
          WHERE strpos(q.way, '|') > 0 AND (e ->> 'a') || '|' || (e ->> 'b') = q.way
          LIMIT 1) w ON true
 WHERE q.water >= (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_swim_depth')::double precision;
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
--   to 120 m) or the far end of a cave or a mine, its edge in and out by up to a quarter (rpg_map_under_room);
--   the mouth of a cave has none (the passage starts at the cave on the surface).
--   Each open square: its ground (rpg_map_grounds under_deep, under_cave, under_mine, under_squeeze) and how hard it is
--   inside that ground's range (rpg_map_under_patch: patches about three squares across, layer 1761), its percent from
--   that (rpg_map_pct; the hardest share of cave floor is rubble, the thicket of rpg_map_band); water (step 14b, Peter
--   2026-10-07: the water the battle grid shows must show on the grids above, so no more scattered pools) where its
--   passage carries a stream or its room holds a lake (rpg_map_under_water): a stream down the middle of the passage,
--   part of its width each side of its winding middle, a lake round its own middle in the room inside its own ragged
--   edge; deepest at the middle, shallowing to 0.1 m at the edge (the depth x (1 - (how far out / edge) squared)),
--   waded or swum by its depth (rpg_map_wade_pct); a column of
--   stone (no way through) on the share col of squares (layer 1763), never on the line down the middle of a passage or
--   the middle of a room, so a piece walking it is never in stone.
-- part = floor, rubble, pool (water: a stream or a lake), column (pct none: no way in) or shaft; water = metres deep; down = metres below
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
  v_wd double precision[] := array_fill(NULL::double precision, ARRAY[p_cols * p_rows]);
  zw record; v_wet boolean := false; v_lx double precision; v_ly double precision; v_le double precision; v_ld double precision;
  v_col double precision[] := array_fill(0::double precision, ARRAY[p_cols * p_rows]);
  v_cl integer[] := array_fill(NULL::integer, ARRAY[p_cols * p_rows]);
  v_cx double precision := p_x0 + p_cols / 2.0; v_cy double precision := p_y0 + p_rows / 2.0;
  v_diag double precision := sqrt(p_cols * p_cols + p_rows * p_rows) / 2.0;
  v_sh bigint; v_ax double precision; v_ay double precision; v_bx double precision; v_by double precision; v_qx double precision; v_qy double precision;
  v_len double precision; v_l2 double precision; v_reach double precision; tt double precision; tc double precision;
  px double precision; py double precision; dx double precision; dy double precision; ddx double precision; ddy double precision;
  f double precision; fd double precision; v_nx double precision; v_ny double precision; v_v double precision;
  v_half double precision; v_dist double precision; v_ang double precision; v_r double precision;
  v_kf double precision; v_key text; v_climb integer; i integer; j integer; q integer; it integer;
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
    -- its stream, if it carries one (step 14b)
    SELECT * INTO zw FROM public.rpg_map_under_water(e.kind, e.skind, CASE WHEN e.a LIKE 'mouth:%' OR e.a LIKE 'end:%' THEN e.a ELSE e.b END, e.a || '|' || e.b);
    v_wet := FOUND AND e.kind <> 'shaft';
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
        v_wd[q] := CASE WHEN v_wet AND v_dist <= zw.part * s.half THEN greatest(0.1, zw.depth * (1 - power(v_dist / (zw.part * s.half), 2))) END;
        v_col[q] := z.col; v_cl[q] := CASE WHEN v_shaft THEN v_climb END;
      END IF;
      IF v_dist < 0.75 THEN v_mid[q] := true; END IF;
    END LOOP;
  END LOOP;
  -- the rooms at the nodes
  FOR nd IN SELECT DISTINCT ON (o->>'n') o->>'n' AS n, (o->>'x')::double precision AS x, (o->>'y')::double precision AS y,
                   (o->>'d')::double precision AS d, o->>'sk' AS sk
              FROM jsonb_array_elements(v_nodes) o ORDER BY o->>'n', (o->>'sk') NULLS LAST
  LOOP
    -- its size and edge (rpg_map_under_room, step 14a)
    SELECT * INTO z FROM public.rpg_map_under_room(nd.n, nd.sk);
    CONTINUE WHEN NOT FOUND;
    v_r := z.r;
    -- its lake, if it holds one (step 14b): round its own middle, inside its own ragged edge
    SELECT * INTO zw FROM public.rpg_map_under_water('room', nd.sk, nd.n, nd.n);
    v_wet := FOUND;
    IF v_wet THEN v_lx := nd.x + zw.dx * v_r; v_ly := nd.y + zw.dy * v_r; END IF;
    CONTINUE WHEN sqrt(power(nd.x + 0.5 - v_cx, 2) + power(nd.y + 0.5 - v_cy, 2)) > 1.25 * v_r + v_diag + 1;
    FOR j IN 0 .. p_rows - 1 LOOP
      FOR i IN 0 .. p_cols - 1 LOOP
        q := j * p_cols + i + 1;
        v_dist := sqrt(power(p_x0 + i - nd.x, 2) + power(p_y0 + j - nd.y, 2));
        CONTINUE WHEN v_dist > 1.25 * v_r + 0.5;
        -- its ragged edge: eight knots round, each 0.75 to 1.25 of its middle size, smooth between
        v_ang := (atan2(p_y0 + j - nd.y, p_x0 + i - nd.x) + pi()) / (2 * pi()) * 8;
        v_kf := v_ang - floor(v_ang); it := floor(v_ang)::integer;
        v_half := v_r * (0.75 + 0.5 * (z.knots[mod(it, 8) + 1] + (z.knots[mod(it + 1, 8) + 1] - z.knots[mod(it, 8) + 1]) * v_kf * v_kf * (3 - 2 * v_kf)));
        CONTINUE WHEN v_dist > greatest(v_half, 1.5);
        v_way[q] := nd.n; v_room[q] := true; v_gr[q] := z.ground; v_dn[q] := nd.d; v_col[q] := z.col; v_cl[q] := NULL;
        v_wd[q] := NULL;
        IF v_wet THEN
          v_ld := sqrt(power(p_x0 + i - v_lx, 2) + power(p_y0 + j - v_ly, 2));
          v_ang := (atan2(p_y0 + j - v_ly, p_x0 + i - v_lx) + pi()) / (2 * pi()) * 8;
          v_kf := v_ang - floor(v_ang); it := floor(v_ang)::integer;
          v_le := zw.part * v_r * (0.75 + 0.5 * (zw.knots[mod(it, 8) + 1] + (zw.knots[mod(it + 1, 8) + 1] - zw.knots[mod(it, 8) + 1]) * v_kf * v_kf * (3 - 2 * v_kf)));
          IF v_ld <= v_le THEN v_wd[q] := greatest(0.1, zw.depth * (1 - power(v_ld / v_le, 2))); END IF;
        END IF;
        IF v_dist < 1 THEN v_mid[q] := true; END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  RETURN QUERY
  WITH sq AS (
         SELECT p_x0 + mod(g.k - 1, p_cols) AS sx, p_y0 + (g.k - 1) / p_cols AS sy, v_way[g.k] AS w, v_gr[g.k] AS gr, v_dn[g.k] AS dn,
                v_mid[g.k] AS mid, v_wd[g.k] AS wd, v_col[g.k] AS cl, v_cl[g.k] AS climb
           FROM generate_series(1, v_n) AS g(k) WHERE v_way[g.k] IS NOT NULL),
       b AS (SELECT DISTINCT ON (sq.gr) sq.gr, r.low, r.high, r.thicket, r.share
               FROM sq LEFT JOIN LATERAL public.rpg_map_band(sq.gr, NULL) r ON true WHERE sq.gr IS NOT NULL),
       n1 AS MATERIALIZED (SELECT * FROM public.rpg_map_under_patch(1761, p_x0, p_y0, p_cols, p_rows, 3)),
       f AS (SELECT sq.*, n1.v AS hd,
                    sq.cl > 0 AND NOT sq.mid AND sq.wd IS NULL AND public.rpg_map_roll(t.seed, 1763, mod(mod(sq.sx, t.span) + t.span, t.span)::integer, sq.sy) <= round(sq.cl * 1000) / 10.0 AS stone
               FROM sq JOIN n1 ON n1.x = sq.sx AND n1.y = sq.sy)
  SELECT f.sx, f.sy,
         CASE WHEN f.climb IS NOT NULL OR f.gr IS NULL THEN 'shaft' WHEN f.stone THEN 'column' WHEN f.wd > 0 THEN 'pool'
              WHEN b.thicket IS NOT NULL AND f.hd >= 1 - b.share THEN 'rubble' ELSE 'floor' END,
         f.gr,
         CASE WHEN f.climb IS NOT NULL OR f.gr IS NULL THEN f.climb WHEN f.stone THEN NULL
              WHEN f.wd > 0 THEN public.rpg_map_wade_pct(f.wd)
              ELSE public.rpg_map_pct(b.low, b.high, b.thicket, b.share, f.hd) END,
         f.hd,
         CASE WHEN f.climb IS NULL AND NOT f.stone AND f.wd > 0 THEN round(f.wd::numeric, 2)::double precision END,
         f.dn, f.w
    FROM f LEFT JOIN b ON b.gr = f.gr
   ORDER BY f.sy, f.sx;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_swim_check(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The swim at the start of a turn in water too deep to wade (Peter 2026-10-03 22:05: a roll against the water's
-- difficulty, rolled regularly while in the water; a miss ducks them under; under too long without breathing water,
-- they drown; back up, they get air). Called by rpg_session_next_turn for whoever's turn begins, on a fight board or a
-- journey. Off the water nothing happens, except that someone still Under climbs out and is no longer Under.
-- The roll: Swimming against the water's pull where they are (rpg_map_swim: still water 0.7, a river's middle 8.6).
-- With swimming gear (an item worn or held that adds to Swimming with Gear) they roll Swimming with Gear instead, gear
-- and all (Peter 2026-10-03 23:12: gear adds to the swimmer's own roll; Swimming with Gear is built on Swimming).
-- Someone whose sheet has no open Swimming swims as skill 0: only a 100 keeps them up. A creature's roll is made from
-- its sheet without training it; a character's goes through rpg_roll (it trains).
-- Made it: they keep their head up, or come up for air and are no longer Under. Missed: they go Under (cannot act, so
-- they are easier to hit and their turn passes; the next turn comes a beat later and they try again), or stay under.
-- Under holds the breath for swim_breath_ticks (180, 30 seconds); past that, unless their card breathes water
-- (rpg_creatures.breathes_water, on the card or any card above it), every tick under costs Physical Vitality at a
-- rate that takes a full bar in swim_drown_ticks (540, 90 seconds): Zaboo (16) loses 1 for every 34 ticks. At 0 they
-- are down (a character never dies). Returns {roll, needed, made, under, harm} or nothing when they are not swimming.
DECLARE
  v_p record; v_s record; v_w record; v_under jsonb; v_key text; v_skill numeric; v_r jsonb; v_nc jsonb; v_roll integer;
  v_made boolean; v_text text; v_breathes boolean; v_breath integer; v_drown integer; v_max integer; v_harm integer := 0;
  v_from bigint; v_roll_id uuid; v_out text; v_gear boolean;
BEGIN
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF NOT FOUND OR v_p.pos_x IS NULL OR v_p.character_id IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_s FROM public.rpg_sessions WHERE id = v_p.session_id;
  IF NOT coalesce(v_s.on_map, false) THEN RETURN NULL; END IF;
  SELECT e INTO v_under FROM jsonb_array_elements(v_p.effects) e WHERE e->>'name' = 'Under' LIMIT 1;
  -- under the ground the water of the passage or room they are in (step 14b, rpg_map_under_swim), else the surface's
  IF v_p.under_at IS NOT NULL THEN
    SELECT * INTO v_w FROM public.rpg_map_under_swim(v_p.pos_x, v_p.pos_y, v_p.under_at, v_p.under_to);
  ELSE
    SELECT * INTO v_w FROM public.rpg_map_swim(v_p.pos_x, v_p.pos_y);
  END IF;
  IF NOT FOUND THEN
    IF v_under IS NOT NULL THEN
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> 'Under')
       WHERE p.id = p_participant_id;
      INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
      VALUES (v_s.agency_id, v_s.id, v_s.round, 'effect', 'info', p_participant_id, v_p.name || ' is out of the deep water and no longer Under.');
    END IF;
    RETURN NULL;
  END IF;
  IF (public.rpg_participant_vitality(p_participant_id)->>'left')::integer <= 0 THEN RETURN NULL; END IF;

  -- with swimming gear on, Swimming with Gear (gear and all) when it is open; else Swimming
  v_gear := EXISTS (SELECT 1 FROM public.rpg_items i WHERE i.character_id = v_p.character_id AND (i.equipped OR i.worn) AND i.stat_key = 'swim_gear')
            AND public.rpg_participant_value(p_participant_id, 'swim_gear') IS NOT NULL;
  v_key := CASE WHEN v_gear THEN 'swim_gear' ELSE 'WM' END;
  v_skill := public.rpg_participant_value(p_participant_id, v_key);
  IF v_p.creature_id IS NULL AND v_skill IS NOT NULL THEN
    v_r := public.rpg_roll(v_p.character_id, v_key, v_w.difficulty, 'Swimming against the water', NULL, v_s.id, p_participant_id);
    v_roll := (v_r->>'roll')::integer; v_nc := jsonb_build_object('needed', v_r->'needed', 'critical', v_r->'critical'); v_roll_id := (v_r->>'roll_id')::uuid;
  ELSE
    v_nc := public.rpg_needed(coalesce(v_skill, 0), v_w.difficulty);
    v_roll := floor(random() * 100)::integer + 1;
  END IF;
  v_made := v_roll >= (v_nc->>'needed')::numeric;
  v_out := public.rpg_outcome(v_roll, (v_nc->>'needed')::numeric, (v_nc->>'critical')::numeric, false, 0)->>'key';
  v_text := v_p.name || ' swims against the water (' || CASE WHEN v_gear THEN 'Swimming with Gear ' ELSE 'Swimming ' END
         || trim_scale(coalesce(v_skill, 0)) || ' against ' || trim_scale(v_w.difficulty) || '): rolls ' || v_roll || ', needs '
         || ceil((v_nc->>'needed')::numeric) || '. ';
  IF v_made THEN
    IF v_under IS NOT NULL THEN
      UPDATE public.rpg_session_participants p SET effects = (SELECT coalesce(jsonb_agg(e), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e WHERE e->>'name' <> 'Under')
       WHERE p.id = p_participant_id;
      v_text := v_text || 'Comes up for air.';
    ELSE
      v_text := v_text || 'Keeps their head above water.';
    END IF;
  ELSIF v_under IS NULL THEN
    UPDATE public.rpg_session_participants
       SET effects = effects || jsonb_build_array(jsonb_build_object('name', 'Under', 'cannot_act', true, 'clear', 'swim', 'source', 'the water',
                                                                     'since', v_s.clock, 'harmed_to', v_s.clock))
     WHERE id = p_participant_id;
    v_text := v_text || 'Goes under!';
  ELSE
    v_breath := public.rpg_setting('swim_breath_ticks')::integer;
    v_drown := public.rpg_setting('swim_drown_ticks')::integer;
    v_breathes := EXISTS (SELECT 1 FROM public.rpg_characters ch
                           CROSS JOIN LATERAL unnest(public.rpg_template_chain(coalesce(v_p.creature_id, ch.template_id))) AS t(id)
                           JOIN public.rpg_creatures c ON c.id = t.id
                          WHERE ch.id = v_p.character_id AND c.breathes_water);
    v_from := greatest((v_under->>'harmed_to')::bigint, (v_under->>'since')::bigint + v_breath);
    IF NOT v_breathes AND v_s.clock > v_from THEN
      v_max := (public.rpg_participant_vitality(p_participant_id)->>'max')::integer;
      v_harm := ceil(v_max * (v_s.clock - v_from)::numeric / v_drown)::integer;
      UPDATE public.rpg_session_participants p
         SET effects = (SELECT coalesce(jsonb_agg(CASE WHEN e->>'name' = 'Under' THEN e || jsonb_build_object('harmed_to', v_s.clock) ELSE e END), '[]'::jsonb) FROM jsonb_array_elements(p.effects) e)
       WHERE p.id = p_participant_id;
      PERFORM set_config('rpg.engine', 'on', true);
      PERFORM public.rpg_session_adjust_vitality(p_participant_id, v_harm);
      v_text := v_text || 'Still under, out of breath and drowning: ' || v_harm || ' damage'
             || CASE WHEN (public.rpg_participant_vitality(p_participant_id)->>'left')::integer <= 0 THEN '. Down.' ELSE '.' END;
    ELSE
      v_text := v_text || 'Still under' || CASE WHEN v_breathes THEN ', breathing the water.'
                                               ELSE ', holding their breath (' || public.rpg_map_duration_text(greatest((v_under->>'since')::bigint + v_breath - v_s.clock, 0)) || ' of air left).' END;
    END IF;
  END IF;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, roll_id, text)
  VALUES (v_s.agency_id, v_s.id, v_s.round, 'check', v_out, p_participant_id, v_roll_id, v_text);
  RETURN jsonb_build_object('roll', v_roll, 'needed', v_nc->'needed', 'made', v_made, 'under', NOT v_made, 'harm', v_harm, 'text', v_text);
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
                 WHEN v_slid THEN 's-' || v_x0::text || '-' || v_y0::text
                 WHEN v_l.level > 1 THEN v_l.level::text || '-' || v_x::text || '-' || v_y::text END,
    'cols', v_cols, 'rows', v_rows, 'origin', jsonb_build_array(v_x0, v_y0), 'scale', v_scale,
    'crumbs', v_crumbs, 'moves', v_moves, 'slides', v_slides,
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

REVOKE ALL ON FUNCTION public.rpg_map_under_water(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_water(text, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_swim(integer, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_swim(integer, integer, text, text) TO service_role;

