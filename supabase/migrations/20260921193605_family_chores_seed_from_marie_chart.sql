-- Seed from Marie's "Kids Chores" email (2026-09-18) and its Chore Charts.xlsx.
-- Titles and amounts exactly as written in the chart.
INSERT INTO public.family_settings (agency_id) VALUES ('126794dd-25ff-47d2-a436-724499733365') ON CONFLICT DO NOTHING;

INSERT INTO public.family_kids (agency_id, name, sort_order, tracking_start)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.n, v.o, DATE '2026-09-21'
FROM (VALUES ('Becca',1),('Bella',2),('Goose',3),('Duck',4)) v(n,o)
WHERE NOT EXISTS (SELECT 1 FROM public.family_kids k WHERE k.name = v.n);

INSERT INTO public.family_checklists (agency_id, name, items)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.n, v.i
FROM (VALUES
 ('Room clean', ARRAY['Bed made','Floor clear','Shelves and dresser tidy','Closet clean','Drawers tidy','Bathroom tidy']),
 ('Dishes (breakfast/lunch/dinner)', ARRAY['Dish mat clear','Dishes washed','Dishwasher loaded','Garbage disposal run','Sink and counter clean (clear of clutter)']),
 ('Clean Bathroom', ARRAY['Clean toilet bowl','Wipe down whole toilet','Clean sink and counter','Clean mirror','Scrub down shower/tub','Sweep and mop floor','Empty trash','Restock hand soap and toilet paper']),
 ('Wipe Table/Counters', ARRAY['Move all items before wiping each surface','Clean toaster','Wipe down coffee maker'])
) v(n,i)
WHERE NOT EXISTS (SELECT 1 FROM public.family_checklists c WHERE c.name = v.n);

