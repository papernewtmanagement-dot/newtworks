-- Peter 2026-09-22: a fact of the day above the chore list, and a shower timer on each kid's screen.

-- 1. Facts. Kid-friendly, true, and nothing that works against Christian principles.
CREATE TABLE IF NOT EXISTS public.family_facts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365' REFERENCES public.agency(id),
  sort_order integer NOT NULL,
  fact text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.family_facts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_facts_family_read ON public.family_facts;
CREATE POLICY family_facts_family_read ON public.family_facts FOR SELECT
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND ((SELECT auth_is_family()) OR (SELECT family_is_parent())));
DROP POLICY IF EXISTS family_facts_parents_all ON public.family_facts;
CREATE POLICY family_facts_parents_all ON public.family_facts FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_facts TO authenticated;

INSERT INTO public.family_facts (sort_order, fact)
SELECT v.s, v.f FROM (VALUES
  (1, 'Honey never spoils. Jars of honey found in ancient Egyptian tombs were still good to eat.'),
  (2, 'An octopus has three hearts.'),
  (3, 'An octopus has blue blood.'),
  (4, 'A group of flamingos is called a flamboyance.'),
  (5, 'Bananas are berries, but strawberries are not.'),
  (6, 'The Eiffel Tower grows about 6 inches taller in summer, because metal expands in the heat.'),
  (7, 'Sea otters hold hands while they sleep so they don''t drift apart.'),
  (8, 'A day on Venus is longer than a year on Venus.'),
  (9, 'Your heart beats about 100,000 times every day.'),
  (10, 'Butterflies taste with their feet.'),
  (11, 'The shortest war in history, between Britain and Zanzibar in 1896, lasted less than an hour.'),
  (12, 'Koalas can sleep up to 20 hours a day.'),
  (13, 'Wombat poop is shaped like little cubes.'),
  (14, 'Lightning is about five times hotter than the surface of the sun.'),
  (15, 'There are more trees on Earth than there are stars in our galaxy.'),
  (16, 'Hummingbirds are the only birds that can fly backward.'),
  (17, 'A hummingbird''s heart can beat more than 1,200 times a minute.'),
  (18, 'You can''t see the Great Wall of China from the Moon with your eyes.'),
  (19, 'Sloths can hold their breath for up to 40 minutes.'),
  (20, 'A shrimp''s heart is in its head.'),
  (21, 'A polar bear''s fur is actually clear, and the skin underneath is black.'),
  (22, 'A giraffe has the same number of neck bones as you: seven.'),
  (23, 'An ostrich''s eye is bigger than its brain.'),
  (24, 'Owls can''t move their eyes, so they turn their heads, as far as 270 degrees.'),
  (25, 'The dot over a lowercase i or j is called a tittle.'),
  (26, 'Russia stretches across 11 time zones.'),
  (27, 'The Pacific Ocean is bigger than all the land on Earth put together.'),
  (28, 'Water gets bigger when it freezes. That''s why ice floats.'),
  (29, 'Sound travels about four times faster in water than in air.'),
  (30, 'Sunlight takes about 8 minutes to reach Earth.'),
  (31, 'Saturn is so light for its size that it would float in a giant bathtub.'),
  (32, 'Jupiter''s Great Red Spot is a storm bigger than the whole Earth.'),
  (33, 'The Gutenberg Bible, printed in the 1450s, was the first major book printed in Europe with movable type.'),
  (34, 'Leonardo da Vinci often wrote backward, so his notes read right in a mirror.'),
  (35, 'Abraham Lincoln is in the National Wrestling Hall of Fame.'),
  (36, 'Long ago, most carrots were purple or yellow, not orange.'),
  (37, 'A fluffy white cloud can weigh more than a million pounds.'),
  (38, 'Tigers have striped skin, not just striped fur.'),
  (39, 'Crows can recognize human faces and remember them for years.'),
  (40, 'Dolphins use special whistles for each other, almost like names.'),
  (41, 'Elephants can''t jump.'),
  (42, 'A blue whale''s heart is about as big as a golf cart.'),
  (43, 'The blue whale is the biggest animal on Earth.'),
  (44, 'Babies are born with about 300 bones. Grown-ups have 206, because some bones join together.'),
  (45, 'For its size, the strongest muscle in your body is the one that closes your jaw.'),
  (46, 'Your stomach makes a brand-new lining every few days.'),
  (47, 'No two people have the same fingerprints, not even identical twins.'),
  (48, 'Koalas have fingerprints that look almost like ours.'),
  (49, 'Some penguins give a pebble to the penguin they want to build a nest with.'),
  (50, 'A group of owls is called a parliament.'),
  (51, 'A newborn kangaroo is about the size of a jellybean.'),
  (52, 'Sea stars have no brain and no blood.'),
  (53, 'Snakes smell with their tongues.'),
  (54, 'Frogs drink water through their skin.'),
  (55, 'Honeybees tell each other where flowers are by doing a "waggle dance."'),
  (56, 'One honeybee makes only about a twelfth of a teaspoon of honey in its whole life.'),
  (57, 'Ants don''t have lungs.'),
  (58, '"Rhythms" is the longest common English word with no a, e, i, o or u.'),
  (59, '"Strengths" is a nine-letter word with only one vowel.'),
  (60, 'The word "alphabet" comes from the first two Greek letters, alpha and beta.'),
  (61, 'Scotland''s national animal is the unicorn.'),
  (62, 'Texas is the only state in the lower 48 that runs its own separate power grid.'),
  (63, 'The Alamo in San Antonio was first built as a Spanish mission church.'),
  (64, 'The King James Bible was first printed in 1611.'),
  (65, 'Parts of the Bible have been translated into more than 3,000 languages.'),
  (66, 'Johann Sebastian Bach often wrote "S.D.G." on his music. It stands for "Soli Deo Gloria," which means "Glory to God alone."'),
  (67, 'Isaac Newton wrote more than a million words about the Bible.'),
  (68, 'Peanuts aren''t really nuts. They grow underground and are related to beans.'),
  (69, 'A pineapple plant takes about two years to grow one pineapple.'),
  (70, 'Apples float because about a quarter of an apple is air.'),
  (71, 'The Aztecs used cacao beans, the beans chocolate comes from, as money.'),
  (72, 'Popcorn pops because a drop of water inside each kernel turns to steam.'),
  (73, 'In the 1830s, ketchup was sold as a medicine.'),
  (74, 'George Washington never lived in the White House. John Adams was the first president to move in.'),
  (75, 'The Statue of Liberty used to be shiny brown copper before it turned green.'),
  (76, 'The Wright brothers'' first airplane flight lasted 12 seconds.'),
  (77, 'The footprints on the Moon will stay there a very long time, because there''s no wind to blow them away.'),
  (78, 'Astronauts can grow up to 2 inches taller in space, because their spines stretch out.'),
  (79, 'There''s no sound in space, because there''s no air to carry it.'),
  (80, 'Venus is the hottest planet, even though Mercury is closer to the sun.'),
  (81, 'A year on Mercury is only 88 Earth days long.'),
  (82, 'About 1.3 million Earths could fit inside the sun.'),
  (83, 'Rainbows are really full circles. From the ground we only see part of the circle.'),
  (84, 'Every snowflake has six sides.'),
  (85, 'Cats sleep about two-thirds of the day.'),
  (86, 'Every dog''s nose print is one of a kind, like a fingerprint.'),
  (87, 'A dog''s sense of smell is thousands of times stronger than yours.'),
  (88, 'Beagles were bred to track rabbits by smell.'),
  (89, 'Pugs were once the pets of Chinese emperors.'),
  (90, 'Goldfish can remember things for months, not just a few seconds.'),
  (91, 'Your fingernails grow faster than your toenails.'),
  (92, 'You can''t hum while you hold your nose closed. Try it!'),
  (93, 'You blink about 15 to 20 times every minute.'),
  (94, 'Mount Everest is the tallest mountain above sea level, but Mauna Kea in Hawaii is taller from its base on the ocean floor.'),
  (95, 'The Dead Sea is so salty that you float on top of it easily.'),
  (96, 'Antarctica is the biggest desert in the world, because it gets so little rain or snow.'),
  (97, 'Canada has more lakes than any other country.'),
  (98, 'The Amazon River carries more water than any other river on Earth.'),
  (99, 'A "jiffy" is a real unit of time, a tiny fraction of a second.'),
  (100, 'Velcro was invented by a man who noticed burrs sticking to his dog''s fur.'),
  (101, 'The Slinky was invented by accident when a spring fell off a shelf.'),
  (102, 'The microwave oven was invented after a candy bar melted in a scientist''s pocket near radar equipment.'),
  (103, 'Bubble wrap was first made to be wallpaper.'),
  (104, 'Play-Doh was first made to clean wallpaper.'),
  (105, 'The first computer mouse was made of wood.')
) v(s, f)
WHERE NOT EXISTS (SELECT 1 FROM public.family_facts);

