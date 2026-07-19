-- Migration 20260719100000: Resume rubric — fix stale drift text + add scoring anchors
-- Fixes 5 stale "1 of N" description bugs (Nature + Drivers added sub-signals over the sprint)
-- Fixes 7 stale "Sub-signal N of 9" notes (total is 11 now: 3+4+4)
-- Adds 0/3/5/7/10 scoring anchors to trait_signature JSONB on each of the 11 sub-signal rules
-- Anchors improve reproducibility across scoring sessions

-- ============================================================
-- PART 1: Fix stale description text
-- ============================================================

UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 2 sub-signals averaged for Nature', '1 of 3 sub-signals averaged for Nature')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND rule_name IN ('Nature: Autonomy', 'Nature: Leadership Emergence');

UPDATE public.hiregauge_rules
SET description = REPLACE(description, '1 of 3 sub-signals averaged for Drivers', '1 of 4 sub-signals averaged for Drivers')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND rule_name IN ('Drivers: Trajectory Direction', 'Drivers: Coherent Pursuit', 'Drivers: Follow-Through');

-- ============================================================
-- PART 2: Fix stale notes ("Sub-signal N of 9" → correct positional labels)
-- ============================================================

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 1 of 4 in Nurture construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Honesty';

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 2 of 4 in Nurture construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Concern for Others';

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 3 of 4 in Nurture construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Hard Work Ethic';

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 4 of 4 in Nurture construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Personal Responsibility';

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 1 of 4 in Drivers construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Trajectory Direction';

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 2 of 4 in Drivers construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Coherent Pursuit';

UPDATE public.hiregauge_rules SET notes = 'Sub-signal 3 of 4 in Drivers construct.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Follow-Through';

-- ============================================================
-- PART 3: Add 0-3-5-7-10 scoring anchors to trait_signature JSONB
-- Structure: trait_signature.anchors = { "0": text, "3": text, "5": text, "7": text, "10": text }
-- ============================================================

-- NATURE: Autonomy
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Zero self-initiated activity. Entirely reactive career — took jobs given, no side projects, no volunteer initiative, no self-taught skills mentioned.',
  '3',  'Minimal — only credentials employer required. No optional certifications, no side work, no volunteer roles.',
  '5',  'Some — one side hustle, one voluntary certification, or a volunteer role mentioned.',
  '7',  'Clear — multiple examples of building or starting without being told (launched a program, started a side business, taught themselves a tool, sustained volunteer leadership).',
  '10', 'Sustained — owned a business, built something substantial, or repeated pattern of initiative across every role for 5+ years.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nature: Autonomy';

-- NATURE: Leadership Emergence
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'No advancement in 10+ years or downward moves only.',
  '3',  'One promotion in 8-10 years, no team ownership.',
  '5',  '2-3 promotions across 10-15 years but all line-level (no supervisor or above).',
  '7',  'Reached supervisor, manager, or team lead within 5-7 years with multiple promotions.',
  '10', 'Fast rise — director/VP or business owner by mid-career, multiple orgs where they climbed quickly.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nature: Leadership Emergence';

-- NATURE: Interpersonal Substrate
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'No people-facing roles ever. All backend, warehouse, technical, or solo work.',
  '3',  'Incidental customer contact (cashier, food service) not core to the role.',
  '5',  '1-3 years customer-facing work (server, front desk, retail sales) or brief consultative role.',
  '7',  'Multi-year consultative or relational work (real estate, financial services, teaching, nursing, ministry) where relationships were core to the job.',
  '10', '10+ years of consultative, trust-based, or relationship-selling work — insurance, financial planning, high-touch B2B, therapy, pastoral care.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nature: Interpersonal Substrate';

