-- roleplaying_map_hole_bottom: the far end of a hole a place card makes is called the bottom of it (Peter 2026-10-10)
CREATE OR REPLACE FUNCTION public.rpg_map_under_node(p_node text)
 RETURNS TABLE(x bigint, y bigint, depth double precision, sea boolean, name text, site jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Where a node of the world under the ground is (step 12d2), the one way a node is read: x, y = the world square over
-- it, depth = metres down, sea = counted below the level of the sea (a great hall) or below the ground (the rest), name
-- = what it is called (a great hall: its name; a chamber: a chamber of cave country; the mouth or the end of the
-- passage of a cave or a mine: that, with its name; the far end of a hole a place card makes is the bottom of it), site = the cave or mine (as rpg_map_under_edges takes it).
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
       CASE WHEN p_node LIKE 'mouth:%' THEN 'the mouth of ' WHEN s.id LIKE 'hole-%' THEN 'the bottom of ' ELSE 'the far end of ' END || s.name,
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

