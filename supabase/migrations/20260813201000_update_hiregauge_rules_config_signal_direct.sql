-- Resume scoring revamp: Config row updated for signal-direct composite
-- Approved spec: session_note "2026-08-12 — Resume scoring revamp: approved spec
-- (signal-level weights + LE anchors + autonomy imputation)"
-- verdict_thresholds UNCHANGED per spec.
-- hiregauge_layer_composite_weights layer=resume rows LEFT UNTOUCHED per spec;
-- resume_weighted_composite() no longer reads them.

UPDATE public.hiregauge_rules
SET
  trait_signature = (
    jsonb_set(
      jsonb_set(
        jsonb_set(
          trait_signature,
          '{construct_weights}',
          '{
            "superseded": true,
            "superseded_on": "2026-08-12",
            "superseded_by": "hiregauge_resume_signal_weights",
            "old_values": {"character": 0.4, "capability": 0.2, "commitment": 0.4}
          }'::jsonb
        ),
        '{subsignal_averaging}',
        '"Constructs (Capability/Character/Commitment) are DISPLAY groupings only — simple means within each construct, for UI presentation. They have no role in the composite. Composite = signal-direct weighted sum over hiregauge_resume_signal_weights, computed by resume_weighted_composite(). Capability = mean(Autonomy, Leadership Emergence, Interpersonal Substrate); Character = mean(Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility); Commitment = mean(Trajectory Direction, Coherent Pursuit, Follow-Through, Goal Orientation)."'::jsonb
      ),
      '{parser_read_order}',
      '[
        "load 13 signal rows",
        "score each signal 0-100 using markers plus anchor calibration",
        "compute composite = signal-direct weighted sum via resume_weighted_composite() over hiregauge_resume_signal_weights (weight > 0 rows); any weight>0 signal missing/null returns NULL composite",
        "constructs (Capability/Character/Commitment) computed separately as simple means, display-only, no composite effect",
        "evaluate resume_screen_signal rules; record fired rules for interviewer flags (no composite effect)",
        "apply verdict thresholds against composite"
      ]'::jsonb
    ) || jsonb_build_object(
      'layer_composite_weights_note',
      'hiregauge_layer_composite_weights layer=resume rows are superseded-for-resume as of 2026-08-12 — left in place untouched, but resume_weighted_composite() no longer reads them.'
    )
  ),
  updated_at = now()
WHERE id = '42e640a0-ccd9-46af-8e0e-f8fe82d54a47';
