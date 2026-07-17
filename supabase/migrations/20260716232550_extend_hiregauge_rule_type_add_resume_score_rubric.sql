-- Extend rule_type CHECK to include 'resume_score_rubric' for parser-facing sub-signal rubrics.
ALTER TABLE public.hiregauge_rules
  DROP CONSTRAINT IF EXISTS hiregauge_rules_rule_type_check;

ALTER TABLE public.hiregauge_rules
  ADD CONSTRAINT hiregauge_rules_rule_type_check
  CHECK (rule_type = ANY (ARRAY[
    'archetype','coaching_variant','money_motivator','diagnostic_tool',
    'filter_rule','exit_mode','recommendation_logic','framework_principle',
    'behavioral_tell','reader_vulnerability','strategic_seat_pattern',
    'character_floor','validity_rule','drive_test','resume_screen_signal',
    'resume_score_rubric'
  ]));;