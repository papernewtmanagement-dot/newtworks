-- Peter 2026-09-22: Becca and Bella's paper charts cover Sat–Mon, so their tracking starts 9/19 like Elliott's.
UPDATE public.family_kids SET tracking_start = DATE '2026-09-19' WHERE name IN ('Becca', 'Bella');
UPDATE public.family_chores c SET active_from = DATE '2026-09-19'
  FROM public.family_kids k WHERE k.id = c.kid_id AND k.name IN ('Becca', 'Bella') AND c.active_from = DATE '2026-09-21';

-- Turtle tank: a weekly Friday chore for Becca (paid) and Elliott (done with her, unpaid).
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
    WHEN p_title ILIKE '%turtle%' THEN '🐢'
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

INSERT INTO public.family_checklists (agency_id, name, items)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'Turtle Tank',
       ARRAY['Scoop out waste and any food the turtle did not eat',
             'Take out about a quarter of the water and refill with treated water',
             'Wipe the glass and rinse the filter in the old tank water',
             'Wash your hands with soap when you finish']
WHERE NOT EXISTS (SELECT 1 FROM public.family_checklists WHERE name = 'Turtle Tank');

INSERT INTO public.family_chores (agency_id, kid_id, title, frequency, due_dow, pay, est_minutes, checklist_id, sort_order, active_from)
SELECT k.agency_id, k.id, 'Turtle Tank', 'weekly', 5,
       CASE WHEN k.name = 'Becca' THEN public.family_minutes_pay(30, k.agency_id) ELSE 0 END,
       CASE WHEN k.name = 'Becca' THEN 30 END,
       (SELECT id FROM public.family_checklists WHERE name = 'Turtle Tank'), 30, DATE '2026-09-19'
FROM public.family_kids k
WHERE k.name IN ('Becca', 'Elliott')
  AND NOT EXISTS (SELECT 1 FROM public.family_chores c WHERE c.kid_id = k.id AND c.title = 'Turtle Tank');
