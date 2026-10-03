-- Meal plan, part 3 (Peter 2026-10-03):
-- 1. Parents' birthdays come from the team table (team.date_of_birth); Grandpa joins dinner.
-- 2. Recipes for approved meals are pulled once a day, at the end of the day (11 pm Central),
--    by an automation recipe on the existing hourly tick. Changing a meal's link clears its
--    recipe so the next nightly pull gets the new one.

ALTER TABLE public.family_meals ADD COLUMN IF NOT EXISTS recipe_pull_note text;
COMMENT ON COLUMN public.family_meals.recipe_pull_note IS 'Why the last nightly recipe pull did not work (e.g. the page blocks robots, a video link). NULL when the recipe is in.';

COMMENT ON COLUMN public.family_settings.meal_adults IS
  'Adults who eat family dinners, for recipe scaling: key, name, gender (male/female), and either team_id (birthday read from team.date_of_birth) or birthday. No birthday = treated as 26-50.';

CREATE OR REPLACE FUNCTION public.family_meal_people(p_on date DEFAULT NULL)
RETURNS TABLE (person_key text, name text, portion numeric, sort_order int)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH d AS (SELECT COALESCE(p_on, (now() AT TIME ZONE 'America/Chicago')::date) AS on_date)
  SELECT x->>'key', x->>'name',
         public.family_meal_portion(COALESCE(tm.date_of_birth, NULLIF(x->>'birthday', '')::date), x->>'gender', d.on_date),
         (ord - 100)::int
  FROM public.family_settings s
  CROSS JOIN d
  CROSS JOIN LATERAL jsonb_array_elements(s.meal_adults) WITH ORDINALITY AS t(x, ord)
  LEFT JOIN public.team tm ON tm.id = NULLIF(x->>'team_id', '')::uuid
  WHERE s.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  UNION ALL
  SELECT 'kid:' || k.id::text, k.name, public.family_meal_portion(k.birthday, k.gender, d.on_date), k.sort_order
  FROM public.family_kids k, d
  WHERE k.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND k.is_active
  ORDER BY 4;
$$;
COMMENT ON FUNCTION public.family_meal_people(date) IS 'Everyone at family dinner (adults from family_settings.meal_adults, birthday from team.date_of_birth when team_id is set; then active kids from family_kids) with their portion from family_meal_portion. Called inside the other meal functions, which check access.';

