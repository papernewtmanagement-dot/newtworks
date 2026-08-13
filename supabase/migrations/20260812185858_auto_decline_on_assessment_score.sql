-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-12 18:58:58 UTC (ledger name: auto_decline_on_assessment_score) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260812185858.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
CREATE OR REPLACE FUNCTION public.auto_decline_on_assessment_score()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_verdict record;
BEGIN
  -- Only candidates the completion write actually landed in 'assessed' (not already
  -- advanced to interview/offer/hired by a human, not already declined, not a test row).
  IF NEW.status IS DISTINCT FROM 'assessed' THEN
    RETURN NULL;
  END IF;
  IF NEW.is_test_candidate THEN
    RETURN NULL;
  END IF;

  -- AFTER trigger: the row is already committed within this transaction, so
  -- verdict_assessment() -> assessment_best_fit_role() etc. read the real just-written
  -- scores, not stale pre-update values. (A BEFORE trigger calling these by-id functions
  -- would read the OLD row instead -- that's why this is AFTER, unlike the resume gate,
  -- which works directly off NEW.resume_analysis without a round-trip query.)
  SELECT * INTO v_verdict FROM public.verdict_assessment(NEW.id, NULL);
  IF v_verdict.composite IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_verdict.verdict = 'decline' THEN
    UPDATE public.hiring_candidates
    SET status = 'declined',
        decline_reason = 'assessment_score',
        status_updated_at = NOW(),
        decision_notes = trim(both E'\n' from COALESCE(decision_notes || E'\n\n', '') ||
          'Auto-declined ' || NOW()::date || ': assessment composite ' || v_verdict.composite ||
          ' (capability ' || COALESCE(v_verdict.capability_score::text,'n/a') ||
          ', character ' || COALESCE(v_verdict.character_score::text,'n/a') ||
          ', commitment ' || COALESCE(v_verdict.commitment_score::text,'n/a') ||
          ') below assessment-layer decline threshold (<60 per hiregauge_verdict_thresholds).')
    WHERE id = NEW.id;
  END IF;

  RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_auto_decline_on_assessment_score
AFTER UPDATE OF assessment_completed_at ON public.hiring_candidates
FOR EACH ROW
WHEN (OLD.assessment_completed_at IS NULL AND NEW.assessment_completed_at IS NOT NULL)
EXECUTE FUNCTION public.auto_decline_on_assessment_score();

COMMENT ON FUNCTION public.auto_decline_on_assessment_score() IS
'Auto-declines a candidate the moment their v2 assessment completes if the assessment-layer composite (verdict_assessment) verdict is decline (<60). Mirrors auto_decline_on_resume_score but for the assessment layer -- that trigger only ever covered the resume gate, and the assessment layer had no equivalent enforcement despite decline_reason already having an assessment_score enum value reserved for it. Gap found 2026-08-12 via Precious Salas (composite 56.40, correctly manually declined by Peter, but should have been automatic).';
