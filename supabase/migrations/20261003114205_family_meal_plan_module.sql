-- Meal plan for the Family area: approved meals, suggested meal ideas, and the dinner for each day.
-- Rules (Peter 2026-10-03): alternate chicken and beef; Thursday simple night; Friday dinner out. Week Sun-Sat.
-- Starting meals: BEEF and CHICKEN tabs of the family's MEAL PLAN sheet, recipe links added where it had none.
CREATE TABLE IF NOT EXISTS public.family_meals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  name text NOT NULL CHECK (btrim(name) <> ''),
  meat text NOT NULL CHECK (meat IN ('chicken', 'beef', 'pork', 'fish', 'none')),
  recipe_url text,
  served_with text,
  is_simple boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'approved' CHECK (status IN ('approved', 'suggested')),
  similar_to text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.family_meals IS
  'The family''s meals. status approved = on the rotation; suggested = an idea Claude found, waiting for a parent to approve (similar_to names the approved meal it is like). is_simple = fits Thursday''s simple night. Only chicken and beef meals are picked automatically; the rest go on a day by hand.';

CREATE UNIQUE INDEX IF NOT EXISTS family_meals_name_key
  ON public.family_meals (agency_id, lower(btrim(name)));

CREATE TABLE IF NOT EXISTS public.family_meal_plan (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  plan_date date NOT NULL,
  kind text NOT NULL CHECK (kind IN ('cook', 'simple', 'out')),
  meal_id uuid REFERENCES public.family_meals(id) ON DELETE SET NULL,
  set_by text NOT NULL DEFAULT 'auto' CHECK (set_by IN ('auto', 'parent')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.family_meal_plan IS
  'Dinner for each day. kind cook = regular night, simple = Thursday easy night, out = Friday dinner out (no meal). set_by auto = picked by family_meal_pick, parent = a parent chose it. Written only by family_meal_week (fills empty days from today on) and family_meal_set_day.';

CREATE UNIQUE INDEX IF NOT EXISTS family_meal_plan_date_key
  ON public.family_meal_plan (agency_id, plan_date);

DROP TRIGGER IF EXISTS family_meals_touch ON public.family_meals;
CREATE TRIGGER family_meals_touch BEFORE UPDATE ON public.family_meals
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.family_meal_slot(p_date date)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE extract(dow FROM p_date)::int
    WHEN 5 THEN 'out'
    WHEN 4 THEN 'simple'
    ELSE 'cook'
  END;
$$;
COMMENT ON FUNCTION public.family_meal_slot(date) IS 'Which kind of night a date is: Friday = out (dinner out), Thursday = simple, else cook. The only place the weekday rules live (Peter 2026-10-03).';

CREATE OR REPLACE FUNCTION public.family_meal_pick(p_date date, p_exclude uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_slot text := public.family_meal_slot(p_date);
  v_last text;
  v_want text;
  v_id uuid;
BEGIN
  IF v_slot = 'out' THEN RETURN NULL; END IF;

  SELECT m.meat INTO v_last
  FROM public.family_meal_plan p
  JOIN public.family_meals m ON m.id = p.meal_id
  WHERE p.plan_date < p_date AND m.meat IN ('chicken', 'beef')
  ORDER BY p.plan_date DESC
  LIMIT 1;
  v_want := CASE WHEN v_last = 'chicken' THEN 'beef' ELSE 'chicken' END;

  SELECT m.id INTO v_id
  FROM public.family_meals m
  LEFT JOIN LATERAL (
    SELECT max(p.plan_date) AS last_on
    FROM public.family_meal_plan p
    WHERE p.meal_id = m.id AND p.plan_date <> p_date
  ) s ON true
  WHERE m.status = 'approved'
    AND m.meat IN ('chicken', 'beef')
    AND m.id IS DISTINCT FROM p_exclude
  ORDER BY (m.is_simple = (v_slot = 'simple')) DESC,
           (m.meat = v_want) DESC,
           s.last_on NULLS FIRST,
           random()
  LIMIT 1;

  RETURN v_id;
END;
$$;
COMMENT ON FUNCTION public.family_meal_pick(date, uuid) IS 'Picks one meal for a date. Meat = opposite of the last chicken-or-beef dinner before the date (chicken if none). Thursday takes a simple meal, other nights a regular one, closest match if none fits. Among matches, the meal served longest ago (or never) wins so the list rotates; ties at random. NULL for dinner out. The only place the choosing rules live.';

CREATE OR REPLACE FUNCTION public.family_meal_week(p_week_start date)
RETURNS TABLE (
  plan_date date, kind text, meal_id uuid, name text, meat text,
  recipe_url text, served_with text, set_by text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_start date := p_week_start - extract(dow FROM p_week_start)::int;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_day date;
  v_slot text;
  v_row public.family_meal_plan%ROWTYPE;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;

  FOR i IN 0..6 LOOP
    v_day := v_start + i;
    CONTINUE WHEN v_day < v_today;
    SELECT * INTO v_row FROM public.family_meal_plan fp
      WHERE fp.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND fp.plan_date = v_day;
    CONTINUE WHEN FOUND AND (v_row.kind = 'out' OR v_row.meal_id IS NOT NULL);
    v_slot := public.family_meal_slot(v_day);
    INSERT INTO public.family_meal_plan (plan_date, kind, meal_id, set_by)
    VALUES (v_day, v_slot, public.family_meal_pick(v_day), 'auto')
    ON CONFLICT (agency_id, plan_date) DO UPDATE
      SET kind = EXCLUDED.kind, meal_id = EXCLUDED.meal_id, set_by = 'auto', updated_at = now();
  END LOOP;

  RETURN QUERY
  SELECT d::date, COALESCE(p.kind, public.family_meal_slot(d::date)), m.id, m.name, m.meat,
         m.recipe_url, m.served_with, p.set_by
  FROM generate_series(v_start, v_start + 6, interval '1 day') d
  LEFT JOIN public.family_meal_plan p
    ON p.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND p.plan_date = d::date
  LEFT JOIN public.family_meals m ON m.id = p.meal_id
  ORDER BY d;
END;
$$;
COMMENT ON FUNCTION public.family_meal_week(date) IS 'The meal plan week on screen (Sunday to Saturday). Fills any empty day from today on with family_meal_pick, then returns all 7 days. Admins and the family login.';

CREATE OR REPLACE FUNCTION public.family_meal_set_day(p_date date, p_meal_id uuid DEFAULT NULL, p_out boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_slot text := public.family_meal_slot(p_date);
  v_current uuid;
  v_meal uuid;
  v_kind text;
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can change the meal plan.'; END IF;

  SELECT fp.meal_id INTO v_current FROM public.family_meal_plan fp
    WHERE fp.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND fp.plan_date = p_date;

  IF p_out THEN
    v_kind := 'out'; v_meal := NULL;
  ELSE
    v_kind := CASE WHEN v_slot = 'out' THEN 'cook' ELSE v_slot END;
    v_meal := COALESCE(p_meal_id, public.family_meal_pick(p_date, v_current));
    IF v_meal IS NULL THEN RAISE EXCEPTION 'No meal to pick.'; END IF;
  END IF;

  INSERT INTO public.family_meal_plan (plan_date, kind, meal_id, set_by)
  VALUES (p_date, v_kind, v_meal, 'parent')
  ON CONFLICT (agency_id, plan_date) DO UPDATE
    SET kind = EXCLUDED.kind, meal_id = EXCLUDED.meal_id, set_by = 'parent', updated_at = now();
END;
$$;
COMMENT ON FUNCTION public.family_meal_set_day(date, uuid, boolean) IS 'Parents change one day. p_out = dinner out; p_meal_id = that meal; neither = pick another by the usual rules, skipping the current one.';

ALTER TABLE public.family_meals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.family_meal_plan ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS family_meals_family_read ON public.family_meals;
CREATE POLICY family_meals_family_read ON public.family_meals
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.auth_is_family()));

DROP POLICY IF EXISTS family_meals_parents_all ON public.family_meals;
CREATE POLICY family_meals_parents_all ON public.family_meals
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));

DROP POLICY IF EXISTS family_meal_plan_family_read ON public.family_meal_plan;
CREATE POLICY family_meal_plan_family_read ON public.family_meal_plan
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.auth_is_family()));

