-- Roleplaying world map step 14f4, lakes in hollows (Peter 2026-10-07 18:21: rivers start on high ground, run downhill and
-- end in the sea, a lake or a bigger river). The big lakes, lakes and ponds were blobs where a field of rolls rose high
-- (part 8), with no tie to the land, so a river could run past or through one. Now they sit in the hollows the downhill
-- routing finds inside each cell of the grid above (rpg_map_drain_cell, Country, Region and City grids): cells the
-- flood filled above their own ground, joined, off the cell's edge, at least map_lake_<grid>_hollow deep, each filled
-- to the height its water spills over at. The hollow depths keep the land under them as before, about 1.5, 1.2 and 1
-- in 100 (3.7 in all, Verpoorter et al. 2014). A river or stream ends where it reaches a lake and the one leaving it
-- starts at its shore. rpg_map_flow lays the water of every lake, great to pond, by one rule (the great lakes' shore
-- rule, step 14f1); the part 8 field is no longer read.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'map_lake_3_hollow', 0.6, 'Big lakes (step 14f4): how deep a hollow of the Country grid must be, in the height of the land, to hold one (about 1.5 in 100 of the land)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_lake_4_hollow', 0.12, 'Lakes (step 14f4): how deep a hollow of the Region grid must be, in the height of the land, to hold one (about 1.2 in 100 of the land)'),
 ('126794dd-25ff-47d2-a436-724499733365', 'map_lake_5_hollow', 0.04, 'Ponds (step 14f4): how deep a hollow of the City grid must be, in the height of the land, to hold one (about 1 in 100 of the land)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_drain_cell(p_level integer, p_cx integer, p_cy integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The rivers of grid p_level inside one cell (p_cx, p_cy) of the grid above it (step 14f2, Peter 2026-10-07 18:21:
-- rivers start on high ground, run downhill and end in the sea, a lake or a bigger river): p_level 3, the rivers inside
-- a Continent cell; 4, the streams inside a Country cell; 5, the brooks inside a Region cell (step 14f3). The great
-- rivers and the rivers out of the great lakes come from the whole Continent grid (rpg_map_drainage); every finer size
-- is found the same way (O'Callaghan & Mark 1984 flow to one of eight neighbours; priority flood, Barnes, Lehman & Mulla
-- 2014) inside one cell of the grid above, on the heights of its 12 x 12 cells (rpg_map_heights), so nothing spans the
-- world and every grid agrees with the one above it (rpg_map_drain_parent tells where the water of a cell above goes):
--  * the water of the cell leaves where the grid above says it goes: by the lowest crossing of the edge it shares with
--    that cell (the lowest pair of cells either side of it), or by the corner toward a cell corner to corner. The cell
--    beside it finds the same crossing, so a river leaves one cell exactly where it enters the next;
--  * the water of each cell that drains into this one comes in at that crossing: all it gathered on the grid above
--    (x 144 cells of this grid a cell above);
--  * inside, every cell drains toward the way out, the sea, or a bigger river or great lake already running through the
--    cell (its cells are where that river's line lies as this grid draws it), lowest pass first;
--  * a river of this size runs where enough cells' water has gathered: a river 20 Country cells (map_drain_river, about
--    11,000 square kilometres), a stream 82 Region cells (map_drain_stream, about 300), a brook 470 City cells
--    (map_drain_brook, about 12): a river's width grows with the square root of the water it carries (Leopold & Maddock
--    1953), so a river 60 m wide drains 1 / 44 of what a great river 400 m wide does, a stream 10 m wide 1 / 36 of a
--    river's, a brook 2 m wide 1 / 25 of a stream's. The way out of the cell is one exactly when the water the grid
--    above gives the cell is enough, so the two cells always agree.
-- Returns {p: its bends, as rpg_map_drainage pieces, in cells of this grid from the world's west and north edges:
-- [id, ax, ay, cx, cy, bx, by, k_start, k_end, start, joins, jt], k = p_level; id = 1,000,000 (rivers), 20,000,000
-- (streams) or 2,000,000,000 (brooks) + the cell above's number x 1,000 + n; joins = the bend it ends on, jt = where
-- along that bend (0 to 1); c: each of its 144 cells [kind, sx, sy, acc, wt] as rpg_map_drain_parent reads them}. Kept
-- for the rest of the transaction (rpg.dc_<p_level>_<p_cx>_<p_cy>, one setting each so a read parses only its own;
-- the ones worked out listed in rpg.dc_new); a read of the map saves those on the saved map's
-- row of the grid above (rpg_map_view_block; notes: rivers), where later reads find it.
DECLARE
  v_w integer; v_h integer; v_sub integer; v_t double precision; v_wt double precision;
  v_memo jsonb; v_key text := p_level || ':' || p_cx || ',' || p_cy; v_cell double precision; v_base bigint; v_k integer; v_kind integer; v_px integer; v_py integer; v_acc double precision;
  v_cw integer; pk integer; psx integer; psy integer; pacc double precision; pwt double precision; v_c jsonb := '[]';
  nb_k integer[]; nb_sx integer[]; nb_sy integer[]; nb_acc double precision[]; v_cached boolean;
  v_ci bigint; v_x0 integer; v_y0 integer; v_est double precision;
  hh double precision[]; land boolean[]; wt double precision[]; outl boolean[]; sea boolean[];
  chn boolean[]; cd double precision[];
  w_id bigint[]; w_ax double precision[]; w_ay double precision[]; w_cx double precision[]; w_cy double precision[]; w_bx double precision[]; w_by double precision[];
  lpb bigint[] := '{}'; lpt double precision[] := '{}'; lpx double precision[] := '{}'; lpy double precision[] := '{}'; jb bigint; jt double precision; jx double precision; jy double precision; pb bigint;
  inflow double precision[]; vin boolean[]; vinx integer[]; viny integer[]; vinf double precision[]; dn integer[]; done boolean[]; ord integer[] := '{}'; acc double precision[];
  isriv boolean[]; up integer[]; bid bigint[];
  hk double precision[] := '{}'; hc integer[] := '{}'; hd integer[] := '{}'; hn integer := 0;
  bz jsonb := '[]';
  v_exit integer := 0; v_exx integer := 0; v_exy integer := 0;
  i integer; j integer; c integer; d integer; e integer; p integer; nb integer; dx integer; dy integer; x integer; y integer;
  f double precision; t double precision; ax double precision; ay double precision; qx double precision; qy double precision;
  kx double precision; ky double precision; mx double precision; my double precision; q double precision;
  r integer; best integer; bsum double precision; sx integer; sy integer;
  v_pieces jsonb := '[]'; v_n integer := 0;
  v_eps constant double precision := 1e-6;
  fl double precision[]; lake boolean[]; lk integer[]; st integer[]; grp integer[]; ng integer := 0; v_hollow double precision;
  v_lakes jsonb := '[]'; edge boolean;
