-- ============================================================================
-- Faking-good (impression management) scoring.
--
-- Ten items were being collected and never scored. This closes that.
--
-- Instrument: the free public-domain analog of the impression-management
-- subscale of the Balanced Inventory of Desirable Responding (Paulhus 1991).
-- Five items are positively keyed (endorsing them looks too good to be true)
-- and five are negatively keyed (denying them looks too good to be true).
--
-- WHAT THIS SCORE MUST NOT BE USED FOR: adjusting or correcting personality
-- facet scores, and rejecting a candidate on its own. Ones, Viswesvaran & Reiss
-- 1996 (Journal of Applied Psychology 81(6) 660-679) found social desirability
-- acts as neither a predictor, a suppressor, nor a mediator of the
-- personality-to-performance relationship, and that correcting scores for it
-- does not improve validity -- it mostly removes real variance. So this is
-- reported as context for reading the self-report profile, nothing more.
--
-- Bands are PROVISIONAL with zero local data. Job applicants score higher on
-- these scales than research volunteers do, so a band drawn from research norms
-- would over-flag. Revisit after 30 completed assessments.
-- ============================================================================

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS impression_management smallint,
  ADD COLUMN IF NOT EXISTS impression_management_band text,
  ADD COLUMN IF NOT EXISTS impression_management_detail jsonb;

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS hiring_candidates_impression_management_range;
ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT hiring_candidates_impression_management_range
  CHECK (impression_management IS NULL OR (impression_management >= 0 AND impression_management <= 100));

COMMENT ON COLUMN public.hiring_candidates.impression_management IS
  'Faking-good index, 0-100. Higher means more too-good-to-be-true answering. Context only: never used to adjust facet scores and never a standalone rejection (Ones, Viswesvaran & Reiss 1996).';

-- Membership and direction live in the extra-traits map so nothing has to parse
-- free text to know which items these are.
INSERT INTO public.hiregauge_item_extra_traits
  (item_number, hypothesized_trait, reverse_coded, is_scored_facet, source_note)
VALUES
  (301, 'impression_management', false, false, 'Positively keyed: endorsement raises the index.'),
  (302, 'impression_management', false, false, 'Positively keyed: endorsement raises the index.'),
  (303, 'impression_management', true,  false, 'Negatively keyed: denial raises the index.'),
  (304, 'impression_management', true,  false, 'Negatively keyed: denial raises the index.'),
  (305, 'impression_management', true,  false, 'Negatively keyed: denial raises the index.'),
  (306, 'impression_management', false, false, 'Positively keyed: endorsement raises the index.'),
  (307, 'impression_management', false, false, 'Positively keyed: endorsement raises the index.'),
  (309, 'impression_management', true,  false, 'Negatively keyed: denial raises the index.'),
  (310, 'impression_management', true,  false, 'Negatively keyed: denial raises the index.')
ON CONFLICT (section, item_number, hypothesized_trait) DO NOTHING;

-- Set the item-level direction flag too. It is not what the index reads, but
-- the straight-lining and Stint 1 long-string checks need to know which items
-- are reverse-worded, and these were all sitting NULL.
UPDATE public.hiregauge_instrument_items
SET reverse_coded = true, updated_at = now()
WHERE item_number IN (303, 304, 305, 309, 310) AND hypothesized_trait IS NULL;

UPDATE public.hiregauge_instrument_items
SET reverse_coded = false, updated_at = now()
WHERE item_number IN (301, 302, 306, 307) AND hypothesized_trait IS NULL;

CREATE OR REPLACE FUNCTION public.hiregauge_v2_impression_management(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS TABLE(score integer, n_items integer, band text, detail jsonb)
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_score numeric;
  v_n     int;
  v_band  text;
  v_detail jsonb;
BEGIN
  WITH scored AS (
    SELECT i.item_number,
           m.reverse_coded,
           i.scale_max,
           r.response_value,
           CASE WHEN m.reverse_coded
                THEN ((i.scale_max - r.response_value) / (i.scale_max - 1.0)) * 100.0
                ELSE ((r.response_value - 1)           / (i.scale_max - 1.0)) * 100.0
           END AS pct
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    JOIN public.hiregauge_item_extra_traits m
      ON m.section = i.section AND m.item_number = i.item_number
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = p_sitting
      AND i.is_active = true
      AND m.hypothesized_trait = 'impression_management'
      AND r.response_value IS NOT NULL
      AND i.scale_max IS NOT NULL AND i.scale_max > 1
  )
  SELECT ROUND(AVG(pct)), COUNT(*)::int,
         jsonb_object_agg(item_number, ROUND(pct))
  INTO v_score, v_n, v_detail
  FROM scored;

  IF v_n IS NULL OR v_n = 0 THEN
    RETURN QUERY SELECT NULL::int, 0, NULL::text,
      jsonb_build_object('reason', 'no_impression_management_responses');
    RETURN;
  END IF;

  v_band := CASE
    WHEN v_score >= 90 THEN 'very_elevated'
    WHEN v_score >= 75 THEN 'elevated'
    ELSE 'typical'
  END;

  RETURN QUERY SELECT v_score::int, v_n, v_band,
    jsonb_build_object(
      'per_item_percent', v_detail,
      'items_scored', v_n,
      'items_expected', 10,
      'bands', 'typical under 75, elevated 75-89, very elevated 90+ (PROVISIONAL, no local data)',
      'interpretation', CASE
        WHEN v_score >= 90 THEN 'Answered as an almost flawless person. Read every self-report facet with heavy caution and lean on the interview, references and the scenario section instead.'
        WHEN v_score >= 75 THEN 'Some polishing. Self-report facets are probably shaded a little favourably.'
        ELSE 'No unusual polishing. Self-report facets can be read at face value.'
      END,
      'do_not', 'Do not adjust facet scores for this and do not reject on this alone (Ones, Viswesvaran & Reiss 1996).'
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_impression_management_to_candidate(p_candidate_id uuid, p_sitting integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  r RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.hiring_candidates WHERE id = p_candidate_id) THEN
    RETURN jsonb_build_object('error', 'candidate_not_found', 'candidate_id', p_candidate_id);
  END IF;

  SELECT * INTO r FROM public.hiregauge_v2_impression_management(p_candidate_id, p_sitting);

  IF r.n_items = 0 THEN
    RETURN jsonb_build_object('candidate_id', p_candidate_id, 'wrote', false, 'reason', 'no_impression_management_responses');
  END IF;

  UPDATE public.hiring_candidates
  SET impression_management = r.score,
      impression_management_band = r.band,
      impression_management_detail = r.detail,
      updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object('candidate_id', p_candidate_id, 'wrote', true,
                            'score', r.score, 'band', r.band, 'n_items', r.n_items);
END;
$function$;
