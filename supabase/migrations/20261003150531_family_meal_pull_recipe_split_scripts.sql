-- Postgres takes a pattern's greediness from its first quantifier, so the old non-greedy
-- script match ran to the last </script> and never parsed. Split on </script> instead.
CREATE OR REPLACE FUNCTION public.family_meal_pull_recipe(p_meal_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_url text; v_res extensions.http_response; v_piece text; v_at int; v_j jsonb; v_rec jsonb;
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

  FOR v_piece IN SELECT unnest(string_to_array(v_res.content, '</script>')) LOOP
    v_at := position('application/ld+json' IN lower(v_piece));
    CONTINUE WHEN v_at = 0;
    v_piece := substr(v_piece, v_at);
    v_piece := substr(v_piece, position('>' IN v_piece) + 1);
    BEGIN
      v_j := btrim(v_piece)::jsonb;
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
REVOKE EXECUTE ON FUNCTION public.family_meal_pull_recipe(uuid) FROM PUBLIC, anon, authenticated;
