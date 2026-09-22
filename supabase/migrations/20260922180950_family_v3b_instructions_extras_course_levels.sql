-- Family v3b (2026-09-22): point-by-point instructions for every chore, the extra chores list,
-- and the course pages flattened to Overview + two semesters at the top level.
-- Marie's four checklists (Room clean, Dishes, Clean Bathroom, Wipe Table/Counters) are kept word for word.

INSERT INTO public.family_checklists (agency_id, name, items)
SELECT '126794dd-25ff-47d2-a436-724499733365', v.n, v.i
FROM (VALUES
 ('Unload Dishwasher', ARRAY['Make sure the dishes are clean and dry','Put away the bottom rack first','Then the top rack','Put the silverware in the drawer by type','Close the dishwasher']),
 ('Drink Water', ARRAY['Fill your cup or bottle all the way','Drink all of it','Put your cup back where it goes']),
 ('Water Bottle', ARRAY['Fill your water bottle all the way','Drink the whole bottle','Refill it so it is ready for next time']),
 ('Burpees', ARRAY['Squat down and put your hands on the floor','Jump your feet back into a plank','Lower your chest to the floor','Push back up and jump your feet in','Jump up and clap over your head','Count each one until you reach the number owed']),
 ('Review Verses', ARRAY['Get your verse cards','Read each verse out loud','Say it again without looking','Check yourself and fix any words you missed']),
 ('Tidy Yard', ARRAY['Pick up toys, balls and trash','Put yard toys back where they go','Throw the trash away','Close the gate behind you']),
 ('Clean Kip''s Nose', ARRAY['Get a soft damp cloth or a pet wipe','Gently clean his nose and the folds around it','Pat it dry with a dry cloth','Tell a parent if you see redness or sores']),
 ('Clothes Ready', ARRAY['Check tomorrow''s weather','Pick your outfit, socks and underwear','Lay them out in your room','Put your shoes by the door']),
 ('Feed Dogs', ARRAY['Scoop the right amount into each bowl','Set each bowl in its spot','Close the food bin tight','Stay until they finish so no one steals']),
 ('Feed Dogs (Give Vitamins)', ARRAY['Scoop the right amount into each bowl','Give each dog its vitamin','Set each bowl in its spot','Close the food bin tight','Stay until they finish so no one steals']),
 ('Water Dogs', ARRAY['Dump out the old water','Rinse the bowl','Fill it with fresh water','Do the inside bowl and the outside bowl']),
 ('Tidy Dusty Bathroom', ARRAY['Put away anything left out','Wipe the sink and counter','Hang the towels straight','Empty the trash if it is full']),
 ('Dog Vitamins', ARRAY['Get the vitamins','Give each dog the right one','Watch to make sure they eat it','Put the bottle back']),
 ('Wipe Stove & Microwave', ARRAY['Make sure the stove is cool','Spray and wipe the stovetop','Wipe the microwave inside and out','Dry both with a towel']),
 ('Put Away Food', ARRAY['Put leftovers in containers with lids','Put them in the fridge','Put snacks and boxes back in the pantry','Wipe up any crumbs']),
 ('Tidy Living Room', ARRAY['Pick up toys, books and cups','Put each thing where it belongs','Fold the blankets','Straighten the couch pillows']),
 ('Clean Loft & Spare Room', ARRAY['Pick up everything off the floor','Put each thing where it belongs','Straighten the pillows and blankets','Throw away any trash']),
 ('Empty Kitchen Trash', ARRAY['Tie the bag closed','Take it to the outside bin','Put a new bag in the can','Wipe the lid if it is dirty']),
 ('Vacuum a Room', ARRAY['Pick up everything on the floor first','Vacuum in rows so you do not miss spots','Get the corners and along the walls','Wind up the cord and put the vacuum away']),
 ('Vacuum Stairs', ARRAY['Start at the top step','Vacuum each step and its edge','Work your way down','Put the vacuum away']),
 ('Change Kitchen Towels', ARRAY['Take the used towels to the laundry','Get clean towels','Hang them where they go']),
 ('Sweep Dining Room', ARRAY['Pull the chairs out of the way','Sweep from the edges to the middle','Sweep the pile into the dustpan','Throw it away and push the chairs back in']),
 ('Be Cute', ARRAY['Smile','Giggle','Give hugs']),
 ('Pick Up Poop', ARRAY['Grab bags and the scooper','Walk the whole yard in rows','Bag every pile','Tie the bags and put them in the outside trash','Wash your hands']),
 ('Empty Your Bathroom Trash', ARRAY['Tie up the bag','Take it to the outside bin','Put in a new bag']),
 ('Wash Dog Bowls', ARRAY['Empty the food and water bowls','Wash them in hot soapy water','Rinse them well','Dry them and fill the water bowl again']),
 ('Wash/Dry Your Laundry', ARRAY['Sort lights and darks','Load the washer without stuffing it','Add soap and start it','Move everything to the dryer when it is done','Clean the lint trap']),
 ('Put Your Laundry Away', ARRAY['Fold or hang each piece','Put it in the right drawer or closet','Put the empty basket back']),
 ('Sweep/Vacuum All Floors', ARRAY['Move chairs and small bins out of the way','Vacuum the carpet and sweep the hard floors','Get the corners and under the desks','Put everything back']),
 ('Mop Floors', ARRAY['Sweep or vacuum first','Fill the bucket with warm water and floor cleaner','Mop from the far corner toward the door','Let it dry before anyone walks on it','Rinse the mop and dump the bucket']),
 ('Empty All Trash Bins', ARRAY['Empty every trash bin into one big bag','Put a new liner in each bin','Take the full bag outside']),
 ('Wipe Counters & Microwave', ARRAY['Clear everything off the counter','Spray and wipe the counter','Wipe the microwave inside and out','Put things back neatly']),
 ('Put Away Groceries', ARRAY['Put cold food in the fridge and freezer first','Put pantry food on the right shelves','Put new food behind the old food','Fold or put away the bags']),
 ('House Trash', ARRAY['Empty every trash can in the house into a bag','Put a new liner in each can','Take the bags to the outside bin']),
 ('Wash a Car', ARRAY['Park in the shade','Rinse the whole car','Wash from the top down with soapy water and a mitt','Rinse again','Dry it with towels so there are no spots']),
 ('Clean Car Windows', ARRAY['Spray the glass cleaner on the cloth, not the window','Wipe every window inside and out','Do the mirrors too','Buff dry so there are no streaks']),
 ('Vacuum a Car', ARRAY['Take out the trash and the floor mats','Vacuum the seats, floors and between the cushions','Shake out and vacuum the mats','Put the mats back'])
) v(n, i)
WHERE NOT EXISTS (SELECT 1 FROM public.family_checklists c WHERE c.name = v.n);

