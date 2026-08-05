-- Peter directive 2026-08-05: consistency retests must not count as extra
-- items in trait scoring. A retest is a second administration of its ORIGINAL
-- item; the pair is averaged into ONE effective item response before facet
-- aggregation, so every published item contributes equal weight. Previously
-- retest rows entered the mean as independent responses, double-weighting
-- retested items (2/7 vs 1/7 in a 6-item facet), and the shared-item retest
-- (238) routed by its own row label instead of its original's destinations.
--
-- Research basis (cited per "never prefer simpler over more accurate"):
--   * Same-sitting duplicate responses are not independent measurements —
--     memory and the consistency motive drive the second answer. Duplicates
--     embedded for validity checking are detection instruments, not content
--     items: Meade & Craig 2012, Psychological Methods 17(3):437-455;
--     Curran 2016, Journal of Experimental Social Psychology 66:4-19.
--   * Averaging the two observations reduces error for that item while
--     preserving the published scale's equal item weighting: aggregation
--     principle, Epstein 1983, Journal of Personality 51(3):360-392;
--     unit-weighted composites, Wainer 1976.
--
-- Consumers verified before this change: the v1-assessment edge function's
-- finalize write-back and hiregauge_v2_stint1_exit_gate both call
-- compute_newtworks_v2_facets_as_row (single source of truth — all facet
-- columns and downstream competency/role-fit/construct functions inherit).
-- compute_newtworks_v2_stint3_triggers re-implements the aggregation inline
-- and had the same double-count — fixed here with the same item-anchored
-- averaging; its no-extra-traits mapping is existing gate behavior and is
-- deliberately left unchanged. The careless-response detectors
-- (retest divergence, even-odd) read raw pairs BY DESIGN and are untouched.
-- n_items_scored now counts unique items, not response rows.

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
    SELECT e.eff_pct, m.hypothesized_trait
    FROM item_effective e
    JOIN public.hiregauge_item_extra_traits m
      ON m.section = e.section AND m.item_number = e.anchor_item_number
    WHERE m.is_scored_facet = true
  )
  SELECT trait, ROUND(AVG(eff_pct))::int, COUNT(*)::int
  FROM item_traits
  GROUP BY trait;
$function$;

CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_stint3_triggers(p_candidate_id uuid)
 RETURNS TABLE(hypothesized_trait text, facet_score integer)
 LANGUAGE sql
 STABLE
AS $function$
  -- Same item-anchored retest averaging as compute_newtworks_v2_facets_as_row
  -- (2026-08-05). Trait mapping stays own-trait-only (no extra traits) —
  -- existing gate behavior, deliberately unchanged.
  WITH answered AS (
    SELECT i.section, i.scale_max, i.reverse_coded,
           COALESCE(i.retest_of_item_number, i.item_number) AS anchor_item_number,
           r.response_value
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = 1
      AND i.section = 'newtworks_v2_personality'
      AND i.is_active = true
      AND i.stint IN (1, 2)  -- stint 1+2 ONLY -- never stint 3
      AND r.response_value IS NOT NULL
      AND i.scale_max IS NOT NULL
      AND i.scale_max > 1
  ),
  item_effective AS (
    SELECT a.section, a.anchor_item_number,
           AVG(CASE WHEN a.reverse_coded
                    THEN ((a.scale_max - a.response_value) / (a.scale_max - 1.0)) * 100.0
                    ELSE ((a.response_value - 1)           / (a.scale_max - 1.0)) * 100.0
               END) AS eff_pct
    FROM answered a
    GROUP BY a.section, a.anchor_item_number
  ),
  facets AS (
    SELECT o.hypothesized_trait, ROUND(AVG(e.eff_pct))::int AS facet_score
    FROM item_effective e
    JOIN public.hiregauge_instrument_items o
      ON o.section = e.section
     AND o.item_number = e.anchor_item_number
     AND o.retest_of_item_number IS NULL
    WHERE o.hypothesized_trait IS NOT NULL
    GROUP BY o.hypothesized_trait
  )
  SELECT f.hypothesized_trait, f.facet_score
  FROM facets f
  WHERE f.facet_score BETWEEN 45 AND 55
    AND EXISTS (
      SELECT 1 FROM public.hiregauge_instrument_items i
      WHERE i.section = 'newtworks_v2_personality'
        AND i.stint = 3
        AND i.is_active = true
        AND i.hypothesized_trait = f.hypothesized_trait
    );
$function$;
