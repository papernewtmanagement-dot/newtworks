-- Add Interpersonal Substrate as third Nature sub-signal.
INSERT INTO public.hiregauge_rules
  (agency_id, rule_type, rule_name, short_label, trait_signature, description, calibration_status, is_active, hiring_stage, notes)
VALUES
('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nature: Interpersonal Substrate', 'Interpersonal Substrate',
 jsonb_build_object(
   'construct', 'nature', 'position', 3,
   'markers_positive', ARRAY[
     'multi-year sustained customer-facing work (sales, service, hospitality, front-of-house)',
     'consultative or advisory roles (real estate, financial services, insurance, healthcare direct-care)',
     'education / coaching / mentoring roles (teacher, coach, trainer, program director)',
     'team leadership involving people development (not just process management)',
     'roles requiring sustained active listening and understanding others'
   ],
   'markers_negative', ARRAY[
     'purely back-office work (warehouse, purchasing, IT-only, accounting-only)',
     'transactional-only customer contact (delivery, dispatch, single-purpose retention call center)',
     'solo technical work with no people interface',
     'physical labor / operations with no consultative dimension'
   ],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'John Kostov', 'evidence', '17 years customer-service leadership across multiple employers: Starbucks front-of-house, Crossover Health elbow-to-elbow, SBM 137-person team, Royal ReFresh 400+ B2B relationships'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Cassandra Alves', 'evidence', 'Retail Women Lead role with peer training responsibility (customer-facing but limited depth and duration)'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Anthony Papini', 'evidence', 'Delivery driver + gig work; transactional customer contact only; no consultative or sustained relational work')
 ),
 'Evidence of sustained interpersonal / consultative / customer-facing work. Parser weight: 1 of 3 sub-signals averaged for Nature.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal added to catch domain-substrate fit. Nature now = mean(Autonomy, Leadership_Emergence, Interpersonal_Substrate).');

-- Update Config row to reflect new Nature averaging.
UPDATE public.hiregauge_rules
SET trait_signature = jsonb_set(
      trait_signature,
      '{subsignal_averaging}',
      '"simple mean within each construct: Nature = mean(Autonomy, Leadership Emergence, Interpersonal Substrate); Nurture = mean(Honesty, Concern for Others, Hard Work Ethic, Personal Responsibility); Drivers = mean(Trajectory Direction, Coherent Pursuit, Follow-Through)"'::jsonb
    ),
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric'
  AND short_label = 'Composite Config';

-- Update prior Nature sub-signal notes to reflect the new 3-sub-signal averaging.
UPDATE public.hiregauge_rules
SET notes = 'Sub-signal 1 of 3 in Nature construct. Nature = mean(Autonomy, Leadership Emergence, Interpersonal Substrate).',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Autonomy';

UPDATE public.hiregauge_rules
SET notes = 'Sub-signal 2 of 3 in Nature construct.',
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND rule_type = 'resume_score_rubric' AND short_label = 'Leadership Emergence';;