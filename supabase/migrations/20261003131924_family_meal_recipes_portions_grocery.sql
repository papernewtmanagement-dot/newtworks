-- Meal plan, part 2 (Peter 2026-10-03):
-- 1. The meal week runs Saturday to Friday, like the kids' chores (family_week_start).
-- 2. Each meal keeps its recipe: how many it serves, the ingredients, the steps.
-- 3. The recipe scales to who is eating, by how much each person normally eats for their
--    age and sex.
-- 4. A grocery list for next week's meals, checked against the inventory, for parents.

ALTER TABLE public.family_meals ADD COLUMN IF NOT EXISTS servings numeric;
ALTER TABLE public.family_meals ADD COLUMN IF NOT EXISTS ingredients jsonb;
ALTER TABLE public.family_meals ADD COLUMN IF NOT EXISTS steps jsonb;
ALTER TABLE public.family_meals ADD COLUMN IF NOT EXISTS recipe_pulled_at timestamptz;
COMMENT ON COLUMN public.family_meals.servings IS 'How many the recipe serves, as the recipe says.';
COMMENT ON COLUMN public.family_meals.ingredients IS 'Array of {text, qty, unit, item, inventory_item_id}. text = the line as written; qty/unit = the amount read from it (null when none, e.g. salt to taste); inventory_item_id = the family_inventory_items row it is bought as, null when it is not on the inventory list.';
COMMENT ON COLUMN public.family_meals.steps IS 'Array of step strings, in order.';

ALTER TABLE public.family_settings ADD COLUMN IF NOT EXISTS meal_adults jsonb
  NOT NULL DEFAULT '[{"key":"dad","name":"Dad","gender":"male","birthday":null},{"key":"mom","name":"Mom","gender":"female","birthday":null}]'::jsonb;
COMMENT ON COLUMN public.family_settings.meal_adults IS 'Adults who eat family dinners, for recipe scaling: key, name, gender (male/female), birthday (null = treated as 26-50).';

CREATE OR REPLACE FUNCTION public.family_meal_portion(p_birthday date, p_gender text, p_on date)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  WITH a AS (
    SELECT CASE WHEN p_birthday IS NULL THEN 30
                ELSE extract(year FROM age(p_on, p_birthday))::int END AS yrs,
           lower(COALESCE(p_gender, '')) IN ('boy', 'male', 'm', 'man') AS male
  )
  SELECT round((CASE
    WHEN yrs < 1 THEN 0
    WHEN yrs = 1 THEN 900
    WHEN male THEN CASE
      WHEN yrs = 2 THEN 1000 WHEN yrs <= 5 THEN 1400 WHEN yrs <= 8 THEN 1600
      WHEN yrs <= 10 THEN 1800 WHEN yrs = 11 THEN 2000 WHEN yrs <= 13 THEN 2200
      WHEN yrs = 14 THEN 2400 WHEN yrs = 15 THEN 2600 WHEN yrs <= 25 THEN 2800
      WHEN yrs <= 45 THEN 2600 WHEN yrs <= 65 THEN 2400 ELSE 2200 END
    ELSE CASE
      WHEN yrs = 2 THEN 1000 WHEN yrs <= 4 THEN 1200 WHEN yrs <= 6 THEN 1400
      WHEN yrs <= 9 THEN 1600 WHEN yrs <= 11 THEN 1800 WHEN yrs <= 18 THEN 2000
      WHEN yrs <= 25 THEN 2200 WHEN yrs <= 50 THEN 2000 ELSE 1800 END
  END)::numeric / 2200, 2)
  FROM a;
$$;
COMMENT ON FUNCTION public.family_meal_portion(date, text, date) IS 'How much one person eats as a share of one adult recipe serving: Dietary Guidelines for Americans 2020-2025 Appendix 2 calories (moderately active) by age and sex, divided by 2,200. Age 1 = 900 (IOM); under 1 = 0. The only portion rule.';

