CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_facets_as_row(p_candidate_id uuid, p_stint integer DEFAULT NULL::integer, p_sitting integer DEFAULT 1)
 RETURNS TABLE(hypothesized_trait text, facet_score integer, n_items_scored integer)
 LANGUAGE sql
 STABLE
AS $function$
  WITH answered AS (
    SELECT i.section, i.scale_max, i.reverse_coded,
           COALESCE(i.retest_of_item_number, i.item_number) AS anchor_item_number,
           r.response_value
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.section = 'newtworks_v2_personality'
      AND i.is_active = true
      AND (p_stint IS NULL OR i.stint = p_stint)
      AND r.response_value IS NOT NULL
      AND i.scale_max IS NOT NULL
      AND i.scale_max > 1
  ),
  item_effective AS (
    -- One row per ORIGINAL item: keyed-normalized responses of the original
    -- and any retest copies averaged together. Normalization uses each
    -- response row's own scale_max/keying (retests are verbatim copies, so
    -- these match by construction).
    SELECT a.section, a.anchor_item_number,
           AVG(CASE WHEN a.reverse_coded
                    THEN ((a.scale_max - a.response_value) / (a.scale_max - 1.0)) * 100.0
                    ELSE ((a.response_value - 1)           / (a.scale_max - 1.0)) * 100.0
               END) AS eff_pct
    FROM answered a
    GROUP BY a.section, a.anchor_item_number
  ),
  item_extra_effective AS (
    -- 2026-08-06: extra-traits leg now honors hiregauge_item_extra_traits.reverse_coded (OQ 643416d6)
    -- Mirrors item_effective's normalization, but keyed by the EXTRA table's own
    -- reverse_coded flag instead of the home item's, since an item can be scored
    -- one direction into its home trait and the opposite direction into an extra trait.
    SELECT a.section, a.anchor_item_number, m.hypothesized_trait AS trait,
           AVG(CASE WHEN m.reverse_coded
                    THEN ((a.scale_max - a.response_value) / (a.scale_max - 1.0)) * 100.0
                    ELSE ((a.response_value - 1)           / (a.scale_max - 1.0)) * 100.0
               END) AS eff_pct
    FROM answered a
    JOIN public.hiregauge_item_extra_traits m
      ON m.section = a.section AND m.item_number = a.anchor_item_number
    WHERE m.is_scored_facet = true
    GROUP BY a.section, a.anchor_item_number, m.hypothesized_trait
  ),
  item_traits AS (
    -- Trait destinations come from the ORIGINAL item's row (own trait) plus
    -- its scored extra traits — never from a retest row's label.
    SELECT e.eff_pct, o.hypothesized_trait AS trait
    FROM item_effective e
    JOIN public.hiregauge_instrument_items o
      ON o.section = e.section
     AND o.item_number = e.anchor_item_number
     AND o.retest_of_item_number IS NULL
    WHERE o.hypothesized_trait IS NOT NULL
    UNION ALL
    SELECT ee.eff_pct, ee.trait
    FROM item_extra_effective ee
  )
  SELECT trait, ROUND(AVG(eff_pct))::int, COUNT(*)::int
  FROM item_traits
  GROUP BY trait;
$function$
