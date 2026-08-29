-- 2026-08-29 — Resume auto-decline gets its own decline_reason.
--
-- WHY: auto_decline_on_resume_score() has always set status='declined' and left
-- decline_reason NULL, with a comment saying the enum "is for a different
-- purpose". That was never true of the assessment gate (which sets
-- 'assessment_score') and it left 92 declined candidates with no reason at all —
-- the single largest group in the Declined view. The decline-notice emailer
-- shipping in the next migration needs to route on this column, so the gap is
-- closed here rather than worked around.

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS team_assessments_decline_reason_check;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT team_assessments_decline_reason_check
  CHECK (
    decline_reason IS NULL
    OR decline_reason = ANY (ARRAY[
      'active_applicant'::text,
      'offer_rescinded'::text,
      'calibration_only'::text,
      'former_team'::text,
      'assessment_score'::text,
      'resume_score'::text,
      'bounced_undeliverable'::text
    ])
  );

CREATE OR REPLACE FUNCTION public.auto_decline_on_resume_score()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_threshold numeric;
  v_composite numeric;
  v_char_avg numeric;
BEGIN
  IF NEW.resume_analysis IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.resume_analysis IS NOT DISTINCT FROM NEW.resume_analysis THEN
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM 'applied' THEN
    RETURN NEW;
  END IF;

  -- Fix (2026-08-11, Peter-approved, open_question 7e377007 part 2): read
  -- the WEIGHTED score (Capability 20% / Character 40% / Commitment 40%)
  -- via public.resume_weighted_composite, not the plain unweighted average
  -- that used to live at resume_analysis->>'avg'. The published verdict
  -- bands (70/50) were designed against the weighted number; for lopsided
  -- profiles the two diverge and the gate was deciding on the wrong one.
  v_composite := public.resume_weighted_composite(NEW.resume_analysis);
  IF v_composite IS NULL THEN
    RETURN NEW;
  END IF;

  -- Change (2026-08-20, Peter directive): the routing gate now reads
  -- auto_decline_threshold, falling back to consider_threshold when unset.
  -- This decouples "who gets auto-declined" from "what the resume verdict
  -- label says", so the published 50/70 band stays research-tied while the
  -- gate can be opened or closed independently.
  SELECT COALESCE(auto_decline_threshold, consider_threshold) INTO v_threshold
  FROM public.hiregauge_verdict_thresholds WHERE layer = 'resume';

  IF v_threshold IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_composite < v_threshold THEN
    -- Early-career lane exception (2026-08-11, Peter-approved): a below-
    -- threshold resume with the early_career flag, a Character-signal
    -- average of 40+, and no integrity flag stays at 'applied' so the
    -- invite pipeline routes it to the assessment. The resume verdict
    -- label remains a decline; this is routing, not scoring.
    v_char_avg :=
      ( COALESCE((NEW.resume_analysis#>>'{signals,honesty,score}')::numeric, 0)
      + COALESCE((NEW.resume_analysis#>>'{signals,concern_for_others,score}')::numeric, 0)
      + COALESCE((NEW.resume_analysis#>>'{signals,hard_work_ethic,score}')::numeric, 0)
      + COALESCE((NEW.resume_analysis#>>'{signals,personal_responsibility,score}')::numeric, 0)
      + COALESCE((NEW.resume_analysis#>>'{signals,presentation,score}')::numeric, 0)
      ) / 5.0;

    IF (NEW.resume_analysis->>'early_career') = 'true'
       AND NEW.integrity_flag IS NOT TRUE
       AND v_char_avg >= 40 THEN
      RETURN NEW;
    END IF;

    NEW.status := 'declined';
    -- Change (2026-08-29): stamp decline_reason = 'resume_score'. It used to be
    -- left NULL on the theory that the enum was for something else; it is not —
    -- the assessment gate has always stamped 'assessment_score' here. Leaving it
    -- NULL made the resume auto-decline invisible to anything routing on reason,
    -- including the candidate decline-notice emailer.
    NEW.decline_reason := 'resume_score';
    NEW.decision_notes := trim(both E'\n' from COALESCE(NEW.decision_notes || E'\n\n', '') ||
      'Auto-declined ' || NOW()::date || ': resume weighted score ' || v_composite ||
      ' below resume-layer auto-decline threshold (' || v_threshold || '). ' ||
      COALESCE(NEW.resume_analysis->>'narrative', ''));
  END IF;

  RETURN NEW;
END;
$function$;

-- Backfill: every historical decline whose notes show the resume gate fired.
-- Evidence-based only — the 3 rows with no such note stay NULL rather than being
-- guessed at.
UPDATE public.hiring_candidates
   SET decline_reason = 'resume_score'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND status = 'declined'
   AND decline_reason IS NULL
   AND decision_notes ILIKE '%resume-layer%';
