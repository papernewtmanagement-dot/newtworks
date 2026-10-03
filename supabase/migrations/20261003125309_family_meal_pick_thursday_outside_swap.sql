-- Peter 2026-10-03 (decision 1B): Thursday is its own easy night. It rotates through all easy meals,
-- whatever the meat, and does not count toward the chicken/beef swap. The swap runs over regular nights only.
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

  -- The swap looks only at regular nights (kind cook); Thursday and dinner out are skipped.
  SELECT m.meat INTO v_last
  FROM public.family_meal_plan p
  JOIN public.family_meals m ON m.id = p.meal_id
  WHERE p.plan_date < p_date AND p.kind = 'cook' AND m.meat IN ('chicken', 'beef')
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
           (v_slot = 'simple' OR m.meat = v_want) DESC,
           s.last_on NULLS FIRST,
           random()
  LIMIT 1;

  RETURN v_id;
END;
$$;
COMMENT ON FUNCTION public.family_meal_pick(date, uuid) IS 'Picks one meal for a date. Regular nights: meat = opposite of the last regular-night chicken-or-beef dinner (chicken if none). Thursday (Peter 2026-10-03): any easy meal, whatever the meat, and it does not count toward the swap. Among matches, the meal served longest ago (or never) wins so the list rotates; ties at random. NULL for dinner out. The only place the choosing rules live.';
REVOKE EXECUTE ON FUNCTION public.family_meal_pick(date, uuid) FROM PUBLIC, anon, authenticated;