DROP POLICY IF EXISTS family_meal_plan_parents_all ON public.family_meal_plan;
CREATE POLICY family_meal_plan_parents_all ON public.family_meal_plan
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()))
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND (SELECT public.family_is_parent()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_meals TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.family_meal_plan TO authenticated;

REVOKE EXECUTE ON FUNCTION public.family_meal_slot(date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_pick(date, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meal_week(date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_set_day(date, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_meal_slot(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_meal_week(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_meal_set_day(date, uuid, boolean) TO authenticated;

INSERT INTO public.family_meals (name, meat, recipe_url, served_with, is_simple, status, similar_to) VALUES
('Hamburger Hashbrown Casserole', 'beef', 'https://kitchendivas.com/hamburger-hash-brown-casserole/', 'Salad', false, 'approved', NULL),
('Spaghetti bolognese', 'beef', 'https://www.recipetineats.com/spaghetti-bolognese/', 'Salad', false, 'approved', NULL),
('Chili con Carne', 'beef', 'https://www.recipetineats.com/chilli-con-carne/', 'Cornbread or fritos, Pico de gallo, cheese, sour cream', false, 'approved', NULL),
('Burgers', 'beef', 'https://natashaskitchen.com/perfect-burger-recipe/', 'Buns, pickles, tomatoes, onions, condiments,', true, 'approved', NULL),
('Picadillo Tacos', 'beef', 'https://muybuenoblog.com/crispy-ground-beef-and-potato-tacos-tacos-de-picadillo/', 'Tortillas, pico, cheese, sour cream, salsa', false, 'approved', NULL),
('Smash burger tacos', 'beef', 'https://www.spendwithpennies.com/smash-burger-tacos/', 'Tortillas, cheese, burger toppings , salad', false, 'approved', NULL),
('Korean Beef Bowl', 'beef', 'https://www.spendwithpennies.com/korean-beef-bowl/', 'Rice, cucumbers, cilantro, carrots, kimchi', false, 'approved', NULL),
('Beef Burrito Bowl', 'beef', 'https://cookathomemom.com/ground-beef-burrito-bowl/', 'Rice, pico, cheese, sour cream, guac, salsa', false, 'approved', NULL),
('Doner Kebab', 'beef', 'https://www.facebook.com/share/r/1B3kSUqswv/', 'Pita bread, tzatziki, fresh veg', false, 'approved', NULL),
('Brisket Chili', 'beef', 'https://urbancowgirllife.com/texas-brisket-chili/', NULL, false, 'approved', NULL),
('Cheeseburger Soup', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a62452547/cheeseburger-soup-recipe/?utm_source=google&utm_medium=cpc&utm_campaign=mgu_ga_pw_md_pmx_prog_org_us_21687406524&gad_source=1&gad_campaignid=21697738690', NULL, false, 'approved', NULL),
('Cheesy Taco Bake', 'beef', 'https://www.delish.com/cooking/recipe-ideas/a49793/easy-cheesy-taco-bake-recipe/', NULL, false, 'approved', NULL),
('Mexican Ground Beef and Rice Casserole', 'beef', 'https://www.recipetineats.com/mexican-ground-beef-casserole-with-rice/', NULL, false, 'approved', NULL),
('One Pan Beef and Ramen Noodles', 'beef', 'https://simplehomeedit.com/recipe/one-pan-beef-ramen-noodles/', NULL, false, 'approved', NULL),
('Slow Cooker Brisket', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a65257015/slow-cooker-beef-brisket-recipe/', NULL, false, 'approved', NULL),
('Irish Nachos', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a38769762/irish-nachos-recipe/', NULL, false, 'approved', NULL),
('Meatball Stroganoff', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a69925651/meatball-stroganoff-recipe/', NULL, false, 'approved', NULL),
('Salisbury Steak Meatballs', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a11479/salisbury-steak-meatballs/', NULL, false, 'approved', NULL),
('Baked Ravioli', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a42029313/baked-ravioli-recipe/', NULL, false, 'approved', NULL),
('Cowboy Casserole', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a37182572/cowboy-casserole-recipe/', NULL, false, 'approved', NULL),
('Shepherds Pie', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a84156/freezer-friendly-shepherds-cottage-pie/', NULL, false, 'approved', NULL),
('Beefy Fried Rice', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a46411670/pork-fried-rice-recipe/', NULL, false, 'approved', NULL),
('Cowboy Nachos', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a70222266/cowboy-nachos-recipe/', NULL, false, 'approved', NULL),
('Soy Ginger Meatballs', 'beef', 'https://www.thepioneerwoman.com/food-cooking/recipes/a63497504/sheet-pan-soy-ginger-meatballs-and-veggies-recipe/', NULL, false, 'approved', NULL),
('Korean Chicken Thighs', 'chicken', 'https://www.foxandbriar.com/korean-chicken-thighs/', 'Rice, cucumber salad, kimchi', false, 'approved', NULL),
('Chicken burrito bowl', 'chicken', 'https://www.cookingclassy.com/chicken-burrito-bowl/', 'Rice, beans, pico, cheese, sour cream, salsa', false, 'approved', NULL),
('Chicken Cutlets', 'chicken', 'https://kristineskitchenblog.com/chicken-cutlets/', 'Mashed potatoes, steamed/roasted veg', false, 'approved', NULL),
('Chicken stir fry', 'chicken', 'https://www.spendwithpennies.com/easy-pepper-chicken-stir-fry/', 'Rice, veggies', false, 'approved', NULL),
('Chicken Broccoli Rice Casserole', 'chicken', 'https://www.tasteofhome.com/recipes/chicken-broccoli-rice-casserole/', NULL, false, 'approved', NULL),
('Crispy Chicken Sandwiches', 'chicken', 'https://bakingamoment.com/fried-chicken-sandwich/', 'Buns, pickles, slaw/onions, salad', true, 'approved', NULL),
('Chicken Enchilada Casserole', 'chicken', 'https://www.tasteofhome.com/recipes/chicken-chili-lasagna/', NULL, false, 'approved', NULL),
('Chicken Caesar Salad', 'chicken', 'https://www.recipetineats.com/chicken-caesar-salad/', NULL, true, 'approved', NULL),
('Chicken Quesadillas', 'chicken', 'https://www.spendwithpennies.com/chicken-quesadillas/', NULL, true, 'approved', NULL),
('Crispy Orange Chicken', 'chicken', 'https://houseofnasheats.com/orange-chicken/', NULL, false, 'approved', NULL),
('Chicken Alfredo', 'chicken', 'https://www.blessthismessplease.com/chicken-fettuccine-alfredo/', NULL, false, 'approved', NULL),
('Chicken Fajitas', 'chicken', 'https://www.recipetineats.com/chicken-fajitas/', NULL, false, 'approved', NULL),
('Chicken Fried Rice', 'chicken', 'https://www.recipetineats.com/chicken-fried-rice/', NULL, false, 'approved', NULL),
('Chicken and Dressing Sheet Pan Supper', 'chicken', 'https://www.thepioneerwoman.com/food-cooking/recipes/a90585/chicken-and-dressing-sheet-pan-supper/', NULL, false, 'approved', NULL),
('Spatchcock Chicken and Potatoes', 'chicken', 'https://www.thepioneerwoman.com/food-cooking/recipes/a46353961/spatchcock-chicken-recipe/', NULL, false, 'approved', NULL),
('Greek Chicken and Potatoes', 'chicken', 'https://www.dinneratthezoo.com/greek-chicken-and-potatoes/', NULL, false, 'approved', NULL),
('Chicken Florentine', 'chicken', 'https://www.thepioneerwoman.com/food-cooking/recipes/a42168684/chicken-florentine-recipe/', NULL, false, 'approved', NULL),
('Chicken and Stuffing Casserole', 'chicken', 'https://www.thepioneerwoman.com/food-cooking/recipes/a40640960/chicken-and-stuffing-casserole-recipe/', NULL, false, 'approved', NULL),
('Coconut Chicken Curry', 'chicken', 'https://www.thepioneerwoman.com/food-cooking/recipes/a44039542/coconut-chicken-curry-recipe/', NULL, false, 'approved', NULL),
('Chicken Bacon Ranch Casserole', 'chicken', 'https://www.thepioneerwoman.com/food-cooking/recipes/a40437260/chicken-bacon-ranch-casserole-recipe/', NULL, false, 'approved', NULL),
('Chinese Beef and Broccoli', 'beef', 'https://www.recipetineats.com/chinese-beef-and-broccoli/', 'Rice', false, 'suggested', 'Korean Beef Bowl'),
('Swedish Meatballs', 'beef', 'https://www.recipetineats.com/swedish-meatballs/', 'Mashed potatoes, green beans', false, 'suggested', 'Meatball Stroganoff'),
('Beef Enchiladas', 'beef', 'https://www.recipetineats.com/beef-enchiladas/', 'Rice, salad', false, 'suggested', 'Cheesy Taco Bake'),
('Lasagna', 'beef', 'https://www.recipetineats.com/lasagna/', 'Salad, garlic bread', false, 'suggested', 'Baked Ravioli'),
('Sloppy Joes', 'beef', 'https://www.budgetbytes.com/sloppy-joes/', 'Buns, chips, pickles', true, 'suggested', 'Burgers'),
('Teriyaki Chicken', 'chicken', 'https://www.recipetineats.com/teriyaki-chicken/', 'Rice, steamed veg', false, 'suggested', 'Korean Chicken Thighs'),
('Chicken Parmigiana', 'chicken', 'https://www.recipetineats.com/chicken-parmigiana/', 'Pasta, salad', false, 'suggested', 'Chicken Cutlets'),
('Chicken Spaghetti Casserole', 'chicken', 'https://houseofnasheats.com/chicken-spaghetti-casserole/', 'Salad', false, 'suggested', 'Chicken Bacon Ranch Casserole'),
('Chicken Caesar Wraps', 'chicken', 'https://www.spendwithpennies.com/chicken-caesar-wrap/', 'Chips, fruit', true, 'suggested', 'Chicken Caesar Salad')
ON CONFLICT DO NOTHING;
