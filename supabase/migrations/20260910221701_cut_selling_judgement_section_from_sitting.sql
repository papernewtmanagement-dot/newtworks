-- Cut the selling-judgement scenarios (section newtworks_v2_sjt, stint 3) from the
-- assessment sitting. Peter directive 2026-09-10: "If it adds the least to our
-- predictive power and takes so long for the candidate, then cut it."
--
-- WHY: weight 0 by construction (no hiregauge_role_facet_weights rows, no sjt norm),
-- one scored candidate, ~20 minutes per sitting at the point where candidates
-- already quit (14 of 27 dropouts happen in stint 2). Once weighted it would have
-- been ~5% of the score; SJTs add little over reasoning + personality already
-- measured (McDaniel, Hartman, Whetzel & Grubb 2007 Personnel Psychology 60:63-91).
--
-- HOW: hard DELETE of the 16 items (Peter's word was "cut"; the purge guard only
-- fires on deactivation, and hiregauge_candidate_responses.item_id cascades, which
-- removes the 48 pilot responses from 3 candidates -- all unweighted). The
-- endpoint needs NO deploy: v1-assessment computes stint3Done as
-- (stint3Items.length === 0 || ...) and finalize checks stint3Total > 0, so an
-- empty stint 3 is skipped straight to stint 5 (verified in
-- supabase/functions/v1-assessment/index.ts lines 511 and 977). CandidateDetail
-- renders the SJT block only when sjt_score is non-null, so clearing the one
-- pilot score hides it. The pilot-ready trigger can never fire again and is
-- dropped. Scorer functions (apply_newtworks_v2_sjt_to_candidate,
-- hiregauge_sjt_pilot_item_stats) stay: finalize calls the scorer best-effort and
-- it is a no-op with no items. hiregauge_sjt_draft_items (authoring drafts) is
-- left alone.

DROP TRIGGER IF EXISTS trg_sjt_pilot_check ON public.hiring_candidates;
DROP FUNCTION IF EXISTS public.hiregauge_sjt_pilot_check_trg();

UPDATE public.hiring_candidates
SET sjt_score = NULL, sjt_topic_detail = NULL
WHERE sjt_score IS NOT NULL OR sjt_topic_detail IS NOT NULL;

DELETE FROM public.hiregauge_instrument_items
WHERE section = 'newtworks_v2_sjt';
