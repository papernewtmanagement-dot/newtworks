-- GMA numerical-reasoning items 31-45 (15 items) -- second of 4 planned GMA
-- subtests (pattern-matching done at items 1-30; numerical here; deductive
-- and verbal remain). Shares the newtworks_v2_cognitive_gma section with
-- pattern-matching (schema already anticipated this via cognitive_domain
-- values gma_pattern/gma_deductive/gma_numerical/gma_verbal) -- item_number
-- continues from 31 to avoid colliding with the pattern bank in the same
-- section. Generated + verified via /home/claude/gma_num/generate_numerical.py
-- (rule-derived sequences, verification pass, duplicate-option gate -- same
-- generator contract as the pattern-matching generator).
--
-- Format: classic number-series completion (Thurstone 1938, Primary Mental
-- Abilities -- Number series as a numerical-reasoning marker; also used in
-- general-aptitude batteries like the Wonderlic Personnel Test). Generic
-- arithmetic/geometric series, not sourced from any single proprietary bank.
--
-- Tier distribution: tier1=3 (31-33, constant difference), tier2=5 (34-38,
-- geometric + increasing-step), tier3=3 (39-41, alternating operations),
-- tier4=4 (42-45, two interleaved sequences -- hardest, candidate must
-- notice the sequence is actually two braided together).
--
-- is_active=false, stint=0 -- same placeholder convention as every other
-- v2 item. Renderer: src/components/GmaNumericalItem.jsx, wired into
-- CandidateAssessment.jsx same session.

INSERT INTO hiregauge_instrument_items
  (section, item_number, item_text, choices, answer_key, cognitive_domain, stint, is_active)
VALUES
(
  'newtworks_v2_cognitive_gma', 31, 'Each number increases by 6. What comes next?',
  '{"sequence": [4, 10, 16, 22, 28], "options": {"A": 34, "B": 35, "C": 33, "D": 40, "E": 36, "F": 28}}'::jsonb, 'A', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 32, 'Each number decreases by 7. What comes next?',
  '{"sequence": [91, 84, 77, 70, 63], "options": {"A": 49, "B": 56, "C": 63, "D": 55, "E": 58, "F": 57}}'::jsonb, 'B', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 33, 'Each number increases by 11. What comes next?',
  '{"sequence": [12, 23, 34, 45, 56], "options": {"A": 69, "B": 67, "C": 66, "D": 56, "E": 68, "F": 78}}'::jsonb, 'B', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 34, 'Each number is multiplied by 3. What comes next?',
  '{"sequence": [2, 6, 18, 54, 162], "options": {"A": 486, "B": 162, "C": 648, "D": 487, "E": 485, "F": 324}}'::jsonb, 'A', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 35, 'Each number is multiplied by 4. What comes next?',
  '{"sequence": [1, 4, 16, 64, 256], "options": {"A": 256, "B": 1023, "C": 768, "D": 1280, "E": 1024, "F": 1025}}'::jsonb, 'E', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 36, 'Each number is multiplied by 2. What comes next?',
  '{"sequence": [6, 12, 24, 48, 96], "options": {"A": 191, "B": 194, "C": 288, "D": 193, "E": 96, "F": 192}}'::jsonb, 'F', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 37, 'The amount added each time grows by a fixed amount. What comes next?',
  '{"sequence": [2, 5, 10, 17, 26], "options": {"A": 26, "B": 38, "C": 36, "D": 52, "E": 37, "F": 46}}'::jsonb, 'E', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 38, 'The amount added each time grows by a fixed amount. What comes next?',
  '{"sequence": [50, 48, 43, 35, 24], "options": {"A": 48, "B": 10, "C": -1, "D": 9, "E": 11, "F": 24}}'::jsonb, 'B', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 39, 'The pattern alternates: add 5, then multiply by 2, repeating. What comes next?',
  '{"sequence": [3, 8, 16, 21, 42], "options": {"A": 44, "B": 46, "C": 48, "D": 84, "E": 47, "F": 49}}'::jsonb, 'E', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 40, 'The pattern alternates: add 4, then multiply by 3, repeating. What comes next?',
  '{"sequence": [1, 5, 15, 19, 57], "options": {"A": 60, "B": 61, "C": 63, "D": 62, "E": 171, "F": 59}}'::jsonb, 'B', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 41, 'The pattern alternates: add -3, then multiply by 2, repeating. What comes next?',
  '{"sequence": [10, 7, 14, 11, 22], "options": {"A": 18, "B": 21, "C": 19, "D": 24, "E": 20, "F": 44}}'::jsonb, 'C', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 42, 'This sequence is actually two sequences braided together (1st, 3rd, 5th... follow one rule; 2nd, 4th... follow another). What comes next?',
  '{"sequence": [1, 100, 6, 90, 11], "options": {"A": 85, "B": 80, "C": 75, "D": 11, "E": 70, "F": 81}}'::jsonb, 'B', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 43, 'This sequence is actually two sequences braided together (1st, 3rd, 5th... follow one rule; 2nd, 4th... follow another). What comes next?',
  '{"sequence": [2, 50, 4, 55, 6], "options": {"A": 62, "B": 60, "C": 65, "D": 58, "E": 61, "F": 6}}'::jsonb, 'B', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 44, 'This sequence is actually two sequences braided together (1st, 3rd, 5th... follow one rule; 2nd, 4th... follow another). What comes next?',
  '{"sequence": [20, 3, 16, 6, 12], "options": {"A": 9, "B": 8, "C": 13, "D": 12, "E": 5, "F": 10}}'::jsonb, 'A', 'gma_numerical', 0, false
),
(
  'newtworks_v2_cognitive_gma', 45, 'This sequence is actually two sequences braided together (1st, 3rd, 5th... follow one rule; 2nd, 4th... follow another). What comes next?',
  '{"sequence": [5, 200, 12, 180, 19], "options": {"A": 153, "B": 140, "C": 19, "D": 161, "E": 167, "F": 160}}'::jsonb, 'F', 'gma_numerical', 0, false
);

