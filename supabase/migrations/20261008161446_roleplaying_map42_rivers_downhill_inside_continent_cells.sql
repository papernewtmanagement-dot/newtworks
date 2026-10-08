-- Roleplaying world map step 14f2 (Peter 2026-10-07 18:21: rivers start on high ground, run downhill and end in the sea,
-- a lake or a bigger river; 22:51: Continent I4 > Country B6 has a river looping from the ocean and back to the ocean).
-- The rivers of the Country grid were the older ones: lines where rolls crossed a level, which could start at the coast
-- and loop back to it. Now they are found downhill inside each Continent cell (rpg_map_drain_cell): its 12 x 12
-- Country cells drain to the sea, a great river's line, or the crossing its water leaves by toward the cell the
-- Continent grid sends it to, where the next cell takes it in; a river runs where 20 Country cells' water has gathered
-- (about 11,000 square kilometres). They wind like every river, never cross, join a bigger river on its line, and
-- each cell's rivers are saved on the saved map once worked out. The great rivers wind exactly as before. Streams and
-- brooks stay the older ones until step 14f3.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'map_drain_river', 20, 'Downhill rivers: Country cells whose water must gather for a river to run (20, about 11,000 square kilometres; step 14f2)')
ON CONFLICT (agency_id, key) DO NOTHING;
UPDATE public.rpg_settings SET label = 'Rivers (found downhill inside each Continent cell, step 14f2): width in squares, 60 m'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'map_river_3_width';

CREATE OR REPLACE FUNCTION public.rpg_map_drain_make()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where the water of the Continent grid runs (step 14f1, Peter 2026-10-07 18:21: rivers start on high ground, run
-- downhill, end in the sea or in lakes or marshes, and lakes drain on by a river). Worked out from the land itself:
-- the height of every Continent cell (rpg_map_heights, the rolls that make land and sea) and its ground
-- (rpg_map_ground_of). Nothing here is rolled; the same land always gives the same rivers. rpg_map_drainage keeps it.
-- How (the standard way water is routed over a height map):
--  * Every cell's water goes to one of its eight neighbours (O'Callaghan & Mark 1984), never across another flow
--    corner to corner. The cell it goes to is found by flooding the land up from the sea, lowest first (priority
--    flood: Planchon & Darboux 2002; Barnes, Lehman & Mulla 2014): each land cell drains to the cell the flood reached
--    it from, so all water runs down to the sea.
--  * A hollow the flood has to fill (land lower than the rim round it) holds water up to the rim, and drains out at
--    the lowest point of the rim: a lake that drains on by a river. Only a hollow at least map_lake_2_hollow deep
--    holds a great lake (shallower ones are flats the river runs through, the way small sinks in real height data
--    are only noise).
--  * Each cell gathers the water of every cell that drains through it (its own counting 1, a desert map_drain_desert:
--    dry land sends on little water). Where at least map_drain_great cells drain (6 Continent cells, about half a
--    million square kilometres: the basins Earth's rivers 400 m wide drain, about 50 of them on Earth's land, and this
--    world has half as much land again) a great river runs. The river out of every great lake runs down to the sea or
--    to a great river: a great river where enough water has gathered, a river before that.
-- Returns {pieces: [...], lakes: [...]}, in Continent cells (a cell's middle is its number + 0.5; the map wraps east
-- to west, so a piece may start or end just past the edge):
--  pieces: [id, ax, ay, cx, cy, bx, by, k_start, k_end, start, joins] = one bend of a river, a curve from (ax, ay)
--    toward (cx, cy) and on to (bx, by) (a quadratic curve, the way the Maps tab draws rivers through the middles
--    between their points); k = the size of river (2 great river, 3 river) where it starts and where it ends;
--    start = 1 where a river rises (its first bend); joins = the id of the bend of the bigger river it joins at that
--    bend's middle, else 0.
--  lakes: [fill, [x, y], ...] = each great lake: the height it fills to and its cells.
--  dn, acc, ch, wt (step 14f2): each cell's own numbers, below.
DECLARE
  v_w integer; v_h integer; v_n integer;
  v_hollow double precision; v_great double precision; v_desert double precision;
  h double precision[]; land boolean[]; wt double precision[];
  fill double precision[]; dn integer[]; done boolean[]; ord integer[] := '{}'; acc double precision[];
  hk double precision[] := '{}'; hc integer[] := '{}'; hd integer[] := '{}'; hn integer := 0;
  lk integer[]; isriv boolean[]; kk integer[]; up integer[];
  i integer; j integer; c integer; d integer; nb integer; dx integer; dy integer; x integer; y integer;
  f double precision; t double precision; e integer; p integer;
  kx double precision; ky double precision; ix integer;
  v_pieces jsonb := '[]'; v_lakes jsonb := '[]'; v_id integer := 0; v_main integer[];
  st integer[]; grp integer[]; ng integer := 0; gdeep double precision[] := '{}';
  v_eps constant double precision := 1e-6;
BEGIN
  SELECT l.across, l.down INTO v_w, v_h FROM public.rpg_map_ladder() l WHERE l.level = 2;
  v_n := v_w * v_h;
  SELECT max(s.value) FILTER (WHERE s.key = 'map_lake_2_hollow'), max(s.value) FILTER (WHERE s.key = 'map_drain_great'),
         max(s.value) FILTER (WHERE s.key = 'map_drain_desert')
    INTO v_hollow, v_great, v_desert
    FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  h := array_fill(0::double precision, ARRAY[v_n]); land := array_fill(false, ARRAY[v_n]); wt := array_fill(1::double precision, ARRAY[v_n]);
  FOR x, y, f IN SELECT r.x, r.y, r.height FROM public.rpg_map_heights(2, 0, 0, v_w, v_h) r LOOP
    h[y * v_w + x + 1] := f;
  END LOOP;
  FOR x, y, kx IN SELECT g.x, g.y, CASE g.kind WHEN 'sea' THEN -1 WHEN 'desert' THEN v_desert ELSE 1 END FROM public.rpg_map_ground_of(2, 0, 0, v_w, v_h) g LOOP
    land[y * v_w + x + 1] := kx >= 0; wt[y * v_w + x + 1] := greatest(kx, 0);
  END LOOP;
  fill := array_fill(NULL::double precision, ARRAY[v_n]); dn := array_fill(0, ARRAY[v_n]); done := array_fill(false, ARRAY[v_n]);

  -- seed the flood: every land cell beside the sea, draining to its lowest sea neighbour
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w; d := 0;
    FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
      CONTINUE WHEN (dx = 0 AND dy = 0) OR y + dy < 0 OR y + dy >= v_h;
      nb := (y + dy) * v_w + ((x + dx + v_w) % v_w) + 1;
      IF NOT land[nb] AND (d = 0 OR h[nb] < h[d]) THEN d := nb; END IF;
    END LOOP; END LOOP;
    IF d > 0 THEN
      -- push (h[c], c, d) onto the heap (lowest height first, then lowest cell number)
      hn := hn + 1; hk[hn] := h[c]; hc[hn] := c; hd[hn] := d; i := hn;
      WHILE i > 1 LOOP
        j := i / 2;
        EXIT WHEN hk[j] < hk[i] OR (hk[j] = hk[i] AND hc[j] <= hc[i]);
        f := hk[i]; hk[i] := hk[j]; hk[j] := f; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
      END LOOP;
    END IF;
  END LOOP;

  -- the flood, lowest first
  WHILE hn > 0 LOOP
    f := hk[1]; c := hc[1]; d := hd[1];
    hk[1] := hk[hn]; hc[1] := hc[hn]; hd[1] := hd[hn]; hn := hn - 1; i := 1;
    LOOP
      j := 2 * i; EXIT WHEN j > hn;
      IF j < hn AND (hk[j + 1] < hk[j] OR (hk[j + 1] = hk[j] AND hc[j + 1] < hc[j])) THEN j := j + 1; END IF;
      EXIT WHEN hk[i] < hk[j] OR (hk[i] = hk[j] AND hc[i] <= hc[j]);
      t := hk[i]; hk[i] := hk[j]; hk[j] := t; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
    END LOOP;
    CONTINUE WHEN done[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w;
    -- two flows never cross corner to corner: where the water of c would run to a corner neighbour past two cells
    -- that already drain one into the other, it runs into the lower of those two instead
    IF land[d] AND (d - 1) / v_w <> y AND (d - 1) % v_w <> x THEN
      e := y * v_w + (d - 1) % v_w + 1;           -- beside c east or west, on c's row
      p := (d - 1) / v_w * v_w + x + 1;           -- beside c north or south, in c's column
      IF done[e] AND dn[e] = p THEN d := p; ELSIF done[p] AND dn[p] = e THEN d := e; END IF;
    END IF;
    done[c] := true; fill[c] := f; dn[c] := d; ord := ord || c;
    FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
      CONTINUE WHEN (dx = 0 AND dy = 0) OR y + dy < 0 OR y + dy >= v_h;
      nb := (y + dy) * v_w + ((x + dx + v_w) % v_w) + 1;
      CONTINUE WHEN NOT land[nb] OR done[nb];
      hn := hn + 1; hk[hn] := greatest(h[nb], f + v_eps); hc[hn] := nb; hd[hn] := c; i := hn;
      WHILE i > 1 LOOP
        j := i / 2;
        EXIT WHEN hk[j] < hk[i] OR (hk[j] = hk[i] AND hc[j] <= hc[i]);
        t := hk[i]; hk[i] := hk[j]; hk[j] := t; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
      END LOOP;
    END LOOP; END LOOP;
  END LOOP;

  -- the water each cell gathers, from the top of the flood down
  acc := wt;
  FOR i IN REVERSE coalesce(array_length(ord, 1), 0) .. 1 LOOP
    c := ord[i]; d := dn[c];
    IF land[d] THEN acc[d] := acc[d] + acc[c]; END IF;
  END LOOP;

  -- the hollows: cells the flood filled above their own ground, joined by their eight neighbours; the deep ones are great lakes
  lk := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c] OR lk[c] <> 0 OR fill[c] <= h[c] + 1e-3;
    ng := ng + 1; st := ARRAY[c]; grp := '{}'; lk[c] := ng; f := 0;
    WHILE coalesce(array_length(st, 1), 0) > 0 LOOP
      p := st[array_length(st, 1)]; st := st[1:array_length(st, 1) - 1]; grp := grp || p; f := greatest(f, fill[p] - h[p]);
      x := (p - 1) % v_w; y := (p - 1) / v_w;
      FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
        CONTINUE WHEN (dx = 0 AND dy = 0) OR y + dy < 0 OR y + dy >= v_h;
        nb := (y + dy) * v_w + ((x + dx + v_w) % v_w) + 1;
        IF land[nb] AND lk[nb] = 0 AND fill[nb] > h[nb] + 1e-3 THEN lk[nb] := ng; st := st || nb; END IF;
      END LOOP; END LOOP;
    END LOOP;
    gdeep[ng] := f;
    IF f >= v_hollow THEN
      v_lakes := v_lakes || jsonb_build_array((SELECT jsonb_build_array(max(fill[g]))
                                               || jsonb_agg(jsonb_build_array((g - 1) % v_w, (g - 1) / v_w) ORDER BY g)
                                                 FROM unnest(grp) AS g));
    END IF;
  END LOOP;
  -- only the deep hollows stay lakes
  FOR c IN 1 .. v_n LOOP
    IF lk[c] > 0 AND gdeep[lk[c]] < v_hollow THEN lk[c] := 0; END IF;
  END LOOP;

  -- the rivers: great rivers where enough water gathers; the way out of every great lake down to the sea or a great river
  isriv := array_fill(false, ARRAY[v_n]); kk := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    IF land[c] AND lk[c] = 0 AND acc[c] >= v_great THEN isriv[c] := true; END IF;
  END LOOP;
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c] OR lk[c] = 0;
    d := dn[c];
    CONTINUE WHEN NOT land[d] OR lk[d] = lk[c];
    -- c is the lake's last cell: its water leaves for d; follow it down
    WHILE land[d] AND lk[d] = 0 AND NOT (isriv[d] AND acc[d] >= v_great) LOOP
      isriv[d] := true; d := dn[d];
    END LOOP;
  END LOOP;
  FOR c IN 1 .. v_n LOOP
    IF isriv[c] THEN kk[c] := CASE WHEN acc[c] >= v_great THEN 2 ELSE 3 END; END IF;
  END LOOP;

  -- the main water into each river cell: the river (or the lake) upstream that brings it the most
  up := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT land[c] OR NOT (isriv[c] OR lk[c] > 0);
    d := dn[c];
    CONTINUE WHEN NOT land[d] OR NOT isriv[d];
    IF up[d] = 0 OR acc[c] > acc[up[d]] OR (acc[c] = acc[up[d]] AND c < up[d]) THEN up[d] := c; END IF;
  END LOOP;

  -- one bend a river cell: from the middle between it and its main water, past its middle, to the middle between it and
  -- the cell below; a river rises at the middle of its first cell; one leaving a lake starts in the lake
  v_main := array_fill(0, ARRAY[v_n]);
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT isriv[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w; d := dn[c];
    kx := x + 0.5 + public.rpg_map_wrap_step(((d - 1) % v_w) - x, v_w) / 2.0; ky := y + 0.5 + (((d - 1) / v_w) - y) / 2.0;
    p := up[c];
    v_id := v_id + 1; v_main[c] := v_id;
    IF p = 0 THEN
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id, x + 0.5, y + 0.5, (x + 0.5 + kx) / 2, (y + 0.5 + ky) / 2, kx, ky, kk[c], kk[c], 1, 0));
    ELSE
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id,
                    x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w) / 2.0, y + 0.5 + (((p - 1) / v_w) - y) / 2.0,
                    x + 0.5, y + 0.5, kx, ky, CASE WHEN lk[p] > 0 THEN kk[c] ELSE kk[p] END, kk[c], 0, 0));
      IF lk[p] > 0 THEN
        -- the lead from the middle of the lake's last cell out to its edge
        v_id := v_id + 1;
        v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id,
                      x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w), y + 0.5 + (((p - 1) / v_w) - y),
                      x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w) * 0.75, y + 0.5 + (((p - 1) / v_w) - y) * 0.75,
                      x + 0.5 + public.rpg_map_wrap_step(((p - 1) % v_w) - x, v_w) / 2.0, y + 0.5 + (((p - 1) / v_w) - y) / 2.0,
                      kk[c], kk[c], 1, 0));
      END IF;
    END IF;
  END LOOP;
  -- the end of each river cell's bend: on into the sea or a lake to the middle of the cell below, or into the bigger
  -- river at the middle of that river's own bend where it is not the main water there
  FOR c IN 1 .. v_n LOOP
    CONTINUE WHEN NOT isriv[c];
    x := (c - 1) % v_w; y := (c - 1) / v_w; d := dn[c];
    dx := public.rpg_map_wrap_step(((d - 1) % v_w) - x, v_w); dy := ((d - 1) / v_w) - y;
    kx := x + 0.5 + dx / 2.0; ky := y + 0.5 + dy / 2.0;
    IF NOT land[d] OR lk[d] > 0 THEN
      v_id := v_id + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id, kx, ky, x + 0.5 + dx * 0.75, y + 0.5 + dy * 0.75, x + 0.5 + dx, y + 0.5 + dy, kk[c], kk[c], 0, 0));
    ELSIF up[d] <> c THEN
      -- the middle of the bend of d, as seen from c (d's own numbers shifted by the step from c)
      SELECT 0.25 * ((z.e2 ->> 1)::double precision) + 0.5 * ((z.e2 ->> 3)::double precision) + 0.25 * ((z.e2 ->> 5)::double precision),
             0.25 * ((z.e2 ->> 2)::double precision) + 0.5 * ((z.e2 ->> 4)::double precision) + 0.25 * ((z.e2 ->> 6)::double precision)
        INTO f, t FROM (SELECT v_pieces -> (v_main[d] - 1) AS e2) z;
      -- shift d's numbers into c's side of the world edge
      ix := (x + dx) - ((d - 1) % v_w);
      f := f + ix;
      -- the bend leaves c the way c's own bend arrives (so the line turns smoothly), half the way to that middle
      kx := sqrt(power(f - (x + 0.5 + dx / 2.0), 2) + power(t - (y + 0.5 + dy / 2.0), 2)) / 2 / sqrt(dx * dx + dy * dy);
      v_id := v_id + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_id, x + 0.5 + dx / 2.0, y + 0.5 + dy / 2.0,
                    x + 0.5 + dx / 2.0 + dx * kx, y + 0.5 + dy / 2.0 + dy * kx, f, t, kk[c], kk[c], 0, v_main[d]));
    END IF;
  END LOOP;
  -- (step 14f2) every Continent cell's own numbers, so each cell's rivers can be found inside it (rpg_map_drain_cell):
  -- dn = the cell its water runs to (cell number y * 144 + x), -1 for the sea; acc = the water it gathers (Continent
  -- cells, a desert counting map_drain_desert), -1 for the sea; ch = 2 or 3 where a downhill river runs through it, 9
  -- where it is a great lake, else 0; wt = the water each of its cells sends on (1, a desert map_drain_desert)
  RETURN jsonb_build_object('pieces', v_pieces, 'lakes', v_lakes,
    'dn', (SELECT jsonb_agg(CASE WHEN land[g] THEN dn[g] - 1 ELSE -1 END ORDER BY g) FROM generate_series(1, v_n) AS g),
    'acc', (SELECT jsonb_agg(CASE WHEN land[g] THEN round(acc[g]::numeric, 2) ELSE -1 END ORDER BY g) FROM generate_series(1, v_n) AS g),
    'ch', (SELECT jsonb_agg(CASE WHEN NOT land[g] THEN 0 WHEN lk[g] > 0 THEN 9 ELSE kk[g] END ORDER BY g) FROM generate_series(1, v_n) AS g),
    'wt', (SELECT jsonb_agg(wt[g] ORDER BY g) FROM generate_series(1, v_n) AS g));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_drainage()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The downhill rivers and great lakes of the Continent grid (rpg_map_drain_make; step 14f1), as kept: the saved map
