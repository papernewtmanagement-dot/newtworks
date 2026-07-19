-- Migration 20260719110000: Correct anchor JSONB keys from 0/3/5/7/10 → 0/30/50/70/100
-- Storage scale is 0-100 (not 0-10). Prior migration 20260719100000 used stale scale — fix.

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Zero self-initiated activity. Entirely reactive career — took jobs given, no side projects, no volunteer initiative, no self-taught skills mentioned.',
  '30',  'Minimal — only credentials employer required. No optional certifications, no side work, no volunteer roles.',
  '50',  'Some — one side hustle, one voluntary certification, or a volunteer role mentioned.',
  '70',  'Clear — multiple examples of building or starting without being told (launched a program, started a side business, taught themselves a tool, sustained volunteer leadership).',
  '100', 'Sustained — owned a business, built something substantial, or repeated pattern of initiative across every role for 5+ years.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nature: Autonomy';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'No advancement in 10+ years or downward moves only.',
  '30',  'One promotion in 8-10 years, no team ownership.',
  '50',  '2-3 promotions across 10-15 years but all line-level (no supervisor or above).',
  '70',  'Reached supervisor, manager, or team lead within 5-7 years with multiple promotions.',
  '100', 'Fast rise — director/VP or business owner by mid-career, multiple orgs where they climbed quickly.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nature: Leadership Emergence';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'No people-facing roles ever. All backend, warehouse, technical, or solo work.',
  '30',  'Incidental customer contact (cashier, food service) not core to the role.',
  '50',  '1-3 years customer-facing work (server, front desk, retail sales) or brief consultative role.',
  '70',  'Multi-year consultative or relational work (real estate, financial services, teaching, nursing, ministry) where relationships were core to the job.',
  '100', '10+ years of consultative, trust-based, or relationship-selling work — insurance, financial planning, high-touch B2B, therapy, pastoral care.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nature: Interpersonal Substrate';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Multiple contradictions — dates do not add up, roles overlap impossibly, or clear title inflation (e.g. "Senior Director" at a 3-person startup for 8 months).',
  '30',  'One or two red flags — vague or suspicious claims, hand-wavy gap explanations, mild title inflation.',
  '50',  'Nothing obvious but some superlatives raise an eyebrow (e.g. "led company-wide transformation" at a small role).',
  '70',  'Clean — no contradictions, plausible claims, appropriate scope descriptions.',
  '100', 'Notably grounded — understated claims, plain-English descriptions, easy-to-verify facts, no puffery anywhere.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Honesty';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Entirely self-focused. "I achieved," "I earned," "I ranked #1." Zero mention of team, customers, or others.',
  '30',  'Mostly self-focused with a passing mention of mentoring or team.',
  '50',  'Balanced — some team-oriented or customer-focused language alongside personal accomplishments.',
  '70',  'Genuinely other-focused — descriptions center on customer outcomes, team successes, mentoring, or community work.',
  '100', 'Strong pattern — sustained volunteer work, teaching, caregiving, community leadership, coaching, or explicit customer-first language throughout the whole resume.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Concern for Others';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Chronic short tenures (under 1 year each) with gaps. No sustained work anywhere.',
  '30',  'Mostly short stints, some gaps, one longer role.',
  '50',  'Mixed — some 2-3 year stints, some short. Overall sustained but not remarkable.',
  '70',  'Solid — multiple 3-5 year tenures, few gaps, evidence of pushing through.',
  '100', 'Exceptional — long tenures (5-10+ years each), never unemployed, evidence of working through hard times without quitting.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Hard Work Ethic';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Multiple unexplained downshifts, gaps, or blame-language ("company let me go," "not a good fit").',
  '30',  'One or two suspicious transitions, some vague explanations.',
  '50',  'Transitions look explainable (school, relocation, career pivot) but not always documented on the resume.',
  '70',  'Every transition has a clear ownership-taking narrative. No unexplained gaps.',
  '100', 'Career reads as intentional throughout — every move looks like something they chose, with clear reasons.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Nurture: Personal Responsibility';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Downward or lateral only for 10+ years.',
  '30',  'Mostly lateral with one small step up.',
  '50',  'Some upward movement but slow — entry-level to mid-level over 10+ years.',
  '70',  'Clear upward trajectory — moved up in title and scope multiple times.',
  '100', 'Strong ascent — entry-level to senior or leadership roles, taking on progressively larger scope over time.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Trajectory Direction';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Random — each recent role in a completely different domain with no connection.',
  '30',  'Some pattern but scattered — hopping between unrelated fields.',
  '50',  'A theme emerging — sticking to a general area but not building depth.',
  '70',  'Clear throughline — recent roles clearly build on each other in a specific direction, especially toward consultative or customer-facing work.',
  '100', 'Focused pursuit — last 3 years clearly show building expertise in a specific direction that aligns with sales, consultative, or insurance/financial-services work.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Coherent Pursuit';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'Multiple abandoned credentials — started degrees, licenses, or certifications and did not finish.',
  '30',  'One or two started-not-finished credentials.',
  '50',  'Baseline credentials completed but nothing beyond required.',
  '70',  'Multiple certifications or degrees earned. Clear pattern of finishing what they start.',
  '100', 'Extensive completions — multiple degrees, licenses, certifications, all finished. Evidence of doing more than what was required.'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Follow-Through';

UPDATE public.hiregauge_rules
SET trait_signature = jsonb_build_object('anchors', jsonb_build_object(
  '0',   'No numbers, no goals, no metrics anywhere on the resume. Pure duty descriptions.',
  '30',  'Vague achievement language ("exceeded targets," "top performer") without specific numbers.',
  '50',  'Some numbers — a specific rank or one quota attainment, but not systematic across roles.',
  '70',  'Multiple specific attainments — "achieved 118% of quota," "ranked #3 out of 40 reps," across multiple roles.',
  '100', 'Systematic — every recent role includes quantified goal attainment with specific numbers, consistently high performance documented (Jakirah-tier).'
))
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rule_type = 'resume_score_rubric' AND rule_name = 'Drivers: Goal Orientation';
