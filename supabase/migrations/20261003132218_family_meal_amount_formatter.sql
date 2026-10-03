CREATE OR REPLACE FUNCTION public.family_meal_amount(p_qty numeric, p_unit text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_counts text[] := ARRAY['clove','can','package','slice','stick','head','bunch','jar','bag','sprig',
                           'stalk','piece','link','cube','ear','fillet','packet','envelope','box','loaf'];
  v_plural text[] := ARRAY['cup','clove','can','package','slice','stick','head','bunch','jar','bag','sprig',
                           'stalk','piece','link','cube','ear','fillet','packet','envelope'];
  q numeric; w int; f numeric; lab text; val numeric; num text; u text := p_unit;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN RETURN NULL; END IF;

  IF u = 'oz' THEN
    q := greatest(round(p_qty), 1);
  ELSIF u IS NULL OR u = ANY (v_counts) THEN
    q := CASE WHEN p_qty < 2 THEN greatest(round(p_qty * 2) / 2, 0.5) ELSE round(p_qty) END;
  ELSE
    q := p_qty;
  END IF;

  w := floor(q); f := q - w;
  SELECT x.l, x.v INTO lab, val
  FROM (VALUES (0::numeric, ''), (0.125, '1/8'), (0.25, '1/4'), (1/3::numeric, '1/3'), (0.375, '3/8'),
               (0.5, '1/2'), (0.625, '5/8'), (2/3::numeric, '2/3'), (0.75, '3/4'), (0.875, '7/8'), (1, '')) AS x(v, l)
  WHERE NOT (w = 0 AND x.v = 0)
  ORDER BY abs(f - x.v) LIMIT 1;
  IF val = 1 THEN w := w + 1; lab := ''; END IF;

  num := CASE WHEN w = 0 THEN lab WHEN lab = '' THEN w::text ELSE w::text || ' ' || lab END;
  IF u = ANY (v_plural) AND (w + val) > 1 THEN u := u || 's'; END IF;
  RETURN trim(num || ' ' || COALESCE(u, ''));
END;
$$;
COMMENT ON FUNCTION public.family_meal_amount(numeric, text) IS 'Shows a recipe amount the way a cook reads it: cups and spoons to the nearest 1/8 or 1/3, whole ounces, halves or whole counts for buns, cloves, cans. The only amount formatter (recipe popup and grocery list).';
GRANT EXECUTE ON FUNCTION public.family_meal_amount(numeric, text) TO authenticated;

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

  v_mult := CASE WHEN COALESCE(v_m.servings, 0) > 0 THEN COALESCE(v_need, 0) / v_m.servings END;

  RETURN jsonb_build_object(
    'meal_id', v_m.id, 'name', v_m.name, 'recipe_url', v_m.recipe_url, 'served_with', v_m.served_with,
    'servings', v_m.servings, 'need_servings', round(COALESCE(v_need, 0), 1), 'multiplier', round(v_mult, 2),
    'people', COALESCE(v_people, '[]'::jsonb),
    'steps', COALESCE(v_m.steps, '[]'::jsonb),
    'ingredients', COALESCE((
      SELECT jsonb_agg(i || jsonb_build_object('amount',
               CASE WHEN v_mult IS NOT NULL THEN public.family_meal_amount((i->>'qty')::numeric * v_mult, i->>'unit') END)
             ORDER BY n)
      FROM jsonb_array_elements(v_m.ingredients) WITH ORDINALITY AS t(i, n)), '[]'::jsonb)
  );
END;
$$;

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
           CASE WHEN COALESCE(m.servings, 0) > 0
                THEN public.family_meal_amount((i->>'qty')::numeric * v_need / m.servings, i->>'unit') END AS amt
    FROM public.family_meal_plan p
    JOIN public.family_meals m ON m.id = p.meal_id
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(m.ingredients, '[]'::jsonb)) i
    WHERE p.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND p.plan_date BETWEEN v_start AND v_start + 6
  ),
  inv AS (
    SELECT l.inv_id, min(l.plan_date) AS first_needed,
           string_agg(DISTINCT l.meal, ', ') AS meals,
           string_agg(CASE WHEN l.amt IS NULL THEN l.i->>'text' ELSE l.amt || ' ' || (l.i->>'item') END
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
         COALESCE(l.amt, l.i->>'text')
  FROM lines l WHERE l.inv_id IS NULL
  ORDER BY 1, 4, 3;
END;
$$;

