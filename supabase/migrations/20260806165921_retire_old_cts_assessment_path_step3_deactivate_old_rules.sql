-- Step 3: deactivate (not delete) hiregauge_rules rows calibrated against
-- old-CTS trait names. Content preserved (calibration history, n_count,
-- interview probes) in case of future reference; just stops firing.
UPDATE public.hiregauge_rules
SET is_active = false
WHERE is_active = true
AND (
  trait_signature::text ILIKE '%deadline_motivation%' OR
  trait_signature::text ILIKE '%recognition_drive%' OR
  trait_signature::text ILIKE '%independent_spirit%' OR
  trait_signature::text ILIKE '%self_promotion%' OR
  trait_signature::text ILIKE '%belief_in_others%' OR
  (trait_signature::text ILIKE '%optimism%' AND trait_signature::text NOT ILIKE '%dispositional_optimism%')
);
