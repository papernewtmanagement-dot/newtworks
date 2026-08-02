-- Correction to Step 10, per origin-thread planning decision 2026-08-02:
-- SJT items are not near-parallel measures of 10 narrow constructs the way
-- Likert facet items are -- each scenario is inherently multidimensional,
-- so per-topic alpha is low by construction, not by defect (Whetzel &
-- McDaniel 2009, HRMR 19:188-202; Catano, Brochu & Lamerson 2012, IJSA
-- 20:333-346). The 10 hypothesized_trait tags are a content blueprint
-- (domain coverage), not a scoring dimension. Score as ONE total composite
-- across all 40 items instead. McDaniel, Hartman, Whetzel & Grubb 2007
-- (Personnel Psychology 60:63-91): SJT total scores predict job
-- performance at .26 uncorrected / .34 corrected with incremental
-- validity above cognitive ability and the Big Five -- no comparable
-- evidence base exists for SJT subscore interpretation.

-- Drop the 10 per-construct columns + their CHECK constraint + sjt_total
-- (superseded by the single sjt_score column below).
ALTER TABLE public.hiring_candidates DROP CONSTRAINT IF EXISTS hiring_candidates_sjt_scores_0_100;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_compliance_licensing_boundary;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_compliance_outbound_consent;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_composure_under_load;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_documentation_discipline;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_escalation_judgment;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_feedback_channel_discipline;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_honesty_integrity;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_peer_accountability;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_service_within_process;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_speaking_up_judgment;
ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS sjt_total;

-- Single total composite (0-100, percent correct across all 40 items).
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_score numeric;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hiring_candidates_sjt_score_0_100') THEN
    ALTER TABLE public.hiring_candidates ADD CONSTRAINT hiring_candidates_sjt_score_0_100
      CHECK (sjt_score IS NULL OR (sjt_score BETWEEN 0 AND 100));
  END IF;
END $$;

-- Per-topic hit counts for qualitative review ONLY -- directional signal,
-- never a standalone score, never fed into any competency or role-fit
-- calculation. This is what the hypothesized_trait blueprint tags are for.
ALTER TABLE public.hiring_candidates ADD COLUMN IF NOT EXISTS sjt_topic_detail jsonb;

-- Rewrite the write-back function in place (same name/signature the edge
-- fn already calls -- no edge fn change needed). Reliability index, if
-- ever added, should be split-half (odd/even), NOT Cronbach's alpha --
-- alpha is the wrong statistic for a multidimensional-item instrument and
-- a low value would be misread as a defect.
CREATE OR REPLACE FUNCTION public.apply_newtworks_v2_sjt_to_candidate(p_candidate_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_agency_id uuid;
  v_correct_n int;
  v_total_n int;
  v_score numeric;
  v_topic_detail jsonb;
BEGIN
  SELECT agency_id INTO v_agency_id FROM public.hiring_candidates WHERE id = p_candidate_id;
  IF v_agency_id IS NULL THEN
    RETURN jsonb_build_object('error','candidate_not_found','candidate_id', p_candidate_id);
  END IF;

  SELECT
    count(*) FILTER (WHERE r.is_correct)::int,
    count(*)::int
  INTO v_correct_n, v_total_n
  FROM public.hiregauge_candidate_responses r
  JOIN public.hiregauge_instrument_items i ON r.item_id = i.id
  WHERE r.candidate_id = p_candidate_id
    AND i.section = 'newtworks_v2_sjt';

  IF v_total_n = 0 THEN
    RETURN jsonb_build_object('candidate_id', p_candidate_id, 'wrote', false, 'reason', 'no_sjt_responses');
  END IF;

  v_score := ROUND(100.0 * v_correct_n::numeric / v_total_n::numeric, 1);

  -- Per-topic hit counts, directional only -- not a scored dimension.
  SELECT jsonb_object_agg(topic, jsonb_build_object('correct', correct_n, 'n', total_n))
  INTO v_topic_detail
  FROM (
    SELECT
      i.hypothesized_trait AS topic,
      count(*) FILTER (WHERE r.is_correct)::int AS correct_n,
      count(*)::int AS total_n
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON r.item_id = i.id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_sjt'
      AND i.hypothesized_trait IS NOT NULL
    GROUP BY i.hypothesized_trait
  ) topic_rows;

  UPDATE public.hiring_candidates SET
    sjt_score = v_score,
    sjt_topic_detail = v_topic_detail,
    updated_at = now()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object(
    'candidate_id', p_candidate_id,
    'wrote', true,
    'sjt_score', v_score,
    'correct', v_correct_n,
    'n', v_total_n,
    'topic_detail', v_topic_detail
  );
END;
$function$;