-- Point every chore at its instructions (Marie's lists stay on the chores they already cover).
UPDATE public.family_chores c SET checklist_id = cl.id
FROM (VALUES
 ('Unload Dishwasher','Unload Dishwasher'), ('Drink Water','Drink Water'), ('Water Bottle 1','Water Bottle'), ('Water Bottle 2','Water Bottle'),
 ('Burpees','Burpees'), ('Review Verses','Review Verses'), ('Tidy Yard','Tidy Yard'), ('Clean Kip''s Nose','Clean Kip''s Nose'),
 ('Clothes Ready for Tomorrow','Clothes Ready'), ('Clothes Ready','Clothes Ready'), ('Feed Dogs','Feed Dogs'),
 ('Feed Dogs (Give Vitamins)','Feed Dogs (Give Vitamins)'), ('Water Dogs (Inside & Outside)','Water Dogs'),
 ('Tidy Dusty Bathroom','Tidy Dusty Bathroom'), ('Dog Vitamins','Dog Vitamins'), ('Wipe Stove & Microwave','Wipe Stove & Microwave'),
 ('Put Away Food','Put Away Food'), ('Tidy Living Room','Tidy Living Room'), ('Clean Loft & Spare Room','Clean Loft & Spare Room'),
 ('Empty Kitchen Trash','Empty Kitchen Trash'), ('Vacuum Living Room','Vacuum a Room'), ('Vacuum Your Bedroom','Vacuum a Room'),
 ('Vacuum Downstairs','Vacuum a Room'), ('Vacuum Loft & Spare Room','Vacuum a Room'), ('Vacuum Bedrooms','Vacuum a Room'),
 ('Vacuum Stairs','Vacuum Stairs'), ('Change Kitchen Towels','Change Kitchen Towels'), ('Sweep Dining Room','Sweep Dining Room'),
 ('Be Cute','Be Cute'), ('Pick Up Poop','Pick Up Poop'), ('Empty Your Bathroom Trash','Empty Your Bathroom Trash'),
 ('Wash Dog Bowls','Wash Dog Bowls'), ('Wash/Dry Your Laundry','Wash/Dry Your Laundry'), ('Put Your Laundry Away','Put Your Laundry Away'),
 ('Sweep/Vacuum All Floors','Sweep/Vacuum All Floors'), ('Mop Downstairs','Mop Floors'), ('Mop All Floors','Mop Floors'),
 ('Empty All Trash Bins','Empty All Trash Bins'), ('Wipe Counters & Microwave','Wipe Counters & Microwave'),
 ('Put Away Groceries','Put Away Groceries'), ('House Trash','House Trash')
) v(title, list)
JOIN public.family_checklists cl ON cl.name = v.list
WHERE c.title = v.title AND c.checklist_id IS NULL;

-- Extra chores. Prices are a starting point for a parent to adjust. Each comes back 14 days after it is done.
INSERT INTO public.family_chores (agency_id, kid_id, title, frequency, pay, repeat_days, checklist_id, sort_order, active_from)
SELECT '126794dd-25ff-47d2-a436-724499733365', NULL, v.t, 'extra', v.p, 14, cl.id, v.o, DATE '2026-09-22'
FROM (VALUES
 ('Wash the RAV4', 5.00, 'Wash a Car', 1), ('Wash the Highlander', 6.00, 'Wash a Car', 2), ('Wash the Corolla', 5.00, 'Wash a Car', 3),
 ('Clean the RAV4 Windows', 2.00, 'Clean Car Windows', 4), ('Clean the Highlander Windows', 2.50, 'Clean Car Windows', 5), ('Clean the Corolla Windows', 2.00, 'Clean Car Windows', 6),
 ('Vacuum the RAV4', 3.00, 'Vacuum a Car', 7), ('Vacuum the Highlander', 4.00, 'Vacuum a Car', 8), ('Vacuum the Corolla', 3.00, 'Vacuum a Car', 9)
) v(t, p, l, o)
JOIN public.family_checklists cl ON cl.name = v.l
WHERE NOT EXISTS (SELECT 1 FROM public.family_chores x WHERE x.frequency = 'extra' AND x.title = v.t);

-- Course: Overview, Semester 1, Semester 2 side by side at the top; class pages stay under their semester.
UPDATE public.manuals SET title = 'Overview', sort_order = 1, updated_at = now()
WHERE manual_type = 'financial_literacy' AND confluence_page_id = '2078179331';
UPDATE public.manuals SET parent_page_id = NULL, sort_order = 2, updated_at = now()
WHERE manual_type = 'financial_literacy' AND confluence_page_id = '2077982724';
UPDATE public.manuals SET parent_page_id = NULL, sort_order = 3, updated_at = now()
WHERE manual_type = 'financial_literacy' AND confluence_page_id = '2078834700';
