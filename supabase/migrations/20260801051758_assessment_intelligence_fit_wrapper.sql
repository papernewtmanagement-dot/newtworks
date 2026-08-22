-- Wrapper for Team.jsx coaching hints + assessment panel, which need the
-- composite AND the best-fit role's live floor/ceiling in one round trip.
-- Centralizes the fetch-then-join in SQL (single source of truth) rather
-- than duplicating it in JS per hardcoded-functions rule (prefer accurate/
-- centralized over simple/duplicated).
CREATE OR REPLACE FUNCTION public.assessment_intelligence_fit(p_assessment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
  v_lss jsonb;
  v_composite numeric;
  v_best_role text;
  v_role_label text;
  v_floor numeric;
  v_ceiling numeric;
BEGIN
  SELECT public.hiregauge_lss_delta_v2(c.*) INTO v_lss
  FROM public.hiring_candidates c
  WHERE c.id = p_assessment_id;

  v_composite := (v_lss->>'intelligence_composite')::numeric;

  SELECT best_role, display_label
    INTO v_best_role, v_role_label
    FROM public.assessment_best_fit_role(p_assessment_id);

  IF v_best_role IS NOT NULL THEN
    SELECT r.intelligence_ideal_min, r.intelligence_ideal_max
      INTO v_floor, v_ceiling
      FROM public.hiring_candidates hc
      JOIN public.hiregauge_role_ideal_ranges r
        ON r.agency_id = hc.agency_id
       AND r.role_category = v_best_role
       AND r.role_level = 'default'
     WHERE hc.id = p_assessment_id;
  END IF;

  RETURN jsonb_build_object(
    'intelligence_composite', v_composite,
    'role_category', v_best_role,
    'role_label', v_role_label,
    'intelligence_floor', v_floor,
    'intelligence_ceiling', v_ceiling
  );
END;
$function$;
