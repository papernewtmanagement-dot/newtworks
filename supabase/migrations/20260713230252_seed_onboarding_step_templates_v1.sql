-- ============================================================================
-- Minimum-viable onboarding template seed
-- ----------------------------------------------------------------------------
-- Drawn from admin manual pages in the Hiring tree. Deliberately kept lean —
-- streamlining pass will refine + expand these later. Steps point back at
-- the source manual page for detail; the module is task-tracker, manual is
-- reference.
--
-- Phase codes:
--   0 = Pre-Day 1
--   1 = Week 1 (Orientation)
--   2 = Weeks 3-4
--   3 = Weeks 5-8
--   4 = Weeks 9-13
--   5 = Week 14+
--
-- Role applicability uses role_category ('Sales' or 'Retention') for the ramp
-- steps, because every new hire starts as role_level='Account Associate' and
-- the ramp branches on which side they're being trained for.
-- ============================================================================

WITH src AS (
  SELECT
    (SELECT id FROM public.manuals WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND title='Desk Checklist')        AS desk_id,
    (SELECT id FROM public.manuals WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND title='Admin Setup')          AS admin_id,
    (SELECT id FROM public.manuals WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND title='Tech Setup')           AS tech_id,
    (SELECT id FROM public.manuals WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND title='Orientation')          AS orient_id,
    (SELECT id FROM public.manuals WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND title='Onboarding Schedule')  AS sched_id,
    (SELECT id FROM public.manuals WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND title='Your Path')            AS path_id
)
INSERT INTO public.onboarding_step_templates
  (agency_id, template_key, title, description, phase, category,
   source_manual_id, applies_to_role_categories, sort_order, is_required)