CREATE OR REPLACE FUNCTION public.family_meal_people(p_on date DEFAULT NULL)
RETURNS TABLE (person_key text, name text, portion numeric, sort_order int)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH d AS (SELECT COALESCE(p_on, (now() AT TIME ZONE 'America/Chicago')::date) AS on_date)
  SELECT x->>'key', x->>'name',
         public.family_meal_portion(NULLIF(x->>'birthday', '')::date, x->>'gender', d.on_date),
         (ord - 100)::int
  FROM public.family_settings s, d, jsonb_array_elements(s.meal_adults) WITH ORDINALITY AS t(x, ord)
  WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  UNION ALL
  SELECT 'kid:' || k.id::text, k.name, public.family_meal_portion(k.birthday, k.gender, d.on_date), k.sort_order
  FROM public.family_kids k, d
  WHERE k.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND k.is_active
  ORDER BY 4;
$$;
COMMENT ON FUNCTION public.family_meal_people(date) IS 'Everyone at family dinner (adults from family_settings.meal_adults, then active kids) with their portion from family_meal_portion. Called inside the other meal functions, which check access.';

CREATE OR REPLACE FUNCTION public.family_meal_recipe(p_meal_id uuid, p_skip text[] DEFAULT '{}')
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_m public.family_meals%ROWTYPE;
  v_people jsonb;
  v_need numeric;
  v_mult numeric;
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN RAISE EXCEPTION 'Not allowed.'; END IF;
  SELECT * INTO v_m FROM public.family_meals WHERE id = p_meal_id;
  IF NOT FOUND THEN RETURN NULL; END IF;

  SELECT jsonb_agg(jsonb_build_object('key', p.person_key, 'name', p.name, 'portion', p.portion,
                                      'eating', NOT (p.person_key = ANY (COALESCE(p_skip, '{}')))) ORDER BY p.sort_order),
         sum(p.portion) FILTER (WHERE NOT (p.person_key = ANY (COALESCE(p_skip, '{}'))))
    INTO v_people, v_need
  FROM public.family_meal_people() p;

  v_mult := CASE WHEN COALESCE(v_m.servings, 0) > 0 THEN round(COALESCE(v_need, 0) / v_m.servings, 3) END;

  RETURN jsonb_build_object(
    'meal_id', v_m.id, 'name', v_m.name, 'recipe_url', v_m.recipe_url, 'served_with', v_m.served_with,
    'servings', v_m.servings, 'need_servings', round(COALESCE(v_need, 0), 1), 'multiplier', v_mult,
    'people', COALESCE(v_people, '[]'::jsonb),
    'steps', COALESCE(v_m.steps, '[]'::jsonb),
    'ingredients', COALESCE((
      SELECT jsonb_agg(i || jsonb_build_object('scaled',
               CASE WHEN (i->>'qty') IS NOT NULL AND v_mult IS NOT NULL
                    THEN round((i->>'qty')::numeric * v_mult, 3) END) ORDER BY n)
      FROM jsonb_array_elements(v_m.ingredients) WITH ORDINALITY AS t(i, n)), '[]'::jsonb)
  );
END;
$$;
COMMENT ON FUNCTION public.family_meal_recipe(uuid, text[]) IS 'One meal''s recipe scaled to who is eating: portions of everyone not in p_skip, added up, divided by the recipe''s servings. The only scaling rule.';

