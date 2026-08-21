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
    -- decline_reason is a constrained enum for a different purpose
    -- (active_applicant/offer_rescinded/calibration_only/former_team) —
    -- use decision_notes for the free-text auto-decline explanation instead.
    NEW.decision_notes := trim(both E'\n' from COALESCE(NEW.decision_notes || E'\n\n', '') ||
      'Auto-declined ' || NOW()::date || ': resume weighted score ' || v_composite ||
      ' below resume-layer auto-decline threshold (' || v_threshold || '). ' ||
      COALESCE(NEW.resume_analysis->>'narrative', ''));
  END IF;

  RETURN NEW;
END;
$function$;
