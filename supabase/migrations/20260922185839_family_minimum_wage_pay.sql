-- Peter 2026-09-22: paid chores move to minimum-wage pay ($7.25/hr), from a realistic minutes estimate per chore.
ALTER TABLE public.family_chores ADD COLUMN IF NOT EXISTS est_minutes smallint CHECK (est_minutes IS NULL OR est_minutes > 0);
ALTER TABLE public.family_settings ADD COLUMN IF NOT EXISTS hourly_rate numeric(6,2) NOT NULL DEFAULT 7.25;

-- The one pay rule: minutes x hourly rate, rounded to the nearest 5 cents.
CREATE OR REPLACE FUNCTION public.family_minutes_pay(p_minutes numeric, p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365')
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  SELECT round(p_minutes * COALESCE(s.hourly_rate, 7.25) / 60 / 0.05) * 0.05
  FROM (SELECT 1) one LEFT JOIN public.family_settings s ON s.agency_id = p_agency_id;
$function$;
GRANT EXECUTE ON FUNCTION public.family_minutes_pay(numeric, uuid) TO authenticated, service_role;

UPDATE public.family_chores c SET est_minutes = v.m
FROM (VALUES
  -- Becca
  ('d18d4f80-2ec8-43d8-8a3a-4f410b31ef85'::uuid, 7),   -- Unload Dishwasher
  ('eb5eaf28-0ada-43c0-80dd-0a582062a1b1', 10),        -- Breakfast Dishes
  ('2f557184-4f73-4087-8517-4ce022043a32', 10),        -- Lunch Dishes
  ('9e6db89d-743f-480a-b706-33288f414eb7', 20),        -- Dinner Dishes
  ('0512285c-379e-4dc4-a29c-586334bc0d92', 10),        -- Tidy Yard
  ('fea872c0-dbea-425a-8916-15c5cd42bd9e', 15),        -- Pick Up Poop
  ('11733314-f4c9-412c-a325-fb16a9c904b9', 2),         -- Empty Your Bathroom Trash
  ('ccaa6db4-3bf7-40bb-b3d2-3cc70941f860', 25),        -- Clean Your Bathroom (Change Mat)
  ('1cd85e1e-a104-4716-9cd9-cd380e5f1b1b', 5),         -- Wash Dog Bowls
  ('5c638e7d-33e0-442e-8409-9b8cea5714bc', 15),        -- Office Sweep/Vacuum All Floors
  ('a1eb1abb-9978-42df-b53a-9399237faf93', 15),        -- Office Clean Bathroom
  -- Bella
  ('a80baad7-bf67-48e4-a62e-7c39d2633de0', 3),         -- Feed Dogs
  ('0e116b58-73d7-4a3f-8de6-922d1b82051a', 3),         -- Water Dogs (morning)
  ('0cfc8b3e-c0cb-4209-bf31-16c6edb5a426', 3),         -- Water Dogs (afternoon)
  ('155d9dc5-b71c-4a6f-9ed9-db26c79c66ef', 3),         -- Water Dogs (evening)
  ('0d1f6c17-2b3b-4ea9-b50d-33635ad90aa4', 5),         -- Tidy Dusty Bathroom
  ('45c99940-d417-4f53-837c-6919b421939b', 5),         -- Wipe Table & Counters
  ('bc5f016e-f291-4b31-982a-3f3e7f220c63', 5),         -- Wipe Table & Counters
  ('77b546b1-6c4f-4ce9-b539-f3ce44e4a449', 5),         -- Wipe Tables & Counters
  ('5f0dac33-81d3-4ecf-836d-aec6b2bdfc95', 2),         -- Dog Vitamins
  ('77f7ef41-cd6e-4af5-9670-322c65e02862', 4),         -- Feed Dogs (Give Vitamins)
  ('6deccd5a-c5e5-4e30-93ea-8d709c5bd221', 5),         -- Wipe Stove & Microwave
  ('f577976e-f953-4e2f-83ae-4953abac8326', 5),         -- Put Away Food
  ('f80491f9-b6f4-4e75-bd5a-943b503949f0', 15),        -- Pick Up Poop
  ('9c06e019-9235-4f91-9edc-32cbeec1739f', 20),        -- Vacuum Downstairs
  ('b93e440a-61ff-4a44-9f0f-4674a4e3ec9a', 10),        -- Vacuum Stairs
  ('c76e10bc-87ea-4bd4-9ac9-0dcb0907abe7', 15),        -- Vacuum Loft & Spare Room
  ('1011bfa2-268b-4a2c-955d-3630f736e08d', 20),        -- Mop Downstairs
  ('befa4692-6a97-4a93-b012-ce929bff78a2', 5),         -- Office Empty All Trash Bins
  ('771310d5-c5d3-411c-9454-d83a3fb86fb0', 10),        -- Office Wipe Counters & Microwave & Stove
  ('84a5bdc1-f1dc-4084-9184-ce6608d1900c', 15),        -- Office Mop All Floors
  -- Elliott
  ('fa87c78e-54b2-45f5-9308-202a9861523c', 10),        -- Tidy Living Room
  ('aec33b4a-3f9c-4e6a-b50b-0dadf7ae0030', 10),        -- Clean Loft & Spare Room
  ('7e06c0e4-4c10-4b6c-b993-c6de63941e50', 3),         -- Empty Kitchen Trash
  ('518afd57-43fa-4dbb-8107-c05a390c5ed3', 10),        -- Put Away Groceries
  ('0c0c81af-daf1-4022-9ba5-3d15d32170b2', 10),        -- House Trash
  ('ad3120bd-e576-4bb4-b68c-1ba0637e92a8', 20),        -- Vacuum Bedrooms
  ('7090605c-fc9d-4529-a1e4-218bd7d2f4e7', 25),        -- Clean Bathroom
  -- Olive
  ('8bbe9910-d988-49f6-9a67-ff4767571b57', 10),        -- Vacuum Living Room
  ('c8164fc9-7265-4e9a-a427-c9a6313ddf05', 2),         -- Change Kitchen Towels
  ('8123231e-7014-4ae8-b568-998dd734f9b8', 5),         -- Sweep Dining Room
  -- Extras
  ('829b90cc-43eb-478e-a5f7-7db2c109831e', 40),        -- Wash the RAV4
  ('4a4ffbdf-eb10-46d4-9086-b2d372686e3f', 50),        -- Wash the Highlander
  ('4f0ae60f-8adc-4a2f-b0e9-3293560032b6', 40),        -- Wash the Corolla
  ('35be96b3-749e-485d-9515-c989c378faab', 10),        -- Clean the RAV4 Windows
  ('2a413dc5-27e9-4f3f-a5f6-745f7feca5a9', 15),        -- Clean the Highlander Windows
  ('d068d846-575e-4726-9080-165b956e69a6', 10),        -- Clean the Corolla Windows
  ('c1ac7e0d-5ebe-47ef-8d00-d63f7ff968b8', 15),        -- Vacuum the RAV4
  ('c4784045-a8d4-4e64-a177-36adedb8267d', 20),        -- Vacuum the Highlander
  ('66759185-5198-4c20-9970-2f35c19b6036', 15)         -- Vacuum the Corolla
) AS v(id, m)
WHERE c.id = v.id;

UPDATE public.family_chores SET pay = public.family_minutes_pay(est_minutes, agency_id)
WHERE est_minutes IS NOT NULL AND pay > 0;
