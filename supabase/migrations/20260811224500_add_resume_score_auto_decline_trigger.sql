CREATE OR REPLACE FUNCTION public.auto_decline_on_resume_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_threshold numeric;
  v_avg numeric;
BEGIN
  -- Only act when resume_analysis actually changed and landed a real score.
  IF NEW.resume_analysis IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.resume_analysis IS NOT DISTINCT FROM NEW.resume_analysis THEN
    RETURN NEW;
  END IF;

  -- Only ever auto-decline a candidate still sitting at 'applied' — never
  -- touch anyone already moved further along (assessment_sent, assessed,
  -- declined, former) so this can't undo a human decision or double-fire.
  IF NEW.status IS DISTINCT FROM 'applied' THEN
    RETURN NEW;
  END IF;

  v_avg := (NEW.resume_analysis->>'avg')::numeric;
  IF v_avg IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT consider_threshold INTO v_threshold
  FROM public.hiregauge_verdict_thresholds WHERE layer = 'resume';

  -- Fails safe: if the threshold row is ever missing, do nothing rather
  -- than guess a cutoff — same fail-safe posture as send_v1_assessment_invitations.
  IF v_threshold IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_avg < v_threshold THEN
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

DROP TRIGGER IF EXISTS trg_auto_decline_on_resume_score ON public.hiring_candidates;
CREATE TRIGGER trg_auto_decline_on_resume_score
BEFORE INSERT OR UPDATE OF resume_analysis ON public.hiring_candidates
FOR EACH ROW
EXECUTE FUNCTION public.auto_decline_on_resume_score();