WITH src(kid, title, freq, pod, grp, pay, cl, ord) AS (VALUES
 ('Becca','Bedroom Clean','daily','morning',NULL,0,'Room clean',1),
 ('Becca','Unload Dishwasher','daily','morning',NULL,0.30,NULL,2),
 ('Becca','Breakfast Dishes','daily','morning',NULL,0.30,'Dishes (breakfast/lunch/dinner)',3),
 ('Becca','DRINK WATER','daily','morning',NULL,0,NULL,4),
 ('Becca','BURPEES','daily','morning',NULL,0,NULL,5),
 ('Becca','REVIEW VERSES','daily','morning',NULL,0,NULL,6),
 ('Becca','Lunch Dishes','daily','afternoon',NULL,0.30,'Dishes (breakfast/lunch/dinner)',7),
 ('Becca','BURPEES','daily','afternoon',NULL,0,NULL,8),
 ('Becca','REVIEW VERSES','daily','afternoon',NULL,0,NULL,9),
 ('Becca','Dinner Dishes','daily','evening',NULL,0.50,'Dishes (breakfast/lunch/dinner)',10),
 ('Becca','Tidy Yard','daily','evening',NULL,0.50,NULL,11),
 ('Becca','Clean Kip''s Nose','daily','evening',NULL,0,NULL,12),
 ('Becca','Clothes Ready for Tomorrow','daily','evening',NULL,0,NULL,13),
 ('Becca','Bedroom Clean','daily','evening',NULL,0,'Room clean',14),
 ('Becca','DRINK WATER','daily','evening',NULL,0,NULL,15),
 ('Becca','Pick up Poop','weekly',NULL,NULL,0.50,NULL,20),
 ('Becca','Empty Your Bathroom Trash','weekly',NULL,NULL,0.20,NULL,21),
 ('Becca','Vacuum Your Bedroom','weekly',NULL,NULL,0,NULL,22),
 ('Becca','Clean Your Bathroom (Change Mat)','weekly',NULL,NULL,3.50,'Clean Bathroom',23),
 ('Becca','Wash Dog Bowls','weekly',NULL,NULL,2.00,NULL,24),
 ('Becca','Wash/Dry Your Laundry','weekly',NULL,NULL,0,NULL,25),
 ('Becca','Put Your Laundry Away','weekly',NULL,NULL,0,NULL,26),
 ('Becca','Sweep/Vacuum All Floors','weekly',NULL,'OFFICE',2.00,NULL,30),
 ('Becca','Clean Bathroom','weekly',NULL,'OFFICE',3.00,'Clean Bathroom',31),

 ('Bella','Bedroom Clean','daily','morning',NULL,0,'Room clean',1),
 ('Bella','Feed Dogs','daily','morning',NULL,0.10,NULL,2),
 ('Bella','Water Dogs (Inside & Outside)','daily','morning',NULL,0.20,NULL,3),
 ('Bella','Tidy Dusty Bathroom','daily','morning',NULL,0.10,NULL,4),
 ('Bella','Wipe Table & Counters','daily','morning',NULL,0.20,'Wipe Table/Counters',5),
 ('Bella','BURPEES','daily','morning',NULL,0,NULL,6),
 ('Bella','REVIEW VERSES','daily','morning',NULL,0,NULL,7),
 ('Bella','DRINK WATER','daily','morning',NULL,0,NULL,8),
 ('Bella','Wipe Table & Counters','daily','afternoon',NULL,0.20,'Wipe Table/Counters',9),
 ('Bella','Water Dogs (Inside & Outside)','daily','afternoon',NULL,0.10,NULL,10),
 ('Bella','Dog Vitamins','daily','afternoon',NULL,0.10,NULL,11),
 ('Bella','BURPEES','daily','afternoon',NULL,0,NULL,12),
 ('Bella','REVIEW VERSES','daily','afternoon',NULL,0,NULL,13),
 ('Bella','Feed Dogs (give vitamins)','daily','evening',NULL,0.10,NULL,14),
 ('Bella','Water Dogs (Inside & Outside)','daily','evening',NULL,0.20,NULL,15),
 ('Bella','Wipe Stove & Microwave','daily','evening',NULL,0.20,NULL,16),
 ('Bella','Wipe Tables & Counters','daily','evening',NULL,0.10,'Wipe Table/Counters',17),
 ('Bella','Put Away Food','daily','evening',NULL,0.10,NULL,18),
 ('Bella','Pick up Poop','weekly',NULL,NULL,0.50,NULL,20),
 ('Bella','Vacuum Downstairs','weekly',NULL,NULL,3.00,NULL,21),
 ('Bella','Vacuum Stairs','weekly',NULL,NULL,1.00,NULL,22),
 ('Bella','Vacuum Loft & Spare Room','weekly',NULL,NULL,3.00,NULL,23),
 ('Bella','Mop Downstairs','weekly',NULL,NULL,2.00,NULL,24),
 ('Bella','Vacuum Your Bedroom','weekly',NULL,NULL,0,NULL,25),
 ('Bella','Wash/Dry Your Laundry','weekly',NULL,NULL,0,NULL,26),
 ('Bella','Put Your Laundry Away','weekly',NULL,NULL,0,NULL,27),
 ('Bella','Empty All Trash Bins','weekly',NULL,'OFFICE',2.00,NULL,30),
 ('Bella','Wipe Counters & Microwave','weekly',NULL,'OFFICE',0.10,NULL,31),
 ('Bella','Mop all Floors','weekly',NULL,'OFFICE',2.00,NULL,32),

 ('Goose','Clean Your Bedroom','daily','morning',NULL,0,'Room clean',1),
 ('Goose','WATER BOTTLE 1','daily','morning',NULL,0,NULL,2),
 ('Goose','BURPEES','daily','morning',NULL,0,NULL,3),
 ('Goose','REVIEW VERSES','daily','morning',NULL,0,NULL,4),
 ('Goose','Tidy Living Room','daily','afternoon',NULL,0.30,NULL,5),
 ('Goose','BURPEES','daily','afternoon',NULL,0,NULL,6),
 ('Goose','REVIEW VERSES','daily','afternoon',NULL,0,NULL,7),
 ('Goose','Clean Loft & Spare Room','daily','evening',NULL,0.50,NULL,8),
 ('Goose','Empty Kitchen Trash','daily','evening',NULL,0.70,NULL,9),
 ('Goose','Clothes Ready','daily','evening',NULL,0,NULL,10),
 ('Goose','Bedroom Clean','daily','evening',NULL,0,'Room clean',11),
 ('Goose','WATER BOTTLE 2','daily','evening',NULL,0,NULL,12),
 ('Goose','Put Away Groceries','weekly',NULL,NULL,1.00,NULL,20),
 ('Goose','House Trash','weekly',NULL,NULL,2.00,NULL,21),
 ('Goose','Vacuum Bedrooms','weekly',NULL,NULL,2.00,NULL,22),
 ('Goose','Clean Bathroom','weekly',NULL,NULL,2.00,'Clean Bathroom',23),

 ('Duck','Clean Your Bedroom','daily','morning',NULL,0,'Room clean',1),
 ('Duck','WATER BOTTLE 1','daily','morning',NULL,0,NULL,2),
 ('Duck','BURPEES','daily','morning',NULL,0,NULL,3),
 ('Duck','REVIEW VERSES','daily','morning',NULL,0,NULL,4),
 ('Duck','Vacuum Living Room','daily','afternoon',NULL,0.25,NULL,5),
 ('Duck','BURPEES','daily','afternoon',NULL,0,NULL,6),
 ('Duck','REVIEW VERSES','daily','afternoon',NULL,0,NULL,7),
 ('Duck','Change Kitchen Towels','daily','evening',NULL,0.10,NULL,8),
 ('Duck','Sweep Dining Room','daily','evening',NULL,1.00,NULL,9),
 ('Duck','Clothes Ready','daily','evening',NULL,0,NULL,10),
 ('Duck','Bedroom Clean','daily','evening',NULL,0,'Room clean',11),
 ('Duck','WATER BOTTLE 2','daily','evening',NULL,0,NULL,12)
)
INSERT INTO public.family_chores (agency_id, kid_id, title, frequency, part_of_day, group_label, pay, checklist_id, sort_order, active_from)
SELECT '126794dd-25ff-47d2-a436-724499733365', k.id, s.title, s.freq, s.pod, s.grp, s.pay::numeric, c.id, s.ord, DATE '2026-09-21'
FROM src s
JOIN public.family_kids k ON k.name = s.kid
LEFT JOIN public.family_checklists c ON c.name = s.cl
WHERE NOT EXISTS (SELECT 1 FROM public.family_chores x WHERE x.kid_id = k.id);
