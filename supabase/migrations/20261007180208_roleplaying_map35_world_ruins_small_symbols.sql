-- Step 14d (Peter 2026-10-07 16:30): the World grid shows a handful more ruins. Besides its own landmarks it shows the
-- Continent grid's ruined cities at least map_world_ruin_across (2,200 m) across: 7 more, 9 in all. A site on the sea
-- is no longer worked out (nothing stands there), and the World grid reads the Continent cells under its sites in one
-- block. Smaller World-grid symbols are the page's part. One new setting; no drops, no new tables.

INSERT INTO public.rpg_settings (agency_id, key, value, label) VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'map_world_ruin_across', 2200, 'World grid (step 14d): it also shows the Continent grid''s ruined cities at least this many metres across');

CREATE OR REPLACE FUNCTION public.rpg_map_landmark_sites(p_level integer, p_x0 integer, p_y0 integer, p_cols integer, p_rows integer)
 RETURNS TABLE(id text, rank integer, x bigint, y bigint, rolls integer[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a landmark could stand on a block of any grid down to the District grid (step 12b), worked out when asked and
-- never stored: the sites of every rank from 1 (the World grid) down to the rank of the grid itself whose spot lies in
-- the block (rpg_map_landmark_site), each with its rank and its rolls (rpg_map_landmark_rolls). A grid of level L
-- shows the landmarks of ranks 1 to L: few on the world, more at each level down (Peter 2026-10-03 17:28); the World
-- grid also gets the sites of rank 2, for the Continent grid's biggest ruined cities (step 14d, rpg_map_landmarks). On the
-- battle grid (step 12b2) a block of squares gets the sites of every rank whose landmark could reach into it: the spot
-- within half the width of the widest landmark or place to go into of its rank (rpg_map_landmark_kinds,
-- rpg_map_location_kinds; step 12c), and one square, of the block;
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
              FROM (SELECT * FROM public.rpg_map_landmark_kinds() UNION ALL SELECT * FROM public.rpg_map_location_kinds()) k
             WHERE k.rank <= greatest(least(p_level, 6), CASE WHEN p_level = 1 THEN 2 ELSE 0 END) GROUP BY k.rank),
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
-- A site is passed over before any ground is read (step 12b2) when neither its landmark nor its place to go into (step
-- 12c) could stand on any ground by its second roll (rpg_map_site_what: the most readily it stands anywhere), and on the
-- battle grid (level 7) when neither footprint, half its width and one square, can reach the block; so the battle grid
-- reads ground only for what may truly stand on it. kind and the rest are a place to go into where no landmark stands
-- and one does (rpg_map_landmark_make).
-- The World grid (step 14d, Peter 2026-10-07: only two ruins there, it should have a handful more) shows its own
-- landmarks and the Continent grid's ruined cities at least map_world_ruin_across metres across (2,200 m: 7 of the 58,
-- 2.2 to 2.9 km), the cities big enough to be marked on a map of the world; nothing else of rank 2 shows there.
WITH s AS MATERIALIZED (
       SELECT t.*, greatest(t.rank, 2) AS dl
         FROM public.rpg_map_landmark_sites(p_level, p_x0, p_y0, p_cols, p_rows) t
        CROSS JOIN (SELECT v.value::double precision AS sq FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_square_m') q
        WHERE (p_level > 1 OR t.rank = 1
               OR EXISTS (SELECT 1 FROM public.rpg_map_site_what('landmark', 2, t.rolls[1:6]) w
                           WHERE w.kind = 'ruins'
                             AND w.across >= (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_world_ruin_across')::double precision))
          AND EXISTS (
                SELECT 1
                  FROM (VALUES ('landmark', t.rolls[1:6]), ('location', t.rolls[7:12])) AS c(cl, r)
                 CROSS JOIN LATERAL public.rpg_map_site_what(c.cl, t.rank, c.r) w
                 WHERE (c.r[2] - 0.5) / 100 < (SELECT v.value FROM public.rpg_settings v WHERE v.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND v.key = 'map_' || c.cl || '_share_' || t.rank)::double precision
                                              * (SELECT max(e.value::double precision) FROM jsonb_each_text(w.grounds) e)
                   AND (p_level < 7
                        OR sqrt(power(greatest(p_x0 - t.x, 0, t.x - (p_x0 + p_cols - 1)), 2) + power(greatest(p_y0 - t.y, 0, t.y - (p_y0 + p_rows - 1)), 2))
                           <= w.across / 2 / q.sq + 1))),
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
         FROM (SELECT DISTINCT sc.dl, sc.cx, sc.cy, sc.across FROM sc WHERE sc.dl <> p_level AND NOT (p_level = 1 AND sc.dl = 2)) d
        CROSS JOIN LATERAL public.rpg_map_kinds(d.dl, mod(mod(d.cx, d.across) + d.across, d.across)::integer, d.cy, 1, 1) k
       UNION ALL
       -- the World grid (step 14d): the Continent cells under its sites read in one block, from the saved map
       SELECT d.dl, d.cx, d.cy, c.kind
         FROM (SELECT DISTINCT sc.dl, sc.cx, sc.cy, sc.across FROM sc WHERE p_level = 1 AND sc.dl = 2) d
         JOIN (SELECT c.* FROM public.rpg_map_ladder() l CROSS JOIN LATERAL public.rpg_map_cells(2, 0, 0, l.across::integer, l.down::integer) c
                WHERE l.level = 2 AND p_level = 1) c
           ON c.x = mod(mod(d.cx, d.across) + d.across, d.across) AND c.y = d.cy),
     -- each site with the ground it stands on
     gr AS MATERIALIZED (
       SELECT sc.*, coalesce(own.kind, far.kind) AS ground
         FROM sc
         LEFT JOIN own ON sc.dl = p_level AND own.x = sc.cx AND own.y = sc.cy
         LEFT JOIN far ON far.dl = sc.dl AND far.cx = sc.cx AND far.cy = sc.cy),
     -- what stands at each (step 14d: nothing stands on the sea, as no kind's grounds hold it, so a site there is not
     -- worked out)
     mk AS MATERIALIZED (
       SELECT gr.id, m.*
         FROM gr CROSS JOIN LATERAL public.rpg_map_landmark_make(gr.rank, gr.x, gr.y, gr.rolls, gr.ground) m
        WHERE gr.ground IS DISTINCT FROM 'sea')
SELECT gr.id, gr.rank, m.kind, m.icon, m.words, m.name, gr.x, gr.y, m.height, m.across
  FROM gr
  LEFT JOIN mk m ON m.id = gr.id
 WHERE p_level > 1 OR gr.rank = 1 OR m.kind = 'ruins';
$function$;

