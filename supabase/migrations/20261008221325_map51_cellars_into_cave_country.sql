-- Roleplaying world map, storeys part 3b: cellars into the world under the ground (Peter 2026-10-08, 1B: link some
-- cellars into the caves and tunnels). A cellar over a chamber of cave country breaks through into it on a roll
-- (map_house_cellar_way_share 0.1; rpg_map_cellar_link, the one home of it): a squeeze (join) from cellar:<x>-<y>, its
-- stair's first square, down to that chamber. rpg_map_cellar_way finds it for a piece down in a cellar; rpg_map_under_enter
-- takes the piece down through it, rpg_map_under_leave brings it back up into the cellar. rpg_map_under_node,
-- rpg_map_under_edges and rpg_map_under_near know the new node (from below the way up is listed once known, never found by
-- a search); rpg_map_under_squares gives it no room; rpg_map_view_block offers the crack and the way back up.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
 ('126794dd-25ff-47d2-a436-724499733365', 'map_house_cellar_way_share', 0.1, 'Storeys: share of cellars over cave country whose floor breaks through into it (Nottingham''s cellar caves)')
ON CONFLICT (agency_id, key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.rpg_map_cellar_link(p_x bigint, p_y bigint)
 RETURNS TABLE(b text, bx bigint, by bigint, bd double precision)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
-- Whether the cellar of a house breaks through into the world under the ground (storeys part 3b, Peter 2026-10-08:
-- some cellars lead down into the underground), the one home of it: p_x, p_y = the cellar's way down, the first square
-- of its stair (world squares from 0, rpg_map_cellar_way). It does where it lies over a chamber of cave country (the
-- chamber of its lattice square, rpg_map_under_nodes: cave country is 3 in 10 of the land) and its roll (part 12 layer
-- 1294 at that square) is under map_house_cellar_way_share (0.1): the towns over soft rock whose cellars were dug on
-- down into caves and older workings (Nottingham's 800 and more sandstone caves under its streets, reached from the
-- cellars of the houses over them; the old quarries under Paris, reached from cellars). b = that chamber
-- (cave-<column>-<row>), bx, by = where it lies, counted the way p_x counts; bd = how deep it is.
SELECT 'cave-' || mod(mod(n.i, t.span / t.cs) + t.span / t.cs, t.span / t.cs) || '-' || n.j, n.x, n.y, n.depth
  FROM public.rpg_map_under_lattice() t
 CROSS JOIN LATERAL public.rpg_map_under_nodes('cave', floor(p_x::double precision / t.cs)::bigint, floor(p_x::double precision / t.cs)::bigint,
                                               floor(p_y::double precision / t.cs)::bigint, floor(p_y::double precision / t.cs)::bigint) n
 WHERE public.rpg_map_roll(t.seed, 1294, mod(mod(p_x, t.span) + t.span, t.span)::integer, p_y::integer)
       <= 100 * public.rpg_setting('map_house_cellar_way_share');
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_cellar_way(p_x integer, p_y integer)
 RETURNS TABLE(node text, name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The way down out of the cellar a piece stands in (storeys part 3b), when there is one: the cellar of the house whose
-- floor -1 square p_x, p_y is (world squares from 1, as pieces stand; rpg_map_building_squares), its way down at the
-- first square of its stair, when that breaks through (rpg_map_cellar_link). node = cellar:<x>-<y> (that square, from
-- 0), the node of the world under the ground a piece going down stands at (rpg_map_under_node).
WITH h AS (SELECT b.id FROM public.rpg_map_building_squares(7, p_x - 1, p_y - 1, 1, 1, true) b WHERE b.floor = -1 LIMIT 1),
     st AS (SELECT b.x, b.y
              FROM h CROSS JOIN LATERAL public.rpg_map_building_squares(7, p_x - 17, p_y - 17, 33, 33, true) b
             WHERE b.id = h.id AND b.floor = -1 AND b.part = 'stair'
             ORDER BY b.y, b.x LIMIT 1)
SELECT 'cellar:' || st.x || '-' || st.y, 'the crack in the cellar floor'
  FROM st CROSS JOIN LATERAL public.rpg_map_cellar_link(st.x, st.y) l;
$function$;

REVOKE ALL ON FUNCTION public.rpg_map_cellar_link(bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_cellar_link(bigint, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_cellar_way(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_cellar_way(integer, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.rpg_map_under_node(p_node text)
 RETURNS TABLE(x bigint, y bigint, depth double precision, sea boolean, name text, site jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a node of the world under the ground is (step 12d2), the one way a node is read: x, y = the world square over
-- it, depth = metres down, sea = counted below the level of the sea (a great hall) or below the ground (the rest), name
-- = what it is called (a great hall: its name; a chamber: a chamber of cave country; the mouth or the end of the
-- passage of a cave or a mine: that, with its name), site = the cave or mine (as rpg_map_under_edges takes it).
-- (storeys part 3b) cellar:<x>-<y>, the way up into a cellar whose floor breaks through (rpg_map_cellar_way): that
-- square, one storey down (map_house_storey_low, 2.4 m), and as its site [x-y, 0, cellar, x, y, its depth, 0, true].
SELECT n.x, n.y, n.depth, true, public.rpg_map_under_hall_name(split_part(p_node, '-', 2)::integer, split_part(p_node, '-', 3)::bigint), NULL::jsonb
  FROM public.rpg_map_under_nodes('deep', split_part(p_node, '-', 2)::bigint, split_part(p_node, '-', 2)::bigint, split_part(p_node, '-', 3)::bigint, split_part(p_node, '-', 3)::bigint) n
 WHERE p_node LIKE 'deep-%'
UNION ALL
SELECT n.x, n.y, n.depth, false, 'a chamber of cave country', NULL::jsonb
  FROM public.rpg_map_under_nodes('cave', split_part(p_node, '-', 2)::bigint, split_part(p_node, '-', 2)::bigint, split_part(p_node, '-', 3)::bigint, split_part(p_node, '-', 3)::bigint) n
 WHERE p_node LIKE 'cave-%'
UNION ALL
SELECT CASE WHEN p_node LIKE 'mouth:%' THEN s.x ELSE o.ex END, CASE WHEN p_node LIKE 'mouth:%' THEN s.y ELSE o.ey END,
       CASE WHEN p_node LIKE 'mouth:%' THEN 0 ELSE o.down END, false,
       CASE WHEN p_node LIKE 'mouth:%' THEN 'the mouth of ' ELSE 'the far end of ' END || s.name,
       jsonb_build_array(s.id, s.rank, s.kind, s.x, s.y, s.height, s.across, true)
  FROM public.rpg_map_under_site(split_part(p_node, ':', 2)) s
 CROSS JOIN LATERAL public.rpg_map_under_own(s.id, s.rank, s.kind, s.x, s.y) o
 WHERE p_node LIKE 'mouth:%' OR p_node LIKE 'end:%'
UNION ALL
SELECT c.x, c.y, c.d, false, 'the way up into a cellar', jsonb_build_array(c.x || '-' || c.y, 0, 'cellar', c.x, c.y, c.d, 0, true)
  FROM (SELECT split_part(substr(p_node, 8), '-', 1)::bigint AS x, split_part(substr(p_node, 8), '-', 2)::bigint AS y,
               public.rpg_setting('map_house_storey_low')::double precision AS d) c
 WHERE p_node LIKE 'cellar:%';
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_edges(p_box bigint[], p_deep boolean, p_cbox bigint[], p_sites jsonb)
 RETURNS TABLE(kind text, a text, b text, ax bigint, ay bigint, bx bigint, by bigint, ad double precision, bd double precision, bend double precision, name text, near boolean, skind text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The passages of the world under the ground (step 12d), the one home of them, worked out when asked and never stored:
-- each row a passage from node a (ax, ay, ad metres down) to node b (bx, by, bd), bend = how far it swings to one side
-- (-1 to 1, a share of a quarter of its length; the page draws the curve and a walk measures it), or a great hall
-- (kind hall, at a, named). Nodes: deep-<column>-<row> a great hall, cave-<column>-<row> a chamber of cave country
-- (rpg_map_under_nodes, columns counted round the world), mouth:<site> and end:<site> the two ends of the own passage of
-- a cave or a mine (site mark-<w6>-<y6>).
--   deep (p_deep): a passage of the Deeps between two great halls (layers 1726 to 1729 whether it is there, east, south
--     and the two corners, at map_deep_link and map_deep_cross, 1731 to 1734 its bend); hall: a great hall in p_box,
--     named by rpg_map_under_hall_name.
--   cave (p_cbox, the box whose chambers are read; none when nothing): a passage of cave country between two chambers
--     (layers 1706 to 1709 and 1711 to 1714, map_cave_link and map_cave_cross). shaft (both): a great hall up to the
--     chamber of cave country over it (layer 1735, map_cave_shaft).
--   Each cave or mine of p_sites (as [id, rank, kind, x, y, height, across, near]): own, its own passage
--     (rpg_map_under_own); join, from its end into the chamber of cave country it lies over (layer 1741); delve, from its
--     end to the great hall of the Deeps under it (layer 1742).
--   (storeys part 3b) each cellar of p_sites (as rpg_map_under_node gives it, [x-y, 0, cellar, x, y, depth, 0, near]):
--     join, a squeeze from it down into the chamber of cave country it lies over, when it breaks through
--     (rpg_map_cellar_link).
-- A passage between nodes is given when it reaches p_box (x0, y0, x1, y1 in world squares, the far ends left out),
-- counted the way the box counts round the world. near = the site was found or known (p_sites); skind = cave or mine
-- for the passages of a site.
WITH t AS MATERIALIZED (
       SELECT u.*, p_box[1] AS gx0, p_box[2] AS gy0, p_box[3] AS gx1, p_box[4] AS gy1
         FROM public.rpg_map_under_lattice() u),
     tiers AS (
       SELECT 'deep' AS tier, t.ds AS s, 1720 AS l, t.deep_link AS link, t.deep_cross AS crs, t.gx0 AS x0, t.gy0 AS y0, t.gx1 AS x1, t.gy1 AS y1 FROM t WHERE p_deep
       UNION ALL
       SELECT 'cave', t.cs, 1700, t.cave_link, t.cave_cross, p_cbox[1], p_cbox[2], p_cbox[3], p_cbox[4] FROM t WHERE p_cbox IS NOT NULL),
     -- the nodes of each tier's box and one lattice square round it
     nd AS MATERIALIZED (
       SELECT r.tier, r.s, r.l, r.link, r.crs, n.*, mod(mod(n.i, t.span / r.s) + t.span / r.s, t.span / r.s)::integer AS w
         FROM tiers r CROSS JOIN t
        CROSS JOIN LATERAL public.rpg_map_under_nodes(r.tier, floor(r.x0::double precision / r.s)::bigint - 1, floor((r.x1 - 1)::double precision / r.s)::bigint + 1,
                                                      floor(r.y0::double precision / r.s)::bigint - 1, floor((r.y1 - 1)::double precision / r.s)::bigint + 1) n),
     -- the passages between them that reach the box: east, south and the two corners
     ed AS (
       SELECT p.tier AS kind, p.tier || '-' || p.w || '-' || p.j AS a, q.tier || '-' || q.w || '-' || q.j AS b,
              p.x AS ax, p.y AS ay, q.x AS bx, q.y AS by, p.depth AS ad, q.depth AS bd,
              (public.rpg_map_roll(t.seed, p.l + 10 + d.k, p.w, p.j::integer) - 50.5) / 50 AS bend, NULL::text AS name, NULL::boolean AS near, NULL::text AS skind
         FROM nd p CROSS JOIN t
        CROSS JOIN (VALUES (1, 1, 0), (2, 0, 1), (3, 1, 1), (4, -1, 1)) AS d(k, di, dj)
         JOIN nd q ON q.tier = p.tier AND q.i = p.i + d.di AND q.j = p.j + d.dj
        WHERE public.rpg_map_roll(t.seed, p.l + 5 + d.k, p.w, p.j::integer) <= 100 * CASE WHEN d.k <= 2 THEN p.link ELSE p.crs END
          AND greatest(p.x, q.x) + p.s / 2 >= t.gx0 AND least(p.x, q.x) - p.s / 2 < t.gx1
          AND greatest(p.y, q.y) + p.s / 2 >= t.gy0 AND least(p.y, q.y) - p.s / 2 < t.gy1),
     -- the shafts from the great halls up into cave country
     sh AS (
       SELECT 'shaft' AS kind, d.tier || '-' || d.w || '-' || d.j AS a, c.tier || '-' || c.w || '-' || c.j AS b,
              d.x AS ax, d.y AS ay, c.x AS bx, c.y AS by, d.depth AS ad, c.depth AS bd, 0::double precision AS bend, NULL::text AS name, NULL::boolean AS near, NULL::text AS skind
         FROM nd d CROSS JOIN t
         JOIN nd c ON c.tier = 'cave' AND c.i = floor(d.x::double precision / t.cs)::bigint AND c.j = floor(d.y::double precision / t.cs)::bigint
        WHERE d.tier = 'deep' AND public.rpg_map_roll(t.seed, 1735, d.w, d.j::integer) <= 100 * t.shaft),
     -- the great halls in the box
     hl AS (
       SELECT 'hall' AS kind, d.tier || '-' || d.w || '-' || d.j AS a, NULL::text AS b, d.x AS ax, d.y AS ay, d.x AS bx, d.y AS by,
              d.depth AS ad, d.depth AS bd, 0::double precision AS bend, public.rpg_map_under_hall_name(d.w, d.j) AS name, NULL::boolean AS near, NULL::text AS skind
         FROM nd d CROSS JOIN t
        WHERE d.tier = 'deep' AND d.x >= t.gx0 AND d.x < t.gx1 AND d.y >= t.gy0 AND d.y < t.gy1),
     -- the caves and mines given, and their own passages
     se AS MATERIALIZED (
       SELECT e ->> 0 AS id, e ->> 2 AS skind, (e ->> 3)::bigint AS x, (e ->> 4)::bigint AS y, coalesce((e ->> 7)::boolean, false) AS near, o.*
         FROM jsonb_array_elements(coalesce(p_sites, '[]'::jsonb)) AS e
        CROSS JOIN LATERAL public.rpg_map_under_own(e ->> 0, (e ->> 1)::integer, e ->> 2, (e ->> 3)::bigint, (e ->> 4)::bigint) o),
     own AS (
       SELECT 'own' AS kind, 'mouth:' || se.id AS a, 'end:' || se.id AS b, se.x AS ax, se.y AS ay, se.ex AS bx, se.ey AS by, 0::double precision AS ad, se.down AS bd,
              se.bend, NULL::text AS name, se.near, se.skind
         FROM se),
     jn AS (
       SELECT 'join' AS kind, 'end:' || se.id AS a, 'cave-' || mod(mod(n.i, t.span / t.cs) + t.span / t.cs, t.span / t.cs) || '-' || n.j AS b,
              se.ex AS ax, se.ey AS ay, n.x AS bx, n.y AS by, se.down AS ad, n.depth AS bd, 0::double precision AS bend, NULL::text AS name, se.near, se.skind
         FROM se CROSS JOIN t
        CROSS JOIN LATERAL public.rpg_map_under_nodes('cave', floor(se.ex::double precision / t.cs)::bigint, floor(se.ex::double precision / t.cs)::bigint,
                                                      floor(se.ey::double precision / t.cs)::bigint, floor(se.ey::double precision / t.cs)::bigint) n
        WHERE public.rpg_map_roll(t.seed, 1741, split_part(se.id, '-', 2)::integer, split_part(se.id, '-', 3)::integer) <= se.join_pct),
     dv AS (
       SELECT 'delve' AS kind, 'end:' || se.id AS a, 'deep-' || mod(mod(n.i, t.span / t.ds) + t.span / t.ds, t.span / t.ds) || '-' || n.j AS b,
              se.ex AS ax, se.ey AS ay, n.x AS bx, n.y AS by, se.down AS ad, n.depth AS bd, 0::double precision AS bend, NULL::text AS name, se.near, se.skind
         FROM se CROSS JOIN t
        CROSS JOIN LATERAL public.rpg_map_under_nodes('deep', floor(se.ex::double precision / t.ds)::bigint, floor(se.ex::double precision / t.ds)::bigint,
                                                      floor(se.ey::double precision / t.ds)::bigint, floor(se.ey::double precision / t.ds)::bigint) n
        WHERE public.rpg_map_roll(t.seed, 1742, split_part(se.id, '-', 2)::integer, split_part(se.id, '-', 3)::integer) <= se.delve_pct),
     cj AS (
       SELECT 'join' AS kind, 'cellar:' || (e ->> 0) AS a, l.b, (e ->> 3)::bigint AS ax, (e ->> 4)::bigint AS ay, l.bx, l.by,
              (e ->> 5)::double precision AS ad, l.bd, 0::double precision AS bend, NULL::text AS name, coalesce((e ->> 7)::boolean, false) AS near, 'cellar'::text AS skind
         FROM jsonb_array_elements(coalesce(p_sites, '[]'::jsonb)) AS e
        CROSS JOIN LATERAL public.rpg_map_cellar_link((e ->> 3)::bigint, (e ->> 4)::bigint) l
        WHERE e ->> 2 = 'cellar')
SELECT * FROM ed
UNION ALL SELECT * FROM sh
UNION ALL SELECT * FROM hl
UNION ALL SELECT * FROM own
UNION ALL SELECT * FROM jn
UNION ALL SELECT * FROM dv
UNION ALL SELECT * FROM cj;
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
-- (storeys part 3b) The way up from a chamber into a cellar (cellar:<x>-<y>) is listed only once known or when a walk
-- heads there; a search does not find it (a crack under a house is found from the house). At a cellar: its squeeze down.
DECLARE
  t record; v_n record; v_box bigint[]; v_cbox bigint[]; v_sites jsonb := '[]'::jsonb; v_deep boolean := true; v_cell bigint[];
BEGIN
  SELECT * INTO t FROM public.rpg_map_under_lattice();
  SELECT * INTO v_n FROM public.rpg_map_under_node(p_node);
  IF NOT FOUND THEN RETURN; END IF;
  IF p_node LIKE 'deep-%' OR p_node LIKE 'cave-%' THEN
    -- the caves and mines, and (storeys part 3b) the cellars, known (or asked for) to break into it
    SELECT coalesce(jsonb_agg(n.site), '[]'::jsonb) INTO v_sites
      FROM (SELECT DISTINCT substr(q.k, length(p_node) + 2) AS nd FROM public.rpg_map_under_known() q
             WHERE q.k LIKE p_node || '|end:%' OR q.k LIKE p_node || '|cellar:%'
            UNION SELECT p_also WHERE p_also LIKE 'end:%' OR p_also LIKE 'cellar:%') s
     CROSS JOIN LATERAL public.rpg_map_under_node(s.nd) n;
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
  ELSIF p_node LIKE 'cellar:%' THEN
    v_box := ARRAY[v_n.x - 1, v_n.y - 1, v_n.x + 2, v_n.y + 2];
    v_sites := jsonb_build_array(v_n.site);
    v_deep := false;
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
--   the mouth of a cave has none (the passage starts at the cave on the surface), nor the way up into a cellar
--   (storeys part 3b: the squeeze starts at the cellar's stair).
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
    IF e.a NOT LIKE 'mouth:%' AND e.a NOT LIKE 'cellar:%' THEN v_nodes := v_nodes || jsonb_build_object('n', e.a, 'x', v_ax, 'y', v_ay, 'd', e.ad, 'sk', e.skind); END IF;
    IF e.b NOT LIKE 'mouth:%' AND e.b NOT LIKE 'cellar:%' THEN v_nodes := v_nodes || jsonb_build_object('n', e.b, 'x', v_bx, 'y', v_by, 'd', e.bd, 'sk', e.skind); END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_map_under_enter(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece on its turn goes into the cave or mine it stands at (step 12d2; rpg_map_under_cave_at): it stands at the
-- mouth of its passage (under_at mouth:<site>), under the ground, until it comes up again (rpg_map_under_leave). Going
-- in takes no time and keeps the turn: the walk on is rpg_map_under_walk.
-- (storeys part 3b) Down in a cellar whose floor breaks through (rpg_map_cellar_way), it goes down through the crack
-- instead: it stands at the way up into the cellar (cellar:<x>-<y>), on no floor of a house.
DECLARE v_sid uuid; v_p record; v_c record; v_cw record; v_text text;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.creature_id IS NOT NULL THEN RAISE EXCEPTION 'creatures move on the fight board'; END IF;
  IF v_p.pos_x IS NULL THEN RAISE EXCEPTION '% is not on the map yet', v_p.name; END IF;
  -- (storeys step) up a house, the way out is down its stair first (rpg_act_stair)
  IF v_p.floor > 0 THEN RAISE EXCEPTION '% is upstairs in a house: come down the stair first', v_p.name; END IF;
  IF v_p.under_at IS NOT NULL THEN RAISE EXCEPTION '% is already under the ground', v_p.name; END IF;
  IF public.rpg_map_in_fight(p_participant_id) THEN RAISE EXCEPTION '% is in a fight: move on the fight board', v_p.name; END IF;
  IF v_p.floor < 0 THEN
    SELECT * INTO v_cw FROM public.rpg_map_cellar_way(v_p.pos_x, v_p.pos_y);
    IF NOT FOUND THEN RAISE EXCEPTION 'this cellar has no way down: % comes up the stair', v_p.name; END IF;
    UPDATE public.rpg_session_participants SET under_at = v_cw.node, under_to = NULL, under_done = 0, floor = 0, walk_to_x = NULL, walk_to_y = NULL
     WHERE id = p_participant_id;
    UPDATE public.rpg_characters SET map_under = map_under || jsonb_build_array('n:' || v_cw.node)
     WHERE id = v_p.character_id AND NOT is_npc AND session_id IS NULL AND NOT map_under ? ('n:' || v_cw.node);
    v_text := v_p.name || ' squeezes down through ' || v_cw.name || '.';
    INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
    SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
    UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_sid;
    RETURN jsonb_build_object('text', v_text);
  END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_map_under_leave(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece on its turn comes up out of a cave or a mine (step 12d2): only from the mouth of its passage, where it stands
-- on the middle square of the cave or mine (the mouth on the battle grid). No time; it keeps the turn.
-- (storeys part 3b) or from the way up into a cellar (cellar:<x>-<y>): it comes up onto that square of the cellar,
-- floor -1 of its house.
DECLARE v_sid uuid; v_p record; v_n record; v_text text;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.under_at IS NULL THEN RAISE EXCEPTION '% is not under the ground', v_p.name; END IF;
  IF (v_p.under_at NOT LIKE 'mouth:%' AND v_p.under_at NOT LIKE 'cellar:%') OR v_p.under_to IS NOT NULL THEN
    RAISE EXCEPTION '% can only come up at the mouth of a cave or a mine, or into a cellar', v_p.name;
  END IF;
  SELECT * INTO v_n FROM public.rpg_map_under_node(v_p.under_at);
  UPDATE public.rpg_session_participants
     SET under_at = NULL, under_to = NULL, under_done = 0, floor = CASE WHEN v_p.under_at LIKE 'cellar:%' THEN -1 ELSE 0 END,
         pos_x = (mod(mod(v_n.x, (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)) + (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1),
                      (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)) + 1)::integer,
         pos_y = (v_n.y + 1)::integer
   WHERE id = p_participant_id;
  v_text := v_p.name || CASE WHEN v_p.under_at LIKE 'cellar:%' THEN ' climbs up into a cellar.' ELSE ' comes up out of ' || replace(v_n.name, 'the mouth of ', '') || '.' END;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_sid;
  RETURN jsonb_build_object('text', v_text);
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
-- or mine it stands at and can go into (rpg_map_under_cave_at), or down in a cellar the crack in its floor it can go
-- down through (storeys part 3b, rpg_map_cellar_way); mouth also at the way up into a cellar.
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
-- ground floor, and floors = its upper floors' plans and its cellar's (floor -1), floor by floor, for the Maps tab's floor switch.
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
         -- (storeys step) the upper floors and cellars (floor -1) of the houses whose squares are seen: [floor, x, y, part], x and y from the
         -- block's first square as the cells count them
         (SELECT jsonb_agg(jsonb_build_array(b.floor, b.x - v_x0 + 1, b.y - v_y0 + 1, b.part) ORDER BY b.floor, b.y, b.x)
            FROM bsq b JOIN cl ON cl.x = b.x AND cl.y = b.y WHERE b.floor <> 0 AND cl.seen)
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
                      'mouth', CASE WHEN (p.under_at LIKE 'mouth:%' OR p.under_at LIKE 'cellar:%') AND p.under_to IS NULL THEN true END,
                      -- (storeys step) the floor of a house it stands on, and the stair it can take on its turn
                      'floor', CASE WHEN p.floor <> 0 THEN p.floor END,
                      'stair', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                    THEN public.rpg_stair_ways(p.id) END,
                      'search', CASE WHEN p.under_to IS NULL AND (p.under_at LIKE 'deep-%' OR p.under_at LIKE 'cave-%') THEN true END,
                      'cave', CASE WHEN p.under_at IS NULL AND p.pos_x IS NOT NULL AND p.creature_id IS NULL AND s.status = 'active' AND p.id = s.current_participant_id
                                   THEN CASE WHEN p.floor < 0 THEN (SELECT c.name FROM public.rpg_map_cellar_way(p.pos_x, p.pos_y) c)
                                             WHEN p.floor = 0 THEN (SELECT c.name FROM public.rpg_map_under_cave_at(p.pos_x, p.pos_y) c) END END,
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
    -- floor or stair; floor 1 is the first floor up, floor -1 a cellar)
    'floors', v_floors,
    'list', v_list, 'within', v_within,
    'grounds', v_grounds,
    'journey', v_journey,
    'ladder', v_ladder, 'square', public.rpg_map_length_text(1));
END $function$;

-- the rule card Moving: one passage after the cellars, in place
UPDATE public.rpg_rules
   SET body = replace(body, $a$*Zaboo (Speed 5) goes down in 22 × 20 ÷ 15 = 29 ticks and back up in 35.*$a$,
                      $a$*Zaboo (Speed 5) goes down in 22 × 20 ÷ 15 = 29 ticks and back up in 35.*
Now and then a cellar's floor has broken through into cave country below, about one cellar in ten of those that lie over it (as under Nottingham, where the houses' cellars lead down into hundreds of sandstone caves). Down in such a cellar the Maps tab offers "Go into the crack in the cellar floor": a narrow squeeze, +400% time a square, down to the cave chamber under the town. From below, that way up is hidden like the ways up into caves and mines, and searching does not find it: only someone who came down it knows it.$a$),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'moving' AND position('a cellar''s floor has broken through' in body) = 0;

NOTIFY pgrst, 'reload schema';

