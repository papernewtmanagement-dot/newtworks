CREATE OR REPLACE FUNCTION public.family_default_icon(p_title text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_title ILIKE '%burpee%' THEN '💪'
    WHEN p_title ILIKE '%exercise%' OR p_title ILIKE '%workout%' THEN '🏃'
    WHEN p_title ILIKE '%school%' OR p_title ILIKE '%homework%' THEN '🎒'
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
UPDATE public.family_chores SET icon = public.family_default_icon(title) WHERE icon = '✨';