-- The fact for a day: the list in order, one a day, starting over at the end.
CREATE OR REPLACE FUNCTION public.family_fact_of_day(p_date date)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  WITH f AS (SELECT fact, row_number() OVER (ORDER BY sort_order, created_at) - 1 AS n, count(*) OVER () AS total FROM public.family_facts)
  SELECT fact FROM f WHERE n = ((p_date - DATE '2026-09-22') % total + total) % total;
$function$;
GRANT EXECUTE ON FUNCTION public.family_fact_of_day(date) TO authenticated, service_role;

-- 2. Shower timer. The clock runs on the server so a refresh doesn't lose it.
ALTER TABLE public.family_kids ADD COLUMN IF NOT EXISTS shower_minutes smallint CHECK (shower_minutes IS NULL OR shower_minutes > 0);
UPDATE public.family_kids SET shower_minutes = 10 WHERE shower_minutes IS NULL AND birthday <= DATE '2023-01-01';
ALTER TABLE public.family_settings ADD COLUMN IF NOT EXISTS shower_fine_per_minute numeric(6,2) NOT NULL DEFAULT 1.00;

CREATE TABLE IF NOT EXISTS public.family_showers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365' REFERENCES public.agency(id),
  kid_id uuid NOT NULL REFERENCES public.family_kids(id) ON DELETE CASCADE,
  started_at timestamptz NOT NULL DEFAULT now(),
  ended_at timestamptz,
  limit_seconds integer NOT NULL,
  seconds integer,
  over_seconds integer,
  fine numeric(8,2),
  ledger_id uuid REFERENCES public.family_ledger(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS family_showers_one_running ON public.family_showers (kid_id) WHERE ended_at IS NULL;
ALTER TABLE public.family_showers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS family_showers_family_read ON public.family_showers;
CREATE POLICY family_showers_family_read ON public.family_showers FOR SELECT
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND ((SELECT auth_is_family()) OR (SELECT family_is_parent())));
DROP POLICY IF EXISTS family_showers_parents_all ON public.family_showers;
CREATE POLICY family_showers_parents_all ON public.family_showers FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT family_is_parent()));
GRANT SELECT ON public.family_showers TO authenticated;

