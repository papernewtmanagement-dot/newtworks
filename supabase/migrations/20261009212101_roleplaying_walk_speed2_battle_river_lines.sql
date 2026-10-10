-- Walk speed step 2 (Peter 2026-10-09 1A): the battle grid's river lines are worked out once a transaction per City cell and cut
-- to each read; this also mends small battle-grid boxes that lost stretches of a river running through them.
CREATE OR REPLACE FUNCTION public.rpg_map_river_line_make(p_level integer, p_sub integer, p_bx0 double precision, p_by0 double precision, p_bx1 double precision, p_by1 double precision, p_reach double precision, p_upto integer DEFAULT 5)
 RETURNS TABLE(pid bigint, k integer, t double precision, x double precision, y double precision, nx0 double precision, ny0 double precision, nx1 double precision, ny1 double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (walk speed step 2, 2026-10-09) The working of rpg_map_river_line, moved here unchanged; each point also carries the points
-- before and after it on its bend (nx0, ny0, nx1, ny1; itself at an end), so a line worked out for a bigger box can be
-- cut to a smaller one exactly as this would cut it. Read only through rpg_map_river_line.
-- The winding line of the downhill rivers (rpg_map_drainage; step 14f1) as grid p_level shows it, near a box of the
-- world (p_bx0 .. p_bx1 east, p_by0 .. p_by1 south, in squares): the one home of where a downhill river runs.
-- rpg_map_rivers reads it for every rule (depth, fords, crossings, walks), rpg_map_river_trace for the line the Maps
-- tab draws. Worked out when asked and never stored.
-- Each bend of a river (rpg_map_river_bends: a curve through the middles between the Continent cells the water runs
-- through, the way the Maps tab draws rivers) swings sideways the way rivers wind (step 10a, kept: Peter 2026-10-07,
-- keep the winding), by rpg_map_river_swing at the point of the bend it moves. A grid shows only swings at least two of
-- its cells wide (with p_sub points a cell, two of those), so each finer grid adds the smaller swings and keeps the
-- line within about half a coarse cell of where the coarser grid drew it. Where a river changes size along a bend its
-- swing passes from the one size's to the other's along it; a river that joins a bigger one ends on that river's own
-- line, at the middle of its bend. Rivers never cross (Peter 2026-10-07): a swing never takes a river more than 0.45
-- of the way to any other bend near it (another river, or its own course where it turns back), nor 0.7 of the radius
-- of its own turn (a bigger swing to the inside of a turn folds the line back on itself), so two that face each other
-- never meet and no river loops, however they swing (the swing s becomes s / sqrt(1 + (s / room)^2)). Where two bends
-- meet the room is the lesser of theirs there, so a river's room runs on unbroken. Only bends within twice the most
-- a swing could be count (beyond that the room is that far), so the room is the same whatever box asks for it.
-- The line is found grid by grid from the Continent grid down: each grid keeps only the stretches whose line, with the
-- most the smaller swings could still move it, comes within p_reach squares of the box, and the next grid looks only
-- at those, so a battle grid reads a few hundred points, not a river's whole length.
-- Rows: points of the line, in order of t along each bend; pid = the bend (its copy a world east is pid + 100,000,000,
-- a world west pid + 200,000,000, given where that copy is the one near the box); k = the size of river (2 great river,
-- 3 river); x, y in squares.
-- (Step 14f2) From the Country grid down this also draws the rivers inside each Continent cell (rpg_map_drain_cell, by
-- way of rpg_map_river_bends), winding the same way; one of them ends on a downhill river's line wherever it meets it
-- (at jt along that river's bend, not only at a bend's middle). Step 14f3: from the Region grid down it draws the
-- streams found inside each Country cell, and from the City grid down the brooks found inside each Region cell, the
-- same way. p_upto: the finest grid whose rivers are read (rpg_map_drain_cell reads the bigger rivers alone to find
-- a cell's own: 2 the Continent grid's, 3 with the rivers, 4 with the streams).
DECLARE
  v_cc double precision; v_world double precision; v_cell double precision; v_lcell double precision;
  v_share double precision; v_sd double precision := sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0));
  v_lv integer; v_gmin double precision; v_lo double precision; v_r double precision; v_most double precision;
  v_sp double precision; v_q integer; v_room constant double precision := 0.45;
  s_n integer[]; s_t0 double precision[]; s_t1 double precision[];
  b_id bigint[]; b_ax double precision[]; b_ay double precision[]; b_cx double precision[]; b_cy double precision[];
  b_bx double precision[]; b_by double precision[]; b_ka integer[]; b_kb integer[]; b_jn bigint[]; b_jt double precision[];
  v_wide double precision; v_it integer;
  j_px double precision[]; j_py double precision[]; j_ux double precision[]; j_uy double precision[]; j_ka integer[]; j_kb integer[];
  m_n integer[]; m_t double precision[]; m_px double precision[]; m_py double precision[]; m_ux double precision[]; m_uy double precision[];
  m_s2 double precision[]; m_s3 double precision[]; m_s3f double precision[]; m_s4 double precision[]; m_s5 double precision[]; b_g integer[]; j_g integer[];
  v_h2 boolean; v_h3 boolean; v_hg boolean[]; v_mg double precision[]; v_rg double precision[];
  w_id bigint[]; w_ax double precision[]; w_ay double precision[]; w_cx double precision[]; w_cy double precision[];
  w_bx double precision[]; w_by double precision[]; w_ka integer[]; w_kb integer[]; w_jn bigint[]; w_jt double precision[]; m_x double precision[]; m_y double precision[]; m_c double precision[]; m_r double precision[];