-- holds them (rpg_map_cache, level 0, notes: drain), saved by rpg_map_cache_warm(1) right after the saved map is
-- cleared. Until then they are worked out here (about 2 seconds) and kept for the rest of the transaction (rpg.drain),
-- so one read of the map works them out at most once. Its pieces and lakes only: each cell's own numbers (step 14f2)
-- are read by rpg_map_drain_cells, so the many reads of the rivers do not carry them.
DECLARE v jsonb;
BEGIN
  v := nullif(current_setting('rpg.drain', true), '')::jsonb;
  IF v IS NULL THEN
    SELECT m.notes -> 'drain' INTO v FROM public.rpg_map_cache m WHERE m.level = 0 AND m.gx = 0 AND m.gy = 0;
    IF v IS NULL THEN
      v := public.rpg_map_drain_make();
    END IF;
    PERFORM set_config('rpg.drainc', jsonb_build_object('dn', v -> 'dn', 'acc', v -> 'acc', 'ch', v -> 'ch', 'wt', v -> 'wt')::text, true);
    v := v - 'dn' - 'acc' - 'ch' - 'wt';
    PERFORM set_config('rpg.drain', v::text, true);
  END IF;
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_drain_cells()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Each Continent cell's own numbers from the downhill rivers (rpg_map_drain_make; step 14f2): dn, acc, ch, wt, kept for
-- the rest of the transaction (rpg.drainc) by rpg_map_drainage, which reads them with the rest.
DECLARE v jsonb;
BEGIN
  v := nullif(current_setting('rpg.drainc', true), '')::jsonb;
  IF v IS NULL THEN
    PERFORM public.rpg_map_drainage();
    v := nullif(current_setting('rpg.drainc', true), '')::jsonb;
  END IF;
  RETURN v;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_river_layers(p_gmin double precision)
 RETURNS TABLE(k integer, n integer, gap double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The swings a downhill river of each size winds by (step 14f1), as read where swings at least p_gmin squares wide
-- show: the layers of part 9 rolls from the Continent cell its course is found on down to the smallest bend a river of
-- its width makes (a quarter of map_river_meander_wave widths, as step 10a), and no closer than p_gmin. k = the size
-- (2 great river, 3 river), n = the layer (rpg_map_layers), gap = squares between its points. k = -3 (step 14f2): a
-- river whose course the Country grid found (rpg_map_drain_cell), its layers from the Country cell down, so its
-- swings keep to the course found there.
SELECT q.k, y.n, y.gap::double precision
  FROM (SELECT 2 AS k, (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_2_width')::double precision AS width, 2 AS lv
        UNION ALL
        SELECT 3, (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_3_width')::double precision, 2
        UNION ALL
        SELECT -3, (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_3_width')::double precision, 3) q
 CROSS JOIN (SELECT (SELECT s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = 'map_river_meander_wave')::double precision AS wave) c
  JOIN public.rpg_map_ladder() l ON l.level = q.lv
  JOIN public.rpg_map_layers() y ON y.gap >= greatest(q.width * c.wave / 4, coalesce(p_gmin, 0)) AND y.gap < l.cell;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_drain_cell(p_cx integer, p_cy integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The rivers inside one Continent cell (step 14f2, Peter 2026-10-07 18:21: rivers start on high ground, run downhill
-- and end in the sea, a lake or a bigger river). The great rivers and the rivers out of the great lakes come from the
-- whole Continent grid (rpg_map_drainage); this finds the rivers of the Country grid inside one of its cells the same
-- way (O'Callaghan & Mark 1984 flow to one of eight neighbours; priority flood, Barnes, Lehman & Mulla 2014), on the
-- heights of its 12 x 12 Country cells (rpg_map_heights), so nothing spans the world and every cell agrees with the
-- grid above it:
--  * the water of the cell leaves where the Continent grid says it goes (rpg_map_drainage dn): by the lowest crossing
--    of the edge it shares with that cell (the lowest pair of Country cells either side of it), or by the corner
--    toward a cell corner to corner. The cell beside it finds the same crossing, so a river leaves one cell exactly
--    where it enters the next;
--  * the water of each cell that drains into this one comes in at that crossing: all it gathered on the Continent grid
--    (rpg_map_drainage acc, x 144 Country cells a Continent cell);
--  * inside, every Country cell drains toward the way out, the sea, or a downhill river or great lake already running
--    through the cell (its Country cells are where that river's line lies), lowest pass first;
--  * a river runs where at least map_drain_river Country cells' water has gathered (20, about 11,000 square
--    kilometres: a river 60 m wide drains about 1 / 44 of the area a great river 400 m wide does, as river width grows
--    with the square root of the water it carries, Leopold & Maddock 1953). The way out of the cell is a river exactly
--    when the water the Continent grid gives the cell is enough, so the two cells always agree.
-- Returns the bends of its rivers as rpg_map_drainage pieces, in Country cells from the world's west and north edges:
-- [id, ax, ay, cx, cy, bx, by, k_start, k_end, start, joins, jt]; k is 3 (a river); id = 1,000,000 + the Continent
-- cell's number x 1,000 + n; joins = the bend it ends on (a bend of this cell or a downhill river's bend), jt = where
-- along that bend (0 to 1). Kept for the rest of the transaction (rpg.dcell); a read of the map saves them on the
-- saved map's Continent grid row (rpg_map_view_block; notes: rivers), where later reads find them.
DECLARE
  v_w integer; v_h integer; v_sub integer; v_t double precision; v_wt double precision;
  v_memo jsonb; v_key text := p_cx || ',' || p_cy; dr jsonb; dc jsonb;
  v_ci integer; v_x0 integer; v_y0 integer; v_est double precision; v_ch integer;
  hh double precision[]; land boolean[]; wt double precision[]; outl boolean[]; sea boolean[];
  chn boolean[]; cb integer[]; ct double precision[]; cd double precision[];
  lpb integer[] := '{}'; lpt double precision[] := '{}'; lpx double precision[] := '{}'; lpy double precision[] := '{}'; jb integer; jt double precision; jx double precision; jy double precision;
  inflow double precision[]; vin boolean[]; vinx integer[]; viny integer[]; vinf double precision[]; dn integer[]; done boolean[]; ord integer[] := '{}'; acc double precision[];
  isriv boolean[]; up integer[]; bid integer[];
  hk double precision[] := '{}'; hc integer[] := '{}'; hd integer[] := '{}'; hn integer := 0;
  bz jsonb := '[]';
  v_exit integer := 0; v_exx integer := 0; v_exy integer := 0;
  i integer; j integer; c integer; d integer; e integer; p integer; nb integer; dx integer; dy integer; x integer; y integer;
  f double precision; t double precision; ax double precision; ay double precision; qx double precision; qy double precision;
  kx double precision; ky double precision; mx double precision; my double precision; q double precision;
  r integer; best integer; bsum double precision; nci integer; ndn integer; sx integer; sy integer;
  v_pieces jsonb := '[]'; v_n integer := 0;
  v_eps constant double precision := 1e-6;
BEGIN
  v_memo := coalesce(nullif(current_setting('rpg.dcell', true), '')::jsonb, '{}'::jsonb);
  IF v_memo ? v_key THEN RETURN v_memo -> v_key; END IF;
  -- saved on the saved map's Continent grid row by an earlier read of the map (rpg_map_view_block)
  SELECT m.notes -> 'rivers' -> v_key INTO v_pieces FROM public.rpg_map_cache m
   WHERE m.level = 2 AND m.gx = floor(p_cx / 12.0)::integer AND m.gy = floor(p_cy / 12.0)::integer;
  IF v_pieces IS NOT NULL THEN
    PERFORM set_config('rpg.dcell', (v_memo || jsonb_build_object(v_key, v_pieces))::text, true);
    RETURN v_pieces;
  END IF;
  v_pieces := '[]';
  SELECT max(l.across) FILTER (WHERE l.level = 2), max(l.down) FILTER (WHERE l.level = 2),
         max(l.cols) FILTER (WHERE l.level = 3)
    INTO v_w, v_h, v_sub FROM public.rpg_map_ladder() l;
  SELECT max(s.value) FILTER (WHERE s.key = 'map_drain_river')
    INTO v_t FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  dr := public.rpg_map_drainage(); dc := public.rpg_map_drain_cells();
  v_ci := p_cy * v_w + p_cx;
  v_ch := (dc -> 'ch' ->> v_ci)::integer;
  -- the sea, and the great lakes, hold no rivers of their own
  IF p_cy < 0 OR p_cy >= v_h OR p_cx < 0 OR p_cx >= v_w OR (dc -> 'acc' ->> v_ci)::double precision < 0 OR v_ch = 9 THEN
    PERFORM set_config('rpg.dcell', (v_memo || jsonb_build_object(v_key, '[]'::jsonb))::text, true);
    RETURN '[]'::jsonb;
  END IF;
  v_x0 := p_cx * v_sub; v_y0 := p_cy * v_sub;
  v_est := (dc -> 'acc' ->> v_ci)::double precision * v_sub * v_sub;
  v_wt := (dc -> 'wt' ->> v_ci)::double precision;

  -- the block: this cell's Country cells and one ring round them, numbered (j + 1) * (v_sub + 2) + (i + 1) + 1 for
  -- i, j from -1 to v_sub
  hh := array_fill(0::double precision, ARRAY[(v_sub + 2) * (v_sub + 2)]);
  FOR x, y, f IN SELECT r0.x, r0.y, r0.height FROM public.rpg_map_heights(3, v_x0 - 1, v_y0 - 1, v_sub + 2, v_sub + 2) r0 LOOP
    hh[(y - v_y0 + 1) * (v_sub + 2) + (x - v_x0 + 1) + 1] := f;
  END LOOP;
  -- the cell's own Country cells, numbered j * v_sub + i + 1: the sea where the Country grid shows it
  -- (rpg_map_ground_of, so a river ends where the map draws the coast), the land sending on the water its Continent
  -- cell does (a desert little)
  land := array_fill(false, ARRAY[v_sub * v_sub]); sea := array_fill(true, ARRAY[v_sub * v_sub]);
  wt := array_fill(0::double precision, ARRAY[v_sub * v_sub]);
  FOR x, y, kx IN SELECT g.x, g.y, CASE g.kind WHEN 'sea' THEN -1 ELSE 1 END FROM public.rpg_map_ground_of(3, v_x0, v_y0, v_sub, v_sub) g LOOP
    c := (y - v_y0) * v_sub + (x - v_x0) + 1;
    land[c] := kx >= 0; sea[c] := kx < 0; wt[c] := CASE WHEN kx >= 0 THEN v_wt ELSE 0 END;
  END LOOP;

  -- the downhill rivers through or past the cell, where the Country grid draws them (rpg_map_river_line of the Continent
  -- grid's rivers alone, winding as they do there, its points an eighth of a Country cell apart), in Country cells
  -- from this cell's corner; a Country cell whose middle lies within 0.71 of a point is that river's water (its line
  -- passes through it): rivers here end there, at the point of that river's bend nearest it
  chn := array_fill(false, ARRAY[v_sub * v_sub]); cb := array_fill(0, ARRAY[v_sub * v_sub]);
  ct := array_fill(0::double precision, ARRAY[v_sub * v_sub]); cd := array_fill('Infinity'::double precision, ARRAY[v_sub * v_sub]);
  SELECT l.cell INTO f FROM public.rpg_map_ladder() l WHERE l.level = 3;
  FOR p, t, mx, my IN
      SELECT r.pid % 100000000, r.t, r.x / f - v_x0, r.y / f - v_y0
        FROM public.rpg_map_river_line(3, 4, (v_x0 - 1) * f, (v_y0 - 1) * f, (v_x0 + v_sub + 1) * f, (v_y0 + v_sub + 1) * f, 0, false) r LOOP
    lpb := lpb || p; lpt := lpt || t; lpx := lpx || mx; lpy := lpy || my;
    FOR i IN greatest(floor(mx - 1)::integer, 0) .. least(floor(mx + 1)::integer, v_sub - 1) LOOP
      FOR j IN greatest(floor(my - 1)::integer, 0) .. least(floor(my + 1)::integer, v_sub - 1) LOOP
        q := sqrt(power(i + 0.5 - mx, 2) + power(j + 0.5 - my, 2));
        c := j * v_sub + i + 1;
        IF q < 0.71 AND q < cd[c] THEN chn[c] := true; cd[c] := q; cb[c] := p; ct[c] := t; END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  -- the way out (a cell no downhill river runs through): toward the cell the Continent grid sends its water to
  ndn := (dc -> 'dn' ->> v_ci)::integer;
  IF v_ch = 0 AND ndn >= 0 THEN
    sx := public.rpg_map_wrap_step(ndn % v_w - p_cx, v_w); sy := ndn / v_w - p_cy;
    IF sx <> 0 AND sy <> 0 THEN
      i := CASE WHEN sx > 0 THEN v_sub - 1 ELSE 0 END; j := CASE WHEN sy > 0 THEN v_sub - 1 ELSE 0 END;
    ELSE
      best := -1; bsum := 'Infinity';
      FOR r IN 0 .. v_sub - 1 LOOP
        i := CASE WHEN sx > 0 THEN v_sub - 1 WHEN sx < 0 THEN 0 ELSE r END;
        j := CASE WHEN sy > 0 THEN v_sub - 1 WHEN sy < 0 THEN 0 ELSE r END;
        f := hh[(j + 1) * (v_sub + 2) + (i + 1) + 1] + hh[(j + sy + 1) * (v_sub + 2) + (i + sx + 1) + 1];
        IF f < bsum THEN bsum := f; best := r; END IF;
      END LOOP;
      i := CASE WHEN sx > 0 THEN v_sub - 1 WHEN sx < 0 THEN 0 ELSE best END;
      j := CASE WHEN sy > 0 THEN v_sub - 1 WHEN sy < 0 THEN 0 ELSE best END;
    END IF;
    v_exit := j * v_sub + i + 1;
    -- the Country cell across the edge it runs into, as a step from the way out
    v_exx := sx; v_exy := sy;
  END IF;

  -- the water coming in: from each cell beside this one that sends its water here and has no downhill river of its
  -- own, at the crossing it leaves by (found the same way from its side)
  inflow := array_fill(0::double precision, ARRAY[v_sub * v_sub]); vin := array_fill(false, ARRAY[v_sub * v_sub]);
  vinx := array_fill(0, ARRAY[v_sub * v_sub]); viny := array_fill(0, ARRAY[v_sub * v_sub]); vinf := array_fill(0::double precision, ARRAY[v_sub * v_sub]);
  FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
    CONTINUE WHEN (dx = 0 AND dy = 0) OR p_cy + dy < 0 OR p_cy + dy >= v_h;
    nci := (p_cy + dy) * v_w + ((p_cx + dx + v_w) % v_w);
    CONTINUE WHEN (dc -> 'acc' ->> nci)::double precision < 0 OR (dc -> 'ch' ->> nci)::integer <> 0
                  OR (dc -> 'dn' ->> nci)::integer <> v_ci;
    IF dx <> 0 AND dy <> 0 THEN
      i := CASE WHEN dx > 0 THEN v_sub - 1 ELSE 0 END; j := CASE WHEN dy > 0 THEN v_sub - 1 ELSE 0 END;
    ELSE
      best := -1; bsum := 'Infinity';
      FOR r IN 0 .. v_sub - 1 LOOP
        i := CASE WHEN dx > 0 THEN v_sub - 1 WHEN dx < 0 THEN 0 ELSE r END;
        j := CASE WHEN dy > 0 THEN v_sub - 1 WHEN dy < 0 THEN 0 ELSE r END;
        f := hh[(j + dy + 1) * (v_sub + 2) + (i + dx + 1) + 1] + hh[(j + 1) * (v_sub + 2) + (i + 1) + 1];
        IF f < bsum THEN bsum := f; best := r; END IF;
      END LOOP;
      i := CASE WHEN dx > 0 THEN v_sub - 1 WHEN dx < 0 THEN 0 ELSE best END;
      j := CASE WHEN dy > 0 THEN v_sub - 1 WHEN dy < 0 THEN 0 ELSE best END;
    END IF;
    c := j * v_sub + i + 1;
    f := (dc -> 'acc' ->> nci)::double precision * v_sub * v_sub;
    inflow[c] := inflow[c] + f;
    -- the river coming in (the biggest, where two come in at one corner cell), and the step back across the edge to it
    IF f >= v_t AND f > vinf[c] THEN vin[c] := true; vinf[c] := f; vinx[c] := dx; viny[c] := dy; END IF;
  END LOOP; END LOOP;

  -- where the water ends: the sea, a downhill river's line, the way out
  outl := array_fill(false, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP outl[c] := sea[c] OR chn[c] OR c = v_exit; END LOOP;
  dn := array_fill(0, ARRAY[v_sub * v_sub]); done := array_fill(false, ARRAY[v_sub * v_sub]);
  -- the flood, from every place water ends, lowest first: each Country cell drains to the cell the flood reached it from
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT outl[c];
    done[c] := true; ord := ord || c;
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
      CONTINUE WHEN (dx = 0 AND dy = 0) OR x + dx < 0 OR x + dx >= v_sub OR y + dy < 0 OR y + dy >= v_sub;
      nb := (y + dy) * v_sub + x + dx + 1;
      CONTINUE WHEN outl[nb];
      hn := hn + 1; hk[hn] := greatest(hh[(y + dy + 1) * (v_sub + 2) + (x + dx + 1) + 1], hh[(y + 1) * (v_sub + 2) + (x + 1) + 1] + v_eps);
      hc[hn] := nb; hd[hn] := c; i := hn;
      WHILE i > 1 LOOP
        j := i / 2;
        EXIT WHEN hk[j] < hk[i] OR (hk[j] = hk[i] AND hc[j] <= hc[i]);
        f := hk[i]; hk[i] := hk[j]; hk[j] := f; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
      END LOOP;
    END LOOP; END LOOP;
  END LOOP;
  WHILE hn > 0 LOOP
    f := hk[1]; c := hc[1]; d := hd[1];
    hk[1] := hk[hn]; hc[1] := hc[hn]; hd[1] := hd[hn]; hn := hn - 1; i := 1;
    LOOP
      j := 2 * i; EXIT WHEN j > hn;
      IF j < hn AND (hk[j + 1] < hk[j] OR (hk[j + 1] = hk[j] AND hc[j + 1] < hc[j])) THEN j := j + 1; END IF;
      EXIT WHEN hk[i] < hk[j] OR (hk[i] = hk[j] AND hc[i] <= hc[j]);
      t := hk[i]; hk[i] := hk[j]; hk[j] := t; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
    END LOOP;
    CONTINUE WHEN done[c];
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    -- two flows never cross corner to corner (as rpg_map_drain_make)
    IF (d - 1) / v_sub <> y AND (d - 1) % v_sub <> x THEN
      e := y * v_sub + (d - 1) % v_sub + 1;
      p := (d - 1) / v_sub * v_sub + x + 1;
      IF done[e] AND dn[e] = p THEN d := p; ELSIF done[p] AND dn[p] = e THEN d := e; END IF;
    END IF;
    done[c] := true; dn[c] := d; ord := ord || c;
    FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
      CONTINUE WHEN (dx = 0 AND dy = 0) OR x + dx < 0 OR x + dx >= v_sub OR y + dy < 0 OR y + dy >= v_sub;
      nb := (y + dy) * v_sub + x + dx + 1;
      CONTINUE WHEN done[nb];
      hn := hn + 1; hk[hn] := greatest(hh[(y + dy + 1) * (v_sub + 2) + (x + dx + 1) + 1], f + v_eps); hc[hn] := nb; hd[hn] := c; i := hn;
      WHILE i > 1 LOOP
        j := i / 2;
        EXIT WHEN hk[j] < hk[i] OR (hk[j] = hk[i] AND hc[j] <= hc[i]);
        t := hk[i]; hk[i] := hk[j]; hk[j] := t; e := hc[i]; hc[i] := hc[j]; hc[j] := e; e := hd[i]; hd[i] := hd[j]; hd[j] := e; i := j;
      END LOOP;
    END LOOP; END LOOP;
  END LOOP;

  -- the water each Country cell gathers, from the top of the flood down (the sea and a river's line gather none)
  acc := array_fill(0::double precision, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP IF land[c] AND NOT chn[c] THEN acc[c] := wt[c] + inflow[c]; END IF; END LOOP;
  FOR i IN REVERSE coalesce(array_length(ord, 1), 0) .. 1 LOOP
    c := ord[i]; d := dn[c];
    IF d > 0 AND NOT sea[d] AND NOT chn[d] THEN acc[d] := acc[d] + acc[c]; END IF;
  END LOOP;

  -- the rivers: land where enough water has gathered; the way out exactly when the Continent grid gives the cell enough
  isriv := array_fill(false, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP
    isriv[c] := land[c] AND NOT chn[c] AND CASE WHEN c = v_exit THEN v_est >= v_t ELSE acc[c] >= v_t END;
  END LOOP;
  -- the main water into each river cell: the river upstream that brings the most, or the river coming in from the
  -- cell beside (-1)
  up := array_fill(0, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP
    IF vin[c] THEN up[c] := -1; END IF;
  END LOOP;
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT isriv[c];
    d := dn[c];
    CONTINUE WHEN d = 0 OR NOT isriv[d];
    IF up[d] = 0 OR (up[d] = -1 AND acc[c] > vinf[d]) OR (up[d] > 0 AND (acc[c] > acc[up[d]] OR (acc[c] = acc[up[d]] AND c < up[d]))) THEN
      up[d] := c;
    END IF;
  END LOOP;

  -- the bends: one a river cell, from the middle between it and its main water, past its middle, to the middle between it
  -- and the cell below (across the edge for the way out); a river rises at the middle of its first cell
  bid := array_fill(0, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT isriv[c];
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    IF c = v_exit THEN dx := v_exx; dy := v_exy;
    ELSE d := dn[c]; dx := (d - 1) % v_sub - x; dy := (d - 1) / v_sub - y; END IF;
    kx := x + 0.5 + dx / 2.0; ky := y + 0.5 + dy / 2.0;
    v_n := v_n + 1; bid[c] := 1000000 + v_ci * 1000 + v_n;
    IF up[c] = 0 THEN
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(bid[c], x + 0.5, y + 0.5, (x + 0.5 + kx) / 2, (y + 0.5 + ky) / 2, kx, ky, 3, 3, 1, 0, 0));
    ELSE
      IF up[c] = -1 THEN
        sx := vinx[c]; sy := viny[c];
      ELSE
        sx := (up[c] - 1) % v_sub - x; sy := (up[c] - 1) / v_sub - y;
      END IF;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(bid[c], x + 0.5 + sx / 2.0, y + 0.5 + sy / 2.0, x + 0.5, y + 0.5, kx, ky, 3, 3, 0, 0, 0));
    END IF;
  END LOOP;
  -- the end of each river cell's bend that does not run on into the next river cell as its main water: into the sea, or
  -- the cell where it sinks away, to that cell's middle; onto a downhill river's line at its nearest point; into a
  -- bigger river of this cell at the middle of that river's own bend
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT isriv[c] OR c = v_exit;
    x := (c - 1) % v_sub; y := (c - 1) / v_sub; d := dn[c];
    dx := (d - 1) % v_sub - x; dy := (d - 1) / v_sub - y;
    kx := x + 0.5 + dx / 2.0; ky := y + 0.5 + dy / 2.0;
    IF chn[d] THEN
      -- the point of that river's line nearest where this one reaches it (each river reaching it from its own side
      -- meets it at its own point), and that point of its bend before it winds (rpg_map_river_line moves the end of
      -- this river with that river's winding, so it ends on its line)
      SELECT u.b, u.t, u.x, u.y INTO jb, jt, jx, jy FROM unnest(lpb, lpt, lpx, lpy) AS u(b, t, x, y) ORDER BY power(u.x - kx, 2) + power(u.y - ky, 2) LIMIT 1;
      SELECT power(1 - jt, 2) * (z.e2 ->> 1)::double precision + 2 * jt * (1 - jt) * (z.e2 ->> 3)::double precision + power(jt, 2) * (z.e2 ->> 5)::double precision,
             power(1 - jt, 2) * (z.e2 ->> 2)::double precision + 2 * jt * (1 - jt) * (z.e2 ->> 4)::double precision + power(jt, 2) * (z.e2 ->> 6)::double precision
        INTO f, t
        FROM (SELECT e0 AS e2 FROM jsonb_array_elements(dr -> 'pieces') AS e0 WHERE (e0 ->> 0)::integer = jb) z;
      -- the Continent bend's point, in Country cells on this cell's side of the world's edge, from this cell's corner
      f := f * v_sub; f := f - round((f - (v_x0 + x + 0.5)) / (v_w * v_sub)) * v_w * v_sub - v_x0; t := t * v_sub - v_y0;
      -- the curve heads for the drawn point; its middle point is set back by half the winding the line adds by its end
      q := sqrt(power(jx - kx, 2) + power(jy - ky, 2)) / 2 / sqrt(dx * dx + dy * dy);
      v_n := v_n + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(1000000 + v_ci * 1000 + v_n, kx, ky, kx + dx * q - (jx - f) / 2, ky + dy * q - (jy - t) / 2, f, t, 3, 3, 0, jb, jt));
    ELSIF NOT isriv[d] THEN
      v_n := v_n + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(1000000 + v_ci * 1000 + v_n, kx, ky, x + 0.5 + dx * 0.75, y + 0.5 + dy * 0.75, x + 0.5 + dx, y + 0.5 + dy, 3, 3, 0, 0, 0));
    ELSIF up[d] <> c THEN
      -- the middle of the bend of d
      SELECT 0.25 * (z.e2 ->> 1)::double precision + 0.5 * (z.e2 ->> 3)::double precision + 0.25 * (z.e2 ->> 5)::double precision,
             0.25 * (z.e2 ->> 2)::double precision + 0.5 * (z.e2 ->> 4)::double precision + 0.25 * (z.e2 ->> 6)::double precision
        INTO f, t FROM (SELECT e0 AS e2 FROM jsonb_array_elements(v_pieces) AS e0 WHERE (e0 ->> 0)::integer = bid[d]) z;
      q := sqrt(power(f - kx, 2) + power(t - ky, 2)) / 2 / sqrt(dx * dx + dy * dy);
      v_n := v_n + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(1000000 + v_ci * 1000 + v_n, kx, ky, kx + dx * q, ky + dy * q, f, t, 3, 3, 0, bid[d], 0.5));
    END IF;
  END LOOP;
  -- a river coming in where the water ends at once: into the sea, or onto a downhill river's line
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT vin[c] OR isriv[c] OR NOT (sea[c] OR chn[c]);
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    sx := vinx[c]; sy := viny[c];
    kx := x + 0.5 + sx / 2.0; ky := y + 0.5 + sy / 2.0;
    v_n := v_n + 1;
    IF chn[c] THEN
      SELECT u.b, u.t, u.x, u.y INTO jb, jt, jx, jy FROM unnest(lpb, lpt, lpx, lpy) AS u(b, t, x, y) ORDER BY power(u.x - kx, 2) + power(u.y - ky, 2) LIMIT 1;
      SELECT power(1 - jt, 2) * (z.e2 ->> 1)::double precision + 2 * jt * (1 - jt) * (z.e2 ->> 3)::double precision + power(jt, 2) * (z.e2 ->> 5)::double precision,
             power(1 - jt, 2) * (z.e2 ->> 2)::double precision + 2 * jt * (1 - jt) * (z.e2 ->> 4)::double precision + power(jt, 2) * (z.e2 ->> 6)::double precision
        INTO f, t
        FROM (SELECT e0 AS e2 FROM jsonb_array_elements(dr -> 'pieces') AS e0 WHERE (e0 ->> 0)::integer = jb) z;
      f := f * v_sub; f := f - round((f - (v_x0 + x + 0.5)) / (v_w * v_sub)) * v_w * v_sub - v_x0; t := t * v_sub - v_y0;
      q := sqrt(power(jx - kx, 2) + power(jy - ky, 2)) / 2 / sqrt(sx * sx + sy * sy);
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(1000000 + v_ci * 1000 + v_n, kx, ky, kx - sx * q - (jx - f) / 2, ky - sy * q - (jy - t) / 2, f, t, 3, 3, 0, jb, jt));
    ELSE
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(1000000 + v_ci * 1000 + v_n, kx, ky, (kx + x + 0.5) / 2, (ky + y + 0.5) / 2, x + 0.5, y + 0.5, 3, 3, 0, 0, 0));
    END IF;
  END LOOP;
  -- in world Country cells
  SELECT coalesce(jsonb_agg(jsonb_build_array(e0 -> 0, (e0 ->> 1)::double precision + v_x0, (e0 ->> 2)::double precision + v_y0,
                                              (e0 ->> 3)::double precision + v_x0, (e0 ->> 4)::double precision + v_y0,
                                              (e0 ->> 5)::double precision + v_x0, (e0 ->> 6)::double precision + v_y0,
                                              e0 -> 7, e0 -> 8, e0 -> 9, e0 -> 10, e0 -> 11) ORDER BY n0), '[]'::jsonb)
    INTO v_pieces FROM jsonb_array_elements(v_pieces) WITH ORDINALITY AS z(e0, n0);
  PERFORM set_config('rpg.dcell', (v_memo || jsonb_build_object(v_key, v_pieces))::text, true);
  RETURN v_pieces;
END;
$function$;

DROP FUNCTION IF EXISTS public.rpg_map_river_swing(double precision, integer, double precision[], double precision[]);
CREATE OR REPLACE FUNCTION public.rpg_map_river_swing(p_gmin double precision, p_q integer, p_x double precision[], p_y double precision[])
 RETURNS TABLE(i integer, s2 double precision, s3 double precision, s3f double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- How far a downhill river swings sideways at each of a list of points (step 14f1), in squares, for a great river (s2)
-- and a river (s3; s3f for a river whose course the Country grid found, step 14f2): the sum over its layers (rpg_map_river_layers, as read where swings p_gmin wide show) of the layer's
-- gap x map_river_meander_amp / map_river_meander_wave x its roll of unit spread, the way rpg_map_rivers swings every
-- river (step 10a). The rolls are read on points p_q squares apart round each point, in tiles of 32 x 32 of them (a
-- read covers every roll of its box), and blended between them. A point given as null is not read (it swings 0).
-- (Step 14f2) Each point's swing is kept for the rest of the transaction (rpg.sw_<p_gmin>_<p_q>, by point), so the
-- many reads of the rivers that one read of the map makes read each roll once.
DECLARE
  v_key text := 'rpg.sw_' || translate(p_gmin::text, '.-e+', '____') || '_' || p_q;
  v_memo jsonb;
  v_add jsonb;
BEGIN
  v_memo := coalesce(nullif(current_setting(v_key, true), '')::jsonb, '{}'::jsonb);
  WITH cf AS (SELECT max(s.value) FILTER (WHERE s.key = 'map_river_meander_amp') / max(s.value) FILTER (WHERE s.key = 'map_river_meander_wave') AS share,
                     sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0)) AS sd
                FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
       wl AS MATERIALIZED (SELECT l.k, l.n, l.gap FROM public.rpg_map_river_layers(p_gmin) l),
       wi AS MATERIALIZED (SELECT u.n, u.gap, row_number() OVER (ORDER BY u.n)::integer AS r FROM (SELECT DISTINCT wl.n, wl.gap FROM wl) u),
       pt AS (SELECT u.x / p_q - 0.5 AS fx, u.y / p_q - 0.5 AS fy FROM unnest(p_x, p_y) AS u(x, y)),
       -- the points rolls are read on that are not kept yet
       nd AS MATERIALIZED (
         SELECT DISTINCT floor(pt.fx)::bigint + a.a AS gx, floor(pt.fy)::bigint + b.b AS gy
           FROM pt CROSS JOIN (VALUES (0), (1)) AS a(a) CROSS JOIN (VALUES (0), (1)) AS b(b)
          WHERE EXISTS (SELECT 1 FROM wi) AND pt.fx IS NOT NULL AND pt.fy IS NOT NULL
            AND NOT v_memo ? ((floor(pt.fx)::bigint + a.a) || ',' || (floor(pt.fy)::bigint + b.b))),
       bx AS (SELECT floor(nd.gx / 32.0) AS tx, floor(nd.gy / 32.0) AS ty, min(nd.gx) AS x0, min(nd.gy) AS y0,
                     max(nd.gx) - min(nd.gx) + 1 AS cols, max(nd.gy) - min(nd.gy) + 1 AS rows
                FROM nd GROUP BY 1, 2),
       rs AS MATERIALIZED (
         -- each such point's swing of each size
         SELECT r.x::bigint AS gx, r.y::bigint AS gy,
                coalesce(sum(wi.gap * cf.share * r.vals[wi.r] / cf.sd) FILTER (WHERE EXISTS (SELECT 1 FROM wl WHERE wl.n = wi.n AND wl.k = 2)), 0) AS s2,
                coalesce(sum(wi.gap * cf.share * r.vals[wi.r] / cf.sd) FILTER (WHERE EXISTS (SELECT 1 FROM wl WHERE wl.n = wi.n AND wl.k = 3)), 0) AS s3,
                coalesce(sum(wi.gap * cf.share * r.vals[wi.r] / cf.sd) FILTER (WHERE EXISTS (SELECT 1 FROM wl WHERE wl.n = wi.n AND wl.k = -3)), 0) AS s3f
           FROM bx CROSS JOIN cf
          CROSS JOIN (SELECT array_agg(9 ORDER BY wi.r) AS parts, array_agg(wi.n ORDER BY wi.r) AS firsts, array_agg(wi.gap::integer ORDER BY wi.r) AS fines FROM wi) a
          CROSS JOIN LATERAL (SELECT array_agg(((nd.gy - bx.y0) * bx.cols + nd.gx - bx.x0)::integer) AS at FROM nd
                               WHERE floor(nd.gx / 32.0) = bx.tx AND floor(nd.gy / 32.0) = bx.ty) w
          CROSS JOIN LATERAL public.rpg_map_rolls_set(a.parts, a.firsts, a.fines, 7, p_q, bx.x0::integer, bx.y0::integer, bx.cols::integer, bx.rows::integer, w.at) r
          CROSS JOIN wi
          GROUP BY r.x, r.y)
  SELECT jsonb_object_agg(rs.gx || ',' || rs.gy, jsonb_build_array(rs.s2, rs.s3, rs.s3f)) INTO v_add FROM rs;
  IF v_add IS NOT NULL THEN
    v_memo := v_memo || v_add;
    PERFORM set_config(v_key, v_memo::text, true);
  END IF;
  RETURN QUERY
  SELECT u.i::integer,
         coalesce((1 - q.ex) * (1 - q.ey) * (m.a ->> 0)::double precision + q.ex * (1 - q.ey) * (m.b ->> 0)::double precision
                  + (1 - q.ex) * q.ey * (m.c ->> 0)::double precision + q.ex * q.ey * (m.d ->> 0)::double precision, 0),
         coalesce((1 - q.ex) * (1 - q.ey) * (m.a ->> 1)::double precision + q.ex * (1 - q.ey) * (m.b ->> 1)::double precision
                  + (1 - q.ex) * q.ey * (m.c ->> 1)::double precision + q.ex * q.ey * (m.d ->> 1)::double precision, 0),
         coalesce((1 - q.ex) * (1 - q.ey) * (m.a ->> 2)::double precision + q.ex * (1 - q.ey) * (m.b ->> 2)::double precision
                  + (1 - q.ex) * q.ey * (m.c ->> 2)::double precision + q.ex * q.ey * (m.d ->> 2)::double precision, 0)
    FROM unnest(p_x, p_y) WITH ORDINALITY AS u(x, y, i)
   CROSS JOIN LATERAL (SELECT floor(u.x / p_q - 0.5)::bigint AS gx, floor(u.y / p_q - 0.5)::bigint AS gy,
                              u.x / p_q - 0.5 - floor(u.x / p_q - 0.5) AS ex, u.y / p_q - 0.5 - floor(u.y / p_q - 0.5) AS ey) q
   CROSS JOIN LATERAL (SELECT v_memo -> (q.gx || ',' || q.gy) AS a, v_memo -> ((q.gx + 1) || ',' || q.gy) AS b,
                              v_memo -> (q.gx || ',' || (q.gy + 1)) AS c, v_memo -> ((q.gx + 1) || ',' || (q.gy + 1)) AS d) m
   ORDER BY u.i;
END;
$function$;

DROP FUNCTION IF EXISTS public.rpg_map_river_bends();
CREATE OR REPLACE FUNCTION public.rpg_map_river_bends(p_level integer, p_bx0 double precision, p_by0 double precision, p_bx1 double precision, p_by1 double precision, p_fine boolean)
 RETURNS TABLE(id integer, ax double precision, ay double precision, cx double precision, cy double precision, bx double precision, by double precision, ka integer, kb integer, rises boolean, joins integer, jt double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The bends of the downhill rivers in squares from the world's west and north edges: a curve from (ax, ay) toward
-- (cx, cy) and on to (bx, by); ka, kb = the size of river where it starts and ends (2 great river, 3 river); rises = a
-- river's first bend; joins = the bend of the bigger river it ends on, else 0, and jt = where along that bend it ends
-- (0 to 1). The great rivers and the rivers out of the great lakes, all of them (rpg_map_drainage; step 14f1, joining
-- at the middle of a bend); on grid p_level from the Country grid down, also the rivers inside each Continent cell
-- that meets the box p_bx0 .. p_bx1 east, p_by0 .. p_by1 south (rpg_map_drain_cell; step 14f2), a river showing from
-- the Country grid down (p_fine false: not those).
SELECT (e ->> 0)::integer, (e ->> 1)::double precision * l.cell, (e ->> 2)::double precision * l.cell,
       (e ->> 3)::double precision * l.cell, (e ->> 4)::double precision * l.cell,
       (e ->> 5)::double precision * l.cell, (e ->> 6)::double precision * l.cell,
       (e ->> 7)::integer, (e ->> 8)::integer, (e ->> 9)::integer = 1, (e ->> 10)::integer, 0.5::double precision
  FROM public.rpg_map_ladder() l
 CROSS JOIN LATERAL jsonb_array_elements(public.rpg_map_drainage() -> 'pieces') AS e
 WHERE l.level = 2
UNION ALL
SELECT (e ->> 0)::integer, (e ->> 1)::double precision * l.cell, (e ->> 2)::double precision * l.cell,
       (e ->> 3)::double precision * l.cell, (e ->> 4)::double precision * l.cell,
       (e ->> 5)::double precision * l.cell, (e ->> 6)::double precision * l.cell,
       (e ->> 7)::integer, (e ->> 8)::integer, (e ->> 9)::integer = 1, (e ->> 10)::integer, (e ->> 11)::double precision
  FROM public.rpg_map_ladder() l
 CROSS JOIN (SELECT c.cell::double precision AS cc, c.across, c.down FROM public.rpg_map_ladder() c WHERE c.level = 2) k
 CROSS JOIN LATERAL (SELECT DISTINCT ((gx.x % k.across) + k.across) % k.across AS x, gy.y
                       FROM generate_series(floor(p_bx0 / k.cc)::integer, floor(p_bx1 / k.cc)::integer) AS gx(x)
                      CROSS JOIN generate_series(greatest(floor(p_by0 / k.cc)::integer, 0), least(floor(p_by1 / k.cc)::integer, k.down - 1)) AS gy(y)
                      WHERE p_level >= 3 AND p_fine) g
 CROSS JOIN LATERAL jsonb_array_elements(public.rpg_map_drain_cell(g.x, g.y)) AS e
 WHERE l.level = 3 AND p_level >= 3;
$function$;

DROP FUNCTION IF EXISTS public.rpg_map_river_line(integer, integer, double precision, double precision, double precision, double precision, double precision);
CREATE OR REPLACE FUNCTION public.rpg_map_river_line(p_level integer, p_sub integer, p_bx0 double precision, p_by0 double precision, p_bx1 double precision, p_by1 double precision, p_reach double precision, p_fine boolean DEFAULT true)
 RETURNS TABLE(pid integer, k integer, t double precision, x double precision, y double precision)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
-- (at jt along that river's bend, not only at a bend's middle). p_fine false: the downhill rivers of the Continent grid
-- alone (rpg_map_drain_cell reads where they run on the Country grid to find a cell's own rivers).
DECLARE
  v_cc double precision; v_world double precision; v_cell double precision; v_lcell double precision;
  v_share double precision; v_sd double precision := sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0));
  v_lv integer; v_gmin double precision; v_lo double precision; v_r double precision; v_most double precision;
  v_sp double precision; v_q integer; v_room constant double precision := 0.45;
  s_n integer[]; s_t0 double precision[]; s_t1 double precision[];
  b_id integer[]; b_ax double precision[]; b_ay double precision[]; b_cx double precision[]; b_cy double precision[];
  b_bx double precision[]; b_by double precision[]; b_ka integer[]; b_kb integer[]; b_jn integer[]; b_jt double precision[];
  v_wide double precision;
  j_px double precision[]; j_py double precision[]; j_ux double precision[]; j_uy double precision[]; j_ka integer[]; j_kb integer[];
  m_n integer[]; m_t double precision[]; m_px double precision[]; m_py double precision[]; m_ux double precision[]; m_uy double precision[];
  m_s2 double precision[]; m_s3 double precision[]; m_s3f double precision[]; b_f boolean[]; j_f boolean[];
  v_h2 boolean; v_h3 boolean; v_h3f boolean; v_mostf double precision; v_rf double precision;
  w_id integer[]; w_ax double precision[]; w_ay double precision[]; w_cx double precision[]; w_cy double precision[];
  w_bx double precision[]; w_by double precision[]; w_ka integer[]; w_kb integer[]; w_jn integer[]; w_jt double precision[]; m_x double precision[]; m_y double precision[]; m_c double precision[]; m_r double precision[];
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
  SELECT greatest(coalesce(sum(l.gap) * v_share * 49.5 / v_sd, 0), 1) INTO v_mostf FROM public.rpg_map_river_layers(0) l WHERE l.k = -3;

  -- (step 14f2) the bends are read for the box and as far round it as any bend could matter here (the rivers inside
  -- the Continent cells there, rpg_map_drain_cell, come with them)
  v_wide := 3 * v_most + p_reach;
  -- read once, here, for the three uses below; the rivers inside the Continent cells swing much less, so only those
  -- cells within reach of the box by their swings are read (9 x v_mostf: the room they and the bigger rivers near
  -- them look for)
  SELECT array_agg(b.id), array_agg(b.ax), array_agg(b.ay), array_agg(b.cx), array_agg(b.cy), array_agg(b.bx), array_agg(b.by),
         array_agg(b.ka), array_agg(b.kb), array_agg(b.joins), array_agg(b.jt)
    INTO w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by, w_ka, w_kb, w_jn, w_jt
    FROM public.rpg_map_river_bends(p_level, p_bx0 - 9 * v_mostf - p_reach, p_by0 - 9 * v_mostf - p_reach,
                                    p_bx1 + 9 * v_mostf + p_reach, p_by1 + 9 * v_mostf + p_reach, p_fine) b;
  IF w_id IS NULL THEN RETURN; END IF;
  -- the bends near the box (with the copy a world east or west where that copy is the near one); each bend lies
  -- inside the box of its three points, and its line within v_most of that
  SELECT array_agg(q.pid ORDER BY q.pid), array_agg(q.ax ORDER BY q.pid), array_agg(q.ay ORDER BY q.pid), array_agg(q.cx ORDER BY q.pid),
         array_agg(q.cy ORDER BY q.pid), array_agg(q.bx ORDER BY q.pid), array_agg(q.by ORDER BY q.pid), array_agg(q.ka ORDER BY q.pid),
         array_agg(q.kb ORDER BY q.pid), array_agg(q.joins ORDER BY q.pid), array_agg(q.jt ORDER BY q.pid)
    INTO b_id, b_ax, b_ay, b_cx, b_cy, b_bx, b_by, b_ka, b_kb, b_jn, b_jt
    FROM (SELECT b.id + CASE o.o WHEN 1 THEN 100000000 WHEN -1 THEN 200000000 ELSE 0 END AS pid, b.ax + o.o * v_world AS ax, b.ay,
                 b.cx + o.o * v_world AS cx, b.cy, b.bx + o.o * v_world AS bx, b.by, b.ka, b.kb, b.joins, b.jt
            FROM unnest(w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by, w_ka, w_kb, w_jn, w_jt) AS b(id, ax, ay, cx, cy, bx, by, ka, kb, joins, jt) CROSS JOIN (VALUES (-1), (0), (1)) AS o(o)
          CROSS JOIN LATERAL (SELECT CASE WHEN b.id >= 1000000 THEN v_mostf ELSE v_most END AS mo) m
          WHERE least(b.ax, b.cx, b.bx) + o.o * v_world - m.mo - p_reach <= p_bx1 AND greatest(b.ax, b.cx, b.bx) + o.o * v_world + m.mo + p_reach >= p_bx0
             AND least(b.ay, b.cy, b.by) - m.mo - p_reach <= p_by1 AND greatest(b.ay, b.cy, b.by) + m.mo + p_reach >= p_by0) q;
  IF b_id IS NULL THEN RETURN; END IF;
  -- (step 14f2) the bends of rivers whose course the Country grid found, and the bends rivers join that are
  b_f := ARRAY(SELECT u.i % 100000000 >= 1000000 FROM unnest(b_id) AS u(i));
  j_f := ARRAY(SELECT u.i >= 1000000 FROM unnest(b_jn) AS u(i));
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
    SELECT min(l.gap), coalesce(bool_or(l.k = 2), false), coalesce(bool_or(l.k = 3), false), coalesce(bool_or(l.k = -3), false)
      INTO v_lo, v_h2, v_h3, v_h3f FROM public.rpg_map_river_layers(v_gmin) l;
    -- (v_rf: the same for a river whose course the Country grid found, step 14f2)
    SELECT coalesce(max(z.r), 0), coalesce(max(z.r) FILTER (WHERE z.k = -3), 0) INTO v_r, v_rf
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
    v_rf := v_rf + 0.2 * coalesce(v_lo, 0);
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
                                            WHERE jj.i > 0 AND jj.i = b_id[s.n] % 100000000 AND s.t0 < jj.t AND s.t1 > jj.t) z
             ORDER BY s.n, z.t) q;
    -- the swing at every point, and at the middle of every bend a river joins
    SELECT array_agg(w.s2 ORDER BY w.i), array_agg(w.s3 ORDER BY w.i), array_agg(w.s3f ORDER BY w.i) INTO m_s2, m_s3, m_s3f
      -- (step 14f2) only the points of rivers that swing at this grid are read (the others swing 0 here)
      FROM public.rpg_map_river_swing(v_gmin, v_q,
             ARRAY(SELECT CASE WHEN ((b_ka[m_n[u.i]] = 2 OR b_kb[m_n[u.i]] = 2) AND v_h2) OR ((b_ka[m_n[u.i]] = 3 OR b_kb[m_n[u.i]] = 3) AND CASE WHEN b_f[m_n[u.i]] THEN v_h3f ELSE v_h3 END)
                                  THEN m_px[u.i] END FROM generate_series(1, cardinality(m_n)) AS u(i))
             || ARRAY(SELECT CASE WHEN ((j_ka[u.n] = 2 OR j_kb[u.n] = 2) AND v_h2) OR ((j_ka[u.n] = 3 OR j_kb[u.n] = 3) AND CASE WHEN j_f[u.n] THEN v_h3f ELSE v_h3 END)
                                  THEN j_px[u.n] END FROM generate_series(1, cardinality(b_id)) AS u(n)),
             m_py || j_py) w;
    -- at this grid itself, the room each point has to swing: 0.45 of the way to the nearest bend of another river or of
    -- its own course that is not the bend it is on, the bends either side of it, or the bends that join or are joined
    -- by it (those meet it on purpose); on the way down the swings are only used to find the stretches near the box, and
    -- a smaller swing never takes a line farther, so the room is not needed there (nor where nothing swings)
    IF v_lv = p_level AND v_lo IS NOT NULL THEN
      WITH nb AS MATERIALIZED (
             -- the bends whose room counts: near enough the box to come within the most two swings could close
             SELECT b.id + CASE o.o WHEN 1 THEN 100000000 WHEN -1 THEN 200000000 ELSE 0 END AS pid, b.id, b.joins, b.ax + o.o * v_world AS ax, b.ay,
                    b.cx + o.o * v_world AS cx, b.cy, b.bx + o.o * v_world AS bx, b.by,
                    ((b.ka = 2 OR b.kb = 2) AND v_h2) OR ((b.ka = 3 OR b.kb = 3) AND CASE WHEN b.id >= 1000000 THEN v_h3f ELSE v_h3 END) AS sw
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
             -- as it could swing (squares 2 x v_mostf across, g 1), at every river's pieces. The downhill rivers of the
             -- Continent grid look at each other's pieces only (g 0), so they wind exactly as before: the rivers inside
             -- the Continent cells were found where those rivers run on the Country grid (rpg_map_drain_cell) and keep
             -- clear of them
             SELECT ch.*, g.g, floor((ch.x0 + ch.x1) / 2 / g.sz)::bigint AS gx, floor((ch.y0 + ch.y1) / 2 / g.sz)::bigint AS gy
               FROM ch CROSS JOIN (VALUES (0, 2 * v_most), (1, 2 * v_mostf)) AS g(g, sz)
              WHERE g.g = 1 OR ch.id < 1000000),
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
                    CASE WHEN b_f[m_n[u.i]] THEN 1 ELSE 0 END AS g
               FROM generate_series(1, cardinality(m_n)) AS u(i)
             UNION ALL
             SELECT cardinality(m_n) + u.n, j_px[u.n], j_py[u.n], CASE WHEN j.sw THEN j.pid END,
                    public.rpg_map_bend_radius(j.ax, j.ay, j.cx, j.cy, j.bx, j.by, b_jt[u.n]), CASE WHEN j_f[u.n] THEN 1 ELSE 0 END
               FROM generate_series(1, cardinality(b_id)) AS u(n)
               LEFT JOIN LATERAL (SELECT nb.* FROM nb WHERE nb.id = b_jn[u.n] ORDER BY power(nb.ax - j_px[u.n], 2) + power(nb.ay - j_py[u.n], 2) LIMIT 1) j ON true
             UNION ALL
             SELECT -nb.pid * 2 - e.e, CASE e.e WHEN 0 THEN nb.ax ELSE nb.bx END, CASE e.e WHEN 0 THEN nb.ay ELSE nb.by END, nb.pid,
                    public.rpg_map_bend_radius(nb.ax, nb.ay, nb.cx, nb.cy, nb.bx, nb.by, e.e), CASE WHEN nb.id >= 1000000 THEN 1 ELSE 0 END
               FROM nb CROSS JOIN (VALUES (0), (1)) AS e(e) WHERE nb.sw),
           pk AS MATERIALIZED (
             -- each point with the nine squares round it, of each set of squares it looks in
             SELECT pt.i, pt.px, pt.py, pt.pid, g.g, (SELECT exa.oth FROM exa WHERE exa.pid = pt.pid) AS oth,
                    floor(pt.px / g.sz)::bigint + ox.o AS gx, floor(pt.py / g.sz)::bigint + oy.o AS gy
               FROM pt
               JOIN (VALUES (0, 0, 2 * v_most), (1, 1, 2 * v_mostf)) AS g(pg, g, sz) ON g.pg = pt.g
              CROSS JOIN (VALUES (-1), (0), (1)) AS ox(o) CROSS JOIN (VALUES (-1), (0), (1)) AS oy(o)
              WHERE pt.pid IS NOT NULL),
           pr AS (
             SELECT pk.i, min(n.d) AS d
               FROM pk JOIN cb ch ON ch.g = pk.g AND ch.gx = pk.gx AND ch.gy = pk.gy
              CROSS JOIN LATERAL public.rpg_seg_nearest(pk.px, pk.py, ch.x0, ch.y0, ch.x1, ch.y1) n
              WHERE NOT ch.pid = ANY (coalesce(pk.oth, '{}'::integer[]))
              GROUP BY pk.i),
           rm AS MATERIALIZED (
             -- each point's own room: toward other bends, and within its own bend's turn (a swing toward the inside
             -- of a turn as big as the turn's radius would fold the line back on itself)
             SELECT pt.i, pt.px, pt.py, pt.pid, pt.g,
                    least(coalesce(pt.rad * 0.7, 'Infinity'), v_room * 2 * CASE pt.g WHEN 1 THEN v_mostf ELSE v_most END, coalesce(v_room * pr.d, 'Infinity')) AS room
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
               SELECT (1 - m_t[u.i]) * CASE WHEN b_ka[r.n] = 2 THEN m_s2[u.i] WHEN b_f[r.n] THEN m_s3f[u.i] ELSE m_s3[u.i] END
                      + m_t[u.i] * CASE WHEN b_kb[r.n] = 2 THEN m_s2[u.i] WHEN b_f[r.n] THEN m_s3f[u.i] ELSE m_s3[u.i] END AS s,
                      (1 - b_jt[r.n]) * CASE WHEN j_ka[r.n] = 2 THEN m_s2[r.a] WHEN j_f[r.n] THEN m_s3f[r.a] ELSE m_s3[r.a] END
                      + b_jt[r.n] * CASE WHEN j_kb[r.n] = 2 THEN m_s2[r.a] WHEN j_f[r.n] THEN m_s3f[r.a] ELSE m_s3[r.a] END AS js) w
             CROSS JOIN LATERAL (
               SELECT w.s / sqrt(1 + power(w.s / greatest(m_c[u.i], 1e-9), 2)) AS own,
                      CASE WHEN b_jn[r.n] > 0 THEN m_t[u.i] ELSE 0 END AS jw,
                      j_ux[r.n] * w.js / sqrt(1 + power(w.js / greatest(m_c[r.a], 1e-9), 2)) AS jx,
                      j_uy[r.n] * w.js / sqrt(1 + power(w.js / greatest(m_c[r.a], 1e-9), 2)) AS jy) q) q;
    IF v_lv = p_level THEN
      RETURN QUERY
      SELECT DISTINCT ON (q.n, q.t) b_id[q.n], b_kb[q.n], q.t, q.x, q.y
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
     CROSS JOIN LATERAL (SELECT CASE WHEN b_f[q.n] THEN v_rf ELSE v_r END AS r) m
     WHERE q.t1 IS NOT NULL
       AND least(q.x0, q.x1) - m.r - p_reach <= p_bx1 AND greatest(q.x0, q.x1) + m.r + p_reach >= p_bx0
       AND least(q.y0, q.y1) - m.r - p_reach <= p_by1 AND greatest(q.y0, q.y1) + m.r + p_reach >= p_by0;
    IF s_n IS NULL THEN RETURN; END IF;
  END LOOP;
END;
$function$;

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
-- on by a river.) The great rivers, the river out of every great lake and (step 14f2) the rivers inside each
-- Continent cell are the downhill rivers: their winding line is rpg_map_river_line, and each cell within reach of it
-- gets the nearest point of it. The streams and brooks are still the older ones (rpg_map_river_field) until they too
-- are found downhill; where a downhill river's water lies over them they are not there.
-- A grid shows a size of river from its own grid down (a great river from the Continent grid, a river from the
-- Country grid, a stream from the Region grid, a brook from the City grid), except that the river out of a great lake
-- shows wherever the lake does.
-- Per cell and river: dist = squares from the cell's middle to the river's middle line; px, py = the nearest point of
-- that line, from the cell's middle, in cells (east and south positive); inside = that point lies in the cell, so the
-- line runs through it. Cells far from a downhill river (more than a cell and a half, or half its width and a cell) have no
-- row for it. The Maps tab draws a river narrower than its grid's cells from rpg_map_river_trace.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     fld AS MATERIALIZED (SELECT f.* FROM public.rpg_map_river_field(p_level, p_x0, p_y0, p_cols, p_rows) f),
     -- the downhill rivers (step 14f1): the great rivers and the rivers out of the great lakes, their winding line
     -- (rpg_map_river_line) near the block, as pieces between its points
     rch AS (SELECT greatest(1.5 * lad.cell, (SELECT st.value FROM st WHERE st.key = 'map_river_2_width')::double precision / 2 + lad.cell) AS reach FROM lad),
     rl AS MATERIALIZED (
       SELECT r.pid, r.k, r.x AS x0, r.y AS y0, lead(r.x) OVER w AS x1, lead(r.y) OVER w AS y1
         FROM lad CROSS JOIN rch
        CROSS JOIN LATERAL public.rpg_map_river_line(p_level, 1, p_x0 * lad.cell, p_y0 * lad.cell, (p_x0 + p_cols) * lad.cell, (p_y0 + p_rows) * lad.cell, rch.reach) r
       WINDOW w AS (PARTITION BY r.pid ORDER BY r.t)),
     rc AS (
       -- every cell of the block within reach of a piece, and the point of the piece nearest its middle
       SELECT DISTINCT ON (c.cx, c.cy, rl.k) c.cx AS x, c.cy AS y, rl.k, n.d AS dist,
              n.nx / lad.cell - (c.cx + 0.5) AS px, n.ny / lad.cell - (c.cy + 0.5) AS py
         FROM rl CROSS JOIN lad CROSS JOIN rch
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
       SELECT rc.x, rc.y, rc.k, rc.dist, rc.px, rc.py, abs(rc.px) <= 0.5 AND abs(rc.py) <= 0.5 AS inside FROM rc
       UNION ALL
       -- the older streams and brooks, except where a downhill river's water lies over them (step 14f2: the older
       -- rivers are gone, found downhill now)
       -- (the cells under that water as one list: a hash of them would be sized for the many cells the planner fears)
       SELECT fld.x, fld.y, fld.k, fld.dist, fld.px, fld.py, fld.inside
         FROM fld
        CROSS JOIN (SELECT coalesce(array_agg(rc.x::bigint * 100000000 + rc.y), '{}'::bigint[]) AS a FROM rc
                     WHERE rc.dist < CASE rc.k WHEN 2 THEN (SELECT st.value FROM st WHERE st.key = 'map_river_2_width')::double precision / 2
                                               WHEN 3 THEN (SELECT st.value FROM st WHERE st.key = 'map_river_3_width')::double precision / 2 END) w
        WHERE fld.k > 3 AND NOT (fld.x::bigint * 100000000 + fld.y) = ANY (w.a))
SELECT DISTINCT ON (al.x, al.y, al.k) al.x, al.y, al.k, al.dist, al.px, al.py, al.inside
  FROM al
 ORDER BY al.x, al.y, al.k, al.dist;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_river_trace(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, k integer, seg double precision[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The rivers of a block of a grid as the Maps tab draws them (step 14c, Peter 2026-10-07: rivers wind at every zoom like
-- rivers, not straight runs, and never cross each other). Worked out when asked and never stored.
-- rpg_map_rivers reads a river's line in each cell from the field at the cell's middle and its slope: the swings a grid
-- can follow from cell to cell (layers at least two cells apart). Drawn that way, a coarse grid showed a river as one
-- point a cell joined up, straight runs. Here a river narrower than the grid's cells is traced closer: on
-- map_river_trace_subs (4) points a cell each way, in the cells within map_river_trace_near (1.5) cells of where
-- rpg_map_rivers puts it, with the same rolls and every swing at least two of those points apart (layers down to half a
-- cell). Its bends now show inside a cell; the next grid down adds only bends smaller than half of this grid's cell, so
-- the line keeps its course as you zoom (within about a quarter of a cell of where the rules read it). The rule that
-- rivers never cross holds here too: each size is read at the level of its side of every bigger river's traced line
-- (rpg_map_river_sides), and only squares of four points on one side of every bigger river carry a line, so a smaller
-- river stops at the bigger one's bank and two lines never cross.
-- Rows: one short piece of a traced line, seg = [x1, y1, x2, y2] in cells of this grid from the world's west and north
-- edges; x, y = the cell its middle lies in; k = its size. Pieces meet end to end (the same side of two squares of
-- points gives the same point). A river as wide as the grid's cells is water there and is not traced.
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     tc AS MATERIALIZED (
       -- the trace: points a cell each way, squares from one to the next, how near, the side step
       SELECT q.m, (lad.cell / q.m)::integer AS s,
              (SELECT st.value FROM st WHERE st.key = 'map_river_trace_near')::double precision AS near,
              (SELECT st.value FROM st WHERE st.key = 'map_river_side_step')::double precision AS step
         FROM lad CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_trace_subs')::integer AS m) q),
     cls AS MATERIALIZED (
       -- each size of river this grid shows: its grid's cell, the smallest gap of its wandering layers as rpg_map_rivers
       -- reads it (lo) and as traced (lo2: a river drawn as a line on this grid, where a cell splits into whole squares)
       SELECT q.k, kl.cell::double precision AS kcell, greatest(w.width * w.wave / 4, 2 * lad.cell) AS lo,
              w.width < lad.cell AND tc.m > 1 AND mod(lad.cell::bigint, tc.m) = 0 AS traced,
              greatest(w.width * w.wave / 4, 2 * lad.cell / tc.m) AS lo2
         FROM generate_series(3, 5) AS q(k)
         JOIN public.rpg_map_ladder() kl ON kl.level = q.k
        CROSS JOIN lad CROSS JOIN tc
        CROSS JOIN LATERAL (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_width')::double precision AS width,
                                   (SELECT st.value FROM st WHERE st.key = 'map_river_meander_wave')::double precision AS wave) w
        WHERE q.k <= p_level),
     -- the share of each scale a river swings: the swing of the smallest bend over its wave (as rpg_map_rivers)
     shr AS (SELECT (SELECT st.value FROM st WHERE st.key = 'map_river_meander_amp')::double precision
                    / (SELECT st.value FROM st WHERE st.key = 'map_river_meander_wave')::double precision AS share),
     -- where the older rivers run (rpg_map_river_field), on the block and one cell round it (step 14f2: only its streams
     -- and brooks are drawn; its rivers are read for the sides of them)
     r1 AS MATERIALIZED (SELECT r.* FROM public.rpg_map_river_field(p_level, p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) r),
     -- the cells near a traced river
     nr AS MATERIALIZED (
       SELECT DISTINCT r1.x, r1.y FROM r1 CROSS JOIN lad CROSS JOIN tc
         JOIN cls c ON c.k = r1.k AND c.traced
        WHERE r1.dist < tc.near * lad.cell AND r1.k > 3),
     dn AS MATERIALIZED (
       -- the trace points those cells need: their own and two rings round them (for the squares on their edges and
       -- the slope at those squares' corners)
       SELECT DISTINCT nr.x * tc.m + a.a AS x, nr.y * tc.m + b.b AS y
         FROM nr CROSS JOIN tc CROSS JOIN generate_series(-2, tc.m + 1) AS a(a) CROSS JOIN generate_series(-2, tc.m + 1) AS b(b)),
     bx AS MATERIALIZED (
       -- the box of trace points that holds them, and which of its points are asked for
       SELECT min(dn.x) AS x0, min(dn.y) AS y0, max(dn.x) - min(dn.x) + 1 AS cols, max(dn.y) - min(dn.y) + 1 AS rows
         FROM dn HAVING count(*) > 0),
     at AS (SELECT array_agg((dn.y - bx.y0) * bx.cols + dn.x - bx.x0) AS at FROM dn CROSS JOIN bx),
     wl2 AS MATERIALIZED (
       -- the wandering layers the trace reads (down to lo2), numbered after the line's own rolls
       SELECT y.n, y.gap::double precision AS gap, (SELECT count(*) FROM cls) + row_number() OVER (ORDER BY y.n)::integer AS i
         FROM public.rpg_map_layers() y
        WHERE EXISTS (SELECT 1 FROM cls c WHERE y.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND y.gap < c.kcell)),
     rd AS (
       -- one reading for each size's line (part 7, its grid's three layers) and one for each wandering layer
       SELECT array_agg(q.part ORDER BY q.i) AS parts, array_agg(q.frst ORDER BY q.i) AS firsts, array_agg(q.fine ORDER BY q.i) AS fines
         FROM (SELECT row_number() OVER (ORDER BY c.k)::integer AS i, 7 AS part, 3 * c.k - 2 AS frst, c.kcell::integer AS fine FROM cls c
               UNION ALL SELECT wl2.i, 9, wl2.n, wl2.gap::integer FROM wl2) q),
     tr AS MATERIALIZED (
       SELECT r.x, r.y, r.vals
         FROM bx CROSS JOIN at CROSS JOIN rd CROSS JOIN tc
        CROSS JOIN LATERAL public.rpg_map_rolls_set(rd.parts, rd.firsts, rd.fines, least(p_level + 1, 7), tc.s, bx.x0, bx.y0, bx.cols, bx.rows, at.at) r
        WHERE EXISTS (SELECT 1 FROM nr)),
     -- each size's place among the line rolls of the readings
     ci AS (SELECT c2.k, row_number() OVER (ORDER BY c2.k)::integer AS i FROM cls c2),
     cw AS MATERIALIZED (
       -- each size's line roll among the readings, and what each wandering layer pushes it per roll (0 when it does not
       -- wander by that layer), by size: 2 great rivers ... 5 brooks
       SELECT (SELECT ci.i FROM ci WHERE ci.k = 2) AS v2, (SELECT ci.i FROM ci WHERE ci.k = 3) AS v3,
              (SELECT ci.i FROM ci WHERE ci.k = 4) AS v4, (SELECT ci.i FROM ci WHERE ci.k = 5) AS v5,
              coalesce(array_agg(wl2.i ORDER BY wl2.i), '{}'::integer[]) AS wi,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 2 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c2,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 3 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c3,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 4 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c4,
              coalesce(array_agg(wl2.gap * shr.share / sqrt(9999 / 12.0 * (26 / 35.0) * (26 / 35.0))
                                 * (SELECT count(*) FROM cls c WHERE c.k = 5 AND wl2.gap >= CASE WHEN c.traced THEN c.lo2 ELSE c.lo END AND wl2.gap < c.kcell) ORDER BY wl2.i), '{}') AS c5
         FROM wl2 CROSS JOIN shr),
     tf AS MATERIALIZED (
       -- each size's line roll and its swing (squares) at each trace point, one row a point
       SELECT tr.x, tr.y, tr.vals[cw.v2] AS b2, tr.vals[cw.v3] AS b3, tr.vals[cw.v4] AS b4, tr.vals[cw.v5] AS b5, sw.s
         FROM tr CROSS JOIN cw
        CROSS JOIN LATERAL (SELECT ARRAY[coalesce(sum(tr.vals[u.i] * u.c2), 0), coalesce(sum(tr.vals[u.i] * u.c3), 0),
                                         coalesce(sum(tr.vals[u.i] * u.c4), 0), coalesce(sum(tr.vals[u.i] * u.c5), 0)] AS s
                              FROM unnest(cw.wi, cw.c2, cw.c3, cw.c4, cw.c5) AS u(i, c2, c3, c4, c5)) sw),
     tsh AS MATERIALIZED (
       -- the pushed field of each size at each trace point with both neighbours each way (slope per square: points tc.s
       -- squares apart), less its level by the sides of the bigger rivers' own traced lines (rpg_map_river_sides)
       SELECT p.x, p.y, p.p2 - l.l2 AS q2, p.p3 - l.l3 AS q3, p.p4 - l.l4 AS q4, p.p5 - l.l5 AS q5, l.s3, l.s4, l.s5
         FROM (SELECT a.x, a.y,
                      1::double precision AS p2,
                      a.b3 + sqrt(power((e.b3 - w.b3) / 2, 2) + power((s.b3 - n.b3) / 2, 2)) / tc.s * a.s[2] AS p3,
                      a.b4 + sqrt(power((e.b4 - w.b4) / 2, 2) + power((s.b4 - n.b4) / 2, 2)) / tc.s * a.s[3] AS p4,
                      a.b5 + sqrt(power((e.b5 - w.b5) / 2, 2) + power((s.b5 - n.b5) / 2, 2)) / tc.s * a.s[4] AS p5
                 FROM tf a CROSS JOIN tc
                 JOIN tf e ON e.x = a.x + 1 AND e.y = a.y
                 JOIN tf w ON w.x = a.x - 1 AND w.y = a.y
                 JOIN tf s ON s.x = a.x AND s.y = a.y + 1
                 JOIN tf n ON n.x = a.x AND n.y = a.y - 1) p
        CROSS JOIN tc
        CROSS JOIN LATERAL public.rpg_map_river_sides(p.p2, p.p3, p.p4, tc.step) l),
     sq AS (
       -- every square of four trace points, for each traced size whose line passes it and whose four corners lie on one
       -- side of every bigger river; its corners a (north-west), b, c, d
       SELECT u.k, a.x, a.y, u.qa, u.qb, u.qc, u.qd
         FROM tsh a
         JOIN tsh b ON b.x = a.x + 1 AND b.y = a.y
         JOIN tsh c ON c.x = a.x + 1 AND c.y = a.y + 1
         JOIN tsh d ON d.x = a.x AND d.y = a.y + 1
        CROSS JOIN LATERAL (VALUES (2, a.q2, b.q2, c.q2, d.q2, true),
                                   (3, a.q3, b.q3, c.q3, d.q3, a.s3 = b.s3 AND a.s3 = c.s3 AND a.s3 = d.s3),
                                   (4, a.q4, b.q4, c.q4, d.q4, a.s4 = b.s4 AND a.s4 = c.s4 AND a.s4 = d.s4),
                                   (5, a.q5, b.q5, c.q5, d.q5, a.s5 = b.s5 AND a.s5 = c.s5 AND a.s5 = d.s5)) AS u(k, qa, qb, qc, qd, one)
         JOIN cls cc ON cc.k = u.k AND cc.traced
        WHERE u.one AND NOT ((u.qa > 0) = (u.qb > 0) AND (u.qa > 0) = (u.qc > 0) AND (u.qa > 0) = (u.qd > 0))),
     ed AS (
       -- where the line crosses each side of the square, in trace points from the world's edges (top, right, bottom,
       -- left); the same side of two squares gives the same point
       SELECT sq.k, sq.x, sq.y, sq.qa, sq.qc,
              CASE WHEN (sq.qa > 0) <> (sq.qb > 0) THEN ARRAY[sq.x + 0.5 + sq.qa / (sq.qa - sq.qb), sq.y + 0.5] END AS et,
              CASE WHEN (sq.qb > 0) <> (sq.qc > 0) THEN ARRAY[sq.x + 1.5, sq.y + 0.5 + sq.qb / (sq.qb - sq.qc)] END AS er,
              CASE WHEN (sq.qd > 0) <> (sq.qc > 0) THEN ARRAY[sq.x + 0.5 + sq.qd / (sq.qd - sq.qc), sq.y + 1.5] END AS eb,
              CASE WHEN (sq.qa > 0) <> (sq.qd > 0) THEN ARRAY[sq.x + 0.5, sq.y + 0.5 + sq.qa / (sq.qa - sq.qd)] END AS el,
              (sq.qa + sq.qb + sq.qc + sq.qd) / 4 AS mid
         FROM sq),
     pc AS MATERIALIZED (
       -- the pieces of line in each square (two where the line passes it twice: split by the middle of the square)
       SELECT ed.k, p.a[1] / tc.m AS x1, p.a[2] / tc.m AS y1, p.b[1] / tc.m AS x2, p.b[2] / tc.m AS y2
         FROM ed CROSS JOIN tc
        CROSS JOIN LATERAL (
          SELECT q.a, q.b FROM (VALUES
            (1, CASE WHEN ed.el IS NULL OR ed.er IS NULL OR ed.et IS NULL OR ed.eb IS NULL THEN coalesce(ed.et, ed.er, ed.eb) END,
                CASE WHEN ed.el IS NULL OR ed.er IS NULL OR ed.et IS NULL OR ed.eb IS NULL THEN coalesce(ed.el, ed.eb, ed.er) END),
            (2, CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN ed.et END,
                CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN CASE WHEN (ed.mid > 0) = (ed.qa > 0) THEN ed.er ELSE ed.el END END),
            (3, CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN ed.eb END,
                CASE WHEN ed.el IS NOT NULL AND ed.er IS NOT NULL AND ed.et IS NOT NULL AND ed.eb IS NOT NULL THEN CASE WHEN (ed.mid > 0) = (ed.qa > 0) THEN ed.el ELSE ed.er END END)
          ) AS q(o, a, b) WHERE q.a IS NOT NULL AND q.b IS NOT NULL AND q.a <> q.b) p),
     ps AS MATERIALIZED (
       SELECT pc.k, floor((pc.x1 + pc.x2) / 2)::integer AS x, floor((pc.y1 + pc.y2) / 2)::integer AS y, pc.x1, pc.y1, pc.x2, pc.y2 FROM pc),
     -- the downhill rivers (step 14f1): their winding line (rpg_map_river_line) read with p_sub points a cell, one piece
     -- from each point to the next, for the sizes narrower than the grid's cells
     dl AS MATERIALIZED (
       SELECT r.pid, r.k, r.x / lad.cell AS x1, r.y / lad.cell AS y1, lead(r.x) OVER w / lad.cell AS x2, lead(r.y) OVER w / lad.cell AS y2,
              (SELECT st.value FROM st WHERE st.key = 'map_river_' || r.k || '_width')::double precision AS width
         FROM lad CROSS JOIN tc
        CROSS JOIN LATERAL public.rpg_map_river_line(p_level, tc.m, p_x0 * lad.cell, p_y0 * lad.cell, (p_x0 + p_cols) * lad.cell, (p_y0 + p_rows) * lad.cell, lad.cell) r
       WINDOW w AS (PARTITION BY r.pid ORDER BY r.t)),
     dp AS MATERIALIZED (
       SELECT dl.k, floor((dl.x1 + dl.x2) / 2)::integer AS x, floor((dl.y1 + dl.y2) / 2)::integer AS y, dl.x1, dl.y1, dl.x2, dl.y2,
              greatest(dl.width / 2 / lad.cell, 0.5 / tc.m) AS band
         FROM dl CROSS JOIN lad CROSS JOIN tc
        WHERE dl.x2 IS NOT NULL AND dl.width < lad.cell)
SELECT ps.x, ps.y, ps.k, ARRAY[ps.x1, ps.y1, ps.x2, ps.y2]
  FROM ps
 WHERE ps.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND ps.y BETWEEN p_y0 AND p_y0 + p_rows - 1
   -- (step 14f2) the older rivers are gone: every river is a downhill one now; streams and brooks are still the older ones
   AND ps.k > 3
   -- an older smaller river stops at the bank of a downhill one (it does not cross it)
   AND NOT EXISTS (SELECT 1 FROM dp
                    WHERE dp.k <= ps.k
                      AND least(ps.x1, ps.x2) <= greatest(dp.x1, dp.x2) + dp.band AND greatest(ps.x1, ps.x2) >= least(dp.x1, dp.x2) - dp.band
                      AND least(ps.y1, ps.y2) <= greatest(dp.y1, dp.y2) + dp.band AND greatest(ps.y1, ps.y2) >= least(dp.y1, dp.y2) - dp.band
                      AND public.rpg_seg_gap(ps.x1, ps.y1, ps.x2, ps.y2, dp.x1, dp.y1, dp.x2, dp.y2) < dp.band)
UNION ALL
SELECT dp.x, dp.y, dp.k, ARRAY[dp.x1, dp.y1, dp.x2, dp.y2]
  FROM dp
 WHERE dp.x BETWEEN p_x0 AND p_x0 + p_cols - 1 AND dp.y BETWEEN p_y0 AND p_y0 + p_rows - 1;
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
         SELECT c.x, c.y, c.kind, c.place_id, c.marks, c.penalty, c.hard, rv.line, rv.px, rv.py, bl.value AS blend, st.steep,
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

  -- (step 14f2) the rivers inside the Continent cells this read worked out (rpg_map_drain_cell, kept for the
  -- transaction in rpg.dcell) are saved on the saved map's Continent grid rows (notes: rivers, by cell), so the next
  -- read finds them there instead of working them out again
  v_dcell := nullif(current_setting('rpg.dcell', true), '')::jsonb;
  IF v_dcell IS NOT NULL AND v_dcell <> '{}'::jsonb THEN
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('rivers', coalesce(m.notes -> 'rivers', '{}'::jsonb) || n.add)
      FROM (SELECT split_part(e.k, ',', 1)::integer / 12 AS gx, split_part(e.k, ',', 2)::integer / 12 AS gy, jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_dcell) AS e(k, v) GROUP BY 1, 2) n
     WHERE m.level = 2 AND m.gx = n.gx AND m.gy = n.gy
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

REVOKE ALL ON FUNCTION public.rpg_map_drain_cells() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_drain_cells() TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_drain_cell(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_drain_cell(integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_river_swing(double precision, integer, double precision[], double precision[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_river_swing(double precision, integer, double precision[], double precision[]) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_river_bends(integer, double precision, double precision, double precision, double precision, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_river_bends(integer, double precision, double precision, double precision, double precision, boolean) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_river_line(integer, integer, double precision, double precision, double precision, double precision, double precision, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_river_line(integer, integer, double precision, double precision, double precision, double precision, double precision, boolean) TO service_role;

-- no function still calls the old forms of the three replaced above
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.prosrc ~ 'rpg_map_river_bends\(\)') THEN
    RAISE EXCEPTION 'a function still calls rpg_map_river_bends()';
  END IF;
END $g$;

-- the world map rule card: one passage added after the great lakes, in place
UPDATE public.rpg_rules
   SET body = replace(body, $a$*A great lake filling a mountain hollow 170 miles across is up to 150 m deep; the river out of it leaves at the low point of its rim and runs on to the sea.*$a$,
                      $a$*A great lake filling a mountain hollow 170 miles across is up to 150 m deep; the river out of it leaves at the low point of its rim and runs on to the sea.* Rivers run downhill too: inside each Continent cell the water of every Country cell (about 23 km across) runs down to the sea, a great river, or the low crossing where the cell's water goes on to the next cell, and a river flows wherever the water of 20 Country cells, about 11,000 square kilometres, has gathered; smaller rivers join bigger ones like the branches of a tree. *20 Country cells of 538 square kilometres each is about 10,800 square kilometres, a square about 104 km a side: the land one river 60 m wide drains.*$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('Rivers run downhill too' in body) = 0;

SELECT public.rpg_map_cache_clear();
NOTIFY pgrst, 'reload schema';

