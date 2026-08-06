-- Step 1: Revert migration 20260806201356's is_active changes on shared items 51, 55, 238
UPDATE hiregauge_instrument_items
SET is_active = true
WHERE section = 'newtworks_v2_personality'
  AND item_number IN (51, 55, 238);

UPDATE hiregauge_instrument_items
SET notes = 'PROTECTED shared item. Keyed to both compassion and friendliness via hiregauge_item_extra_traits. Twin copies 163/167 already retired. Mis-flagged as duplicate 2026-08-03 (reverted) and 2026-08-06 (reverted). Do not deactivate without Peter''s explicit direction.'
WHERE section = 'newtworks_v2_personality'
  AND item_number IN (51, 55, 238);

-- Step 2: Rewrite compassion norms notes -- keep citation/mean/sd, delete the false duplicate/verification claims
UPDATE hiregauge_facet_norms
SET notes = 'Source: 4-item facet, N=320,128 combined US sample, raw M=15.03 SD=3.10 on 4-20 scale. item_mean=15.03/4=3.7575, item_sd=3.10/4=0.775. Converted per spec formula. Accepted imprecision: item-count mismatch vs our facet (12 items).'
WHERE facet = 'compassion';

-- Step 3: Decouple scoring from serving
ALTER TABLE hiregauge_instrument_items
  ADD COLUMN IF NOT EXISTS score_excluded boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.compute_newtworks_v2_facets_as_row(p_candidate_id uuid, p_stint integer DEFAULT NULL::integer, p_sitting integer DEFAULT 1)
 RETURNS TABLE(hypothesized_trait text, facet_score integer, n_items_scored integer)
 LANGUAGE sql
 STABLE
AS $function$
  -- is_active governs SERVING only (whether an item is handed to a candidate
  -- taking the assessment right now). score_excluded governs SCORING only
  -- (whether an already-recorded response counts toward a facet score).
  -- These used to be the same column. That let a later bank edit (deactivating
  -- an item) retroactively rewrite the scores of candidates who validly
  -- answered it BEFORE the edit -- exactly what happened 2026-08-06 when
  -- items 51/55/238 were wrongly deactivated and it silently changed
  -- compassion/friendliness for 9 already-scored candidates. Use
  -- score_excluded for anything that should stop counting for both past and
  -- future responses; leave is_active alone to control serving only.
  WITH answered AS (
    SELECT i.section, i.scale_max, i.reverse_coded,
           COALESCE(i.retest_of_item_number, i.item_number) AS anchor_item_number,
           r.response_value
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.section = 'newtworks_v2_personality'
      AND i.score_excluded IS NOT TRUE
      AND (p_stint IS NULL OR i.stint = p_stint)
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
  item_extra_effective AS (
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
$function$;

-- Step 4: updated_at trigger so bank edits are traceable going forward
CREATE OR REPLACE FUNCTION public.set_updated_at_hiregauge_instrument_items()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hiregauge_instrument_items_updated_at ON hiregauge_instrument_items;
CREATE TRIGGER trg_hiregauge_instrument_items_updated_at
BEFORE UPDATE ON hiregauge_instrument_items
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at_hiregauge_instrument_items();
