-- =====================================================================
-- REVERT of two changes made in error earlier on 2026-08-03
-- (migration 20260803204512 / commit 5e53afe, fixes B and C).
-- Both overwrote deliberate, documented design decisions. Fix A of that
-- migration (revoking anon read on the item bank) STANDS and is not
-- touched here.
-- =====================================================================
--
-- REVERT B -- item 238 retest target.
--   Claimed defect: item 238 carried hypothesized_trait='friendliness' but
--   retest_of_item_number=51, a compassion item, so it looked like a
--   cross-construct retest that could never fail.
--   Why that was wrong: migration 20260803000100
--   (hiregauge_shared_item_dual_trait_scoring) states it directly -- "Item
--   238 was the repeat-check for 163. Repoint it at 51, which carries the
--   identical sentence and is the surviving copy." Item 51 is scored for
--   BOTH compassion AND friendliness via hiregauge_item_extra_traits, so
--   retesting 51 IS retesting a friendliness item. The check that flagged
--   this compared hiregauge_instrument_items.hypothesized_trait only and
--   ignored the extra-traits table -- the same table
--   compute_newtworks_v2_facets_as_row reads to build facet scores.
--   Restoring the designed state, plus a note on the row so a future pass
--   does not "fix" it a third time.
--
-- REVERT C -- straight-lining measure.
--   Claimed defect: comparing raw response_value across a battery mixing
--   scale_max 4/5/7 misses a candidate who always clicks the top option.
--   Why that was wrong: the shipped function's own docstring already
--   settled this -- "Computed on RAW response_value (not reverse-coded)
--   since straightlining is about literal answer repetition, not adjusted
--   trait direction," citing Johnson 2005 and Huang, Curran, Keeney,
--   Poposki & DeShon 2012, who define the long-string index on the literal
--   repeated response option. The op-rule "mixed scale sizes are locked"
--   was applied to this function without first checking that its raw-value
--   choice had already been reasoned through and documented.
--   Restoring raw response_value and the original detail string verbatim.
-- =====================================================================

-- --- REVERT B ---------------------------------------------------------
UPDATE public.hiregauge_instrument_items
SET retest_of_item_number = 51,
    item_text             = 'Cheer people up.',
    hypothesized_trait    = 'friendliness',
    reverse_coded         = false,
    scale_max             = 5,
    notes                 = 'Within-sitting repeat-check. Points at item 51 BY DESIGN: 51 carries '
                            || 'the identical sentence and is scored for BOTH compassion and '
                            || 'friendliness via hiregauge_item_extra_traits, so a retest of 51 is a '
                            || 'friendliness retest. Origin: migration 20260803000100 '
                            || '(shared-item dual-trait scoring), which retired the duplicate copy '
                            || '(item 163) and kept 51. DO NOT repoint this at a different item on the '
                            || 'basis that 51''s hypothesized_trait reads compassion -- check '
                            || 'hiregauge_item_extra_traits first. Repointed to 162 in error on '
                            || '2026-08-03 and reverted the same day.',
    updated_at            = now()
WHERE section = 'newtworks_v2_personality'
  AND item_number = 238;

-- --- REVERT C ---------------------------------------------------------
-- Restored to the pre-20260803204512 body. Original docstring preserved.
--
-- (c) Straightlining / long-string index. Johnson (2005) and Huang, Curran,
-- Keeney, Poposki & DeShon (2012) use the longest unbroken run of identical
-- response values ("long string") as a careless-responding signal; Huang et
-- al. use a threshold around 10 consecutive identical responses. Computed on
-- RAW response_value (not reverse-coded) since straightlining is about
-- literal answer repetition, not adjusted trait direction. Ordered by
-- served_at (actual served order for this candidate), not item_number.
--
-- DO NOT convert this to normalized scale position. That was attempted on
-- 2026-08-03 on the grounds that mixed scale_max values (4/5/7) make raw
-- values incomparable, and reverted the same day: the measure is defined on
-- the literal repeated response option, not on a derived position. If the
-- "always clicks the top option across different scale lengths" pattern is
-- worth catching, it is a SEPARATE seventh method with its own citation and
-- its own threshold -- not a redefinition of the long-string index.
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_straightlining(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH ordered AS (
    SELECT r.response_value,
           r.served_at,
           ROW_NUMBER() OVER (ORDER BY r.served_at) AS pos
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.response_value IS NOT NULL
      AND r.served_at IS NOT NULL
  ),
  grp AS (
    SELECT response_value, pos,
           pos - ROW_NUMBER() OVER (PARTITION BY response_value ORDER BY pos) AS grp_key
    FROM ordered
  ),
  runs AS (
    SELECT response_value, count(*)::int AS run_length
    FROM grp
    GROUP BY response_value, grp_key
  ),
  agg AS (
    SELECT COALESCE(max(run_length), 0) AS longest_run
    FROM runs
  )
  SELECT
    (longest_run >= 10) AS fired,
    format('longest identical-response run: %s items', longest_run) AS detail
  FROM agg;
$function$;
