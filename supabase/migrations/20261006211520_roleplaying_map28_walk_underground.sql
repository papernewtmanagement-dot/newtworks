-- roleplaying map step 12d2: walking the world under the ground (Peter 2026-10-06 1A). Columns under_at, under_to,
-- under_done on rpg_session_participants and map_under on rpg_characters (no new tables); five settings. New
-- rpg_map_under_hall_name, _own, _edges (the one home of the passages; rpg_map_underground now reads it), _known, _site,
-- _ends, _node, _ways, _where, _cave_at, _way_words, and the moves rpg_map_under_enter, _leave, _walk, _search;
-- rpg_map_walk (not under the ground), rpg_place (brings a piece up), rpg_map_view_block (pieces under the ground and
-- their ways); rule card world_map. No drops.

-- step 12d2: a piece under the ground, and what the group knows of the world under the ground (no new tables)
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS under_at text;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS under_to text;
ALTER TABLE public.rpg_session_participants ADD COLUMN IF NOT EXISTS under_done double precision NOT NULL DEFAULT 0;
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS map_under jsonb NOT NULL DEFAULT '[]'::jsonb;
COMMENT ON COLUMN public.rpg_session_participants.under_at IS 'Step 12d2: the node of the world under the ground the piece stands at, or set off from when under_to is set (deep-<col>-<row>, cave-<col>-<row>, mouth:<site>, end:<site>); empty on the surface';
COMMENT ON COLUMN public.rpg_session_participants.under_to IS 'Step 12d2: the node the piece is walking to, partway along the passage; empty at a node';
COMMENT ON COLUMN public.rpg_session_participants.under_done IS 'Step 12d2: metres walked along the passage from under_at toward under_to';
COMMENT ON COLUMN public.rpg_characters.map_under IS 'Step 12d2: what the character knows of the world under the ground: passages walked (a|b) and nodes stood at (n:<node>)';

-- step 12d2: how fast the world under the ground is walked (Peter 2026-10-06 1A)
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.key, v.value, v.label
  FROM (VALUES ('map_under_deep_pct', 25::numeric, 'Underground: percent more time a square of the Deeps takes (big galleries, dark)'),
               ('map_under_cave_pct', 250, 'Underground: percent more time a square of a cave passage takes (cavers make about 1 km an hour, a walker about 4.7)'),
               ('map_under_mine_pct', 50, 'Underground: percent more time a square of the galleries of a mine takes (cut and level)'),
               ('map_under_crawl_pct', 400, 'Underground: percent more time a square takes where a cave or mine breaks through to cave country or the Deeps (squeezes and crawls)'),
               ('map_under_search_hours', 1, 'Underground: hours a search of a chamber or a great hall for the ways up into caves and mines takes')) AS v(key, value, label)
 WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings s WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND s.key = v.key);

CREATE OR REPLACE FUNCTION public.rpg_map_under_hall_name(p_w integer, p_j bigint)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
-- The name of a great hall of the Deeps (step 12d), the one home of it: The <word> Deep, the word by where its lattice
-- square lies (a column plus 7 times a row, out of 48, as the landmarks are named), so no two halls near each other
-- share one. p_w = its column counted round the world, p_j its row.
SELECT 'The ' || (ARRAY['Grey', 'Black', 'Raven', 'Eagle', 'Storm', 'Cloud', 'Snow', 'Iron', 'High', 'Old', 'White', 'Red',
                        'Wolf', 'Crow', 'Wind', 'Thunder', 'Frost', 'Stag', 'Hawk', 'Dun', 'Bleak', 'Long', 'Gold', 'Star',
                        'Silver', 'Copper', 'Bright', 'Shadow', 'Ember', 'Ash', 'Bear', 'Boar', 'Fox', 'Owl', 'Heron', 'Falcon',
                        'Moon', 'Sun', 'Dawn', 'Dusk', 'Rain', 'Mist', 'Thorn', 'Bramble', 'Holly', 'Oak', 'Elder', 'King'])
                  [1 + mod(mod(p_w, 48) + 7 * mod(p_j, 48)::integer, 48)] || ' Deep';
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_own(p_id text, p_rank integer, p_kind text, p_x bigint, p_y bigint)
 RETURNS TABLE(ex bigint, ey bigint, len double precision, down double precision, join_pct integer, delve_pct integer, bend double precision)
 LANGUAGE sql
 STABLE