-- NURTURE: Honesty
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Multiple contradictions — dates do not add up, roles overlap impossibly, or clear title inflation (e.g. "Senior Director" at a 3-person startup for 8 months).',
  '3',  'One or two red flags — vague or suspicious claims, hand-wavy gap explanations, mild title inflation.',
  '5',  'Nothing obvious but some superlatives raise an eyebrow (e.g. "led company-wide transformation" at a small role).',
  '7',  'Clean — no contradictions, plausible claims, appropriate scope descriptions.',
  '10', 'Notably grounded — understated claims, plain-English descriptions, easy-to-verify facts, no puffery anywhere.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Honesty';

-- NURTURE: Concern for Others
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Entirely self-focused. "I achieved," "I earned," "I ranked #1." Zero mention of team, customers, or others.',
  '3',  'Mostly self-focused with a passing mention of mentoring or team.',
  '5',  'Balanced — some team-oriented or customer-focused language alongside personal accomplishments.',
  '7',  'Genuinely other-focused — descriptions center on customer outcomes, team successes, mentoring, or community work.',
  '10', 'Strong pattern — sustained volunteer work, teaching, caregiving, community leadership, coaching, or explicit customer-first language throughout the whole resume.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Concern for Others';

-- NURTURE: Hard Work Ethic
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Chronic short tenures (under 1 year each) with gaps. No sustained work anywhere.',
  '3',  'Mostly short stints, some gaps, one longer role.',
  '5',  'Mixed — some 2-3 year stints, some short. Overall sustained but not remarkable.',
  '7',  'Solid — multiple 3-5 year tenures, few gaps, evidence of pushing through.',
  '10', 'Exceptional — long tenures (5-10+ years each), never unemployed, evidence of working through hard times without quitting.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Hard Work Ethic';

-- NURTURE: Personal Responsibility
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Multiple unexplained downshifts, gaps, or blame-language ("company let me go," "not a good fit").',
  '3',  'One or two suspicious transitions, some vague explanations.',
  '5',  'Transitions look explainable (school, relocation, career pivot) but not always documented on the resume.',
  '7',  'Every transition has a clear ownership-taking narrative. No unexplained gaps.',
  '10', 'Career reads as intentional throughout — every move looks like something they chose, with clear reasons.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Personal Responsibility';

-- DRIVERS: Trajectory Direction
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Downward or lateral only for 10+ years.',
  '3',  'Mostly lateral with one small step up.',
  '5',  'Some upward movement but slow — entry-level to mid-level over 10+ years.',
  '7',  'Clear upward trajectory — moved up in title and scope multiple times.',
  '10', 'Strong ascent — entry-level to senior or leadership roles, taking on progressively larger scope over time.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Trajectory Direction';

-- DRIVERS: Coherent Pursuit
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Random — each recent role in a completely different domain with no connection.',
  '3',  'Some pattern but scattered — hopping between unrelated fields.',
  '5',  'A theme emerging — sticking to a general area but not building depth.',
  '7',  'Clear throughline — recent roles clearly build on each other in a specific direction, especially toward consultative or customer-facing work.',
  '10', 'Focused pursuit — last 3 years clearly show building expertise in a specific direction that aligns with sales, consultative, or insurance/financial-services work.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Coherent Pursuit';

-- DRIVERS: Follow-Through
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'Multiple abandoned credentials — started degrees, licenses, or certifications and did not finish.',
  '3',  'One or two started-not-finished credentials.',
  '5',  'Baseline credentials completed but nothing beyond required.',
  '7',  'Multiple certifications or degrees earned. Clear pattern of finishing what they start.',
  '10', 'Extensive completions — multiple degrees, licenses, certifications, all finished. Evidence of doing more than what was required.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Follow-Through';

-- DRIVERS: Goal Orientation
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',  'No numbers, no goals, no metrics anywhere on the resume. Pure duty descriptions.',
  '3',  'Vague achievement language ("exceeded targets," "top performer") without specific numbers.',
  '5',  'Some numbers — a specific rank or one quota attainment, but not systematic across roles.',
  '7',  'Multiple specific attainments — "achieved 118% of quota," "ranked #3 out of 40 reps," across multiple roles.',
  '10', 'Systematic — every recent role includes quantified goal attainment with specific numbers, consistently high performance documented (Jakirah-tier).'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Goal Orientation';
