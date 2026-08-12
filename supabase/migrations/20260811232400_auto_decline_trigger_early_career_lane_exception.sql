-- NOTE: sibling file to 20260811231424 -- see that file's header for context
-- on why this is a consolidated mirror of three unmirrored 2026-08-11
-- migrations (reminder loop fix, early-career invite lane, early-career
-- trigger exception). Body reconstructed 2026-08-12 from the live pg_proc
-- definition as read at the start of this session, before this session's
-- own weighted-composite edit (see 20260812035528 for what changed after).
CREATE OR REPLACE FUNCTION public.auto_decline_on_resume_score()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_threshold numeric;
  v_avg numeric;
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

  v_avg := (NEW.resume_analysis->>'avg')::numeric;
  IF v_avg IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT consider_threshold INTO v_threshold
  FROM public.hiregauge_verdict_thresholds WHERE layer = 'resume';

  IF v_threshold IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_avg < v_threshold THEN
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
      'Auto-declined ' || NOW()::date || ': resume score ' || v_avg ||
      ' below resume-layer consider threshold (' || v_threshold || '). ' ||
      COALESCE(NEW.resume_analysis->>'narrative', ''));
  END IF;

  RETURN NEW;
END;
$function$;
