-- Walk speed step 6 (Peter 2026-10-09 1B): the background save-ahead also reads the battle grid where a piece stands or goes,
-- so its river lines are kept on the saved map before anyone walks there.
CREATE OR REPLACE FUNCTION public.rpg_map_drain_save(p_fill boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Keeps the rivers a read of the map worked out (rpg_map_drain_cell lists them in rpg.dc_new for the transaction) on the
-- saved map's row of the grid above each (notes: rivers, by cell), so the next read finds them instead of working them
-- out again: the one home of that saving (moved here from rpg_map_view_block, speed step 1, 2026-10-09). p_fill: also
-- save the rows of those grids first where there are none (rpg_map_cache_fill, about 2 seconds a Country grid), as the
-- background read does (rpg_map_view_prepare_run). Returns how many rows took rivers.
DECLARE v_dcell jsonb; v_n integer := 0; v_bl jsonb;
BEGIN
  -- the rivers inside the cells of the grid above that this read worked out (rpg_map_drain_cell, kept for
  -- the transaction, listed in rpg.dc_new by 'grid:x,y': rivers inside Continent cells, streams inside Country cells and brooks
  -- inside Region cells, step 14f3) are saved on the saved map's row of that grid (notes: rivers, by cell), where it
  -- has one, so the next read finds them there instead of working them out again
  SELECT jsonb_object_agg(u.k, current_setting('rpg.dc_' || replace(replace(u.k, ':', '_'), ',', '_'), true)::jsonb) INTO v_dcell
    FROM unnest(string_to_array(nullif(current_setting('rpg.dc_new', true), ''), ' ')) AS u(k);
  IF v_dcell IS NOT NULL AND v_dcell <> '{}'::jsonb THEN
    -- (speed step 1) called in the background (p_fill), the rows of the grids above that are not saved yet are saved
    -- first (rpg_map_cache_fill), so every river worked out finds a row to be kept on; a read of the map in a click
    -- does not pay for that and keeps only what has a row already
    IF p_fill THEN
      PERFORM public.rpg_map_cache_fill(q.lv, q.gx * 12, q.gy * 12, 12, 12)
         FROM (SELECT DISTINCT split_part(e.k, ':', 1)::integer - 1 AS lv, split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx,
                      split_part(e.k, ',', 2)::integer / 12 AS gy
                 FROM jsonb_each(v_dcell) AS e(k, v)) q
        WHERE q.lv >= 2 AND NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = q.lv AND m.gx = q.gx AND m.gy = q.gy);
    END IF;
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('rivers', coalesce(m.notes -> 'rivers', '{}'::jsonb) || n.add)
      FROM (SELECT split_part(e.k, ':', 1)::integer - 1 AS lv, split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx,
                   split_part(e.k, ',', 2)::integer / 12 AS gy, jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_dcell) AS e(k, v) GROUP BY 1, 2, 3) n
     WHERE m.level = n.lv AND m.gx = n.gx AND m.gy = n.gy
       AND NOT coalesce(m.notes -> 'rivers', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
    GET DIAGNOSTICS v_n = ROW_COUNT;
  END IF;
  -- (walk speed step 5, Peter 2026-10-09) the battle grid's river lines a read worked out for each City cell
  -- (rpg_map_river_line, kept for the transaction, listed in rpg.bl_new by 'upto:cx,cy') are kept on the City grid's
  -- row over that cell (notes: blines), so a later read skips working them out; called in the background (p_fill) the
  -- rows missing are saved first (rpg_map_cache_fill), as for the rivers above
  SELECT jsonb_object_agg(u.k, current_setting('rpg.bl_' || replace(replace(u.k, ':', '_'), ',', '_'), true)::jsonb) INTO v_bl
    FROM unnest(string_to_array(nullif(trim(coalesce(current_setting('rpg.bl_new', true), '')), ''), ' ')) AS u(k);
  IF v_bl IS NOT NULL AND v_bl <> '{}'::jsonb THEN
    IF p_fill THEN
      PERFORM public.rpg_map_cache_fill(5, q.gx * 12, q.gy * 12, 12, 12)
         FROM (SELECT DISTINCT split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx, split_part(e.k, ',', 2)::integer / 12 AS gy
                 FROM jsonb_each(v_bl) AS e(k, v)) q
        WHERE NOT EXISTS (SELECT 1 FROM public.rpg_map_cache m WHERE m.level = 5 AND m.gx = q.gx AND m.gy = q.gy);
    END IF;
    UPDATE public.rpg_map_cache m
       SET notes = coalesce(m.notes, '{}'::jsonb) || jsonb_build_object('blines', coalesce(m.notes -> 'blines', '{}'::jsonb) || n.add)
      FROM (SELECT split_part(split_part(e.k, ':', 2), ',', 1)::integer / 12 AS gx, split_part(e.k, ',', 2)::integer / 12 AS gy,
                   jsonb_object_agg(e.k, e.v) AS add
              FROM jsonb_each(v_bl) AS e(k, v) GROUP BY 1, 2) n
     WHERE m.level = 5 AND m.gx = n.gx AND m.gy = n.gy
       AND NOT coalesce(m.notes -> 'blines', '{}'::jsonb) ?& ARRAY(SELECT jsonb_object_keys(n.add));
  END IF;
  RETURN v_n;
END $function$
;
CREATE OR REPLACE FUNCTION public.rpg_map_views_at(p_x bigint, p_y bigint)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
-- The maps of the Maps tab over one world square (p_x, p_y counted from 1, as pieces stand), as the tab names them: its
-- Region grid, City grid and District grid (walk speed step, 2026-10-09; the one home of it, read by the hourly
-- save-ahead for the pieces of the journey and by rpg_map_walk_prepare), and (walk speed step 6) the battle grid of
-- 12 by 12 squares it lies in, so its river lines are worked out and kept on the saved map in the background too.
SELECT ARRAY['4-' || floor((p_x - 1) / 20736.0)::bigint || '-' || floor((p_y - 1) / 20736.0)::bigint,
             '5-' || floor((p_x - 1) / 1728.0)::bigint || '-' || floor((p_y - 1) / 1728.0)::bigint,
             '6-' || floor((p_x - 1) / 144.0)::bigint || '-' || floor((p_y - 1) / 144.0)::bigint,
             's-' || (floor((p_x - 1) / 12.0)::bigint * 12) || '-' || (floor((p_y - 1) / 12.0)::bigint * 12)];
$function$
;

