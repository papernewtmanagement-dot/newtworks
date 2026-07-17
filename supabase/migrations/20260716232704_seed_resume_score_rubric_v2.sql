INSERT INTO public.hiregauge_rules
  (agency_id, rule_type, rule_name, short_label, trait_signature, description, calibration_status, is_active, hiring_stage, notes)
VALUES
('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nature: Autonomy', 'Autonomy',
 jsonb_build_object(
   'construct', 'nature', 'position', 1,
   'markers_positive', ARRAY['self-employed / founded / owned / started own business', 'concurrent independent work streams', 'initiative verbs (created / developed / established / launched) tied to specific outcomes', 'side projects at real scale (revenue, users, team size)'],
   'markers_negative', ARRAY['only filled assigned employee roles', 'no self-initiated projects', 'entirely gig or W-2 work with no elevation'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'Tommy Lynch', 'evidence', 'Owned Country Square Wine & Liquors (300k inventory, POS, state liquor license compliance) concurrent with state trooper role and Coldwell Banker realtor 2015-17'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Stephanie Rogers', 'evidence', 'Elevated within existing systems (retail Sales Assoc -> TAP Supervisor, Team Teacher -> Lead Teacher) but did not start own venture'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Anthony Papini', 'evidence', 'Entirely gig-driver work (U.S. Silica loadout, Uber Eats, Amazon delivery via Alamo Parcel); no autonomous initiative visible')
 ),
 'Evidence of self-directed action outside employer scaffolding. Parser weight: 1 of 2 sub-signals averaged for Nature.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 1 of 9. Nature = mean(Autonomy, Leadership_Emergence).'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nature: Leadership Emergence', 'Leadership Emergence',
 jsonb_build_object(
   'construct', 'nature', 'position', 2,
   'markers_positive', ARRAY['promoted within 12 months of joining an employer', 'multiple documented promotions over tenure', 'earned role at unusual young age or short tenure', 'picked out by system for elevation with title change'],
   'markers_negative', ARRAY['stayed flat for years with no title change', 'no promotions across multiple employers', 'self-claimed leadership language without corroborating title advancement'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'John Kostov', 'evidence', 'Starbucks 5-year progression barista -> Store Manager in Missoula; 137-person unionized custodial team scope at SBM; developed systems influencing company-wide at Braganza Tea'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Anthony Vela', 'evidence', 'Space City Takeout Sales Manager 6.75 years, real team-building of 20+ reps, but stayed at similar leadership level across subsequent employers'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Vicken Shakarian', 'evidence', '4 years same purchasing role with no upward move; claimed Supervisor title at La Costa Glen starting March 2015 is implausible given June 2016 HS graduation')
 ),
 'Speed and repetition of title advancement across career. Parser weight: 1 of 2 sub-signals averaged for Nature.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 2 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nurture: Honesty', 'Honesty',
 jsonb_build_object(
   'construct', 'nurture', 'position', 1,
   'markers_positive', ARRAY['specific verifiable outcomes with numbers', 'no unprompted self-superiority language', 'timeline math consistent with graduation dates and age', 'external corroboration for claims (awards, recognitions with issuer)'],
   'markers_negative', ARRAY['unprompted self-superiority woven into ordinary duty descriptions', 'implausible timeline (title dates predating credential dates)', 'vague grand claims without external evidence', 'self-labeled excellence without corroboration'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'Tommy Lynch', 'evidence', 'Earnest mission-oriented voice throughout; zero self-promotion flourishes; specific concurrent-work timeline is externally verifiable'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Matthew Carlton', 'evidence', 'Voice has warmth but self-labels "high energy, positive attitude, ability to connect with people from all walks of life" without external corroboration'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Bob Williams', 'evidence', '"My work was considered superior among my musical colleagues" woven into Judson ISD description; "I was an opera singer at a point in my career" dropped as background context in Dallas Opera transportation manager role')
 ),
 'Absence of inflation, superiority language, and timeline math contradictions. Parser weight: 1 of 4 sub-signals averaged for Nurture.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 3 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nurture: Concern for Others', 'Concern for Others',
 jsonb_build_object(
   'construct', 'nurture', 'position', 2,
   'markers_positive', ARRAY['mentions team / customers / students / patients as beneficiaries of positive outcomes', 'warmth language (elbow-to-elbow, meaningful connections, well-balanced team, tight-knit)', 'service-orientation language tied to specific others', 'we / us / team as agents in bullet points'],
   'markers_negative', ARRAY['entirely first-person achievement statements', 'all metrics / outcomes with zero relationship language', 'zero warmth signals', 'coworkers referenced only as resources or obstacles'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'John Kostov', 'evidence', '"Elbow-to-elbow with all staff" (Crossover Health), "well-balanced tight-knit team" (Starbucks); repeated team-language across multiple employers'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Matthew Carlton', 'evidence', 'Self-described "ability to connect with people from all walks of life" but no concrete team or customer moment given as evidence'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Jakirah Goolsby', 'evidence', 'Every bullet is action-outcome-metric; zero warmth signals; zero team-culture references; zero relationship-building language across 5+ years of insurance-adjacent work')
 ),
 'Presence of warmth signals and other-directed language on the resume. Parser weight: 1 of 4 sub-signals averaged for Nurture.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 4 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nurture: Hard Work Ethic', 'Hard Work Ethic',
 jsonb_build_object(
   'construct', 'nurture', 'position', 3,
   'markers_positive', ARRAY['durable tenure (3+ years per employer)', 'concurrent jobs / two-job stretches', 'worked through school (dates overlap enrollment)', 'sustained effort visible across 10+ year career span'],
   'markers_negative', ARRAY['short stints (multiple <12 months)', 'unexplained gap >6 months', 'declining tenure pattern (each job shorter than previous)', 'no evidence of sustained effort across career'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'Tommy Lynch', 'evidence', '14+ years law enforcement across two agencies (Virginia State Police 2007-14, Cape Charles PD 2018-25) plus concurrent liquor store owner + realtor stretch 2015-17'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Cassandra Alves', 'evidence', 'Concurrent enrollment + retail work through college pursuit; short recent stints (Bath & Body Works 3mo, Victoria Secret 2mo) but explained by degree pursuit'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Cheryl Hemphill', 'evidence', 'Three industry pivots in trailing 2 years; current role 5 months old at Globe Life; pattern of short tenure across post-pivot period')
 ),
 'Durability and consistency of work effort over time. Parser weight: 1 of 4 sub-signals averaged for Nurture.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 5 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Nurture: Personal Responsibility', 'Personal Responsibility',
 jsonb_build_object(
   'construct', 'nurture', 'position', 4,
   'markers_positive', ARRAY['gaps and downshifts explained cleanly on resume', 'ownership language (I built, I decided, I owned the outcome)', 'forward trajectory after documented setbacks', 'transitions framed as choices with reasoning'],
   'markers_negative', ARRAY['unexplained major downshift (senior role -> gig or entry-level)', 'unexplained gap >6 months', 'blame-shifting phrases (company let me go, team failed, manager did not support)', 'downshift without acknowledgment or reframe'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'Tommy Lynch', 'evidence', 'Every career move traceable and forward; state trooper -> executive protection unit -> back to trooper II -> Cape Charles PD Master Officer + Field Training Officer; ownership visible throughout'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'April Varian', 'evidence', 'Warehouse operations trajectory stable across S. Bertram tenure; no signal of ownership beyond assigned roles; no downshifts to explain, no ownership language to signal'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Bob Williams', 'evidence', '4-year unexplained downshift from Master-level educator + opera performer to Amazon delivery driver 2022-present; no acknowledgment or reframe on resume')
 ),
 'Ownership of career transitions and absence of unexplained downshifts. Parser weight: 1 of 4 sub-signals averaged for Nurture.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 6 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Drivers: Trajectory Direction', 'Trajectory Direction',
 jsonb_build_object(
   'construct', 'drivers', 'position', 1,
   'markers_positive', ARRAY['earned upward promotions with title changes', 'increasing scope / scale / responsibility over time', 'progression trajectory maintained across employer changes'],
   'markers_negative', ARRAY['lateral drift with no upward moves', 'unexplained downshift in title or scope', 'declining trajectory (each role smaller than previous)'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'April Varian', 'evidence', '5 years at S. Bertram Foods with 3 earned internal promotions (Replenishment Manager 2020-21 -> Inventory Manager 2021-23 -> Project Manager Slot Coordination 2023-25)'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Anthony Vela', 'evidence', 'Cold-calling throughline maintained across 14 years but title and scope stayed at similar level (Sales Manager -> SDR -> Business Development)'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Randy Castle', 'evidence', 'Alpha Romeo Service Manager 2021-23 (claimed top performer) -> Avenue 5 Property Management porter/groundskeeper 2023-24 -> Synergy Refrigeration dispatcher 2025 (2 months); unexplained downshift mid-career')
 ),
 'Direction of title and scope movement across career. Parser weight: 1 of 3 sub-signals averaged for Drivers.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 7 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Drivers: Coherent Pursuit', 'Coherent Pursuit',
 jsonb_build_object(
   'construct', 'drivers', 'position', 2,
   'markers_positive', ARRAY['one industry or skill stack pursued consistently over 3+ years', 'late-career pivot after long tenure OK (single coherent pivot into adjacent domain)', 'clear directional theme across employers'],
   'markers_negative', ARRAY['2+ complete industry pivots in trailing 3 years', 'currently pursuing degree in unrelated field (signals fallback income for target seat)', 'no coherent thread across recent work'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'Tommy Lynch', 'evidence', 'Law enforcement throughline 14+ years with adjacent entrepreneurial work; not searching for direction; committed pursuit visible'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Matthew Carlton', 'evidence', '25 years in sales with coherent late pivot from real estate into insurance via recent credentials (P&C, L&H, AHIP, AML, ACA); single directional shift within sales domain'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Cheryl Hemphill', 'evidence', 'Healthcare 16 years -> UT Austin Full Stack bootcamp -> QA/BA at ExcelPros -> insurance sales at Globe Life all within trailing 3 years; still searching for direction')
 ),
 'Consistency of directional pursuit across the trailing 3 years. Parser weight: 1 of 3 sub-signals averaged for Drivers.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 8 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Drivers: Follow-Through', 'Follow-Through',
 jsonb_build_object(
   'construct', 'drivers', 'position', 3,
   'markers_positive', ARRAY['completed degrees earning credential', 'earned licenses (state licensing, professional certifications)', 'sustained side projects with visible outcomes', 'stacked credentials in target domain'],
   'markers_negative', ARRAY['started but did not finish degree', 'motivation seminars listed as skill / education substitute', 'no completed credentials across career', 'aspirational credentials without completion evidence'],
   'anchor_high', jsonb_build_object('score', '9-10', 'candidate', 'Matthew Carlton', 'evidence', 'TX P&C + TX Life & Health + AHIP Medicare 2025-26 + AML certification + ACA Marketplace Certification all current and recent, evidencing serious pivot into insurance'),
   'anchor_mid', jsonb_build_object('score', '5', 'candidate', 'Stephanie Rogers', 'evidence', 'BA Integrated Studies with Communications minor completed 2025 (recent completion earning credential); no post-BA credentials yet given early career stage'),
   'anchor_low', jsonb_build_object('score', '1-2', 'candidate', 'Anthony Vela', 'evidence', 'Education / Professional Development section anchored by Tony Robbins Unleash the Power Within attended 4 times (2014, 2015, 2016, 2023) plus Tony Robbins Business Mastery 2015; no completed credentials, no degree, motivation seminars as skill substitute')
 ),
 'Completion rate on credentials and pursuits started. Parser weight: 1 of 3 sub-signals averaged for Drivers.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Sub-signal 9 of 9.'),

('126794dd-25ff-47d2-a436-724499733365', 'resume_score_rubric', 'Config: Composite math + penalty + thresholds', 'Composite Config',
 jsonb_build_object(
   'construct', 'config',
   'construct_weights', jsonb_build_object('nature', 0.35, 'nurture', 0.30, 'drivers', 0.35),
   'subsignal_averaging', 'simple mean within each construct',
   'rule_count_penalty', jsonb_build_object(
     'applies_when', 'any resume_screen_signal rule fires on this candidate',
     'penalty_per_rule', -0.5,
     'applied_to', 'composite score after weighted average of constructs'
   ),
   'verdict_thresholds', jsonb_build_object(
     'pass', '>= 7.0',
     'consider', '5.0 to 6.99',
     'decline', '< 5.0',
     'decline_character', 'any character-signaling resume_screen_signal rule fires (self_superiority_language is calibrated example) AND composite < 5.0'
   ),
   'parser_read_order', ARRAY['load 9 sub-signal rows with construct=nature/nurture/drivers', 'score each sub-signal 1-10 using markers plus anchor calibration', 'average sub-signals within construct', 'weighted average across constructs per weights above', 'evaluate resume_screen_signal rules against resume text', 'subtract penalty per rule fired', 'apply verdict thresholds']
 ),
 'Composite math config for parser. Weights Nature 0.35 / Nurture 0.30 / Drivers 0.35. Penalty -0.5 per resume_screen_signal rule fired. Thresholds Pass >=7.0 / Consider 5.0-6.99 / Decline <5.0.',
 'calibrated_n3plus', true, ARRAY['resume_review'],
 'Config row - not a scoring sub-signal. Parser reads this first.');;