AS $function$
-- The own passage of a cave or a mine (step 12d), the one home of how long and how deep it runs: from its mouth (p_x,
-- p_y, its middle) into the hill, the opposite way to where its mouth faces (layer 1631 at its middle, as
-- rpg_map_landmark_squares draws the mouth), as long and as deep as its kind and a roll make it (layers 1743 and 1744 at
-- its site, p_id mark-<w6>-<y6>): a great cave 0.5 to 5 km, its end a fifth of that down; a cave 100 m to 1 km; a
-- hollow 10 to 100 m; mine workings 1 to 5 km of galleries (Levant ran a mile out under the sea) down a shaft of 0.5 to
-- 4 km (Mponeng 4 km); a mine 100 to 800 m down 50 to 500 m; each as many short as long on a doubling scale. ex, ey =
-- its end in world squares, counted the way p_x counts; len, down = metres; join_pct = the chance in 100 its end breaks
-- into the chamber of cave country it lies over (a great cave always, a cave 70, mine workings 50, a mine 30),
-- delve_pct = into the great hall of the Deeps under it (mine workings 30, a great cave 20); bend = how far it swings
-- to one side (layer 1745). Nothing for any other kind.
SELECT p_x + round(q.len / t.sq * cos(d.dir))::bigint, p_y + round(q.len / t.sq * sin(d.dir))::bigint, q.len, q.down, z.join_pct, z.delve_pct,
       (public.rpg_map_roll(t.seed, 1745, s.w6, s.y6) - 50.5) / 50
  FROM public.rpg_map_under_lattice() t
 CROSS JOIN (SELECT split_part(p_id, '-', 2)::integer AS w6, split_part(p_id, '-', 3)::integer AS y6) s
  JOIN (VALUES ('cave', 4, 500, 5000, NULL::double precision, NULL::double precision, 100, 20),
               ('cave', 5, 100, 1000, NULL, NULL, 70, 0),
               ('cave', 6, 10, 100, NULL, NULL, 0, 0),
               ('mine', 4, 1000, 5000, 500, 4000, 50, 30),
               ('mine', 5, 100, 800, 50, 500, 30, 0)) AS z(zkind, zrank, len_low, len_high, down_low, down_high, join_pct, delve_pct)
    ON z.zkind = p_kind AND z.zrank = p_rank
 CROSS JOIN LATERAL (SELECT 2 * pi() * (public.rpg_map_roll(t.seed, 1631, mod(mod(p_x, t.span) + t.span, t.span)::integer, p_y::integer) - 0.5) / 100 + pi() AS dir) d
 CROSS JOIN LATERAL (SELECT z.len_low * power(z.len_high / z.len_low, (public.rpg_map_roll(t.seed, 1743, s.w6, s.y6) - 0.5) / 100) AS len) l0
 CROSS JOIN LATERAL (SELECT l0.len,
                            coalesce(z.down_low * power(z.down_high / z.down_low, (public.rpg_map_roll(t.seed, 1744, s.w6, s.y6) - 0.5) / 100), l0.len / 5) AS down) q;
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
        WHERE public.rpg_map_roll(t.seed, 1742, split_part(se.id, '-', 2)::integer, split_part(se.id, '-', 3)::integer) <= se.delve_pct)