CREATE OR REPLACE FUNCTION public.family_meal_clean_text(p text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE s text := COALESCE(p, ''); m text[]; n int := 0;
BEGIN
  s := regexp_replace(s, '<[^>]+>', '', 'g');
  s := replace(replace(replace(replace(replace(replace(s, '&nbsp;', ' '), '&quot;', '"'), '&#39;', ''''), '&apos;', ''''), '&lt;', '<'), '&gt;', '>');
  LOOP
    m := regexp_match(s, '&#(\d+);');
    EXIT WHEN m IS NULL OR n > 60;
    s := replace(s, '&#' || m[1] || ';', chr(m[1]::int));
    n := n + 1;
  END LOOP;
  s := replace(s, '&amp;', '&');
  s := replace(s, chr(160), ' ');
  RETURN btrim(regexp_replace(s, '\s+', ' ', 'g'));
END;
$$;

CREATE OR REPLACE FUNCTION public.family_meal_lead_number(p text, OUT qty numeric, OUT rest text)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE s text := btrim(COALESCE(p, '')); m text[]; k text; v numeric;
BEGIN
  FOR k, v IN SELECT * FROM (VALUES ('½', 0.5), ('¼', 0.25), ('¾', 0.75), ('⅓', 0.3333), ('⅔', 0.6667),
                                    ('⅛', 0.125), ('⅜', 0.375), ('⅝', 0.625), ('⅞', 0.875)) f(k, v) LOOP
    s := regexp_replace(s, '(\d)\s*-?\s*' || k, '\1 ' || v::text, 'g');
    s := replace(s, k, v::text);
  END LOOP;
  m := regexp_match(s, '^((\d+(?:\.\d+)?)\s*[\s-]\s*(\d+)/(\d+))');
  IF m IS NOT NULL THEN
    qty := m[2]::numeric + m[3]::numeric / NULLIF(m[4]::numeric, 0);
    rest := substr(s, length(m[1]) + 1); RETURN;
  END IF;
  m := regexp_match(s, '^((\d+(?:\.\d+)?)\s+(0?\.\d+))');
  IF m IS NOT NULL THEN qty := m[2]::numeric + m[3]::numeric; rest := substr(s, length(m[1]) + 1); RETURN; END IF;
  m := regexp_match(s, '^((\d+)/(\d+))');
  IF m IS NOT NULL THEN qty := m[2]::numeric / NULLIF(m[3]::numeric, 0); rest := substr(s, length(m[1]) + 1); RETURN; END IF;
  m := regexp_match(s, '^(\d+(?:\.\d+)?)');
  IF m IS NOT NULL THEN qty := m[1]::numeric; rest := substr(s, length(m[1]) + 1); RETURN; END IF;
  qty := NULL; rest := s;
END;
$$;

CREATE OR REPLACE FUNCTION public.family_meal_parse_ingredient(p_line text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  t text := public.family_meal_clean_text(p_line);
  q numeric; q2 numeric; r text; r2 text; m text[]; w text; u text; item text;
BEGIN
  SELECT n.qty, n.rest INTO q, r FROM public.family_meal_lead_number(t) n;
  IF q IS NOT NULL THEN
    m := regexp_match(r, '^(\s*(?:-|–|to)\s*)');
    IF m IS NOT NULL THEN
      SELECT n.qty, n.rest INTO q2, r2 FROM public.family_meal_lead_number(substr(r, length(m[1]) + 1)) n;
      IF q2 IS NOT NULL THEN q := (q + q2) / 2; r := r2; END IF;
    END IF;
  END IF;
  r := btrim(COALESCE(r, ''));

  m := regexp_match(r, '^((g|kg|ml|l)\M\.?)', 'i');
  IF q IS NOT NULL AND m IS NOT NULL THEN
    u := lower(m[2]); r := btrim(substr(r, length(m[1]) + 1));
  ELSIF q IS NOT NULL THEN
    w := lower(rtrim(split_part(r, ' ', 1), ','));
    u := CASE w
      WHEN 'cup' THEN 'cup' WHEN 'cups' THEN 'cup' WHEN 'c' THEN 'cup' WHEN 'c.' THEN 'cup'
      WHEN 'tablespoon' THEN 'tbsp' WHEN 'tablespoons' THEN 'tbsp' WHEN 'tbsp' THEN 'tbsp' WHEN 'tbs' THEN 'tbsp' WHEN 'tbsp.' THEN 'tbsp' WHEN 't' THEN 'tbsp'
      WHEN 'teaspoon' THEN 'tsp' WHEN 'teaspoons' THEN 'tsp' WHEN 'tsp' THEN 'tsp' WHEN 'tsp.' THEN 'tsp'
      WHEN 'pound' THEN 'lb' WHEN 'pounds' THEN 'lb' WHEN 'lb' THEN 'lb' WHEN 'lbs' THEN 'lb' WHEN 'lb.' THEN 'lb' WHEN 'lbs.' THEN 'lb'
      WHEN 'ounce' THEN 'oz' WHEN 'ounces' THEN 'oz' WHEN 'oz' THEN 'oz' WHEN 'oz.' THEN 'oz'
      WHEN 'clove' THEN 'clove' WHEN 'cloves' THEN 'clove' WHEN 'can' THEN 'can' WHEN 'cans' THEN 'can'
      WHEN 'package' THEN 'package' WHEN 'packages' THEN 'package' WHEN 'pkg' THEN 'package'
      WHEN 'jar' THEN 'jar' WHEN 'jars' THEN 'jar' WHEN 'bag' THEN 'bag' WHEN 'bags' THEN 'bag'
      WHEN 'pinch' THEN 'pinch' WHEN 'dash' THEN 'dash' WHEN 'slice' THEN 'slice' WHEN 'slices' THEN 'slice'
      WHEN 'stick' THEN 'stick' WHEN 'sticks' THEN 'stick' WHEN 'quart' THEN 'qt' WHEN 'quarts' THEN 'qt'
      WHEN 'pint' THEN 'pint' WHEN 'pints' THEN 'pint' WHEN 'head' THEN 'head' WHEN 'heads' THEN 'head'
      WHEN 'bunch' THEN 'bunch' WHEN 'bunches' THEN 'bunch' WHEN 'sprig' THEN 'sprig' WHEN 'sprigs' THEN 'sprig'
      WHEN 'box' THEN 'box' WHEN 'boxes' THEN 'box' WHEN 'loaf' THEN 'loaf' WHEN 'envelope' THEN 'envelope'
      WHEN 'packet' THEN 'packet' WHEN 'packets' THEN 'packet' WHEN 'stalk' THEN 'stalk' WHEN 'stalks' THEN 'stalk'
      WHEN 'cube' THEN 'cube' WHEN 'cubes' THEN 'cube' WHEN 'ear' THEN 'ear' WHEN 'ears' THEN 'ear'
      WHEN 'fillets' THEN 'fillet' WHEN 'piece' THEN 'piece' WHEN 'pieces' THEN 'piece' WHEN 'handful' THEN 'handful'
      WHEN 'link' THEN 'link' WHEN 'links' THEN 'link' WHEN 'whole' THEN '-'
      ELSE NULL END;
    IF u IS NOT NULL THEN
      r := btrim(substr(r, length(split_part(r, ' ', 1)) + 1));
      IF u = '-' THEN u := NULL; END IF;
    END IF;
  END IF;

  IF u IN ('g', 'kg', 'ml', 'l') THEN
    r := btrim(regexp_replace(r, '^(?:/\s*[\d.¼½¾/ ]+\s*(?:oz|lb|lbs|cups?|tbsp|tsp|fl oz)\.?\s*|\(\s*[\d.¼½¾/ ]+\s*(?:oz|lb|lbs|cups?|tbsp|tsp|fl oz)\.?\s*\)\s*)', '', 'i'));
    IF u = 'kg' THEN q := q * 1000; u := 'g'; END IF;
    IF u = 'l' THEN q := q * 1000; u := 'ml'; END IF;
    IF u = 'g' THEN
      q := q / 28.35; u := 'oz';
      IF q >= 16 THEN q := q / 16; u := 'lb'; END IF;
    ELSE
      IF q >= 59 THEN q := q / 236.6; u := 'cup'; ELSE q := q / 14.79; u := 'tbsp'; END IF;
    END IF;
  END IF;

  item := regexp_replace(r, '^of\s+', '', 'i');
  item := regexp_replace(item, '^/\s*[\d.]+\s*(?:g|kg|ml|l)\M\s*', '', 'i');
  item := btrim(item, ' ,');
  RETURN jsonb_build_object('text', t, 'qty', round(q, 4), 'unit', u, 'item', item);
END;
$$;
COMMENT ON FUNCTION public.family_meal_parse_ingredient(text) IS 'Reads one recipe ingredient line into {text, qty, unit, item}: fractions and ranges (average), US units, metric converted to US (g to oz/lb, ml to tbsp/cup). The only ingredient reader.';

CREATE OR REPLACE FUNCTION public.family_meal_link_inventory(p_item text)
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT NULLIF(i->>'inventory_item_id', '')::uuid
       FROM public.family_meals m, jsonb_array_elements(COALESCE(m.ingredients, '[]'::jsonb)) i
      WHERE lower(i->>'item') = lower(btrim(p_item)) AND NULLIF(i->>'inventory_item_id', '') IS NOT NULL
      LIMIT 1),
    (SELECT it.id
       FROM public.family_inventory_items it
       CROSS JOIN LATERAL (
         SELECT array_agg(regexp_replace(tok, '(es|s)$', '')) AS toks
         FROM regexp_split_to_table(lower(regexp_replace(it.name, '^spices\s*-\s*', '', 'i')), '[^a-zñé]+') tok
         WHERE tok NOT IN ('', 'other', 'and', 'or')
       ) t
      WHERE it.section NOT IN ('CLEANING SUPPLIES', 'HOME GOODS', 'PERSONAL CARE')
        AND cardinality(t.toks) > 0
        AND NOT EXISTS (SELECT 1 FROM unnest(t.toks) tok WHERE lower(COALESCE(p_item, '')) !~ ('\m' || tok))
      ORDER BY cardinality(t.toks) DESC, length(it.name) DESC
      LIMIT 1));
$$;
COMMENT ON FUNCTION public.family_meal_link_inventory(text) IS 'Which inventory item an ingredient is bought as: the same ingredient already linked in another meal, else an inventory item whose every word appears in the ingredient (spices by spice name), most specific first. NULL if none.';

CREATE OR REPLACE FUNCTION public.family_meal_pull_recipe(p_meal_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_url text; v_res extensions.http_response; v_blk text[]; v_j jsonb; v_rec jsonb;
  v_ing jsonb; v_steps jsonb; v_yield text; v_serv numeric; m text[];
BEGIN
  SELECT recipe_url INTO v_url FROM public.family_meals WHERE id = p_meal_id;
  IF v_url IS NULL THEN RETURN 'no link'; END IF;

  PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '15000');
  v_res := extensions.http((
    'GET', v_url,
    ARRAY[extensions.http_header('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'),
          extensions.http_header('Accept', 'text/html')],
    NULL, NULL)::extensions.http_request);
  IF v_res.status <> 200 THEN RETURN 'page answered ' || v_res.status; END IF;

  FOR v_blk IN SELECT regexp_matches(v_res.content, '<script[^>]*application/ld\+json[^>]*>(.*?)</script>', 'gi') LOOP
    BEGIN
      v_j := v_blk[1]::jsonb;
    EXCEPTION WHEN others THEN
      CONTINUE;
    END;
    v_rec := jsonb_path_query_first(v_j, 'lax $.** ? (@."@type" == "Recipe")');
    EXIT WHEN v_rec IS NOT NULL;
  END LOOP;
  IF v_rec IS NULL THEN RETURN 'no recipe data on the page'; END IF;

  SELECT jsonb_agg(p || jsonb_build_object('inventory_item_id', public.family_meal_link_inventory(p->>'item')) ORDER BY n)
    INTO v_ing
  FROM (SELECT public.family_meal_parse_ingredient(x) AS p, n
          FROM jsonb_array_elements_text(COALESCE(v_rec->'recipeIngredient', '[]'::jsonb)) WITH ORDINALITY AS a(x, n)
         WHERE public.family_meal_clean_text(x) <> '') s;
  IF v_ing IS NULL THEN RETURN 'recipe has no ingredient list'; END IF;

  IF jsonb_typeof(v_rec->'recipeInstructions') = 'string' THEN
    v_steps := jsonb_build_array(public.family_meal_clean_text(v_rec->>'recipeInstructions'));
  ELSE
    SELECT jsonb_agg(public.family_meal_clean_text(s #>> '{}') ORDER BY n) INTO v_steps
    FROM (
      SELECT x AS s, n FROM jsonb_array_elements(COALESCE(v_rec->'recipeInstructions', '[]'::jsonb)) WITH ORDINALITY AS a(x, n)
       WHERE jsonb_typeof(x) = 'string'
      UNION ALL
      SELECT t, 1000 * a.n + b.n FROM jsonb_array_elements(COALESCE(v_rec->'recipeInstructions', '[]'::jsonb)) WITH ORDINALITY AS a(x, n),
             LATERAL jsonb_path_query(a.x, 'lax $.**.text') WITH ORDINALITY AS b(t, n)
       WHERE jsonb_typeof(a.x) = 'object'
    ) z
    WHERE public.family_meal_clean_text(s #>> '{}') <> '';
  END IF;

  v_yield := CASE jsonb_typeof(v_rec->'recipeYield')
               WHEN 'array' THEN (SELECT string_agg(y, ' ') FROM jsonb_array_elements_text(v_rec->'recipeYield') y)
               ELSE v_rec->>'recipeYield' END;
  m := regexp_match(COALESCE(v_yield, ''), '(\d+(?:\.\d+)?)(?:\s*(?:-|to|–)\s*(\d+(?:\.\d+)?))?');
  IF m IS NOT NULL THEN v_serv := (m[1]::numeric + COALESCE(m[2], m[1])::numeric) / 2; END IF;

  UPDATE public.family_meals
     SET servings = v_serv, ingredients = v_ing, steps = COALESCE(v_steps, '[]'::jsonb),
         recipe_pulled_at = now(), recipe_pull_note = NULL
   WHERE id = p_meal_id;
  RETURN 'ok';
END;
$$;
COMMENT ON FUNCTION public.family_meal_pull_recipe(uuid) IS 'Pulls one meal''s recipe (servings, ingredients via family_meal_parse_ingredient and family_meal_link_inventory, steps) from the schema.org Recipe data on its page. Returns ok or the reason it could not.';

CREATE OR REPLACE FUNCTION public.family_meal_pull_recipes(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE r record; v_msg text; v_ok int := 0; v_fail jsonb := '[]'::jsonb;
BEGIN
  FOR r IN
    SELECT id, name FROM public.family_meals
     WHERE agency_id = p_agency_id AND status = 'approved'
       AND recipe_url IS NOT NULL AND ingredients IS NULL
     ORDER BY created_at
     LIMIT 15
  LOOP
    BEGIN
      v_msg := public.family_meal_pull_recipe(r.id);
    EXCEPTION WHEN others THEN
      v_msg := 'error: ' || SQLERRM;
    END;
    IF v_msg = 'ok' THEN
      v_ok := v_ok + 1;
    ELSE
      UPDATE public.family_meals SET recipe_pull_note = v_msg WHERE id = r.id;
      v_fail := v_fail || jsonb_build_object('meal', r.name, 'why', v_msg);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('pulled', v_ok, 'not_pulled', v_fail);
END;
$$;
COMMENT ON FUNCTION public.family_meal_pull_recipes(uuid, uuid) IS 'Automation handler (nightly, 11 pm Central): pulls the recipe for every approved meal with a link and no recipe yet, up to 15 a night. Failures are noted on the meal (recipe_pull_note) and retried the next night.';

CREATE OR REPLACE FUNCTION public.family_meals_url_changed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.recipe_url IS DISTINCT FROM OLD.recipe_url THEN
    NEW.servings := NULL; NEW.ingredients := NULL; NEW.steps := NULL;
    NEW.recipe_pulled_at := NULL; NEW.recipe_pull_note := NULL;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS family_meals_url_changed ON public.family_meals;
CREATE TRIGGER family_meals_url_changed BEFORE UPDATE OF recipe_url ON public.family_meals
  FOR EACH ROW EXECUTE FUNCTION public.family_meals_url_changed();

REVOKE EXECUTE ON FUNCTION public.family_meal_people(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meal_clean_text(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_lead_number(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_parse_ingredient(text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.family_meal_link_inventory(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meal_pull_recipe(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meal_pull_recipes(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.family_meals_url_changed() FROM PUBLIC, anon, authenticated;