CREATE OR REPLACE FUNCTION public.family_shower_start(p_kid_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_limit int; v_row public.family_showers;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT shower_minutes * 60 INTO v_limit FROM public.family_kids WHERE id = p_kid_id AND is_active;
  IF v_limit IS NULL THEN RAISE EXCEPTION 'No shower timer for this kid.'; END IF;
  SELECT * INTO v_row FROM public.family_showers WHERE kid_id = p_kid_id AND ended_at IS NULL;
  IF v_row.id IS NULL THEN
    INSERT INTO public.family_showers (kid_id, limit_seconds) VALUES (p_kid_id, v_limit) RETURNING * INTO v_row;
  END IF;
  RETURN to_jsonb(v_row);
END $function$;

-- Stop: every second over the limit costs the per-minute fine / 60, rounded to the cent.
-- The fine goes in the ledger like any given fine, so it settles at the week close-out.
CREATE OR REPLACE FUNCTION public.family_shower_stop(p_kid_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_row public.family_showers; v_secs int; v_over int; v_fine numeric; v_rate numeric; v_ledger uuid;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT * INTO v_row FROM public.family_showers WHERE kid_id = p_kid_id AND ended_at IS NULL FOR UPDATE;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'No shower is running.'; END IF;
  SELECT COALESCE(shower_fine_per_minute, 1.00) INTO v_rate FROM public.family_settings WHERE agency_id = v_row.agency_id;
  v_secs := floor(extract(epoch FROM now() - v_row.started_at))::int;
  v_over := GREATEST(0, v_secs - v_row.limit_seconds);
  v_fine := round(v_over * COALESCE(v_rate, 1.00) / 60.0, 2);
  IF v_fine > 0 THEN
    INSERT INTO public.family_ledger (agency_id, kid_id, entry_date, bucket, kind, amount, note)
    VALUES (v_row.agency_id, p_kid_id, (v_row.started_at AT TIME ZONE 'America/Chicago')::date, 'spend', 'fine', -v_fine,
            'Shower ' || (v_secs / 60) || ':' || lpad((v_secs % 60)::text, 2, '0') || ' (' || (v_over / 60) || ':' || lpad((v_over % 60)::text, 2, '0') || ' over)')
    RETURNING id INTO v_ledger;
  END IF;
  UPDATE public.family_showers SET ended_at = now(), seconds = v_secs, over_seconds = v_over, fine = v_fine, ledger_id = v_ledger
   WHERE id = v_row.id RETURNING * INTO v_row;
  RETURN to_jsonb(v_row);
END $function$;

-- A parent can cancel a timer that was started by mistake.
CREATE OR REPLACE FUNCTION public.family_shower_cancel(p_kid_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can cancel the timer.'; END IF;
  DELETE FROM public.family_showers WHERE kid_id = p_kid_id AND ended_at IS NULL;
END $function$;

REVOKE ALL ON FUNCTION public.family_shower_start(uuid) FROM public, anon;
REVOKE ALL ON FUNCTION public.family_shower_stop(uuid) FROM public, anon;
REVOKE ALL ON FUNCTION public.family_shower_cancel(uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.family_shower_start(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.family_shower_stop(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.family_shower_cancel(uuid) TO authenticated, service_role;
