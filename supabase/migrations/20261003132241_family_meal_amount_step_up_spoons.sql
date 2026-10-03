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
  q numeric := p_qty; w int; f numeric; lab text; val numeric; num text; u text := p_unit;
BEGIN
  IF p_qty IS NULL OR p_qty <= 0 THEN RETURN NULL; END IF;
  -- Step big spoon amounts up: 3 tsp = 1 tbsp, 4 tbsp = 1/4 cup.
  IF u = 'tsp' AND q >= 3 THEN q := q / 3; u := 'tbsp'; END IF;
  IF u = 'tbsp' AND q >= 4 THEN q := q / 16; u := 'cup'; END IF;

  IF u = 'oz' THEN
    q := greatest(round(q), 1);
  ELSIF u IS NULL OR u = ANY (v_counts) THEN
    q := CASE WHEN q < 2 THEN greatest(round(q * 2) / 2, 0.5) ELSE round(q) END;
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
