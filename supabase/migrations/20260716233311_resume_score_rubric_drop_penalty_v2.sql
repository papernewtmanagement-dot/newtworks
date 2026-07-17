-- verdict_impact CHECK allows: hard_decline, soft_decline, consider, soft_hire, hard_hire, informational.
-- Use hard_decline for self_superiority (character-signaling); parser derives decline_character label
-- from the character_flag list in Config row.

UPDATE public.hiregauge_rules
SET verdict_impact = 'hard_decline',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_screen_signal'
  AND short_label = 'Self-superiority language';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object(
      'construct', 'config',
      'construct_weights', jsonb_build_object('nature', 0.35, 'nurture', 0.30, 'drivers', 0.35),
      'subsignal_averaging', 'simple mean within each construct',
      'rule_count_penalty', jsonb_build_object(
        'penalty_per_rule', 0,
        'rationale', 'rules and sub-signals draw from same evidence pool; point penalty double-counted signal. Rules are now interviewer flags.'
      ),
      'character_flag_mechanism', jsonb_build_object(
        'trigger', 'any resume_screen_signal rule with verdict_impact=hard_decline AND short_label in character_flagged_rules fires',
        'effect', 'framework verdict = decline_character regardless of composite',
        'character_flagged_rules', ARRAY['Self-superiority language']
      ),
      'verdict_thresholds', jsonb_build_object(
        'pass', 'composite >= 7.0',
        'consider', 'composite 5.0 to 6.99',
        'decline', 'composite < 5.0',
        'decline_character', 'any character-flagged rule fires (see character_flag_mechanism above)'
      ),
      'parser_read_order', ARRAY[
        'load 9 sub-signal rows with construct=nature/nurture/drivers',
        'score each sub-signal 1-10 using markers plus anchor calibration',
        'average sub-signals within construct',
        'weighted average across constructs per weights above',
        'evaluate resume_screen_signal rules against resume text',
        'record which rules fired for interviewer flags but do NOT subtract from composite',
        'if any fired rule short_label is in character_flagged_rules, output decline_character',
        'else apply verdict thresholds against composite'
      ]
    ),
    description = 'Composite math config for parser. Weights Nature 0.35 / Nurture 0.30 / Drivers 0.35. No point penalty from rules (informational flags only). decline_character triggered when a character-flagged rule fires (see character_flag_mechanism).',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND short_label = 'Composite Config';;