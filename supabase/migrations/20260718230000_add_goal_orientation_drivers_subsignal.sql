-- Add Goal Orientation as fourth Drivers sub-signal.
-- Peter directive 2026-07-18: resume needs to be read for goal/target/quota language
-- and quantified attainment against those goals. Distinct signal from Trajectory
-- Direction (title movement), Coherent Pursuit (consistency of domain), and
-- Follow-Through (completing what you start). This is the resume-side echo of
-- CTS Deadline Motivation.
INSERT INTO public.hiregauge_rules
  (agency_id, rule_type, rule_name, short_label, trait_signature, description, calibration_status, is_active, hiring_stage, notes)
VALUES
('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Drivers: Goal Orientation', 'Goal Orientation',
 jsonb_build_object(
   'construct', 'drivers', 'position', 4,
   'markers_positive', ARRAY[
     'specific goal / target / quota / KPI language on resume',
     'quantified outcomes tied to stated targets (e.g. "hit 120% of quota", "exceeded target by X%", "achieved N of M")',
     'growth-from-to language with numbers (e.g. "grew territory from $X to $Y over N months")',
     'recognition tied to goal attainment (Presidents Club, Rookie of the Year, awards linked to numbers)',
     'multiple years of consistent goal-hit language across employers',
     'unprompted specificity — candidate volunteers metrics without being asked'
   ],
   'markers_negative', ARRAY[
     'entirely responsibility / activity language with no outcomes',
     'vague achievement language without numbers ("consistently exceeded expectations", "top performer")',
     'metrics for non-goal outcomes only (headcount, volume) without target comparison',
     'goal language on early roles but disappears in recent roles',
     'no mention of quota / target / goal / KPI anywhere on the resume'
   ],
   'anchor_high', jsonb_build_object(
     'score', '9-10',
     'candidate', 'placeholder — needs anchoring on next high-goal-orientation resume',
     'evidence', 'e.g. "hit 137% of quota FY23", "grew book from $2M to $4.1M over 24 months", "Presidents Club 2022 and 2024", quantified across every recent role'),
   'anchor_mid', jsonb_build_object(
     'score', '5',
     'candidate', 'April Varian',
     'evidence', 'Some outcome language on promotions but no goal / target / quota references; documented promotions and title progression but no explicit "hit N of target" pattern'),
   'anchor_low', jsonb_build_object(
     'score', '1-2',
     'candidate', 'Anthony Papini',
     'evidence', 'Delivery driver + gig work; no goals, no targets, no quotas mentioned; role list only')
 ),
 'Presence of goal / target / quota / KPI language on the resume and quantified attainment against those targets. Parser weight: 1 of 4 sub-signals averaged for Drivers.',
 'emerging_n1', true, ARRAY['resume_review'],
 'Sub-signal 4 of Drivers. Drivers = mean(Trajectory Direction, Coherent Pursuit, Follow-Through, Goal Orientation).');

-- Refresh Composite Config row: 10 sub-signals -> 11, Drivers averaging includes Goal Orientation.
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
      jsonb_set(
        trait_signature,
        '{subsignal_averaging}',
        '"simple mean within each construct: Nature = mean(Autonomy, Leadership Emergence, Interpersonal Substrate); Nurture = mean(Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility); Drivers = mean(Trajectory Direction, Coherent Pursuit, Follow-Through, Goal Orientation)"'::jsonb
      ),
      '{parser_read_order,0}',
      '"load 11 sub-signal rows"'::jsonb
    ),
    updated_at = NOW()
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND rule_type='resume_score_rubric'
  AND short_label='Composite Config';
