-- Seed the missing 'gma' block in settings.hiregauge_lss_calibration_v2.
-- Without it, hiregauge_lss_delta_v2 RAISES an exception for any candidate holding
-- gma_* accuracy data, which would crash every competency + role-fit score on the
-- FIRST new-instrument completion. Speed is deliberately NEUTRAL
-- (p2_5 = p97_5 = baseline => clamp(t) = baseline => multiplier = exp(-k*0) = 1),
-- because zero live GMA response distributions exist; efficiency therefore equals
-- accuracy until recalibration at n>=30 completions (per OQ "v2 assessment
-- provisional thresholds", 29 CFR Part 1607 local-validation step). Item counts and
-- chance rates are arithmetic from the active bank on 2026-08-04: 4 items/domain;
-- chance = mean(1/n_choices): pattern 2-choice = 0.5, deductive 3-choice = 0.3333,
-- numerical 2-choice = 0.5, verbal 6-choice = 0.1667. Do NOT invent speed
-- percentiles before real distributions exist (op-rule: never prefer simpler over
-- more accurate — and never fabricate accuracy that does not exist).
UPDATE public.settings
SET setting_value = jsonb_set(
      setting_value::jsonb,
      '{gma}',
      '{"pattern":{"items":4,"baseline_seconds":60,"p2_5_seconds":60,"p97_5_seconds":60,"chance_rate":0.5},
        "deductive":{"items":4,"baseline_seconds":60,"p2_5_seconds":60,"p97_5_seconds":60,"chance_rate":0.3333},
        "numerical":{"items":4,"baseline_seconds":60,"p2_5_seconds":60,"p97_5_seconds":60,"chance_rate":0.5},
        "verbal":{"items":4,"baseline_seconds":60,"p2_5_seconds":60,"p97_5_seconds":60,"chance_rate":0.1667},
        "_provisional":"Speed neutralized (p2_5=p97_5=baseline -> multiplier 1). Recalibrate percentiles at n>=30 completions."}'::jsonb
    )::text
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key = 'hiregauge_lss_calibration_v2'
  AND NOT (setting_value::jsonb ? 'gma');
