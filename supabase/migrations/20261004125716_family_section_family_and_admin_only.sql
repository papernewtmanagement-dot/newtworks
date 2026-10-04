-- Peter 2026-10-04: every link below the last line of the sidebar (Family, Inventory, Meal Plan,
-- Roleplaying, Dancer, Course, Gridstrike) is for owner, admin and the family login only.
-- An audit found two gaps, closed here:
--   1. Roleplaying pictures (bucket rpg-images) could be read by any signed-in login. Now the
--      same people who can play: the family login, owner and admin (rpg_can_play()).
--   2. family_champs_ack() ran for any signed-in login. It now checks the login first, the same
--      way the other family functions do.
ALTER POLICY rpg_images_read ON storage.objects
  USING (bucket_id = 'rpg-images' AND (SELECT public.rpg_can_play()));

CREATE OR REPLACE FUNCTION public.family_champs_ack(p_week_start date)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.require_login('family');
  UPDATE public.family_settings
     SET champs_announced_week = GREATEST(COALESCE(champs_announced_week, p_week_start), p_week_start),
         updated_at = now();
$function$;

