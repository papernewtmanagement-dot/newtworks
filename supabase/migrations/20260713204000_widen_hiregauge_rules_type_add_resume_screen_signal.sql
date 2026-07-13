-- Widen hiregauge_rules.rule_type CHECK constraint to allow 'resume_screen_signal'.
-- New rule_type added 2026-07-13 to support pre-assessment resume-screen framework rules.
-- 5 seed rules inserted in same session (session_note 2026-07-13 resume tell analysis).

ALTER TABLE public.hiregauge_rules
  DROP CONSTRAINT IF EXISTS hiregauge_rules_rule_type_check;

ALTER TABLE public.hiregauge_rules
  ADD CONSTRAINT hiregauge_rules_rule_type_check
  CHECK (rule_type = ANY (ARRAY[
    'archetype'::text,
    'coaching_variant'::text,
    'money_motivator'::text,
    'diagnostic_tool'::text,
    'filter_rule'::text,
    'exit_mode'::text,
    'recommendation_logic'::text,
    'framework_principle'::text,
    'behavioral_tell'::text,
    'reader_vulnerability'::text,
    'strategic_seat_pattern'::text,
    'character_floor'::text,
    'validity_rule'::text,
    'drive_test'::text,
    'resume_screen_signal'::text
  ]));
