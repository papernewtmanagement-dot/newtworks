-- Delivery wiring, part 1 of 2 (edge function patch is part 2, shipped separately as a code commit).
--
-- (a) Move the 100 FC pairs from stint=1 to stint=2. They were parked at
-- stint=1 during authoring; stint 2 is where they actually belong -- it's
-- the unconditional personality-baseline slot they replace. Purely a data
-- placement fix, safe to apply now since is_active is still false on all
-- 100 items (Peter's go-live gate, untouched here).
UPDATE public.hiregauge_instrument_items
SET stint = 2
WHERE section = 'newtworks_v2_personality_fc';

-- (b) Single source-of-truth helper the edge function's finalize step calls
-- to decide which facet-scoring function to run and which assessment_source
-- to write. Data-driven (checks which personality section the candidate
-- actually has responses in), not a persistent per-candidate flag set at
-- invite time -- so there is still exactly ONE assessment being served at
-- any given moment (whichever section is_active), consistent with the
-- 2026-08-02 v1-assessment directive against a dual-path switch. The
-- practical effect: a candidate's path is decided by which section was live
-- at the moment they reached stint 2, and stays that way for the rest of
-- their sitting even if is_active flips underneath them mid-assessment.
CREATE OR REPLACE FUNCTION public.hiregauge_candidate_used_fc_personality(p_candidate_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND r.sitting = 1
      AND i.section = 'newtworks_v2_personality_fc'
  );
$function$;
