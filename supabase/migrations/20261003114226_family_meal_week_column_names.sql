-- family_meal_week: output column names clashed with table columns; #variable_conflict use_column fixes it.
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
