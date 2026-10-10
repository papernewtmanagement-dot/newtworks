-- roleplaying_character_list_figure: the Characters list carries each character's map figure (Peter 2026-10-10)
CREATE OR REPLACE FUNCTION public.rpg_character_list()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- The Characters tab list. A creature made for a fight (session_id set) is not on it. Each with its map figure
-- (icon_path, Peter 2026-10-10: the figure on every character card, not a generic picture).
SELECT public.require_login('family');
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kid_id', c.kid_id, 'kid_name', k.name,
           'is_npc', c.is_npc, 'color', c.color, 'vitality_damage', c.vitality_damage, 'is_active', c.is_active,
           'created_at', c.created_at, 'icon_path', c.icon_path) ORDER BY c.is_npc, k.sort_order NULLS LAST, c.created_at), '[]'::jsonb)
  FROM public.rpg_characters c
  LEFT JOIN public.family_kids k ON k.id = c.kid_id
  WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND c.is_active AND c.session_id IS NULL
    AND NOT public.rpg_is_object_card(c.template_id) AND (SELECT public.rpg_can_play());
$function$;