CREATE OR REPLACE FUNCTION public.family_meal_fill(p_through date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_day date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_row public.family_meal_plan%ROWTYPE;
BEGIN
  WHILE v_day <= p_through LOOP
    SELECT * INTO v_row FROM public.family_meal_plan fp
      WHERE fp.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND fp.plan_date = v_day;
    IF NOT (FOUND AND (v_row.kind = 'out' OR v_row.meal_id IS NOT NULL)) THEN
      INSERT INTO public.family_meal_plan (plan_date, kind, meal_id, set_by)
      VALUES (v_day, public.family_meal_slot(v_day), public.family_meal_pick(v_day), 'auto')
      ON CONFLICT (agency_id, plan_date) DO UPDATE
        SET kind = EXCLUDED.kind, meal_id = EXCLUDED.meal_id, set_by = 'auto', updated_at = now();
    END IF;
    v_day := v_day + 1;
  END LOOP;
END;
$$;
COMMENT ON FUNCTION public.family_meal_fill(date) IS 'Fills every empty day from today through p_through, in date order, with family_meal_pick. The only writer of auto picks. Called by family_meal_week and family_meal_grocery, which check access.';

CREATE OR REPLACE FUNCTION public.family_meal_week(p_week_start date)
RETURNS TABLE (
  plan_date date, kind text, meal_id uuid, name text, meat text,
  recipe_url text, served_with text, set_by text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
#variable_conflict use_column
DECLARE
  v_start date := public.family_week_start(p_week_start);
BEGIN
  IF NOT (public.family_is_parent() OR public.auth_is_family()) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  PERFORM public.family_meal_fill(v_start + 6);

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
COMMENT ON FUNCTION public.family_meal_week(date) IS 'The meal plan week on screen, Saturday to Friday like the chores (family_week_start). Fills empty days through the week''s end with family_meal_fill, then returns all 7 days. Admins and the family login.';

CREATE OR REPLACE FUNCTION public.family_meal_grocery(p_week_start date DEFAULT NULL)
RETURNS TABLE (
  status text, item_id uuid, name text, section text, first_needed date, meals text, amounts text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
#variable_conflict use_column
DECLARE
  v_start date := public.family_week_start(COALESCE(p_week_start, (now() AT TIME ZONE 'America/Chicago')::date + 7));
  v_need numeric;
BEGIN
  IF NOT public.family_is_parent() THEN RAISE EXCEPTION 'Only a parent can see the grocery list.'; END IF;
  PERFORM public.family_meal_fill(v_start + 6);
  SELECT sum(portion) INTO v_need FROM public.family_meal_people();

  RETURN QUERY
  WITH lines AS (
    SELECT p.plan_date, m.name AS meal, i,
           NULLIF(i->>'inventory_item_id', '')::uuid AS inv_id,
           CASE WHEN (i->>'qty') IS NOT NULL AND COALESCE(m.servings, 0) > 0
                THEN round((i->>'qty')::numeric * v_need / m.servings, 2) END AS amt
    FROM public.family_meal_plan p
    JOIN public.family_meals m ON m.id = p.meal_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.ingredients, '[]'::jsonb)) i
    WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND p.plan_date BETWEEN v_start AND v_start + 6
  ),
  inv AS (
    SELECT l.inv_id, min(l.plan_date) AS first_needed,
           string_agg(DISTINCT l.meal, ', ') AS meals,
           string_agg(COALESCE(trim(to_char(l.amt, 'FM999990.##') || ' ' || COALESCE(l.i->>'unit', '')), '') ||
                      CASE WHEN l.amt IS NULL THEN (l.i->>'text') ELSE ' ' || (l.i->>'item') END
                      || ' (' || l.meal || ')', '; ' ORDER BY l.plan_date) AS amounts
    FROM lines l WHERE l.inv_id IS NOT NULL GROUP BY l.inv_id
  )
  SELECT CASE WHEN b.is_low THEN 'low'
              WHEN b.likely_out OR (b.out_on IS NOT NULL AND b.out_on <= v.first_needed) THEN 'need'
              WHEN b.days_left IS NULL THEN 'check'
              ELSE 'have' END,
         v.inv_id, b.name, b.section, v.first_needed, v.meals, v.amounts
  FROM inv v JOIN public.family_inventory_board() b ON b.item_id = v.inv_id
  UNION ALL
  SELECT 'other', NULL, COALESCE(NULLIF(l.i->>'item', ''), l.i->>'text'), NULL, l.plan_date, l.meal,
         CASE WHEN l.amt IS NULL THEN l.i->>'text'
              ELSE trim(to_char(l.amt, 'FM999990.##') || ' ' || COALESCE(l.i->>'unit', '')) END
  FROM lines l WHERE l.inv_id IS NULL
  ORDER BY 1, 4, 3;
END;
$$;
COMMENT ON FUNCTION public.family_meal_grocery(date) IS 'Grocery list for a Sat-Fri week''s meals (default: next week), scaled to the whole family, checked against family_inventory_board(): low / need / have / check per inventory item, other = not on the inventory list. Parents only. Inventory Admin shows it from Wednesday.';

REVOKE EXECUTE ON FUNCTION public.family_meal_portion(date, text, date) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_people(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meal_fill(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meal_recipe(uuid, text[]) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_grocery(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.family_meal_portion(date, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_meal_recipe(uuid, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.family_meal_grocery(date) TO authenticated;

