-- Add lss_total_accuracy (and lss_total_ideal_min for symmetry) to _hiregauge_get_trait_value
-- so validity/LSS rules can reference these columns in trait_signature conditions.
CREATE OR REPLACE FUNCTION public._hiregauge_get_trait_value(p_ta hiring_candidates, p_trait text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_trait
    WHEN 'deadline_motivation'     THEN p_ta.deadline_motivation::numeric
    WHEN 'recognition_drive'       THEN p_ta.recognition_drive::numeric
    WHEN 'assertiveness'           THEN p_ta.assertiveness::numeric
    WHEN 'independent_spirit'      THEN p_ta.independent_spirit::numeric
    WHEN 'analytical'              THEN p_ta.analytical::numeric
    WHEN 'compassion'              THEN p_ta.compassion::numeric
    WHEN 'self_promotion'          THEN p_ta.self_promotion::numeric
    WHEN 'belief_in_others'        THEN p_ta.belief_in_others::numeric
    WHEN 'optimism'                THEN p_ta.optimism::numeric
    WHEN 'overall_score'           THEN p_ta.overall_score::numeric
    WHEN 'lss_total_accuracy'      THEN p_ta.lss_total_accuracy::numeric
    WHEN 'lss_total_ideal_min'     THEN p_ta.lss_total_ideal_min::numeric
    WHEN 'maintains_high_activity' THEN
      CASE
        WHEN p_ta.deadline_motivation IS NULL OR p_ta.recognition_drive IS NULL
          OR p_ta.assertiveness IS NULL OR p_ta.independent_spirit IS NULL
          OR p_ta.analytical IS NULL OR p_ta.compassion IS NULL
          OR p_ta.self_promotion IS NULL OR p_ta.belief_in_others IS NULL
          OR p_ta.optimism IS NULL THEN NULL
        ELSE (public.cts_sales_outbound_competencies(
          p_ta.deadline_motivation, p_ta.recognition_drive, p_ta.assertiveness,
          p_ta.independent_spirit, p_ta.analytical, p_ta.compassion,
          p_ta.self_promotion, p_ta.belief_in_others, p_ta.optimism
        )->>'maintains_high_activity')::numeric
      END
    ELSE NULL
  END;
$function$;
