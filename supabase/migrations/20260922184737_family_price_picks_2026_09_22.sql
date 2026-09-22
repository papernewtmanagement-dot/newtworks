-- Peter's price picks 2026-09-22.
UPDATE public.family_checklists
   SET name = 'Wipe Counters & Microwave & Stove',
       items = ARRAY['Clear everything off the counter','Spray and wipe the counter','Wipe the microwave inside and out','Make sure the stove is cool, then spray and wipe the stovetop','Put things back neatly']
 WHERE id = '3fc9b746-bc4c-449f-a1be-40d4b3e2f17c';

UPDATE public.family_chores SET title = 'Wipe Counters & Microwave & Stove', pay = 1.00
 WHERE id = '771310d5-c5d3-411c-9454-d83a3fb86fb0';

UPDATE public.family_chores SET pay = 0.75 WHERE id IN ('eb5eaf28-0ada-43c0-80dd-0a582062a1b1', '2f557184-4f73-4087-8517-4ce022043a32');
UPDATE public.family_chores SET pay = 1.00 WHERE id = '9e6db89d-743f-480a-b706-33288f414eb7';
