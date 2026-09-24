-- Roleplaying module, step 4 of the build plan (persistent_memory spec
-- "Roleplaying module — build plan + state", project roleplaying): the Rules tab.
-- One read for the whole tab, from the same rows the character sheet reads:
--   rules        every rpg_rules row, verbatim, in sort order
--   stats        every rpg_stat_definitions row with its formula spelled out by
--                rpg_formula_text(), the same text the sheet shows
--   level_costs  skill points to go from each level to the next, from rpg_level_cost()
--   settings     the numbers the rules run on (rpg_settings), game master only
-- The needed-roll calculator on the tab calls rpg_needed() itself, so it can never
-- disagree with a real roll. Nothing destructive: one new function, no tables.

CREATE OR REPLACE FUNCTION public.rpg_rules_page(p_max_level integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
SELECT public.require_login('family');
  WITH gm AS (SELECT public.family_is_parent() AS is_gm),
       names AS (
         SELECT coalesce(jsonb_object_agg(d.key, d.name), '{}'::jsonb) AS m
         FROM public.rpg_stat_definitions d
         WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365')
  SELECT jsonb_build_object(
    'is_gm', gm.is_gm,
    'rules', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'key', r.key, 'title', r.title, 'body', r.body, 'source', r.source)
                ORDER BY r.sort_order, r.key), '[]'::jsonb)
              FROM public.rpg_rules r
              WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
    'stats', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'key', d.key, 'name', d.name, 'abbr', d.abbr, 'grp', d.grp, 'kind', d.kind,
                'trainable', d.trainable, 'default_value', d.default_value,
                'formula_text', public.rpg_formula_text(d.formula, names.m))
                ORDER BY d.sort_order, d.key), '[]'::jsonb)
              FROM public.rpg_stat_definitions d CROSS JOIN names
              WHERE d.agency_id = '126794dd-25ff-47d2-a436-724499733365'),
    'level_costs', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                      'level', l, 'next_level', l + 1, 'points', public.rpg_level_cost(l))
                      ORDER BY l), '[]'::jsonb)
                    FROM generate_series(0, greatest(coalesce(p_max_level, 30), 1)) AS l),
    'crit_chance', public.rpg_setting('crit_chance'),
    'default_difficulty', public.rpg_setting('default_difficulty'),
    'level_cost_multiplier', public.rpg_setting('level_cost_multiplier'),
    'settings', CASE WHEN gm.is_gm THEN
                  (SELECT coalesce(jsonb_agg(jsonb_build_object('key', s.key, 'value', s.value, 'label', s.label)
                     ORDER BY s.key), '[]'::jsonb)
                   FROM public.rpg_settings s
                   WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365')
                ELSE '[]'::jsonb END)
  FROM gm
  WHERE (SELECT public.rpg_can_play());
$function$;

GRANT EXECUTE ON FUNCTION public.rpg_rules_page(integer) TO authenticated;
