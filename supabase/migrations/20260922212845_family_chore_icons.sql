-- Peter 2026-09-22: every chore gets an icon. Picked from the title; a new chore gets one automatically.
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS icon text;

CREATE OR REPLACE FUNCTION public.family_default_icon(p_title text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_title ILIKE '%burpee%' THEN '💪'
    WHEN p_title ILIKE '%verse%' THEN '📖'
    WHEN p_title ILIKE '%babysit%' THEN '👶'
    WHEN p_title ILIKE '%cute%' THEN '🥰'
    WHEN p_title ILIKE '%poop%' THEN '💩'
    WHEN p_title ILIKE '%dog%' OR p_title ILIKE '%kip%' THEN '🐶'
    WHEN p_title ILIKE '%water%' THEN '💧'
    WHEN p_title ILIKE '%rav4%' OR p_title ILIKE '%highlander%' OR p_title ILIKE '%corolla%' OR p_title ILIKE '% car%' THEN '🚗'
    WHEN p_title ILIKE '%dish%' THEN '🍽️'
    WHEN p_title ILIKE '%trash%' THEN '🗑️'
    WHEN p_title ILIKE '%mop%' THEN '🪣'
    WHEN p_title ILIKE '%vacuum%' OR p_title ILIKE '%sweep%' THEN '🧹'
    WHEN p_title ILIKE '%bathroom%' THEN '🛁'
    WHEN p_title ILIKE '%laundry%' OR p_title ILIKE '%towel%' THEN '🧺'
    WHEN p_title ILIKE '%clothes%' THEN '👕'
    WHEN p_title ILIKE '%bedroom%' THEN '🛏️'
    WHEN p_title ILIKE '%grocer%' THEN '🛒'
    WHEN p_title ILIKE '%food%' THEN '🥫'
    WHEN p_title ILIKE '%yard%' THEN '🌳'
    WHEN p_title ILIKE '%counter%' OR p_title ILIKE '%table%' OR p_title ILIKE '%stove%' OR p_title ILIKE '%microwave%' THEN '🧽'
    WHEN p_title ILIKE '%living room%' OR p_title ILIKE '%loft%' OR p_title ILIKE '%tidy%' THEN '🛋️'
    ELSE '✨'
  END;
$function$;

CREATE OR REPLACE FUNCTION public.family_chores_set_icon()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.icon IS NULL OR NEW.icon = '' THEN NEW.icon := public.family_default_icon(NEW.title); END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS family_chores_set_icon ON public.family_chores;
CREATE TRIGGER family_chores_set_icon BEFORE INSERT ON public.family_chores
  FOR EACH ROW EXECUTE FUNCTION public.family_chores_set_icon();

UPDATE public.family_chores SET icon = public.family_default_icon(title) WHERE icon IS NULL;