SELECT '126794dd-25ff-47d2-a436-724499733365'::uuid, k, t, d, ph, c, mid, cats, ord, req FROM src, LATERAL (
  VALUES
    -- ── Phase 0: Pre-Day 1 ────────────────────────────────────────────────
    ('p0_offer_signed',           'Offer signed',                                'Signed offer letter on file.',                                              0, 'documents',      NULL,     NULL::text[], 10,  true),
    ('p0_pc_license',             'P&C license on file',                          'Mandatory before starting. Reception exception: may start unlicensed if licensing is front-loaded in Weeks 1-4.', 0, 'licensing', src.path_id, NULL, 20, true),
    ('p0_welcome_text',           'Welcome text sent from Peter',                'Personal welcome message received by new hire.',                            0, 'documents',      NULL,     NULL::text[], 30,  true),
    ('p0_first_week_schedule',    'First-week schedule sent to new hire',        'New hire has visibility on what Week 1 looks like before Day 1.',           0, 'documents',      NULL,     NULL::text[], 40,  true),
    ('p0_yubikey_ordered',        'Yubikey ordered',                             'Physical security key procured and en route.',                              0, 'systems',        NULL,     NULL::text[], 50,  true),
    ('p0_ecrm_account',           'ECRM account provisioned',                    'State Farm ECRM login created via Agent Team Member System Access Request.', 0, 'systems',       NULL,     NULL::text[], 60,  true),
    ('p0_newtworks_login',        'Newtworks login created',                     'Invite-team-member flow completed. User row + auth login exist.',           0, 'systems',        NULL,     NULL::text[], 70,  true),
    ('p0_desk_setup',             'Desk fully set up',                           'Two monitors, mouse, keyboard, dock, laptop verified, webcam, cables tucked, headset tested on all three audio paths (system / Teams / phone), desk supplies staged.', 0, 'physical_setup', src.desk_id, NULL, 80, true),
    ('p0_references_requested',   'References requested + received',             '3 professional references. Former managers/supervisors ideal.',             0, 'documents',      src.admin_id, NULL, 90, true),
    ('p0_prior_appts_terminated', 'Prior insurance appointments terminated',     'New hire has terminated all prior appointments/authorizations with other insurers in all states.', 0, 'compliance', src.admin_id, NULL, 100, true),
    ('p0_door_alarm_codes',       'Door + alarm codes provided',                 'Physical office access.',                                                   0, 'systems',        NULL,     NULL::text[], 110, false),

    -- ── Phase 1: Week 1 Orientation ───────────────────────────────────────
    ('p1_tech_setup_page',        'Complete Tech Setup page',                    'Yubikey login, VPN, Windows Hello, Cloud Drive path, taskbar pinning.',     1, 'systems',        src.tech_id, NULL, 10, true),
    ('p1_orientation_page',       'Complete Orientation page (The Ten, Sales Fundamentals, Compliance, Newtworks intro, SCF Scorecard walkthrough)', 'Absorption week content. Watch the videos, do the paperwork, get set up, shadow calls as they arise.', 1, 'training', src.orient_id, NULL, 20, true),
    ('p1_paperwork_pack',         'HR paperwork: W-4, I-9, SF Annual Certification, Non-Compete, Payroll & Bio', 'Signed and returned.',                          1, 'documents',      src.orient_id, NULL, 30, true),
    ('p1_workday_courses',        'Workday courses: Info Security & Privacy, Anti-Money Laundering — U.S., Multiline Compliance, Product Overview, Life Insurance Illustrations', 'All 5 completed in Week 1.', 1, 'compliance', src.orient_id, NULL, 40, true),
    ('p1_compliance_ack',         'Sign compliance acknowledgment',              'Confirms understanding of what may / may not be said on customer-facing surfaces.', 1, 'compliance', src.orient_id, NULL, 50, true),
    ('p1_first_scf_practice',     'Fill first SCF Scorecard as practice',        'Simple Conversation Fit Scorecard walkthrough during a shadow call.',       1, 'training',       src.orient_id, NULL, 60, true),
    ('p1_ten_why',                'The Ten #1 — Type out your why + send to Peter', 'Homework from the Scripture-frame clip.',                                1, 'training',       src.orient_id, NULL, 70, true),

    -- Sales-track Week 1 (shadow-only, no production expectations)
    ('p1_sales_shadow_5',         'Shadow 5 quote opportunities',                'Sit with a senior AM. SCF Scorecard on every conversation.',                1, 'role_specific',  src.sched_id, ARRAY['Sales'], 100, true),

    -- Retention-track Week 1
    ('p1_ret_answer_by_3',        'Answer inbound calls by the 3rd ring',        'Front-line service standard.',                                              1, 'role_specific',  src.sched_id, ARRAY['Retention'], 100, true),
    ('p1_ret_log_ecrm',           'Log every conversation in ECRM',              'Every inbound + outbound touch documented.',                                1, 'role_specific',  src.sched_id, ARRAY['Retention'], 110, true),
    ('p1_ret_pivot_every_call',   'Attempt a pivot on every eligible call',      'Retention is the listening surface — notice, log, hand to right teammate.', 1, 'role_specific',  src.sched_id, ARRAY['Retention'], 120, true),
    ('p1_ret_shadow_5_quotes',    'Shadow 5 quote opportunities',                'Sit with a senior Account Manager, fill SCF Scorecard on each.',            1, 'role_specific',  src.sched_id, ARRAY['Retention'], 130, true),

    -- ── Phase 2: Weeks 3-4 ────────────────────────────────────────────────
    ('p2_1on1_started',           'Weekly 1:1 with Peter established',           'Standing weekly. SCF Scorecard review + process check.',                    2, 'training',       src.sched_id, NULL, 10, true),
    ('p2_daily_wrapup',           'Daily Wrap-up complete end of each day',      'Habit locked.',                                                             2, 'training',       src.sched_id, NULL, 20, true),

    ('p2_sales_first_quotes',     'First independent quotes',                    '75% shadow OK. Contribute to team quote target.',                           2, 'role_specific',  src.sched_id, ARRAY['Sales'], 100, true),
    ('p2_sales_fanatical',        'Watch Fanatical Prospecting clip on Orientation', 'Weeks 3-4 skill development window.',                                    2, 'role_specific',  src.orient_id, ARRAY['Sales'], 110, false),

    ('p2_ret_late_pay',           'Late-pay list outbound — 2 blocks/week, Tue/Thu 10-11am', 'First recurring outbound rhythm.',                              2, 'role_specific',  src.sched_id, ARRAY['Retention'], 100, true),
    ('p2_ret_service_by_5',       'Service inbox complete by 5pm each day',      'Nothing lingers overnight.',                                                2, 'role_specific',  src.sched_id, ARRAY['Retention'], 110, true),
    ('p2_ret_welcome_2wk',        '2 welcome meetings per week',                 'New-customer face time.',                                                   2, 'role_specific',  src.sched_id, ARRAY['Retention'], 120, true),

    -- ── Phase 3: Weeks 5-8 ────────────────────────────────────────────────
    ('p3_sales_50_shadow',        'Down to 50% shadow',                          'Team quote share ramping.',                                                 3, 'role_specific',  src.sched_id, ARRAY['Sales'], 10, true),
    ('p3_sales_life_fit',         '1 Life FIT per week',                          'Life pipeline starts.',                                                    3, 'role_specific',  src.sched_id, ARRAY['Sales'], 20, true),
    ('p3_sales_go_for_no',        'Watch Go for No clips on Orientation',        'Weeks 5-8 skill development window.',                                       3, 'role_specific',  src.orient_id, ARRAY['Sales'], 30, false),

    ('p3_ret_ah_review',          'Auto/Home Review on renewal + 30 days for your alphabet-split book', 'Rolling renewal review cadence begins.',              3, 'role_specific',  src.sched_id, ARRAY['Retention'], 10, true),
    ('p3_ret_life_review',        'Life Review for households with 3+ P&C but no Life', 'Cross-sell pipeline for retention seat.',                             3, 'role_specific',  src.sched_id, ARRAY['Retention'], 20, true),
    ('p3_ret_farewell',           'Farewell Review on every cancellation',       'Learn why + attempt save.',                                                 3, 'role_specific',  src.sched_id, ARRAY['Retention'], 30, true),
    ('p3_ret_welcome_3_5',        '3-5 welcome meetings per week',               'Ramp up from 2/wk.',                                                        3, 'role_specific',  src.sched_id, ARRAY['Retention'], 40, true),
    ('p3_ret_hh_outbound',        '5 household outbound per week',               'Prospecting-adjacent outreach on existing book.',                           3, 'role_specific',  src.sched_id, ARRAY['Retention'], 50, true),

    -- ── Phase 4: Weeks 9-13 ───────────────────────────────────────────────
    ('p4_sales_25_shadow',        'Down to 25% shadow',                          'Full Account Manager quote share (15/wk).',                                 4, 'role_specific',  src.sched_id, ARRAY['Sales'], 10, true),
    ('p4_sales_life_2plus',       '2+ Life FIT per week',                        'Life pipeline scaling.',                                                    4, 'role_specific',  src.sched_id, ARRAY['Sales'], 20, true),
    ('p4_sales_auto_loan',        'Auto Loan Process ownership',                 'Full end-to-end responsibility on Auto Loan flow.',                         4, 'role_specific',  src.sched_id, ARRAY['Sales'], 30, true),

    ('p4_ret_service_surge',      'Service-surge quoting begins',                'Take incoming service calls that turn into quote opportunities.',           4, 'role_specific',  src.sched_id, ARRAY['Retention'], 10, true),
    ('p4_ret_5_home_5_auto',      '5 Home Review + 5 Auto Review outbound per week', 'Formal review cadence at full pace.',                                    4, 'role_specific',  src.sched_id, ARRAY['Retention'], 20, true),
    ('p4_ret_claims_weekly',      'Claims Review weekly',                        'Recurring claim-touch rhythm established.',                                 4, 'role_specific',  src.sched_id, ARRAY['Retention'], 30, true),
    ('p4_ret_wtw_2_3',            'Contribute 2-3 quotes/week to team Win the Week', 'Retention side actively contributes to the team quote line.',            4, 'role_specific',  src.sched_id, ARRAY['Retention'], 40, true),

    -- ── Phase 5: Week 14+ ─────────────────────────────────────────────────
    ('p5_pc_licensed_verified',   'P&C license verified as active',              'Reception starters must be licensed by Week 14 at the latest.',             5, 'licensing',      src.path_id, NULL, 10, true),
    ('p5_remote_device_form',     'State Farm Agent Owned Mobile Device Access form submitted', 'Only agency-owned devices allowed. Follow SF setup steps + activation key.', 5, 'systems', src.sched_id, NULL, 20, false),

    ('p5_sales_independent',      'Fully independent',                           'Escalated shadows count 50%. Full AM quote share (15/wk) + team WTW contribution.', 5, 'role_specific', src.sched_id, ARRAY['Sales'], 100, true),
    ('p5_sales_life_3plus',       '3+ Life FIT per week — Champions Circle pace', '60+ Life items/year target.',                                              5, 'role_specific',  src.sched_id, ARRAY['Sales'], 110, true),

    ('p5_ret_full_role',          'Full retention role',                         'Every responsibility unlocked.',                                            5, 'role_specific',  src.sched_id, ARRAY['Retention'], 100, true),
    ('p5_ret_life_2plus',         'Life Review 2+ per week',                     'Retention Life cross-sell at full pace.',                                   5, 'role_specific',  src.sched_id, ARRAY['Retention'], 110, true),
    ('p5_ret_monthly_audit',      'Monthly renewal audit',                       'Recurring monthly rhythm.',                                                 5, 'role_specific',  src.sched_id, ARRAY['Retention'], 120, true),
    ('p5_ret_wtw_3_5',            'Contribute 3-5 quotes/week to team Win the Week', 'Retention share of team target at veteran pace.',                        5, 'role_specific',  src.sched_id, ARRAY['Retention'], 130, true)
  ) AS v(k, t, d, ph, c, mid, cats, ord, req)
ON CONFLICT (agency_id, template_key) DO NOTHING;

-- Report the count
DO $$
DECLARE v_count INT;
BEGIN
  SELECT COUNT(*) INTO v_count FROM public.onboarding_step_templates
   WHERE agency_id='126794dd-25ff-47d2-a436-724499733365' AND is_active=true;
  RAISE NOTICE 'onboarding_step_templates seeded — total active rows: %', v_count;
END $$;;