BEGIN
  IF p_level < 2 THEN RETURN; END IF;
  SELECT max(l.cell) FILTER (WHERE l.level = 2), max(l.span) FILTER (WHERE l.level = 1), max(l.cell) FILTER (WHERE l.level = p_level)
    INTO v_cc, v_world, v_cell FROM public.rpg_map_ladder() l;
  SELECT max(s.value) FILTER (WHERE s.key = 'map_river_meander_amp') / max(s.value) FILTER (WHERE s.key = 'map_river_meander_wave')
    INTO v_share FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  -- the most any swing could move a line: every layer at its farthest roll (49.5) the same way
  SELECT coalesce(max(z.most), 0) INTO v_most
    FROM (SELECT sum(l.gap) * v_share * 49.5 / v_sd AS most FROM public.rpg_map_river_layers(0) l GROUP BY l.k) z;
  -- (step 14f2) the most a river whose course the Country grid found could move (its swings are smaller): such a river
  -- looks for its room only that far round it
  -- (step 14f3) the same for a river found on the Country grid (group 1), a stream (2) and a brook (3); group 0 is the
  -- Continent grid's rivers (v_most)
  SELECT ARRAY[v_most] || array_agg(greatest(coalesce(z.most, 0), 1) ORDER BY g.g)
    INTO v_mg
    FROM generate_series(1, 3) AS g(g)
    LEFT JOIN (SELECT -l.k - 2 AS g, sum(l.gap) * v_share * 49.5 / v_sd AS most FROM public.rpg_map_river_layers(0) l WHERE l.k < 0 GROUP BY l.k) z ON z.g = g.g;

  -- (step 14f2) the bends are read for the box and as far round it as any bend could matter here (the rivers inside
  -- the Continent cells there, rpg_map_drain_cell, come with them)
  v_wide := 3 * v_most + p_reach;
  -- read once, here, for the three uses below (rpg_map_river_bends reads the rivers found inside the cells near the box,
  -- each size as far round it as its swings could matter)
  SELECT array_agg(b.id), array_agg(b.ax), array_agg(b.ay), array_agg(b.cx), array_agg(b.cy), array_agg(b.bx), array_agg(b.by),
         array_agg(b.ka), array_agg(b.kb), array_agg(b.joins), array_agg(b.jt)
    INTO w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by, w_ka, w_kb, w_jn, w_jt
    FROM public.rpg_map_river_bends(p_level, p_bx0, p_by0, p_bx1, p_by1, p_reach, p_upto) b;
  IF w_id IS NULL THEN RETURN; END IF;
  -- the bends near the box (with the copy a world east or west where that copy is the near one); each bend lies
  -- inside the box of its three points, and its line within v_most of that
  SELECT array_agg(q.pid ORDER BY q.pid), array_agg(q.ax ORDER BY q.pid), array_agg(q.ay ORDER BY q.pid), array_agg(q.cx ORDER BY q.pid),
         array_agg(q.cy ORDER BY q.pid), array_agg(q.bx ORDER BY q.pid), array_agg(q.by ORDER BY q.pid), array_agg(q.ka ORDER BY q.pid),
         array_agg(q.kb ORDER BY q.pid), array_agg(q.joins ORDER BY q.pid), array_agg(q.jt ORDER BY q.pid)
    INTO b_id, b_ax, b_ay, b_cx, b_cy, b_bx, b_by, b_ka, b_kb, b_jn, b_jt
    FROM (SELECT b.id + CASE o.o WHEN 1 THEN 1000000000000 WHEN -1 THEN 2000000000000 ELSE 0 END AS pid, b.ax + o.o * v_world AS ax, b.ay,
                 b.cx + o.o * v_world AS cx, b.cy, b.bx + o.o * v_world AS bx, b.by, b.ka, b.kb, b.joins, b.jt
            FROM unnest(w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by, w_ka, w_kb, w_jn, w_jt) AS b(id, ax, ay, cx, cy, bx, by, ka, kb, joins, jt) CROSS JOIN (VALUES (-1), (0), (1)) AS o(o)
          CROSS JOIN LATERAL (SELECT v_mg[(CASE WHEN b.id < 1000000 THEN 0 WHEN b.id < 20000000 THEN 1 WHEN b.id < 2000000000 THEN 2 ELSE 3 END) + 1] AS mo) m
          WHERE least(b.ax, b.cx, b.bx) + o.o * v_world - m.mo - p_reach <= p_bx1 AND greatest(b.ax, b.cx, b.bx) + o.o * v_world + m.mo + p_reach >= p_bx0
             AND least(b.ay, b.cy, b.by) - m.mo - p_reach <= p_by1 AND greatest(b.ay, b.cy, b.by) + m.mo + p_reach >= p_by0) q;
  IF b_id IS NULL THEN RETURN; END IF;
  -- (step 14f2) the bends of rivers whose course the Country grid found, and the bends rivers join that are
  b_g := ARRAY(SELECT CASE WHEN u.i % 1000000000000 < 1000000 THEN 0 WHEN u.i % 1000000000000 < 20000000 THEN 1 WHEN u.i % 1000000000000 < 2000000000 THEN 2 ELSE 3 END FROM unnest(b_id) AS u(i));
  j_g := ARRAY(SELECT CASE WHEN u.i < 1000000 THEN 0 WHEN u.i < 20000000 THEN 1 WHEN u.i < 2000000000 THEN 2 ELSE 3 END FROM unnest(b_jn) AS u(i));
  -- where a river joins a bigger one: the point of that river's bend it ends on (its middle, or for a river of a
  -- Continent cell the point of a downhill river's bend nearest it: jt along it) and the way across it there
  SELECT array_agg(coalesce(j.px, 0) ORDER BY u.n), array_agg(coalesce(j.py, 0) ORDER BY u.n),
         array_agg(coalesce(j.ux, 0) ORDER BY u.n), array_agg(coalesce(j.uy, 0) ORDER BY u.n),
         array_agg(coalesce(j.ka, 2) ORDER BY u.n), array_agg(coalesce(j.kb, 2) ORDER BY u.n)
    INTO j_px, j_py, j_ux, j_uy, j_ka, j_kb
    FROM unnest(b_jn, b_jt) WITH ORDINALITY AS u(jn, jt, n)
    LEFT JOIN LATERAL (SELECT power(1 - u.jt, 2) * b.ax + 2 * u.jt * (1 - u.jt) * b.cx + power(u.jt, 2) * b.bx AS px,
                              power(1 - u.jt, 2) * b.ay + 2 * u.jt * (1 - u.jt) * b.cy + power(u.jt, 2) * b.by AS py,
                              -d.dy / greatest(sqrt(d.dx * d.dx + d.dy * d.dy), 1e-9) AS ux, d.dx / greatest(sqrt(d.dx * d.dx + d.dy * d.dy), 1e-9) AS uy, b.ka, b.kb
                         FROM unnest(w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by, w_ka, w_kb, w_jn, w_jt) AS b(id, ax, ay, cx, cy, bx, by, ka, kb, joins, jt)
                        CROSS JOIN LATERAL (SELECT 2 * (1 - u.jt) * (b.cx - b.ax) + 2 * u.jt * (b.bx - b.cx) AS dx,
                                                   2 * (1 - u.jt) * (b.cy - b.ay) + 2 * u.jt * (b.by - b.cy) AS dy) d
                        WHERE b.id = u.jn) j ON u.jn > 0;
  -- every bend whole, to start
  s_n := ARRAY(SELECT generate_series(1, cardinality(b_id)));
  s_t0 := array_fill(0::double precision, ARRAY[cardinality(b_id)]);
  s_t1 := array_fill(1::double precision, ARRAY[cardinality(b_id)]);

  -- grid by grid, from the Continent grid down to this one
  FOR v_lv IN 2 .. p_level LOOP
    v_lcell := (SELECT l.cell FROM public.rpg_map_ladder() l WHERE l.level = v_lv);
    v_gmin := 2 * v_lcell / CASE WHEN v_lv = p_level THEN p_sub ELSE 1 END;
    -- a grid on the way down that adds no swing of its own finds nothing the grid above did not
    CONTINUE WHEN v_lv > 2 AND v_lv < p_level
              AND NOT EXISTS (SELECT 1 FROM public.rpg_map_river_layers(v_gmin) l WHERE l.gap < 2 * v_lcell * 12);
    -- the smallest swing read at this grid, and the most the smaller ones could still move the line
    -- (step 14f2) and which sizes swing at this grid at all: a point whose river does not swing here needs no room
    SELECT min(l.gap), coalesce(bool_or(l.k = 2), false), coalesce(bool_or(l.k = 3), false), ARRAY[false, coalesce(bool_or(l.k = -3), false), coalesce(bool_or(l.k = -4), false), coalesce(bool_or(l.k = -5), false)]
      INTO v_lo, v_h2, v_h3, v_hg FROM public.rpg_map_river_layers(v_gmin) l;
    -- (v_rg: the same for the rivers found on the finer grids, by group, steps 14f2 and 14f3)
    SELECT coalesce(max(z.r) FILTER (WHERE z.k > 0), 0),
           ARRAY[0, coalesce(max(z.r) FILTER (WHERE z.k = -3), 0), coalesce(max(z.r) FILTER (WHERE z.k = -4), 0), coalesce(max(z.r) FILTER (WHERE z.k = -5), 0)]
      INTO v_r, v_rg
      FROM (SELECT l.k, sum(l.gap) * v_share * 49.5 / v_sd AS r FROM public.rpg_map_river_layers(0) l WHERE l.gap < v_gmin GROUP BY l.k) z;
    -- points along the bend about v_sp squares apart: an eighth of the smallest swing read on the way down, then at this
    -- grid half a cell (half of a p_sub-th of a cell when drawn), and a sixteenth of the smallest swing read for the
    -- rules (a quarter when drawn: the Maps tab draws a smooth curve through them), or an eighth of a Continent cell
    -- where nothing swings; the rolls on points v_q squares apart. A stretch between two points may bow out from the
    -- straight line between them by up to about a fifth of the smallest swing read: that is added to the margin a
    -- stretch is kept by.
    -- (step 14f2) For the rules on the District and battle grids, whose cells are smaller than a sixteenth of the
    -- smallest swing, the points are that sixteenth apart (at most 32 squares), not half a cell: the line between them
    -- stays within about a square of the curve, and a river near a battle grid is a few dozen points, not hundreds.
    v_sp := greatest(CASE WHEN v_lv < p_level THEN least(v_lcell / 2, coalesce(v_lo, v_cc) / 8)
                          WHEN p_sub = 1 THEN least(greatest(v_lcell / 2, 32), coalesce(v_lo / 16, v_cc / 8))
                          ELSE least(v_lcell / (2 * p_sub), coalesce(v_lo / 4, v_cc / 8)) END, 0.5);
    v_r := v_r + 0.2 * coalesce(v_lo, 0);
    v_rg := ARRAY(SELECT u.r + 0.2 * coalesce(v_lo, 0) FROM unnest(v_rg) AS u(r));
    v_q := greatest(floor(coalesce(v_lo, v_cc) / 4), 1)::integer;
    SELECT array_agg(q.n ORDER BY q.n, q.t), array_agg(q.t ORDER BY q.n, q.t), array_agg(q.px ORDER BY q.n, q.t), array_agg(q.py ORDER BY q.n, q.t),
           array_agg(q.dx / q.dl ORDER BY q.n, q.t), array_agg(q.dy / q.dl ORDER BY q.n, q.t),
           array_agg(public.rpg_map_bend_radius(b_ax[q.n], b_ay[q.n], b_cx[q.n], b_cy[q.n], b_bx[q.n], b_by[q.n], q.t) ORDER BY q.n, q.t)
      INTO m_n, m_t, m_px, m_py, m_ux, m_uy, m_r
      FROM (SELECT DISTINCT ON (s.n, z.t) s.n, z.t,
                   power(1 - z.t, 2) * b_ax[s.n] + 2 * z.t * (1 - z.t) * b_cx[s.n] + power(z.t, 2) * b_bx[s.n] AS px,
                   power(1 - z.t, 2) * b_ay[s.n] + 2 * z.t * (1 - z.t) * b_cy[s.n] + power(z.t, 2) * b_by[s.n] AS py,
                   -(2 * (1 - z.t) * (b_cy[s.n] - b_ay[s.n]) + 2 * z.t * (b_by[s.n] - b_cy[s.n])) AS dx,
                   2 * (1 - z.t) * (b_cx[s.n] - b_ax[s.n]) + 2 * z.t * (b_bx[s.n] - b_cx[s.n]) AS dy,
                   greatest(sqrt(power(2 * (1 - z.t) * (b_cx[s.n] - b_ax[s.n]) + 2 * z.t * (b_bx[s.n] - b_cx[s.n]), 2)
                                 + power(2 * (1 - z.t) * (b_cy[s.n] - b_ay[s.n]) + 2 * z.t * (b_by[s.n] - b_cy[s.n]), 2)), 1e-9) AS dl
              FROM unnest(s_n, s_t0, s_t1) AS s(n, t0, t1)
             CROSS JOIN LATERAL (SELECT greatest(ceil((s.t1 - s.t0) * (sqrt(power(b_bx[s.n] - b_ax[s.n], 2) + power(b_by[s.n] - b_ay[s.n], 2))
                                                                       + sqrt(power(b_cx[s.n] - b_ax[s.n], 2) + power(b_cy[s.n] - b_ay[s.n], 2))
                                                                       + sqrt(power(b_bx[s.n] - b_cx[s.n], 2) + power(b_by[s.n] - b_cy[s.n], 2))) / 2 / v_sp), 1)::integer AS cnt) c
             CROSS JOIN LATERAL (SELECT s.t0 + (s.t1 - s.t0) * j / c.cnt AS t FROM generate_series(0, c.cnt) AS j
                                 -- the point of a bend a river joins, so the joining river ends on a point of this line
                                 UNION ALL SELECT jj.t FROM unnest(b_jn, b_jt) AS jj(i, t)
                                            WHERE jj.i > 0 AND jj.i = b_id[s.n] % 1000000000000 AND s.t0 < jj.t AND s.t1 > jj.t) z
             ORDER BY s.n, z.t) q;
    -- the swing at every point, and at the middle of every bend a river joins
    SELECT array_agg(w.s2 ORDER BY w.i), array_agg(w.s3 ORDER BY w.i), array_agg(w.s3f ORDER BY w.i), array_agg(w.s4 ORDER BY w.i), array_agg(w.s5 ORDER BY w.i)
      INTO m_s2, m_s3, m_s3f, m_s4, m_s5
      -- (step 14f2) only the points of rivers that swing at this grid are read (the others swing 0 here)
      FROM public.rpg_map_river_swing(v_gmin, v_q,
             ARRAY(SELECT CASE WHEN (CASE WHEN b_g[m_n[u.i]] = 0 THEN ((b_ka[m_n[u.i]] = 2 OR b_kb[m_n[u.i]] = 2) AND v_h2) OR ((b_ka[m_n[u.i]] = 3 OR b_kb[m_n[u.i]] = 3) AND v_h3) ELSE v_hg[b_g[m_n[u.i]] + 1] END)
                                  THEN m_px[u.i] END FROM generate_series(1, cardinality(m_n)) AS u(i))
             || ARRAY(SELECT CASE WHEN (CASE WHEN j_g[u.n] = 0 THEN ((j_ka[u.n] = 2 OR j_kb[u.n] = 2) AND v_h2) OR ((j_ka[u.n] = 3 OR j_kb[u.n] = 3) AND v_h3) ELSE v_hg[j_g[u.n] + 1] END)
                                  THEN j_px[u.n] END FROM generate_series(1, cardinality(b_id)) AS u(n)),
             m_py || j_py) w;
    -- at this grid itself, the room each point has to swing: 0.45 of the way to the nearest bend of another river or of
    -- its own course that is not the bend it is on, the bends either side of it, or the bends that join or are joined
    -- by it (those meet it on purpose); on the way down the swings are only used to find the stretches near the box, and
    -- a smaller swing never takes a line farther, so the room is not needed there (nor where nothing swings)
    IF v_lv = p_level AND v_lo IS NOT NULL THEN
      WITH nb AS MATERIALIZED (
             -- the bends whose room counts: near enough the box to come within the most two swings could close
             SELECT b.id + CASE o.o WHEN 1 THEN 1000000000000 WHEN -1 THEN 2000000000000 ELSE 0 END AS pid, b.id, b.joins, b.ax + o.o * v_world AS ax, b.ay,
                    b.cx + o.o * v_world AS cx, b.cy, b.bx + o.o * v_world AS bx, b.by,
                    (CASE WHEN (CASE WHEN b.id < 1000000 THEN 0 WHEN b.id < 20000000 THEN 1 WHEN b.id < 2000000000 THEN 2 ELSE 3 END) = 0 THEN ((b.ka = 2 OR b.kb = 2) AND v_h2) OR ((b.ka = 3 OR b.kb = 3) AND v_h3) ELSE v_hg[(CASE WHEN b.id < 1000000 THEN 0 WHEN b.id < 20000000 THEN 1 WHEN b.id < 2000000000 THEN 2 ELSE 3 END) + 1] END) AS sw, CASE WHEN b.id < 1000000 THEN 0 WHEN b.id < 20000000 THEN 1 WHEN b.id < 2000000000 THEN 2 ELSE 3 END AS gg
               FROM unnest(w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by, w_ka, w_kb, w_jn, w_jt) AS b(id, ax, ay, cx, cy, bx, by, ka, kb, joins, jt) CROSS JOIN (VALUES (-1), (0), (1)) AS o(o)
              WHERE least(b.ax, b.cx, b.bx) + o.o * v_world - 3 * v_most - p_reach <= p_bx1 AND greatest(b.ax, b.cx, b.bx) + o.o * v_world + 3 * v_most + p_reach >= p_bx0
                AND least(b.ay, b.cy, b.by) - 3 * v_most - p_reach <= p_by1 AND greatest(b.ay, b.cy, b.by) + 3 * v_most + p_reach >= p_by0),
           ch AS MATERIALIZED (
             -- each such bend as 8 straight pieces
             SELECT nb.pid, nb.id, nb.joins, nb.ax, nb.ay, nb.bx, nb.by,
                    power(1 - a.t0, 2) * nb.ax + 2 * a.t0 * (1 - a.t0) * nb.cx + power(a.t0, 2) * nb.bx AS x0,
                    power(1 - a.t0, 2) * nb.ay + 2 * a.t0 * (1 - a.t0) * nb.cy + power(a.t0, 2) * nb.by AS y0,
                    power(1 - a.t1, 2) * nb.ax + 2 * a.t1 * (1 - a.t1) * nb.cx + power(a.t1, 2) * nb.bx AS x1,
                    power(1 - a.t1, 2) * nb.ay + 2 * a.t1 * (1 - a.t1) * nb.cy + power(a.t1, 2) * nb.by AS y1
               FROM nb CROSS JOIN LATERAL (SELECT g / 8.0 AS t0, (g + 1) / 8.0 AS t1 FROM generate_series(0, 7) AS g) a),
           cb AS MATERIALIZED (
             -- the pieces by squares 2 x v_most across (a point only looks as far as that: beyond it the room is that far).
             -- (step 14f2) A river whose course the Country grid found swings much less, so its points look only as far
             -- as it could swing (squares 2 x v_mg across: g 1 a river, 2 a stream, 3 a brook, step 14f3), at every
             -- river's pieces. The downhill rivers of the
             -- Continent grid look at each other's pieces only (g 0), so they wind exactly as before: the rivers inside
             -- the Continent cells were found where those rivers run on the Country grid (rpg_map_drain_cell) and keep
             -- clear of them
             SELECT ch.*, g.g, floor((ch.x0 + ch.x1) / 2 / g.sz)::bigint AS gx, floor((ch.y0 + ch.y1) / 2 / g.sz)::bigint AS gy
               FROM ch CROSS JOIN (VALUES (0, 2 * v_most), (1, 2 * v_mg[2]), (2, 2 * v_mg[3]), (3, 2 * v_mg[4])) AS g(g, sz)
              WHERE g.g > 0 OR ch.id < 1000000),
           en AS (SELECT nb.pid, round(nb.ax)::bigint AS ex, round(nb.ay)::bigint AS ey FROM nb
                  UNION SELECT nb.pid, round(nb.bx)::bigint, round(nb.by)::bigint FROM nb),
           ex AS MATERIALIZED (
             -- for each bend near the box, the bends that do not count toward its room: itself, those it joins or that
             -- join it, and those that share an end with it
             SELECT a.pid, c.pid AS other FROM en a JOIN en c ON c.ex = a.ex AND c.ey = a.ey
             UNION SELECT a.pid, c.pid FROM nb a JOIN nb c ON c.id = a.id
             UNION SELECT a.pid, c.pid FROM nb a JOIN nb c ON c.id = a.joins
             UNION SELECT a.pid, c.pid FROM nb a JOIN nb c ON c.joins = a.id),
           -- (step 14f2) those bends as one list a bend, so each pair of a point and a piece checks the list it has
           exa AS MATERIALIZED (SELECT ex.pid, array_agg(ex.other) AS oth FROM ex GROUP BY ex.pid),
           pt AS (
             -- every point read, with the bend it is on: the points of the bends, the points of the bends rivers join,
             -- and the two ends of every bend near the box; only where the river swings at this grid (step 14f2: a river
             -- that does not swing here needs no room)
             SELECT u.i, m_px[u.i] AS px, m_py[u.i] AS py, (SELECT nb.pid FROM nb WHERE nb.pid = b_id[m_n[u.i]] AND nb.sw) AS pid, m_r[u.i] AS rad,
                    b_g[m_n[u.i]] AS g
               FROM generate_series(1, cardinality(m_n)) AS u(i)
             UNION ALL
             SELECT cardinality(m_n) + u.n, j_px[u.n], j_py[u.n], CASE WHEN j.sw THEN j.pid END,
                    public.rpg_map_bend_radius(j.ax, j.ay, j.cx, j.cy, j.bx, j.by, b_jt[u.n]), j_g[u.n]
               FROM generate_series(1, cardinality(b_id)) AS u(n)
               LEFT JOIN LATERAL (SELECT nb.* FROM nb WHERE nb.id = b_jn[u.n] ORDER BY power(nb.ax - j_px[u.n], 2) + power(nb.ay - j_py[u.n], 2) LIMIT 1) j ON true
             UNION ALL
             SELECT -nb.pid * 2 - e.e, CASE e.e WHEN 0 THEN nb.ax ELSE nb.bx END, CASE e.e WHEN 0 THEN nb.ay ELSE nb.by END, nb.pid,
                    public.rpg_map_bend_radius(nb.ax, nb.ay, nb.cx, nb.cy, nb.bx, nb.by, e.e), nb.gg
               FROM nb CROSS JOIN (VALUES (0), (1)) AS e(e) WHERE nb.sw),
           pk AS MATERIALIZED (
             -- each point with the nine squares round it, of each set of squares it looks in
             SELECT pt.i, pt.px, pt.py, pt.pid, g.g, (SELECT exa.oth FROM exa WHERE exa.pid = pt.pid) AS oth,
                    floor(pt.px / g.sz)::bigint + ox.o AS gx, floor(pt.py / g.sz)::bigint + oy.o AS gy
               FROM pt
               JOIN (VALUES (0, 0, 2 * v_most), (1, 1, 2 * v_mg[2]), (2, 2, 2 * v_mg[3]), (3, 3, 2 * v_mg[4])) AS g(pg, g, sz) ON g.pg = pt.g
              CROSS JOIN (VALUES (-1), (0), (1)) AS ox(o) CROSS JOIN (VALUES (-1), (0), (1)) AS oy(o)
              WHERE pt.pid IS NOT NULL),
           pr AS (
             SELECT pk.i, min(n.d) AS d
               FROM pk JOIN cb ch ON ch.g = pk.g AND ch.gx = pk.gx AND ch.gy = pk.gy
              CROSS JOIN LATERAL public.rpg_seg_nearest(pk.px, pk.py, ch.x0, ch.y0, ch.x1, ch.y1) n
              WHERE NOT ch.pid = ANY (coalesce(pk.oth, '{}'::bigint[]))
              GROUP BY pk.i),
           rm AS MATERIALIZED (
             -- each point's own room: toward other bends, and within its own bend's turn (a swing toward the inside
             -- of a turn as big as the turn's radius would fold the line back on itself)
             SELECT pt.i, pt.px, pt.py, pt.pid, pt.g,
                    least(coalesce(pt.rad * 0.7, 'Infinity'), v_room * 2 * v_mg[pt.g + 1], coalesce(v_room * pr.d, 'Infinity')) AS room
               FROM pt LEFT JOIN pr ON pr.i = pt.i
              WHERE pt.pid IS NOT NULL),
           jn AS (
             -- the room where bends meet: the least of the rooms each of them has there, so a river's room runs on
             -- unbroken from one bend into the next (step 14f2: a river found on the Country grid that ends where a
             -- downhill river's bend does is not that river running on)
             SELECT e.i, min(coalesce(o.room, 'Infinity')) AS room
               FROM rm e JOIN rm o ON o.i < 0 AND o.g = e.g AND abs(o.px - e.px) < 1 AND abs(o.py - e.py) < 1
              WHERE e.i < 0 GROUP BY e.i)
      -- a point's room: its own, and no more than its bend's room at its two ends would give it there
      SELECT array_agg(coalesce(least(rm.room, (1 - f.t) * ja.room + f.t * jb.room), 'Infinity') ORDER BY pt.i)
        INTO m_c
        FROM pt
        CROSS JOIN LATERAL (SELECT CASE WHEN pt.i <= cardinality(m_n) THEN m_t[pt.i] ELSE b_jt[pt.i - cardinality(m_n)] END AS t) f
        LEFT JOIN rm ON rm.i = pt.i
        LEFT JOIN jn ja ON ja.i = -pt.pid * 2
        LEFT JOIN jn jb ON jb.i = -pt.pid * 2 - 1
       WHERE pt.i > 0;
    ELSE
      m_c := array_fill('Infinity'::double precision, ARRAY[cardinality(m_n) + cardinality(b_id)]);
    END IF;
    -- the line: each point of the bend moved across it by its swing, passing from the swing of its start size to that
    -- of its end size along it, held within its room; a joining river's last stretch passes to the bigger river's own
    -- move at its middle
    SELECT array_agg(q.x ORDER BY q.i), array_agg(q.y ORDER BY q.i) INTO m_x, m_y
      FROM (SELECT u.i, m_px[u.i] + m_ux[u.i] * q.own * (1 - q.jw) + q.jw * q.jx AS x,
                   m_py[u.i] + m_uy[u.i] * q.own * (1 - q.jw) + q.jw * q.jy AS y
              FROM generate_series(1, cardinality(m_n)) AS u(i)
             CROSS JOIN LATERAL (SELECT m_n[u.i] AS n, cardinality(m_n) + m_n[u.i] AS a) r
             CROSS JOIN LATERAL (
               SELECT (1 - m_t[u.i]) * CASE WHEN b_g[r.n] = 0 THEN CASE WHEN b_ka[r.n] = 2 THEN m_s2[u.i] ELSE m_s3[u.i] END WHEN b_g[r.n] = 1 THEN m_s3f[u.i] WHEN b_g[r.n] = 2 THEN m_s4[u.i] ELSE m_s5[u.i] END
                      + m_t[u.i] * CASE WHEN b_g[r.n] = 0 THEN CASE WHEN b_kb[r.n] = 2 THEN m_s2[u.i] ELSE m_s3[u.i] END WHEN b_g[r.n] = 1 THEN m_s3f[u.i] WHEN b_g[r.n] = 2 THEN m_s4[u.i] ELSE m_s5[u.i] END AS s,
                      (1 - b_jt[r.n]) * CASE WHEN j_g[r.n] = 0 THEN CASE WHEN j_ka[r.n] = 2 THEN m_s2[r.a] ELSE m_s3[r.a] END WHEN j_g[r.n] = 1 THEN m_s3f[r.a] WHEN j_g[r.n] = 2 THEN m_s4[r.a] ELSE m_s5[r.a] END
                      + b_jt[r.n] * CASE WHEN j_g[r.n] = 0 THEN CASE WHEN j_kb[r.n] = 2 THEN m_s2[r.a] ELSE m_s3[r.a] END WHEN j_g[r.n] = 1 THEN m_s3f[r.a] WHEN j_g[r.n] = 2 THEN m_s4[r.a] ELSE m_s5[r.a] END AS js) w
             CROSS JOIN LATERAL (
               SELECT w.s / sqrt(1 + power(w.s / greatest(m_c[u.i], 1e-9), 2)) AS own,
                      CASE WHEN b_jn[r.n] > 0 THEN m_t[u.i] ELSE 0 END AS jw,
                      j_ux[r.n] * w.js / sqrt(1 + power(w.js / greatest(m_c[r.a], 1e-9), 2)) AS jx,
                      j_uy[r.n] * w.js / sqrt(1 + power(w.js / greatest(m_c[r.a], 1e-9), 2)) AS jy) q) q;
    -- (step 14f3) a joining river ends exactly where the bigger river is drawn: that river may itself be passing to the
    -- move of the one it joins (a brook joins a stream that joins a river that joins a great river), so the end is
    -- moved onto the bigger river's own point there as drawn, the whole bend shifted by it in step with how far along
    -- it a point lies (three times over, for such chains)
    IF v_lv = p_level THEN
      FOR v_it IN 1 .. 3 LOOP
        WITH pts AS (SELECT u.i, m_n[u.i] AS n, m_t[u.i] AS t, m_x[u.i] AS x, m_y[u.i] AS y FROM generate_series(1, cardinality(m_n)) AS u(i)),
             ends AS (SELECT DISTINCT ON (p.n) p.n, p.x, p.y FROM pts p WHERE b_jn[p.n] > 0 AND p.t > 1 - 1e-9 ORDER BY p.n, p.t DESC),
             tg AS (SELECT DISTINCT ON (e.n) e.n, q.x - e.x AS dx, q.y - e.y AS dy
                      FROM ends e JOIN pts q ON b_id[q.n] % 1000000000000 = b_jn[e.n] AND abs(q.t - b_jt[e.n]) < 1e-9
                     ORDER BY e.n, power(q.x - e.x, 2) + power(q.y - e.y, 2))
        SELECT array_agg(p.x + coalesce(p.t * tg.dx, 0) ORDER BY p.i), array_agg(p.y + coalesce(p.t * tg.dy, 0) ORDER BY p.i)
          INTO m_x, m_y
          FROM pts p LEFT JOIN tg ON tg.n = p.n;
      END LOOP;
      RETURN QUERY
      SELECT DISTINCT ON (q.n, q.t) b_id[q.n], b_kb[q.n], q.t, q.x, q.y, coalesce(q.x0, q.x), coalesce(q.y0, q.y), coalesce(q.x1, q.x), coalesce(q.y1, q.y)
        FROM (SELECT m_n[u.i] AS n, m_t[u.i] AS t, m_x[u.i] AS x, m_y[u.i] AS y,
                     lag(m_x[u.i]) OVER w AS x0, lag(m_y[u.i]) OVER w AS y0, lead(m_x[u.i]) OVER w AS x1, lead(m_y[u.i]) OVER w AS y1
                FROM generate_series(1, cardinality(m_n)) AS u(i)
              WINDOW w AS (PARTITION BY m_n[u.i] ORDER BY m_t[u.i])) q
       WHERE least(q.x, coalesce(q.x0, q.x), coalesce(q.x1, q.x)) - p_reach <= p_bx1 AND greatest(q.x, coalesce(q.x0, q.x), coalesce(q.x1, q.x)) + p_reach >= p_bx0
         AND least(q.y, coalesce(q.y0, q.y), coalesce(q.y1, q.y)) - p_reach <= p_by1 AND greatest(q.y, coalesce(q.y0, q.y), coalesce(q.y1, q.y)) + p_reach >= p_by0
       ORDER BY q.n, q.t;
      RETURN;
    END IF;
    -- keep the stretches between two points whose line, with the most the finer swings could move it, comes near the box
    SELECT array_agg(q.n ORDER BY q.n, q.t0), array_agg(q.t0 ORDER BY q.n, q.t0), array_agg(q.t1 ORDER BY q.n, q.t0)
      INTO s_n, s_t0, s_t1
      FROM (SELECT m_n[u.i] AS n, m_t[u.i] AS t0, lead(m_t[u.i]) OVER w AS t1, m_x[u.i] AS x0, m_y[u.i] AS y0,
                   lead(m_x[u.i]) OVER w AS x1, lead(m_y[u.i]) OVER w AS y1
              FROM generate_series(1, cardinality(m_n)) AS u(i)
            WINDOW w AS (PARTITION BY m_n[u.i] ORDER BY m_t[u.i])) q
     CROSS JOIN LATERAL (SELECT CASE WHEN b_g[q.n] = 0 THEN v_r ELSE v_rg[b_g[q.n] + 1] END AS r) m
     WHERE q.t1 IS NOT NULL
       AND least(q.x0, q.x1) - m.r - p_reach <= p_bx1 AND greatest(q.x0, q.x1) + m.r + p_reach >= p_bx0
       AND least(q.y0, q.y1) - m.r - p_reach <= p_by1 AND greatest(q.y0, q.y1) + m.r + p_reach >= p_by0;
    IF s_n IS NULL THEN RETURN; END IF;
  END LOOP;
END;
$function$
;
REVOKE ALL ON FUNCTION public.rpg_map_river_line_make(integer, integer, double precision, double precision, double precision, double precision, double precision, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_river_line_make(integer, integer, double precision, double precision, double precision, double precision, double precision, integer) TO service_role;
CREATE OR REPLACE FUNCTION public.rpg_map_river_line(p_level integer, p_sub integer, p_bx0 double precision, p_by0 double precision, p_bx1 double precision, p_by1 double precision, p_reach double precision, p_upto integer DEFAULT 5)
 RETURNS TABLE(pid bigint, k integer, t double precision, x double precision, y double precision)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
-- The winding line of the downhill rivers as grid p_level shows it, near a box of the world (p_bx0 .. p_bx1 east,
-- p_by0 .. p_by1 south, in squares), within p_reach squares of it: the one home of where a downhill river runs (the
-- working is rpg_map_river_line_make; rpg_map_rivers, rpg_map_cliffs, rpg_map_drain_cell and rpg_map_river_trace read
-- it). Rows: points of the line in order of t along each bend (pid), k = the size of river, x, y in squares.
-- (Walk speed step 2, Peter 2026-10-09 1A: walks ran near the 8 seconds a login may take, a third of a second for each
-- read of the battle grid's rivers, 9 to 11 a walk.) On the battle grid the line is worked out once a transaction for
-- each City cell a box touches (144 by 144 squares), within 240 squares of it, kept (rpg.bl_<upto>_<cx>_<cy>), and each
-- read cuts those to its own box and reach: where a river runs does not depend on the box that asks, so these are the
-- points the working gives the box itself. That also mends small boxes: worked out for a box a few squares wide, the
-- working dropped stretches of a river running right through it (a river 60 m wide in the hills of Continent C4 was
-- missing from its battle grids). A box of more than 3 by 3 City cells, a reach past 240, or a box within 300,000
-- squares of the world's east or west edge (where a river's copy a world away may be the near one) is worked out on
-- its own.
DECLARE v_c constant double precision := 144; v_r constant double precision := 240;
        v_cx0 bigint; v_cy0 bigint; v_cx1 bigint; v_cy1 bigint; a bigint; b bigint; v_key text; v_m jsonb; v_all jsonb := '[]';
BEGIN
  IF p_level = 7 AND p_sub = 1 AND p_reach <= v_r AND p_bx0 > 300000 AND p_bx1 < 35831808 - 300000 THEN
    v_cx0 := floor(p_bx0 / v_c)::bigint; v_cy0 := floor(p_by0 / v_c)::bigint;
    v_cx1 := floor((p_bx1 - 1e-9) / v_c)::bigint; v_cy1 := floor((p_by1 - 1e-9) / v_c)::bigint;
    IF v_cx1 - v_cx0 <= 2 AND v_cy1 - v_cy0 <= 2 THEN
      FOR b IN v_cy0 .. greatest(v_cy0, v_cy1) LOOP FOR a IN v_cx0 .. greatest(v_cx0, v_cx1) LOOP
        v_key := 'rpg.bl_' || coalesce(p_upto, 5) || '_' || a || '_' || b;
        v_m := nullif(current_setting(v_key, true), '')::jsonb;
        IF v_m IS NULL THEN
          SELECT coalesce(jsonb_agg(jsonb_build_array(m.pid, m.k, m.t, m.x, m.y, m.nx0, m.ny0, m.nx1, m.ny1)), '[]'::jsonb) INTO v_m
            FROM public.rpg_map_river_line_make(7, 1, a * v_c, b * v_c, (a + 1) * v_c, (b + 1) * v_c, v_r, p_upto) m;
          PERFORM set_config(v_key, v_m::text, true);
        END IF;
        v_all := v_all || v_m;
      END LOOP; END LOOP;
      RETURN QUERY
      SELECT DISTINCT ON (q.pid, q.t) q.pid, q.k, q.t, q.x, q.y
        FROM (SELECT (e ->> 0)::bigint AS pid, (e ->> 1)::integer AS k, (e ->> 2)::double precision AS t, (e ->> 3)::double precision AS x,
                     (e ->> 4)::double precision AS y, (e ->> 5)::double precision AS x0, (e ->> 6)::double precision AS y0,
                     (e ->> 7)::double precision AS x1, (e ->> 8)::double precision AS y1
                FROM jsonb_array_elements(v_all) AS e) q
       WHERE least(q.x, q.x0, q.x1) - p_reach <= p_bx1 AND greatest(q.x, q.x0, q.x1) + p_reach >= p_bx0
         AND least(q.y, q.y0, q.y1) - p_reach <= p_by1 AND greatest(q.y, q.y0, q.y1) + p_reach >= p_by0
       ORDER BY q.pid, q.t;
      RETURN;
    END IF;
  END IF;
  RETURN QUERY SELECT m.pid, m.k, m.t, m.x, m.y FROM public.rpg_map_river_line_make(p_level, p_sub, p_bx0, p_by0, p_bx1, p_by1, p_reach, p_upto) m;
END $fn$;
CREATE OR REPLACE FUNCTION public.rpg_map_rivers(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, k integer, dist double precision, px double precision, py double precision, inside boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the rivers run on any block of any grid, worked out when asked and never stored: the one home of where every
-- river runs for the rules (rpg_map_flow reads it for depth, the fords and the crossings for where a river lies;
-- rpg_map_river_trace draws the same lines). k: 2 great rivers, 3 rivers, 4 streams, 5 brooks.
-- (Step 14f1, Peter 2026-10-07: rivers start on high ground, run downhill, end in the sea or a lake, and lakes drain
-- on by a river.) Every river is a downhill one: the great rivers and the river out of every great lake (step 14f1),
-- the rivers inside each Continent cell (step 14f2), the streams inside each Country cell and the brooks inside each
-- Region cell (step 14f3). Their winding line is rpg_map_river_line, and each cell within reach of it gets the
-- nearest point of it.
-- A grid shows a size of river from its own grid down (a great river from the Continent grid, a river from the
-- Country grid, a stream from the Region grid, a brook from the City grid), except that the river out of a great lake
-- shows wherever the lake does.
-- Per cell and river: dist = squares from the cell's middle to the river's middle line; px, py = the nearest point of
-- that line, from the cell's middle, in cells (east and south positive); inside = that point lies in the cell, so the
-- line runs through it. Cells far from a downhill river (more than a cell and a half, or half its width and a cell) have no
-- row for it. The Maps tab draws a river narrower than its grid's cells from rpg_map_river_trace.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     -- the downhill rivers, their winding line (rpg_map_river_line) near the block, as pieces between its points
     rch AS (SELECT greatest(1.5 * lad.cell, (SELECT st.value FROM st WHERE st.key = 'map_river_2_width')::double precision / 2 + lad.cell) AS reach FROM lad),
     rl AS MATERIALIZED (
       SELECT r.pid, r.k, r.x AS x0, r.y AS y0, lead(r.x) OVER w AS x1, lead(r.y) OVER w AS y1
         FROM lad CROSS JOIN rch
        CROSS JOIN LATERAL public.rpg_map_river_line(p_level, 1, p_x0 * lad.cell, p_y0 * lad.cell, (p_x0 + p_cols) * lad.cell, (p_y0 + p_rows) * lad.cell, rch.reach) r
       WINDOW w AS (PARTITION BY r.pid ORDER BY r.t)),
     -- each size of river's own reach: a cell and a half, or half its width and a cell (step 14f3: a brook two squares
     -- wide looks no further than it needs to)
     rk AS (SELECT w.k, greatest(1.5 * lad.cell, (SELECT st.value FROM st WHERE st.key = 'map_river_' || w.k || '_width')::double precision / 2 + lad.cell) AS reach
              FROM lad CROSS JOIN generate_series(2, 5) AS w(k)),
     -- (walk speed step 2) only the pieces within their own size's reach of the block
     rn AS MATERIALIZED (
       SELECT rl.* FROM rl CROSS JOIN lad JOIN rk ON rk.k = rl.k
        WHERE rl.x1 IS NOT NULL
          AND greatest(rl.x0, rl.x1) + rk.reach >= p_x0 * lad.cell AND least(rl.x0, rl.x1) - rk.reach <= (p_x0 + p_cols) * lad.cell
          AND greatest(rl.y0, rl.y1) + rk.reach >= p_y0 * lad.cell AND least(rl.y0, rl.y1) - rk.reach <= (p_y0 + p_rows) * lad.cell),
     rc AS (
       -- every cell of the block within reach of a piece, and the point of the piece nearest its middle
       SELECT DISTINCT ON (c.cx, c.cy, rl.k) c.cx AS x, c.cy AS y, rl.k, n.d AS dist,
              n.nx / lad.cell - (c.cx + 0.5) AS px, n.ny / lad.cell - (c.cy + 0.5) AS py
         FROM rn rl CROSS JOIN lad JOIN rk rch ON rch.k = rl.k
        CROSS JOIN LATERAL generate_series(greatest(p_x0, floor((least(rl.x0, rl.x1) - rch.reach) / lad.cell)::integer),
                                           least(p_x0 + p_cols - 1, floor((greatest(rl.x0, rl.x1) + rch.reach) / lad.cell)::integer)) AS gx(cx)
        CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((least(rl.y0, rl.y1) - rch.reach) / lad.cell)::integer),
                                           least(p_y0 + p_rows - 1, floor((greatest(rl.y0, rl.y1) + rch.reach) / lad.cell)::integer)) AS gy(cy)
        CROSS JOIN LATERAL (SELECT (gx.cx + 0.5) * lad.cell AS mx, (gy.cy + 0.5) * lad.cell AS my) m
        CROSS JOIN LATERAL public.rpg_seg_nearest(m.mx, m.my, rl.x0, rl.y0, rl.x1, rl.y1) n
        CROSS JOIN LATERAL (SELECT gx.cx, gy.cy) c
        WHERE rl.x1 IS NOT NULL
        ORDER BY c.cx, c.cy, rl.k, n.d),
     al AS (
       SELECT rc.x, rc.y, rc.k, rc.dist, rc.px, rc.py, abs(rc.px) <= 0.5 AND abs(rc.py) <= 0.5 AS inside FROM rc)
SELECT DISTINCT ON (al.x, al.y, al.k) al.x, al.y, al.k, al.dist, al.px, al.py, al.inside
  FROM al
 ORDER BY al.x, al.y, al.k, al.dist;
$function$
;
CREATE OR REPLACE FUNCTION public.rpg_map_cliffs(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, mountains double precision, hills double precision, gorge integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cliffs of a block of the battle grid, worked out when asked and never stored: the one home of which squares are
-- rock to climb and how steep (rpg_map_cliff, rpg_map_costs, rpg_map_walk and rpg_map_view_block read it, each with the
-- square's own ground: mountains = how steep the square is when it is mountains, hills = when it is hills; any other
-- ground has no cliffs).
-- Two kinds of cliff (step 7c; canyons, Peter 2026-10-09: when rivers run through hills or mountains that would create
-- canyons):
--  * a mountain square whose steep (rpg_map_steep) is in the top map_cliff_share, at its own angle (rpg_map_cliff_angle);
--  * the wall of a gorge: a hills or mountains square beside a river (rpg_map_river_line: great rivers, rivers and
--    streams; a brook cuts no gorge), out to the rim. The gorge is map_gorge_depth_K metres deep in hills (great river 40,
--    river 25, stream 8) and map_gorge_mountain_times (3) that in mountains (120, 75, 24); its walls stand at
--    map_gorge_angle_hills (55 degrees) or map_gorge_angle_mountains (70), so each wall reaches depth / tan(angle) past
--    the bank (half the river wide from its middle line): a river in hills 25 m / tan 55 = 17.5 m, 16 squares each side;
--    in mountains 75 m / tan 70 = 27.3 m, 24 squares.
-- Where both meet the steeper wins. gorge = the size of river whose gorge wall the square is (2 great river, 3 river,
-- 4 stream; nothing when it is no gorge wall). Only the battle grid has cliffs: a coarser grid's cells are walked at
-- their ground's own time. Squares with no cliff on either ground have no row.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s
             WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'
               AND (s.key LIKE 'map\_gorge\_%' OR s.key LIKE 'map\_river\__\_width' OR s.key = 'map_square_m')),
     cf AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_gorge_angle_hills')::double precision AS ah,
                   (SELECT st.value FROM st WHERE st.key = 'map_gorge_angle_mountains')::double precision AS am,
                   (SELECT st.value FROM st WHERE st.key = 'map_gorge_mountain_times')::double precision AS times,
                   (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision AS sq),
     -- each size of river and ground: half the river wide, how deep its gorge, how steep and how far past the bank its
     -- wall reaches, in squares
     kw AS (SELECT w.k, g.kind, (SELECT st.value FROM st WHERE st.key = 'map_river_' || w.k || '_width')::double precision / 2 AS half,
                   d.depth, a.angle, d.depth / tan(radians(a.angle)) / cf.sq AS wall
              FROM generate_series(2, 5) AS w(k) CROSS JOIN cf
             CROSS JOIN (VALUES ('hills'), ('mountains')) AS g(kind)
             CROSS JOIN LATERAL (SELECT coalesce((SELECT st.value FROM st WHERE st.key = 'map_gorge_depth_' || w.k)::double precision, 0)
                                        * CASE WHEN g.kind = 'mountains' THEN cf.times ELSE 1 END AS depth) d
             CROSS JOIN LATERAL (SELECT CASE WHEN g.kind = 'mountains' THEN cf.am ELSE cf.ah END AS angle) a
             WHERE d.depth > 0 AND p_level = 7),
     kr AS (SELECT kw.k, max(kw.half + kw.wall) AS reach FROM kw GROUP BY kw.k),
     -- the rivers that cut gorges (great rivers, rivers, streams) near the block, as pieces between their points, each
     -- kept when it comes within its own gorge's reach of the block
     -- the rivers that cut gorges (great rivers, rivers, streams; read with the brooks, as the rivers are drawn, and the
     -- brooks left out by their gorge depth of 0) near the block, as straight pieces between every
     -- fourth point of their line (a square apart on the battle grid; four squares strays from the line by well under a
     -- square, nothing beside a wall tens of squares wide), each kept when it comes within its own gorge's reach of the block
     pt AS (SELECT r.pid, r.k, r.t, r.x, r.y, row_number() OVER (PARTITION BY r.pid ORDER BY r.t) AS rn, count(*) OVER (PARTITION BY r.pid) AS n
              FROM (SELECT max(kr.reach) + 1 AS reach FROM kr HAVING count(*) > 0) m
             CROSS JOIN LATERAL public.rpg_map_river_line(7, 1, p_x0::double precision, p_y0::double precision,
                                                          (p_x0 + p_cols)::double precision, (p_y0 + p_rows)::double precision,
                                                          greatest(m.reach, 180)) r),
     rl AS MATERIALIZED (
       SELECT q.* FROM (
         SELECT pt.k, pt.x AS x0, pt.y AS y0, lead(pt.x) OVER w AS x1, lead(pt.y) OVER w AS y1
           FROM pt WHERE mod(pt.rn - 1, 4) = 0 OR pt.rn = pt.n
         WINDOW w AS (PARTITION BY pt.pid ORDER BY pt.t)) q
        JOIN kr ON kr.k = q.k
        WHERE q.x1 IS NOT NULL
          AND greatest(q.x0, q.x1) >= p_x0 - kr.reach AND least(q.x0, q.x1) <= p_x0 + p_cols + kr.reach
          AND greatest(q.y0, q.y1) >= p_y0 - kr.reach AND least(q.y0, q.y1) <= p_y0 + p_rows + kr.reach),
     sq AS (SELECT gx.x, gy.y FROM generate_series(p_x0, p_x0 + p_cols - 1) AS gx(x) CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) AS gy(y)
             WHERE EXISTS (SELECT 1 FROM rl)),
     -- each square and how near each size of river comes to its middle
     nd AS (SELECT sq.x, sq.y, rl.k, min(n.d) AS d
              FROM sq JOIN kr ON true
              JOIN rl ON rl.k = kr.k
                     AND sq.x + 0.5 BETWEEN least(rl.x0, rl.x1) - kr.reach AND greatest(rl.x0, rl.x1) + kr.reach
                     AND sq.y + 0.5 BETWEEN least(rl.y0, rl.y1) - kr.reach AND greatest(rl.y0, rl.y1) + kr.reach
             CROSS JOIN LATERAL public.rpg_seg_nearest(sq.x + 0.5, sq.y + 0.5, rl.x0, rl.y0, rl.x1, rl.y1) n
             GROUP BY sq.x, sq.y, rl.k),
     -- the gorge wall a square is on each ground: the deepest gorge it is inside the rim of (a square under the river is
     -- water, not hills or mountains, so is never climbed)
     gw AS (SELECT nd.x, nd.y, kw.kind, kw.angle, nd.k, kw.depth
              FROM nd JOIN kw ON kw.k = nd.k WHERE nd.d < kw.half + kw.wall),
     gm AS (SELECT DISTINCT ON (gw.x, gw.y) gw.x, gw.y, gw.angle, gw.k FROM gw WHERE gw.kind = 'mountains' ORDER BY gw.x, gw.y, gw.depth DESC),
     gh AS (SELECT DISTINCT ON (gw.x, gw.y) gw.x, gw.y, gw.angle, gw.k FROM gw WHERE gw.kind = 'hills' ORDER BY gw.x, gw.y, gw.depth DESC),
     -- (walk speed step) only the squares steep enough to be a cliff (the top map_cliff_share) are given their angle
     mc AS (SELECT s.x, s.y, a.angle FROM public.rpg_map_steep(p_level, p_x0, p_y0, p_cols, p_rows) s
             CROSS JOIN LATERAL (SELECT public.rpg_map_cliff_angle(s.steep) AS angle) a
             WHERE p_level = 7 AND s.steep >= 1 - (SELECT st2.value FROM public.rpg_settings st2
                                                   WHERE st2.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND st2.key = 'map_cliff_share')
               AND a.angle IS NOT NULL),
     al AS (SELECT gm.x, gm.y FROM gm UNION SELECT gh.x, gh.y FROM gh UNION SELECT mc.x, mc.y FROM mc)
SELECT al.x, al.y, greatest(gm.angle, mc.angle), gh.angle,
       CASE WHEN gm.angle >= coalesce(mc.angle, 0) THEN gm.k ELSE gh.k END
  FROM al LEFT JOIN gm ON gm.x = al.x AND gm.y = al.y LEFT JOIN gh ON gh.x = al.x AND gh.y = al.y
  LEFT JOIN mc ON mc.x = al.x AND mc.y = al.y;
$function$
;

