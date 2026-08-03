-- ============================================================================
-- Shared-item scoring. Some items belong to more than one published scale --
-- the same free-personality-pool sentence is keyed onto two different facets
-- by its source instruments. Previously both copies were administered, which
-- (a) wasted candidate time, (b) artificially inflated apparent internal
-- consistency, and (c) produced two answers to one question that cannot be
-- reconciled. Fix: administer once, score for both facets.
--
-- CAUTION TO CARRY FORWARD: a shared item makes the two facet scores share
-- measurement error, so they will correlate slightly more than the underlying
-- traits do. Any competency or role-fit formula must not treat two facets that
-- share an item as two independent readings. One shared item out of six is a
-- small effect but it is not zero.
--
-- Direction is per trait, not per item. "Rarely get irritated" is reverse-keyed
-- for anger and forward-keyed for emotional stability. Both are correct.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.hiregauge_item_extra_traits (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  section text NOT NULL DEFAULT 'newtworks_v2_personality',
  item_number integer NOT NULL,
  hypothesized_trait text NOT NULL,
  reverse_coded boolean NOT NULL,
  is_scored_facet boolean NOT NULL DEFAULT true,
  source_note text,
  created_at timestamptz DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_hiregauge_item_extra_traits
  ON public.hiregauge_item_extra_traits (section, item_number, hypothesized_trait);

COMMENT ON TABLE public.hiregauge_item_extra_traits IS
  'Additional traits an item is scored for beyond hiregauge_instrument_items.hypothesized_trait. One row per extra trait. reverse_coded is the direction FOR THAT TRAIT and may differ from the item row. is_scored_facet=false means the trait is a validity index, not a personality facet, and must not appear in facet output.';

-- Retire the redundant copies. Deactivate only, never delete.
UPDATE public.hiregauge_instrument_items
SET is_active = false, updated_at = now()
WHERE section IN ('newtworks_v2_personality')
  AND item_number IN (163, 214, 217, 167, 169, 308);

-- Item 238 was the repeat-check for 163. Repoint it at 51, which carries the
-- identical sentence and is the surviving copy.
UPDATE public.hiregauge_instrument_items
SET retest_of_item_number = 51, updated_at = now()
WHERE item_number = 238;

INSERT INTO public.hiregauge_item_extra_traits
  (item_number, hypothesized_trait, reverse_coded, is_scored_facet, source_note)
VALUES
  (51,  'friendliness',          false, true,
   'Same sentence as retired item 163. Keyed to both Compassion and Friendliness in the free personality item pool. Same direction for both.'),
  (55,  'friendliness',          true,  true,
   'Same sentence as retired item 167. Reverse-keyed for both Compassion and Friendliness.'),
  (134, 'emotional_stability',   false, true,
   'Same sentence as retired item 214. Reverse-keyed for Anger (agreeing means less anger) but FORWARD-keyed for Emotional Stability (agreeing means more stability). Opposite directions, both correct.'),
  (124, 'emotional_stability',   false, true,
   'Same sentence as retired item 217. Reverse-keyed for Anxiety, forward-keyed for Emotional Stability.'),
  (21,  'dutifulness',           false, true,
   'Same sentence as retired item 169. Keyed to both HEXACO Fairness and Dutifulness. Same direction.'),
  (306, 'fairness',              false, true,
   'Item 306 is a faking-good item whose text is HEXACO Fairness item 1 (retired copy: item 17). Scoring it for fairness as well restores fairness to six scored items after the 2026-08-02 length trim.'),
  (19,  'impression_management', false, false,
   'HEXACO Fairness item that is also a positively-keyed impression-management item. Same sentence as retired item 308. Endorsement raises the impression-management index. Not a personality facet -- validity index only.')
ON CONFLICT (section, item_number, hypothesized_trait) DO NOTHING;

-- Facet scoring now reads the item row plus any extra-trait rows.
CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_facets_as_row(
  p_candidate_id uuid,
  p_stint integer DEFAULT NULL::integer,
  p_sitting integer DEFAULT 1
)
RETURNS TABLE(hypothesized_trait text, facet_score integer, n_items_scored integer)
LANGUAGE sql
STABLE
AS $function$
  WITH answered AS (
    SELECT i.id, i.item_number, i.section, i.scale_max, i.reverse_coded,
           i.hypothesized_trait, r.response_value
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
  scored_items AS (
    SELECT a.hypothesized_trait AS trait, a.scale_max, a.reverse_coded, a.response_value
    FROM answered a
    WHERE a.hypothesized_trait IS NOT NULL
    UNION ALL
    SELECT m.hypothesized_trait, a.scale_max, m.reverse_coded, a.response_value
    FROM answered a
    JOIN public.hiregauge_item_extra_traits m
      ON m.section = a.section AND m.item_number = a.item_number
    WHERE m.is_scored_facet = true
  ),
  normalized AS (
    SELECT trait,
           CASE WHEN reverse_coded
                THEN ((scale_max - response_value) / (scale_max - 1.0)) * 100.0
                ELSE ((response_value - 1)        / (scale_max - 1.0)) * 100.0
           END AS pct
    FROM scored_items
  )
  SELECT trait, ROUND(AVG(pct))::int, COUNT(*)::int
  FROM normalized
  GROUP BY trait;
$function$;