SELECT * FROM ed
UNION ALL SELECT * FROM sh
UNION ALL SELECT * FROM hl
UNION ALL SELECT * FROM own
UNION ALL SELECT * FROM jn
UNION ALL SELECT * FROM dv;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_known()
 RETURNS TABLE(k text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- What the group knows of the world under the ground (step 12d2): every passage a player character walked
-- (a|b, its two nodes in order) and every node one stood at (n:<node>), from their map_under (rpg_map_under_walk).
-- The kids login shares one map, so what any of them walked, all of them see.
SELECT DISTINCT e #>> '{}'
  FROM public.rpg_characters c CROSS JOIN LATERAL jsonb_array_elements(c.map_under) e
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND NOT c.is_npc AND c.session_id IS NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_site(p_id text)
 RETURNS TABLE(id text, rank integer, kind text, name text, x bigint, y bigint, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cave or mine at a site (step 12d2), found by its id alone (mark-<w6>-<y6>): the site of each rank 4 to 6 whose
-- rank-6 square that is (rpg_map_landmark_site), and what stands there (rpg_map_landmarks at the grid of its rank, one
-- cell), when it is a cave or a mine. Its column is counted round the world.
SELECT m.id, m.rank, m.kind, m.name, m.x, m.y, m.height, m.across
  FROM (SELECT split_part(p_id, '-', 2)::bigint AS w6, split_part(p_id, '-', 3)::bigint AS y6) s
 CROSS JOIN public.rpg_map_landmark_lattice() t
 CROSS JOIN generate_series(4, 6) AS rk
 CROSS JOIN LATERAL public.rpg_map_landmark_site(rk, floor(s.w6::double precision / 12 ^ (6 - rk))::bigint, floor(s.y6::double precision / 12 ^ (6 - rk))::bigint,
                                                 t.seed, t.l6, t.jit, t.a6) st
  JOIN public.rpg_map_ladder() l ON l.level = rk
 CROSS JOIN LATERAL public.rpg_map_landmarks(rk, floor(st.x::double precision / l.cell)::integer, floor(st.y::double precision / l.cell)::integer, 1, 1, NULL) m
 WHERE NOT st.picked AND st.w6 = s.w6 AND st.y6 = s.y6 AND m.id = p_id AND m.kind IN ('cave', 'mine');
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_ends(p_box bigint[], p_ranks integer[], p_link text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The caves and mines of ranks p_ranks whose own passage ends in p_box (x0, y0, x1, y1, world squares, the far ends left
-- out) and breaks through there (p_link join: into cave country; delve: into the Deeps), as rpg_map_under_edges takes
-- them ([id, rank, kind, x, y, height, across, true]): the ways up to the surface a search of a chamber or a great hall
-- finds (step 12d2; rpg_map_under_search). Read cheaply first: the sites of those ranks within the longest own passage
-- of the box (rpg_map_landmark_site), what their place-to-go-into rolls make them whatever the ground
-- (rpg_map_site_what: a cave or a mine that could stand on some ground), where their passage ends and whether it breaks
-- through (rpg_map_under_own; layers 1741 and 1742); only those left are read on the ground (rpg_map_landmarks at the
-- grid of their rank, one cell: about a tenth of a second each).
WITH lt AS (SELECT * FROM public.rpg_map_landmark_lattice()),
     ut AS (SELECT * FROM public.rpg_map_under_lattice()),
     rk AS (SELECT r, ceil(CASE WHEN r = 4 THEN 5000 ELSE 1000 END / ut.sq)::bigint AS reach, lt.l6 * (12 ^ (6 - r))::bigint AS w
              FROM unnest(p_ranks) AS r CROSS JOIN ut CROSS JOIN lt WHERE r IN (4, 5)),
     st AS MATERIALIZED (
       SELECT rk.r, s.*
         FROM rk CROSS JOIN lt
        CROSS JOIN LATERAL generate_series(floor((p_box[1] - rk.reach)::double precision / rk.w)::bigint, floor((p_box[3] + rk.reach)::double precision / rk.w)::bigint) AS a
        CROSS JOIN LATERAL generate_series(greatest(floor((p_box[2] - rk.reach)::double precision / rk.w)::bigint, 0), floor((p_box[4] + rk.reach)::double precision / rk.w)::bigint) AS b
        CROSS JOIN LATERAL public.rpg_map_landmark_site(rk.r, a, b, lt.seed, lt.l6, lt.jit, lt.a6) s
        WHERE NOT s.picked),
     cand AS MATERIALIZED (
       SELECT st.*, 'mark-' || st.w6 || '-' || st.y6 AS id, w.kind
         FROM st CROSS JOIN lt
        CROSS JOIN LATERAL (SELECT public.rpg_map_landmark_rolls(st.w6, st.y6, lt.seed) AS rolls) ro
        CROSS JOIN LATERAL public.rpg_map_site_what('location', st.r, ro.rolls[7:12]) w
        WHERE w.kind IN ('cave', 'mine')
          AND (ro.rolls[8] - 0.5) / 100 < (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_location_share_' || st.r)::double precision
                                          * (SELECT max(e.value::double precision) FROM jsonb_each_text(w.grounds) e)),
     ends AS MATERIALIZED (
       SELECT cand.* FROM cand CROSS JOIN lt
        CROSS JOIN LATERAL public.rpg_map_under_own(cand.id, cand.r, cand.kind, cand.x, cand.y) o
        WHERE o.ex >= p_box[1] AND o.ex < p_box[3] AND o.ey >= p_box[2] AND o.ey < p_box[4]
          AND public.rpg_map_roll(lt.seed, CASE p_link WHEN 'join' THEN 1741 ELSE 1742 END, cand.w6::integer, cand.y6::integer)
              <= CASE p_link WHEN 'join' THEN o.join_pct ELSE o.delve_pct END),
     made AS (
       SELECT m.* FROM ends
         JOIN public.rpg_map_ladder() l ON l.level = ends.r
        CROSS JOIN LATERAL public.rpg_map_landmarks(ends.r, floor(ends.x::double precision / l.cell)::integer, floor(ends.y::double precision / l.cell)::integer, 1, 1, NULL) m
        WHERE m.id = ends.id AND m.kind IN ('cave', 'mine'))
SELECT coalesce(jsonb_agg(jsonb_build_array(made.id, made.rank, made.kind, made.x, made.y, made.height, made.across, true) ORDER BY made.id), '[]'::jsonb) FROM made;
$function$;

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
 WHERE p_node LIKE 'mouth:%' OR p_node LIKE 'end:%';
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_ways(p_node text, p_find boolean, p_also text)
 RETURNS TABLE(to_node text, kind text, skind text, up boolean, metres double precision, base numeric, to_x bigint, to_y bigint, to_depth double precision, to_sea boolean, to_name text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The ways on from a node of the world under the ground (step 12d2), the one home of them: every passage of it
-- (rpg_map_under_edges) to the node at its other end, read over just enough of the world: round a great hall the halls
-- next to it and the chamber over it; round a chamber the chambers next to it and the great hall whose shaft comes up
-- into it; at the mouth or the end of the passage of a cave or a mine that passage and where its end breaks through.
-- The ways up from a chamber or a great hall into the passage of a cave or a mine are hidden: listed once the group
-- knows them (rpg_map_under_known: walked or found), or p_find (a search, rpg_map_under_search: rpg_map_under_ends over
-- the chamber's or the hall's lattice square), or p_also (that one node, end:<site>, when a walk heads there).
-- metres = how far the passage runs: along its curve (the chord, plus two thirds of the square of its swing, a share of
-- a quarter of its length) and down or up the difference in depth (a shaft straight up or down); up = it climbs.
-- base = its time at Speed 10 in ticks: every square of it takes move_ticks (5) and its percent more
-- (map_under_deep_pct for the Deeps, map_under_cave_pct for cave country and the passage of a cave, map_under_mine_pct
-- for the galleries of a mine, map_under_crawl_pct where a cave or mine breaks through to cave country or the Deeps);
-- a shaft is climbed at map_climb_rate (300 m an hour) up or down. to_* = the node at the other end
-- (rpg_map_under_node).
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
  WITH e AS (
         SELECT u.*, u.a = p_node AS fwd FROM public.rpg_map_under_edges(v_box, v_deep, v_cbox, v_sites) u
          WHERE u.kind <> 'hall' AND (u.a = p_node OR u.b = p_node)),
       w AS (
         SELECT DISTINCT ON (CASE WHEN e.fwd THEN e.b ELSE e.a END)
                CASE WHEN e.fwd THEN e.b ELSE e.a END AS nb, e.kind AS k, e.skind AS sk,
                CASE WHEN e.fwd THEN e.bd - e.ad ELSE e.ad - e.bd END AS dd,
                sqrt(power(e.bx - e.ax, 2) + power(e.by - e.ay, 2)) * t.sq * (1 + power(e.bend * 0.25, 2) * 2 / 3) AS flat
           FROM e ORDER BY CASE WHEN e.fwd THEN e.b ELSE e.a END, e.kind)
  SELECT w.nb, w.k, w.sk,
         -- a great hall lies below the level of the sea, the rest below the ground: going from a hall up into cave
         -- country, or from a passage end down to a hall, is a shaft either way
         CASE WHEN w.k = 'shaft' THEN p_node LIKE 'deep-%' WHEN w.k = 'delve' THEN p_node LIKE 'deep-%' ELSE w.dd < 0 END,
         CASE WHEN w.k = 'shaft' THEN abs(w.dd) ELSE sqrt(power(w.flat, 2) + power(w.dd, 2)) END,
         CASE WHEN w.k = 'shaft'
              THEN abs(w.dd) / public.rpg_setting('map_climb_rate') * public.rpg_setting('ticks_per_hour')
              ELSE sqrt(power(w.flat, 2) + power(w.dd, 2)) / t.sq * public.rpg_setting('move_ticks')
                   * (1 + public.rpg_setting(CASE WHEN w.k = 'deep' THEN 'map_under_deep_pct'
                                                  WHEN w.k IN ('join', 'delve') THEN 'map_under_crawl_pct'
                                                  WHEN w.k = 'own' AND w.sk = 'mine' THEN 'map_under_mine_pct'
                                                  ELSE 'map_under_cave_pct' END) / 100) END::numeric,
         m.x, m.y, m.depth, m.sea, m.name
    FROM w CROSS JOIN LATERAL public.rpg_map_under_node(w.nb) m;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_where(p_at text, p_to text, p_done double precision)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a piece under the ground is, in words (step 12d2): at a node (In The Raven Deep, 20,180 feet below the sea), or
-- partway along a passage (In a passage to a chamber of cave country, 1.2 miles to go). The one home of those words.
SELECT CASE WHEN p_to IS NULL
            THEN 'Underground: at ' || a.name
                 || CASE WHEN a.depth > 0 THEN ', ' || to_char(round(a.depth / 0.3048), 'FM999,999') || ' feet ' || CASE WHEN a.sea THEN 'below the sea' ELSE 'down' END ELSE '' END
            ELSE 'Underground: in a passage to ' || b.name || ', ' || public.rpg_map_length_text(round(greatest(w.metres - coalesce(p_done, 0), 0) / ut.sq)::numeric) || ' to go' END
  FROM public.rpg_map_under_node(p_at) a
 CROSS JOIN public.rpg_map_under_lattice() ut
  LEFT JOIN LATERAL public.rpg_map_under_node(p_to) b ON p_to IS NOT NULL
  LEFT JOIN LATERAL (SELECT u.metres FROM public.rpg_map_under_ways(p_at, false, p_to) u WHERE u.to_node = p_to LIMIT 1) w ON p_to IS NOT NULL;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_cave_at(p_x integer, p_y integer)
 RETURNS TABLE(id text, rank integer, kind text, name text, x bigint, y bigint, height double precision, across double precision)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The cave or mine a piece standing on world square p_x, p_y (counted from 1, as pieces stand) can go into (step 12d2):
-- one whose footprint the square lies on or next to (rpg_map_landmarks at the battle grid: within half its width and one
-- square of its middle), the nearest.
SELECT l.id, l.rank, l.kind, l.name, l.x, l.y, l.height, l.across
  FROM public.rpg_map_landmarks(7, p_x - 1, p_y - 1, 1, 1, NULL) l
 CROSS JOIN (SELECT public.rpg_setting('map_square_m')::double precision AS sq) q
 WHERE l.kind IN ('cave', 'mine')
   AND sqrt(power(l.x - (p_x - 1), 2) + power(l.y - (p_y - 1), 2)) <= l.across / 2 / q.sq + 1
 ORDER BY sqrt(power(l.x - (p_x - 1), 2) + power(l.y - (p_y - 1), 2)) LIMIT 1;
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

CREATE OR REPLACE FUNCTION public.rpg_map_under_leave(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece on its turn comes up out of a cave or a mine (step 12d2): only from the mouth of its passage, where it stands
-- on the middle square of the cave or mine (the mouth on the battle grid). No time; it keeps the turn.
DECLARE v_sid uuid; v_p record; v_n record; v_text text;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.under_at IS NULL THEN RAISE EXCEPTION '% is not under the ground', v_p.name; END IF;
  IF v_p.under_at NOT LIKE 'mouth:%' OR v_p.under_to IS NOT NULL THEN RAISE EXCEPTION '% can only come up at the mouth of a cave or a mine', v_p.name; END IF;
  SELECT * INTO v_n FROM public.rpg_map_under_node(v_p.under_at);
  UPDATE public.rpg_session_participants
     SET under_at = NULL, under_to = NULL, under_done = 0,
         pos_x = (mod(mod(v_n.x, (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)) + (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1),
                      (SELECT l.span FROM public.rpg_map_ladder() l WHERE l.level = 1)) + 1)::integer,
         pos_y = (v_n.y + 1)::integer
   WHERE id = p_participant_id;
  v_text := v_p.name || ' comes up out of ' || replace(v_n.name, 'the mouth of ', '') || '.';
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_sid;
  RETURN jsonb_build_object('text', v_text);
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
-- under which it is (pos_x, pos_y). What a player character walked the group knows (map_under: the passage and the
-- nodes at its ends, rpg_map_under_known). The time is the turn, and the turn passes on.
DECLARE
  v_sid uuid; v_p record; v_w record; v_from text; v_to text; v_done double precision; v_left integer; v_need integer;
  v_walk integer; v_m double precision; v_camped boolean := false; v_arrived boolean; v_speed numeric; v_tph integer;
  v_day integer; v_camp integer; v_a record; v_f double precision; v_x bigint; v_y bigint; v_span bigint; v_text text; v_next jsonb; v_key text;
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
  -- where it stands: the square over its spot along the passage
  SELECT * INTO v_a FROM public.rpg_map_under_node(v_from);
  v_f := CASE WHEN v_w.metres > 0 THEN v_m / v_w.metres ELSE 1 END;
  v_x := round(v_a.x + (v_w.to_x - v_a.x) * v_f)::bigint; v_y := round(v_a.y + (v_w.to_y - v_a.y) * v_f)::bigint;
  SELECT l.span INTO v_span FROM public.rpg_map_ladder() l WHERE l.level = 1;
  UPDATE public.rpg_session_participants
     SET under_at = CASE WHEN v_arrived THEN v_to ELSE v_from END, under_to = CASE WHEN v_arrived THEN NULL ELSE v_to END,
         under_done = CASE WHEN v_arrived THEN 0 ELSE v_m END,
         pos_x = (mod(mod(v_x, v_span) + v_span, v_span) + 1)::integer, pos_y = (greatest(v_y, 0) + 1)::integer,
         day_walk_ticks = CASE WHEN v_camped THEN 0 ELSE day_walk_ticks + v_walk END, walk_to_x = NULL, walk_to_y = NULL
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
                 ELSE ' toward ' || v_w.to_name || ', and camps in the passage for ' || public.rpg_map_duration_text(v_camp) || '. '
                      || public.rpg_map_length_text(round((v_w.metres - v_m) / (SELECT u.sq FROM public.rpg_map_under_lattice() u))::numeric) || ' to go.' END;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  v_next := public.rpg_session_next_turn(v_sid);
  RETURN jsonb_build_object('text', v_text, 'arrived', v_arrived, 'camped', v_camped, 'next', v_next);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_way_words(p_kind text, p_skind text, p_up boolean, p_metres double precision, p_ticks integer, p_to_name text, p_to_depth double precision, p_to_sea boolean)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
-- How a way on under the ground is told on the Maps tab (step 12d2), the one home of those words: what the passage is,
-- where it goes, how far, about how long at the piece's Speed, and how deep its far end lies. Through the Deeps to The
-- Raven Deep · 26 miles · about 34 h 10 min · 20,180 feet below the sea.
SELECT CASE p_kind WHEN 'deep' THEN 'Through the Deeps to ' WHEN 'cave' THEN 'Along a cave passage to '
                   WHEN 'shaft' THEN CASE WHEN p_up THEN 'Up a shaft to ' ELSE 'Down a shaft to ' END
                   WHEN 'own' THEN CASE WHEN p_up THEN 'Back up the passage to ' ELSE 'Into the passage, to ' END
                   WHEN 'join' THEN CASE WHEN p_up THEN 'Squeezing up to ' ELSE 'Squeezing through to ' END
                   ELSE CASE WHEN p_up THEN 'Up the deep workings to ' ELSE 'Down the deep workings to ' END END
       || p_to_name || ' · ' || public.rpg_map_length_text(round(p_metres / public.rpg_setting('map_square_m'))::numeric)
       || ' · about ' || public.rpg_map_duration_text(p_ticks)
       || ' · ' || to_char(round(p_to_depth / 0.3048), 'FM999,999') || ' feet ' || CASE WHEN p_to_sea THEN 'below the sea' ELSE 'down' END;
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
-- walked or stood in (rpg_map_under_known).
WITH kn AS MATERIALIZED (SELECT k.k FROM public.rpg_map_under_known() k WHERE NOT p_all),
     t AS (SELECT ARRAY[p_x0::bigint * l.cell, p_y0::bigint * l.cell, (p_x0 + p_cols)::bigint * l.cell, (p_y0 + p_rows)::bigint * l.cell] AS box
             FROM public.rpg_map_ladder() l WHERE l.level = p_level),
     u AS (SELECT e.* FROM t
            CROSS JOIN LATERAL public.rpg_map_under_edges(t.box, p_level BETWEEN 2 AND 6 AND (p_all OR EXISTS (SELECT 1 FROM kn)),
                                                          CASE WHEN p_level BETWEEN 3 AND 6 AND (p_all OR EXISTS (SELECT 1 FROM kn)) THEN t.box END,
                                                          CASE WHEN p_level BETWEEN 4 AND 6 THEN p_sites END) e)
SELECT u.kind, u.a, u.b, u.ax, u.ay, u.bx, u.by, u.ad, u.bd, u.bend, u.name
  FROM u
 WHERE p_all OR (u.kind = 'own' AND u.near)
    OR EXISTS (SELECT 1 FROM kn WHERE kn.k = CASE WHEN u.kind = 'hall' THEN 'n:' || u.a ELSE least(u.a, u.b) || '|' || greatest(u.a, u.b) END);
$function$;

CREATE OR REPLACE FUNCTION public.rpg_map_under_search(p_participant_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A piece under the ground searches the chamber or great hall it stands at for the ways up into the passages of caves
-- and mines that break into it (step 12d2; rpg_map_under_ways with p_find): it takes map_under_search_hours (1) of its
-- turn, and what it finds a player character's group knows from then on (map_under), so the ways stay listed. The turn
-- passes on.
DECLARE v_sid uuid; v_p record; v_n record; v_keys text[]; v_t integer; v_text text;
BEGIN
  v_sid := public.rpg_map_turn(p_participant_id);
  SELECT * INTO v_p FROM public.rpg_session_participants WHERE id = p_participant_id;
  IF v_p.under_at IS NULL OR v_p.under_to IS NOT NULL OR NOT (v_p.under_at LIKE 'deep-%' OR v_p.under_at LIKE 'cave-%') THEN
    RAISE EXCEPTION '% can search a chamber or a great hall, not here', v_p.name;
  END IF;
  SELECT * INTO v_n FROM public.rpg_map_under_node(v_p.under_at);
  SELECT coalesce(array_agg(DISTINCT least(v_p.under_at, w.to_node) || '|' || greatest(v_p.under_at, w.to_node)), '{}') INTO v_keys
    FROM public.rpg_map_under_ways(v_p.under_at, true, NULL) w WHERE w.to_node LIKE 'end:%';
  UPDATE public.rpg_characters
     SET map_under = map_under || (SELECT coalesce(jsonb_agg(k), '[]'::jsonb) FROM unnest(v_keys) AS k WHERE NOT map_under ? k)
   WHERE id = v_p.character_id AND v_p.creature_id IS NULL AND NOT is_npc AND session_id IS NULL;
  v_t := round(public.rpg_setting('map_under_search_hours') * public.rpg_setting('ticks_per_hour'))::integer;
  UPDATE public.rpg_sessions SET turn_move_ticks = v_t, turn_action_ticks = 0, updated_at = now() WHERE id = v_sid;
  v_text := v_p.name || ' searches ' || v_n.name || ' for ' || public.rpg_map_duration_text(v_t) || ' and finds '
         || CASE cardinality(v_keys) WHEN 0 THEN 'no way up into the passage of a cave or a mine.'
                                     WHEN 1 THEN 'one way up into the passage of a cave or a mine.'
                                     ELSE cardinality(v_keys) || ' ways up into the passages of caves and mines.' END;
  INSERT INTO public.rpg_events (agency_id, session_id, round, kind, outcome, actor_id, text)
  SELECT s.agency_id, s.id, s.round, 'move', 'info', p_participant_id, v_text FROM public.rpg_sessions s WHERE s.id = v_sid;
  RETURN jsonb_build_object('text', v_text, 'found', cardinality(v_keys), 'next', public.rpg_session_next_turn(v_sid));
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
  IF v_p.under_at IS NOT NULL THEN RAISE EXCEPTION '% is under the ground: walk its passages, or come up at the mouth of a cave or a mine', v_p.name; END IF;
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

CREATE OR REPLACE FUNCTION public.rpg_place(p_participant_id uuid, p_x integer DEFAULT NULL::integer, p_y integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The game master puts a piece on a square of the world map (counted from 1, as pieces stand), or with no square takes
-- it off. Free, any time, but never onto the sea or a square someone takes up; placing a piece forgets where it was
-- heading, and brings it up from under the ground (step 12d2). A fight off the map has no board, so there it can only
-- take someone off.
DECLARE v_p record; v_s record; v_who text;
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
    IF (SELECT f.sea FROM public.rpg_fight_square(v_s.id, p_x, p_y) f) THEN RAISE EXCEPTION 'that square is sea or water too rough to swim'; END IF;
    SELECT o.name INTO v_who FROM public.rpg_session_participants o
     WHERE o.session_id = v_p.session_id AND o.id <> v_p.id AND o.pos_x = p_x AND o.pos_y = p_y AND public.rpg_participant_blocks(o.id) LIMIT 1;
    IF v_who IS NOT NULL THEN RAISE EXCEPTION '% is on that square', v_who; END IF;
    UPDATE public.rpg_session_participants SET pos_x = p_x, pos_y = p_y, walk_to_x = NULL, walk_to_y = NULL, under_at = NULL, under_to = NULL, under_done = 0
     WHERE id = p_participant_id;
    IF v_p.creature_id IS NULL THEN PERFORM public.rpg_map_trail_add(v_p.character_id, p_x, p_y, p_x, p_y); END IF;
  END IF;
  UPDATE public.rpg_sessions SET updated_at = now() WHERE id = v_s.id;
  RETURN jsonb_build_object('ok', true);
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
                      'ways', CASE WHEN p.under_at IS NOT NULL AND s.status = 'active' AND p.id = s.current_participant_id
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

-- the helpers run only inside the map reads and moves (the service role only); the moves are called by the page
REVOKE ALL ON FUNCTION public.rpg_map_under_hall_name(integer, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_hall_name(integer, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_own(text, integer, text, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_own(text, integer, text, bigint, bigint) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_edges(bigint[], boolean, bigint[], jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_edges(bigint[], boolean, bigint[], jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_known() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_known() TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_site(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_site(text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_ends(bigint[], integer[], text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_ends(bigint[], integer[], text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_node(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_node(text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_ways(text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_ways(text, boolean, text) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_where(text, text, double precision) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_where(text, text, double precision) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_cave_at(integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_cave_at(integer, integer) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_way_words(text, text, boolean, double precision, integer, text, double precision, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_way_words(text, text, boolean, double precision, integer, text, double precision, boolean) TO service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_enter(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_enter(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_leave(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_leave(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_walk(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_walk(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.rpg_map_under_search(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpg_map_under_search(uuid) TO authenticated, service_role;

-- the rule card (step 12d2): walking under the ground
UPDATE public.rpg_rules
   SET body = replace(body,
                'a roll of 50 puts it about 960 feet down.*',
                'a roll of 50 puts it about 960 feet down.*' || chr(10) || chr(10)
                || 'To go under the ground, a piece stands at a cave or a mine and goes in. Under the ground it walks one passage at a time to where the passage leads: on through the Deeps at a good pace (+25% time), along cave passages by crawling and scrambling (+250%: cavers make about half a mile an hour), through the galleries of a mine (+50%), squeezing through where a cave or mine breaks into cave country or the Deeps (+400%), and up or down a shaft at 1,000 feet an hour. The walking day is the same as on the surface: 8 hours, then 16 to camp, in the passage if need be. From below, the ways up into caves and mines are hidden until someone searches the chamber or great hall (1 hour) or has walked them. A piece comes up only at the mouth of a cave or a mine.' || chr(10)
                || '*At Speed 10 the 2,440-foot passage of Storm Grotto takes about 32 minutes, and the 1.26-mile squeeze from its far end into cave country about 2 hours 6 minutes.*'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'world_map'
   AND position('a roll of 50 puts it about 960 feet down.*' IN body) > 0
   AND position('To go under the ground, a piece stands at a cave' IN body) = 0;

