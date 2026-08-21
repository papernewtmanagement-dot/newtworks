-- Peter directive 2026-08-20: turn the resume auto-decline OFF for the time being
-- so more candidates reach the assessment.
--
-- WHY A NEW COLUMN INSTEAD OF SETTING consider_threshold = 0:
-- hiregauge_verdict_thresholds.consider_threshold does TWO jobs. It gates the
-- resume auto-decline AND it draws the decline/consider band that
-- _hiregauge_layer_verdict publishes as the displayed resume verdict. Zeroing it
-- would relabel all ~234 below-50 resumes as "consider" across the candidate page
-- and the framework verdict, silently rescoping a research-tied band
-- (see persistent_memory operational_rule "Resume screening layer — canonical
-- weights, early-career definition, research basis").
-- auto_decline_threshold separates the routing gate from the published label.
-- NULL falls back to consider_threshold, so every other layer is unchanged.

ALTER TABLE public.hiregauge_verdict_thresholds
  ADD COLUMN IF NOT EXISTS auto_decline_threshold numeric;

COMMENT ON COLUMN public.hiregauge_verdict_thresholds.auto_decline_threshold IS
  'Routing-only floor for auto-decline and invite eligibility. NULL = use consider_threshold. Does NOT affect the published verdict label band.';

UPDATE public.hiregauge_verdict_thresholds
SET auto_decline_threshold = 0,
    updated_at = NOW()
WHERE layer = 'resume';