BEGIN
  v_memo := nullif(current_setting('rpg.dc_' || p_level || '_' || p_cx || '_' || p_cy, true), '')::jsonb;
  IF v_memo IS NOT NULL THEN RETURN v_memo; END IF;
  -- saved on the saved map's row of the grid above by an earlier read of the map (rpg_map_view_block)
  SELECT m.notes -> 'rivers' -> v_key INTO v_pieces FROM public.rpg_map_cache m
   WHERE m.level = p_level - 1 AND m.gx = floor(p_cx / 12.0)::integer AND m.gy = floor(p_cy / 12.0)::integer;
  IF v_pieces IS NOT NULL THEN
    PERFORM set_config('rpg.dc_' || p_level || '_' || p_cx || '_' || p_cy, v_pieces::text, true);
    RETURN v_pieces;
  END IF;
  v_pieces := '[]';
  SELECT max(l.across) FILTER (WHERE l.level = p_level - 1), max(l.down) FILTER (WHERE l.level = p_level - 1),
         max(l.cols) FILTER (WHERE l.level = p_level), max(l.cell) FILTER (WHERE l.level = p_level), max(l.across) FILTER (WHERE l.level = p_level)
    INTO v_w, v_h, v_sub, v_cell, v_cw FROM public.rpg_map_ladder() l;
  SELECT max(s.value) FILTER (WHERE s.key = CASE p_level WHEN 3 THEN 'map_drain_river' WHEN 4 THEN 'map_drain_stream' ELSE 'map_drain_brook' END),
         max(s.value) FILTER (WHERE s.key = 'map_lake_' || p_level || '_hollow')
    INTO v_t, v_hollow FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365';
  v_k := p_level;
  v_base := CASE p_level WHEN 3 THEN 1000000 WHEN 4 THEN 20000000 ELSE 2000000000 END;
  -- the cell and the eight round it on the grid above, numbered (dy + 1) * 3 + dx + 2
  SELECT array_agg(q.kind ORDER BY q.dy, q.dx), array_agg(q.sx ORDER BY q.dy, q.dx), array_agg(q.sy ORDER BY q.dy, q.dx), array_agg(q.acc ORDER BY q.dy, q.dx)
    INTO nb_k, nb_sx, nb_sy, nb_acc FROM public.rpg_map_drain_parent(p_level, p_cx, p_cy) q;
  SELECT q.kind, q.sx, q.sy, q.acc, q.wt INTO v_kind, v_px, v_py, v_acc, v_wt FROM public.rpg_map_drain_parent(p_level, p_cx, p_cy) q WHERE q.dx = 0 AND q.dy = 0;
  -- the sea, and the great lakes, hold no rivers of their own
  IF p_cy < 0 OR p_cy >= v_h OR p_cx < 0 OR p_cx >= v_w OR v_kind = 1 THEN
    PERFORM set_config('rpg.dc_' || p_level || '_' || p_cx || '_' || p_cy, jsonb_build_object('p', '[]'::jsonb)::text, true);
    PERFORM set_config('rpg.dc_new', concat_ws(' ', nullif(current_setting('rpg.dc_new', true), ''), v_key), true);
    RETURN jsonb_build_object('p', '[]'::jsonb);
  END IF;
  v_ci := p_cy::bigint * v_w + p_cx;
  v_x0 := p_cx * v_sub; v_y0 := p_cy * v_sub;
  v_est := v_acc * v_sub * v_sub;

  -- the block: this cell's Country cells and one ring round them, numbered (j + 1) * (v_sub + 2) + (i + 1) + 1 for
  -- i, j from -1 to v_sub
  hh := array_fill(0::double precision, ARRAY[(v_sub + 2) * (v_sub + 2)]);
  FOR x, y, f IN SELECT r0.x, r0.y, r0.height FROM public.rpg_map_heights(p_level, v_x0 - 1, v_y0 - 1, v_sub + 2, v_sub + 2) r0 LOOP
    hh[(y - v_y0 + 1) * (v_sub + 2) + (x - v_x0 + 1) + 1] := f;
  END LOOP;
  -- the cell's own cells, numbered j * v_sub + i + 1: the sea where this grid shows it (rpg_map_ground_of, so a river
  -- ends where the map draws the coast), the land sending on the water the cell above does (a desert little)
  land := array_fill(false, ARRAY[v_sub * v_sub]); sea := array_fill(true, ARRAY[v_sub * v_sub]);
  wt := array_fill(0::double precision, ARRAY[v_sub * v_sub]);
  -- (the block is one grid of this grid's size: its ground is read from the saved map where that grid is saved, the
  -- same sea as rpg_map_ground_of gives, without working the ground out again)
  v_cached := EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = p_level AND m.gx = p_cx AND m.gy = p_cy);
  FOR x, y, kx IN SELECT g.x, g.y, CASE g.kind WHEN 'sea' THEN -1 ELSE 1 END FROM public.rpg_map_cells(p_level, v_x0, v_y0, v_sub, v_sub) g WHERE v_cached
                  UNION ALL
                  SELECT g.x, g.y, CASE g.kind WHEN 'sea' THEN -1 ELSE 1 END FROM public.rpg_map_ground_of(p_level, v_x0, v_y0, v_sub, v_sub) g WHERE NOT v_cached LOOP
    c := (y - v_y0) * v_sub + (x - v_x0) + 1;
    land[c] := kx >= 0; sea[c] := kx < 0; wt[c] := CASE WHEN kx >= 0 THEN v_wt ELSE 0 END;
  END LOOP;

  -- the bigger rivers through or past the cell, where this grid draws them (rpg_map_river_line of the rivers found on the
  -- grids above alone, winding as they do here, its points an eighth of a cell apart, as the Maps tab draws it), in cells of this grid from this
  -- cell's corner; a cell whose middle lies within 0.71 of a point is that river's water (its line passes through it):
  -- rivers here end there, at the point of that river's bend nearest it. Their bends before they wind, for where a
  -- river here ends on one (rpg_map_river_bends)
  chn := array_fill(false, ARRAY[v_sub * v_sub]); cd := array_fill('Infinity'::double precision, ARRAY[v_sub * v_sub]);
  SELECT array_agg(r.pid % 1000000000000), array_agg(r.t), array_agg(r.x / v_cell - v_x0), array_agg(r.y / v_cell - v_y0)
    INTO lpb, lpt, lpx, lpy
    FROM public.rpg_map_river_line(p_level, 4, (v_x0 - 1) * v_cell, (v_y0 - 1) * v_cell, (v_x0 + v_sub + 1) * v_cell, (v_y0 + v_sub + 1) * v_cell, 0, p_level - 1) r;
  lpb := coalesce(lpb, '{}'); lpt := coalesce(lpt, '{}'); lpx := coalesce(lpx, '{}'); lpy := coalesce(lpy, '{}');
  FOR r IN 1 .. cardinality(lpb) LOOP
    mx := lpx[r]; my := lpy[r];
    FOR i IN greatest(floor(mx - 1)::integer, 0) .. least(floor(mx + 1)::integer, v_sub - 1) LOOP
      FOR j IN greatest(floor(my - 1)::integer, 0) .. least(floor(my + 1)::integer, v_sub - 1) LOOP
        q := sqrt(power(i + 0.5 - mx, 2) + power(j + 0.5 - my, 2));
        c := j * v_sub + i + 1;
        IF q < 0.71 AND q < cd[c] THEN chn[c] := true; cd[c] := q; END IF;
      END LOOP;
    END LOOP;
  END LOOP;
  SELECT array_agg(b.id), array_agg(b.ax / v_cell), array_agg(b.ay / v_cell), array_agg(b.cx / v_cell), array_agg(b.cy / v_cell), array_agg(b.bx / v_cell), array_agg(b.by / v_cell)
    INTO w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by
    FROM public.rpg_map_river_bends(p_level, (v_x0 - 1) * v_cell, (v_y0 - 1) * v_cell, (v_x0 + v_sub + 1) * v_cell, (v_y0 + v_sub + 1) * v_cell, 0, p_level - 1) b
   WHERE b.id = ANY (lpb);

  -- the way out (a cell no bigger river runs through): toward the cell the grid above sends its water to
  IF v_kind = 0 AND (v_px <> 0 OR v_py <> 0) THEN
    sx := v_px; sy := v_py;
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
    pk := nb_k[(dy + 1) * 3 + dx + 2]; psx := nb_sx[(dy + 1) * 3 + dx + 2]; psy := nb_sy[(dy + 1) * 3 + dx + 2]; pacc := nb_acc[(dy + 1) * 3 + dx + 2];
    CONTINUE WHEN pk <> 0 OR psx <> -dx OR psy <> -dy;
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
    f := pacc * v_sub * v_sub;
    inflow[c] := inflow[c] + f;
    -- the river coming in (the biggest, where two come in at one corner cell), and the step back across the edge to it
    IF f >= v_t AND f > vinf[c] THEN vin[c] := true; vinf[c] := f; vinx[c] := dx; viny[c] := dy; END IF;
  END LOOP; END LOOP;

  -- where the water ends: the sea, a downhill river's line, the way out
  outl := array_fill(false, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP outl[c] := sea[c] OR chn[c] OR c = v_exit; END LOOP;
  dn := array_fill(0, ARRAY[v_sub * v_sub]); done := array_fill(false, ARRAY[v_sub * v_sub]);
  fl := array_fill(0::double precision, ARRAY[v_sub * v_sub]);
  -- the flood, from every place water ends, lowest first: each Country cell drains to the cell the flood reached it from
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT outl[c];
    done[c] := true; ord := ord || c;
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    fl[c] := hh[(y + 1) * (v_sub + 2) + (x + 1) + 1];
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
    done[c] := true; dn[c] := d; ord := ord || c; fl[c] := f;
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

  -- the lakes (step 14f4, Peter 2026-10-07: lakes sit in the hollows of the land): the cells the flood filled above their
  -- own ground, joined by their eight neighbours, at least map_lake_<grid>_hollow deep (the height of the land; a
  -- shallower one is a flat the water runs through, the way small sinks in real height data are, as the great lakes),
  -- that keep off the cell's edge (water that pools against the edge only does so because the cell is found alone; the
  -- grid above sends it on). Each fills to the height its water spills over at and drains on from its lowest rim cell.
  lk := array_fill(0, ARRAY[v_sub * v_sub]); lake := array_fill(false, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    CONTINUE WHEN NOT land[c] OR chn[c] OR lk[c] <> 0 OR fl[c] <= hh[(y + 1) * (v_sub + 2) + (x + 1) + 1] + 1e-3;
    ng := ng + 1; st := ARRAY[c]; grp := '{}'; lk[c] := ng; f := 0; edge := false;
    WHILE coalesce(array_length(st, 1), 0) > 0 LOOP
      p := st[array_length(st, 1)]; st := st[1:array_length(st, 1) - 1]; grp := grp || p;
      x := (p - 1) % v_sub; y := (p - 1) / v_sub;
      f := greatest(f, fl[p] - hh[(y + 1) * (v_sub + 2) + (x + 1) + 1]);
      IF x = 0 OR y = 0 OR x = v_sub - 1 OR y = v_sub - 1 THEN edge := true; END IF;
      FOR dy IN -1 .. 1 LOOP FOR dx IN -1 .. 1 LOOP
        CONTINUE WHEN (dx = 0 AND dy = 0) OR x + dx < 0 OR x + dx >= v_sub OR y + dy < 0 OR y + dy >= v_sub;
        nb := (y + dy) * v_sub + x + dx + 1;
        IF land[nb] AND NOT chn[nb] AND lk[nb] = 0 AND fl[nb] > hh[(y + dy + 1) * (v_sub + 2) + (x + dx + 1) + 1] + 1e-3 THEN
          lk[nb] := ng; st := st || nb;
        END IF;
      END LOOP; END LOOP;
    END LOOP;
    IF f >= v_hollow AND NOT edge THEN
      FOREACH p IN ARRAY grp LOOP lake[p] := true; END LOOP;
      v_lakes := v_lakes || jsonb_build_array((SELECT jsonb_build_array(max(fl[g])) || jsonb_agg(g - 1 ORDER BY g) FROM unnest(grp) AS g));
    END IF;
  END LOOP;

  -- the rivers: land where enough water has gathered, not in a lake; the way out exactly when the Continent grid gives
  -- the cell enough
  isriv := array_fill(false, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP
    isriv[c] := land[c] AND NOT chn[c] AND NOT lake[c] AND CASE WHEN c = v_exit THEN v_est >= v_t ELSE acc[c] >= v_t END;
  END LOOP;
  -- the main water into each river cell: the river upstream that brings the most, or the river coming in from the
  -- cell beside (-1)
  up := array_fill(0, ARRAY[v_sub * v_sub]);
  FOR c IN 1 .. v_sub * v_sub LOOP
    IF vin[c] THEN up[c] := -1; END IF;
  END LOOP;
  -- (a lake with enough water that drains on into a river cell is that river's main water too: the river leaves the lake
  -- at its shore)
  FOR c IN 1 .. v_sub * v_sub LOOP
    CONTINUE WHEN NOT isriv[c] AND NOT (lake[c] AND acc[c] >= v_t);
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
    v_n := v_n + 1; bid[c] := v_base + v_ci * 1000 + v_n;
    IF up[c] = 0 THEN
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(bid[c], x + 0.5, y + 0.5, (x + 0.5 + kx) / 2, (y + 0.5 + ky) / 2, kx, ky, v_k, v_k, 1, 0, 0));
    ELSE
      IF up[c] = -1 THEN
        sx := vinx[c]; sy := viny[c];
      ELSE
        sx := (up[c] - 1) % v_sub - x; sy := (up[c] - 1) / v_sub - y;
      END IF;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(bid[c], x + 0.5 + sx / 2.0, y + 0.5 + sy / 2.0, x + 0.5, y + 0.5, kx, ky, v_k, v_k, 0, 0, 0));
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
      SELECT power(1 - jt, 2) * z.ax + 2 * jt * (1 - jt) * z.cx + power(jt, 2) * z.bx, power(1 - jt, 2) * z.ay + 2 * jt * (1 - jt) * z.cy + power(jt, 2) * z.by
        INTO f, t
        FROM unnest(w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by) AS z(id, ax, ay, cx, cy, bx, by) WHERE z.id = jb LIMIT 1;
      -- that bend's point, in cells of this grid on this cell's side of the world's edge, from this cell's corner
      f := f - round((f - (v_x0 + x + 0.5)) / v_cw) * v_cw - v_x0; t := t - v_y0;
      -- the curve heads for the drawn point; its middle point is set back by half the winding the line adds by its end
      q := sqrt(power(jx - kx, 2) + power(jy - ky, 2)) / 2 / sqrt(dx * dx + dy * dy);
      v_n := v_n + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_base + v_ci * 1000 + v_n, kx, ky, kx + dx * q - (jx - f) / 2, ky + dy * q - (jy - t) / 2, f, t, v_k, v_k, 0, jb, jt));
    ELSIF NOT isriv[d] THEN
      v_n := v_n + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_base + v_ci * 1000 + v_n, kx, ky, x + 0.5 + dx * 0.75, y + 0.5 + dy * 0.75, x + 0.5 + dx, y + 0.5 + dy, v_k, v_k, 0, 0, 0));
    ELSIF up[d] <> c THEN
      -- the middle of the bend of d
      SELECT 0.25 * (z.e2 ->> 1)::double precision + 0.5 * (z.e2 ->> 3)::double precision + 0.25 * (z.e2 ->> 5)::double precision,
             0.25 * (z.e2 ->> 2)::double precision + 0.5 * (z.e2 ->> 4)::double precision + 0.25 * (z.e2 ->> 6)::double precision
        INTO f, t FROM (SELECT e0 AS e2 FROM jsonb_array_elements(v_pieces) AS e0 WHERE (e0 ->> 0)::bigint = bid[d]) z;
      q := sqrt(power(f - kx, 2) + power(t - ky, 2)) / 2 / sqrt(dx * dx + dy * dy);
      v_n := v_n + 1;
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_base + v_ci * 1000 + v_n, kx, ky, kx + dx * q, ky + dy * q, f, t, v_k, v_k, 0, bid[d], 0.5));
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
      SELECT power(1 - jt, 2) * z.ax + 2 * jt * (1 - jt) * z.cx + power(jt, 2) * z.bx, power(1 - jt, 2) * z.ay + 2 * jt * (1 - jt) * z.cy + power(jt, 2) * z.by
        INTO f, t
        FROM unnest(w_id, w_ax, w_ay, w_cx, w_cy, w_bx, w_by) AS z(id, ax, ay, cx, cy, bx, by) WHERE z.id = jb LIMIT 1;
      f := f - round((f - (v_x0 + x + 0.5)) / v_cw) * v_cw - v_x0; t := t - v_y0;
      q := sqrt(power(jx - kx, 2) + power(jy - ky, 2)) / 2 / sqrt(sx * sx + sy * sy);
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_base + v_ci * 1000 + v_n, kx, ky, kx - sx * q - (jx - f) / 2, ky - sy * q - (jy - t) / 2, f, t, v_k, v_k, 0, jb, jt));
    ELSE
      v_pieces := v_pieces || jsonb_build_array(jsonb_build_array(v_base + v_ci * 1000 + v_n, kx, ky, (kx + x + 0.5) / 2, (ky + y + 0.5) / 2, x + 0.5, y + 0.5, v_k, v_k, 0, 0, 0));
    END IF;
  END LOOP;
  -- each cell's own numbers, for the grid below (rpg_map_drain_parent)
  FOR c IN 1 .. v_sub * v_sub LOOP
    x := (c - 1) % v_sub; y := (c - 1) / v_sub;
    IF c = v_exit THEN sx := v_exx; sy := v_exy;
    ELSIF dn[c] > 0 THEN sx := (dn[c] - 1) % v_sub - x; sy := (dn[c] - 1) / v_sub - y;
    ELSE sx := 0; sy := 0; END IF;
    v_c := v_c || jsonb_build_array(jsonb_build_array(CASE WHEN sea[c] OR lake[c] THEN 1 WHEN chn[c] THEN 2 WHEN isriv[c] THEN 3 ELSE 0 END,
                                                      sx, sy, round(acc[c]::numeric, 3), wt[c]));
  END LOOP;
  -- in world cells of this grid
  SELECT coalesce(jsonb_agg(jsonb_build_array(e0 -> 0, (e0 ->> 1)::double precision + v_x0, (e0 ->> 2)::double precision + v_y0,
                                              (e0 ->> 3)::double precision + v_x0, (e0 ->> 4)::double precision + v_y0,
                                              (e0 ->> 5)::double precision + v_x0, (e0 ->> 6)::double precision + v_y0,
                                              e0 -> 7, e0 -> 8, e0 -> 9, e0 -> 10, e0 -> 11) ORDER BY n0), '[]'::jsonb)
    INTO v_pieces FROM jsonb_array_elements(v_pieces) WITH ORDINALITY AS z(e0, n0);
  v_pieces := jsonb_build_object('p', v_pieces, 'c', v_c, 'l', v_lakes);
  PERFORM set_config('rpg.dc_' || p_level || '_' || p_cx || '_' || p_cy, v_pieces::text, true);
  PERFORM set_config('rpg.dc_new', concat_ws(' ', nullif(current_setting('rpg.dc_new', true), ''), v_key), true);
  RETURN v_pieces;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_flow(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(x integer, y integer, depth double precision, line integer, current double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Rivers and lakes on any block of any grid, worked out when asked and never stored: the one home of where water lies
-- on land and how it flows (Peter 2026-10-03 17:28: rivers and lakes; step 7b: swimming). rpg_map_water reads it for
-- depth and line, rpg_map_swim for the pull a swimmer meets.
-- Rivers run where rpg_map_rivers says, with their bends: great rivers 400 m wide (Continent), rivers 60 m (Country),
-- streams 10 m (Region), brooks 2 m (City), each map_river_<grid>_width squares wide and map_river_<grid>_depth deep in
-- the middle, shallower toward the banks (depth = middle x (1 - (2 x distance / width)^2)), and flowing
-- map_river_<grid>_current m/s in the middle, slower where it is shallower (speed = middle x (depth / middle depth)
-- ^ 2/3, Manning). Lakes sit in the hollows of the land (step 14f4): the great lakes in the deep hollows of the
-- Continent grid, the big lakes, lakes and ponds in the hollows rpg_map_drain_cell finds on the Country, Region and City
-- grids (map_lake_<grid>_hollow deep, so about 1.5, 1.2 and 1 in 100 of the land is under them, 3.7 in all, as on
-- Earth: Verpoorter et al. 2014), each filled to the height its water spills over at; their
-- bed drops map_lake_slope (1 in 20) from the shore, down to map_lake_<grid>_depth; their water is still
-- (map_still_current, 0.1 m/s of small waves). A grid shows only the water its own cells or coarser ones make: a brook
-- is not on the Region grid. depth = metres of water at the middle of the cell (the deepest of what lies there; 0 for
-- none). A river narrower than the grid's cell is a line on that grid and not water in the cell (step 10a, 2026-10-05:
-- before, a 60 m river crossing the middle of a 1.2-mile cell made the whole cell water, a chain of ponds along the
-- line once the line wandered); it fills cells only on grids whose cells it is at least as wide as (a great river
-- from the City grid down, a river and a stream on the District grid and the battle grid, a brook on the battle
-- grid). line = the biggest river whose line runs through the cell (2 a great river, 3 a river, 4 a stream, 5 a
-- brook; 0 none): a grid too coarse to hold a river as cells still knows it is there (rpg_map_walk looks closer at a
-- deep one). current = how fast the water there pulls, m/s (the fastest of what lies there; 0 on dry land).
-- A ford (step 11, Peter 2026-10-04: bridges and fords): on the battle grid, the squares of a river or a stream that
-- rpg_map_ford_cells names (a road that fords it, or a planned ford off the roads) are knee-deep, map_wade_ford_depth
-- (0.5 m) at most, however deep the river is beside them, so the walk wades there instead of swimming; the current
-- follows the shallower depth. A bridge changes no water: its squares are road ground (rpg_map_cells).
WITH st AS (SELECT s.key, s.value FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
     lad AS (SELECT l.cell::double precision AS cell FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     rk AS MATERIALIZED (
       SELECT q.k, (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_width')::double precision AS width,
              (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_depth')::double precision AS deep,
              (SELECT st.value FROM st WHERE st.key = 'map_river_' || q.k || '_current')::double precision AS flow
         FROM generate_series(2, 5) AS q(k)),
     rv0 AS MATERIALIZED (
       SELECT r.x, r.y, r.k,
              CASE WHEN r.dist < w.width / 2 AND w.width >= lad.cell THEN w.deep * (1 - power(2 * r.dist / w.width, 2)) ELSE 0 END AS depth,
              CASE WHEN r.inside THEN r.k END AS line, w.deep, w.flow
         FROM public.rpg_map_rivers(p_level, p_x0, p_y0, p_cols, p_rows) r CROSS JOIN lad
         -- (step 14e) each size's width, depth and current read once, not once a square (the same numbers, about five
         -- times faster on a block with a river)
         LEFT JOIN rk w ON w.k = r.k),
     -- the fords of the block (step 11): only the battle grid, only where it holds a river or a stream
     fd AS MATERIALIZED (
       SELECT f.x, f.y, f.k, (SELECT st.value FROM st WHERE st.key = 'map_wade_ford_depth')::double precision AS deep
         FROM public.rpg_map_ford_cells(p_level, p_x0, p_y0, p_cols, p_rows) f
        WHERE p_level = 7 AND EXISTS (SELECT 1 FROM rv0 WHERE rv0.k IN (3, 4) AND rv0.depth > 0)),
     rv AS (SELECT rv0.x, rv0.y, q.depth, rv0.line,
                   CASE WHEN q.depth > 0 THEN rv0.flow * power(q.depth / rv0.deep, 2.0 / 3) ELSE 0 END AS current
              FROM rv0
              LEFT JOIN fd ON fd.x = rv0.x AND fd.y = rv0.y AND fd.k = rv0.k
             CROSS JOIN LATERAL (SELECT CASE WHEN fd.x IS NOT NULL THEN least(rv0.depth, fd.deep) ELSE rv0.depth END AS depth) q),
     -- the lakes (steps 14f1 and 14f4): the great lakes, the deep hollows of the Continent grid (rpg_map_drainage), and
     -- the big lakes, lakes and ponds in the hollows found inside each cell of the Country, Region and City grids'
     -- cells above (rpg_map_drain_cell), each full to its rim and each shown from its own grid down. Water lies where
     -- the ground of this grid is below the lake's level, in the lake's own cells and in the near half of the cells of
     -- its rim (so the shore follows the land, not the edges of the lake's cells); the bed drops map_lake_slope from
     -- the shore, down to map_lake_<grid>_depth
     gc AS (SELECT l.level AS lv, l.cell::double precision AS cc, l.across AS cw, l.down AS ch,
                   (SELECT st.value FROM st WHERE st.key = 'map_lake_' || l.level || '_depth')::double precision AS deep
              FROM public.rpg_map_ladder() l WHERE l.level BETWEEN 2 AND least(p_level, 5)),
     -- the cells of the grid above each lake size's grid that lie under the block or one of that grid's cells round it
     gp AS (SELECT gc.lv, ((px.x % (gc.cw / 12)) + gc.cw / 12) % (gc.cw / 12) AS px, py.y AS py
              FROM gc CROSS JOIN lad
             CROSS JOIN LATERAL generate_series(floor((p_x0 * lad.cell - gc.cc) / (12 * gc.cc))::integer, floor(((p_x0 + p_cols) * lad.cell + gc.cc) / (12 * gc.cc))::integer) AS px(x)
             CROSS JOIN LATERAL generate_series(greatest(floor((p_y0 * lad.cell - gc.cc) / (12 * gc.cc))::integer, 0),
                                                least(floor(((p_y0 + p_rows) * lad.cell + gc.cc) / (12 * gc.cc))::integer, gc.ch / 12 - 1)) AS py(y)
             WHERE gc.lv >= 3),
     gk AS MATERIALIZED (
       SELECT 2 AS lv, (e.v ->> 0)::double precision AS lvl, (c.v ->> 0)::integer AS cx, (c.v ->> 1)::integer AS cy
         FROM jsonb_array_elements(public.rpg_map_drainage() -> 'lakes') WITH ORDINALITY AS e(v, n)
        CROSS JOIN LATERAL jsonb_array_elements(e.v) WITH ORDINALITY AS c(v, i)
        WHERE c.i > 1 AND p_level >= 2
       UNION ALL
       SELECT gp.lv, (e.v ->> 0)::double precision, gp.px * 12 + (c.v::text::integer % 12), gp.py * 12 + (c.v::text::integer / 12)
         FROM (SELECT DISTINCT gp.lv, gp.px, gp.py FROM gp) gp
        CROSS JOIN LATERAL jsonb_array_elements(public.rpg_map_drain_cell(gp.lv, gp.px, gp.py) -> 'l') AS e(v)
        CROSS JOIN LATERAL jsonb_array_elements(e.v) WITH ORDINALITY AS c(v, i)
        WHERE c.i > 1),
     gb AS MATERIALIZED (
       -- the block's cells that lie in a lake's cell or one beside it, with that cell and where in it the cell lies
       SELECT DISTINCT u.lv, b.x, b.y, q.cx, q.cy, q.fx, q.fy
         FROM lad
        CROSS JOIN LATERAL (SELECT DISTINCT gk.lv, gk.cx + ox.o AS ux, gk.cy + oy.o AS uy
                              FROM gk CROSS JOIN (VALUES (-1), (0), (1)) AS ox(o) CROSS JOIN (VALUES (-1), (0), (1)) AS oy(o)) u
         JOIN gc ON gc.lv = u.lv
        CROSS JOIN LATERAL (SELECT k.k FROM generate_series(floor((p_x0 * lad.cell - u.ux * gc.cc) / (gc.cw * gc.cc))::integer,
                                                              floor(((p_x0 + p_cols) * lad.cell - u.ux * gc.cc) / (gc.cw * gc.cc))::integer) AS k(k)) w
        CROSS JOIN LATERAL generate_series(greatest(p_x0, floor(((u.ux + w.k * gc.cw) * gc.cc) / lad.cell)::integer),
                                           least(p_x0 + p_cols - 1, ceil(((u.ux + w.k * gc.cw + 1) * gc.cc) / lad.cell)::integer - 1)) AS bx(x)
        CROSS JOIN LATERAL generate_series(greatest(p_y0, floor((u.uy * gc.cc) / lad.cell)::integer),
                                           least(p_y0 + p_rows - 1, ceil(((u.uy + 1) * gc.cc) / lad.cell)::integer - 1)) AS byy(y)
        CROSS JOIN LATERAL (SELECT bx.x, byy.y) b
        CROSS JOIN LATERAL (SELECT (mod(mod(floor((b.x + 0.5) * lad.cell / gc.cc)::bigint, gc.cw) + gc.cw, gc.cw))::integer AS cx,
                                   floor((b.y + 0.5) * lad.cell / gc.cc)::integer AS cy,
                                   (b.x + 0.5) * lad.cell / gc.cc - floor((b.x + 0.5) * lad.cell / gc.cc) AS fx,
                                   (b.y + 0.5) * lad.cell / gc.cc - floor((b.y + 0.5) * lad.cell / gc.cc) AS fy) q),
     gw AS MATERIALIZED (
       -- each such cell's lake of each size: its own cell's, else the lake of a rim cell it lies in the near half of
       SELECT DISTINCT ON (gb.lv, gb.x, gb.y) gb.lv, gb.x, gb.y, gk.lvl, gc.deep
         FROM gb JOIN gc ON gc.lv = gb.lv
         JOIN gk ON gk.lv = gb.lv AND abs(public.rpg_map_wrap_step(gk.cx - gb.cx, gc.cw)) <= 1 AND abs(gk.cy - gb.cy) <= 1
        CROSS JOIN LATERAL (SELECT public.rpg_map_wrap_step(gk.cx - gb.cx, gc.cw) AS dx, gk.cy - gb.cy AS dy) d
        WHERE (d.dx = 0 AND d.dy = 0)
           OR ((d.dx = 0 OR (d.dx = 1 AND gb.fx >= 0.5) OR (d.dx = -1 AND gb.fx < 0.5))
               AND (d.dy = 0 OR (d.dy = 1 AND gb.fy >= 0.5) OR (d.dy = -1 AND gb.fy < 0.5)))
        ORDER BY gb.lv, gb.x, gb.y, (d.dx = 0 AND d.dy = 0) DESC, gk.lvl DESC),
     gh AS MATERIALIZED (
       SELECT h.x, h.y, h.height FROM public.rpg_map_heights(p_level, p_x0 - 1, p_y0 - 1, p_cols + 2, p_rows + 2) h WHERE EXISTS (SELECT 1 FROM gw)),
     gl AS (
       SELECT gw.x, gw.y,
              least(gw.deep,
                    (gw.lvl - h.height) / greatest(sqrt(power((e.height - w.height) / 2, 2) + power((s.height - n.height) / 2, 2)), 1e-9) * lad.cell
                    * (SELECT st.value FROM st WHERE st.key = 'map_square_m')::double precision
                    * (SELECT st.value FROM st WHERE st.key = 'map_lake_slope')::double precision) AS depth
         FROM gw CROSS JOIN lad
         JOIN gh h ON h.x = gw.x AND h.y = gw.y
         JOIN gh e ON e.x = gw.x + 1 AND e.y = gw.y JOIN gh w ON w.x = gw.x - 1 AND w.y = gw.y
         JOIN gh s ON s.x = gw.x AND s.y = gw.y + 1 JOIN gh n ON n.x = gw.x AND n.y = gw.y - 1
        -- (the lake's own level less the 0.001 a hollow must be filled by to count as one, as rpg_map_drain_make: the
        -- cell its water spills over stands at the lake's level and is its shore)
        WHERE h.height < gw.lvl - 1e-3),
     dep AS (SELECT rv.x, rv.y, rv.depth, rv.line, rv.current FROM rv
             UNION ALL
             SELECT gl.x, gl.y, gl.depth, NULL::integer, (SELECT st.value FROM st WHERE st.key = 'map_still_current')::double precision FROM gl
)
SELECT b.x, b.y, coalesce(max(dep.depth), 0), coalesce(min(dep.line), 0), coalesce(max(dep.current), 0)
  FROM (SELECT gx AS x, gy AS y FROM generate_series(p_x0, p_x0 + p_cols - 1) gx CROSS JOIN generate_series(p_y0, p_y0 + p_rows - 1) gy) b
  LEFT JOIN dep ON dep.x = b.x AND dep.y = b.y
 GROUP BY b.x, b.y;
$function$;

-- the world map rule card: one passage added after the lakes' share, in place
UPDATE public.rpg_rules
   SET body = replace(body, $a$lakes and ponds cover about 4 in 100 of the land.$a$,
                      $a$lakes and ponds cover about 4 in 100 of the land. They sit in the hollows of the land, filled up to the lowest point of their rim, where the water runs on: big lakes in the hollows of the Country grid, lakes in those of the Region grid, ponds in those of the City grid, and a river that reaches one ends at its shore. *Of every 100 square miles of land about 1.5 lie under big lakes, 1.2 under lakes and 1 under ponds: 3.7 in all, as on Earth.*$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map' AND position('They sit in the hollows of the land' in body) = 0;

SELECT public.rpg_map_cache_clear();
NOTIFY pgrst, 'reload schema';

