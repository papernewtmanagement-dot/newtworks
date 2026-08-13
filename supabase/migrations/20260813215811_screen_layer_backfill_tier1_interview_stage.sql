-- Screen layer backfill, tier 1: the 5 candidates at interview stage.
-- Planning-thread scoring (Claude in chat) against hiregauge_rules
-- rule_type='screen_score_rubric'. Signals only + narrative + scored_at +
-- scored_model; construct scores are NEVER stored (computed on read by
-- screen_character / screen_commitment / verdict_screen).

BEGIN;

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 58,
    'accountability', 80,
    'role_interest_specificity', 32,
    'challenge_realism', 25),
  'narrative', 'Character is carried entirely by item 5: a real, consequential, verifiable mistake (inherited physics project list included an item students were not permitted to have, already sent to parents), owned in his own words ("I failed to see"), corrected same day to headmaster, assistant headmaster and all parents. Minor deductions - the "what I should have done differently" is implied rather than stated, the inherited-list mention is mild deflection, and it closes on "the project was a success." Job history is plausible and resume-consistent but thin: a 9+ year, multi-role education resume is covered by one general statement about administration turnover, though the current iFly shift scarcity is concrete and checkable. Commitment is the weak side. Item 2 never names insurance or this kind of work at all - "stability," "something different," "use some of my skills" would paste into any application, honest but content-free. Item 3 is the textbook softball the anchor names, worsened by a minimizer ("can be different but not difficult"); small credit for the candid admission that some jobs take him longer to master, but he does not touch rejection, licensing or pace. Interview probes: what specifically about insurance sales, and what he thinks the hard 90 days actually look like. Item 7 named a person (Brenda Dennis) with no employer or contact - not a refusal, so no amber, but not yet checkable; get employer and number at interview.',
  'scored_at', '2026-08-13T21:40:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '31617d6f-e3f4-456f-9dfd-9bb9abbc4955';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 68,
    'accountability', 72,
    'role_interest_specificity', 62,
    'challenge_realism', 42),
  'narrative', 'Strongest commitment profile of the interview-stage group. Item 1 accounts for all three resume entries with no contradictions, and the failed-business explanation is genuinely unflattering and specific (niche idea, larger competitors undercut on price) - real ownership. Deduction: the HEB reason carries a superiority note ("misrepresented by data points management does not fully understand"), which is externally attributed and worth probing. Item 2 ties interest to his own verifiable history - 75-100 calls a day for his own company, and an explicit preference for performance-based pay - but never reaches insurance or this agency specifically, so it sits between generic and specific. Item 3 names one real hard part (difficult conversations and customers) and then immediately dismisses it ("nothing I cannot handle"); licensing, pace and product learning go unmentioned. Item 5 is a concrete operational miss (under-ordered for the 4th of July against a 40% year-over-year increase) with a real correction and a specific, usable "what I would do differently" - compare prior-year data sheets, look for reasons volume runs higher; capped below the high band because the consequence was modest and it closes on impressing management. Item 7 checkable (Robert, HEB manager, number given) - and the HEB reason above is the reference-check question. Note his comp preference is the predictable higher base, which sits against his stated performance-pay motivation; worth reconciling at interview.',
  'scored_at', '2026-08-13T21:40:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '5489f7e2-195a-4938-beb0-07882b433a51';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 60,
    'accountability', 70,
    'role_interest_specificity', 48,
    'challenge_realism', 22),
  'narrative', 'Item 5 is the standout: rehiring an employee who had quit and walked out, whose performance then got worse, with the fault placed squarely on her own emotional decision-making and a specific stated lesson (decide on what is best for the company, not on emotion). Held just below the high band because she describes the lesson without describing what she actually did to correct the situation. Item 1 is clean and verifiable on the ten-year role (owner retired) and non-blaming throughout, but a resume spanning office administration, executive support, finance coordination, legal administration and operations management gets only two sentences - thin coverage rather than any contradiction. Item 2 contains the one genuinely insurance-specific detail in the whole tier - she wants her adjuster license - but that is a carrier claims credential, not the license this agency seat runs on, so the interest is real and pointed at a different job than the one she applied for; the rest is the exact low-anchor phrase about enjoying working with people. That mismatch is the single most important interview question for her. Item 3 is the verbatim low anchor - learning the new systems, plus self-reassurance about being a fast learner. Item 7 is the best reference in the tier: full name, title, organization and number.',
  'scored_at', '2026-08-13T21:40:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '37ac6fa0-0a04-495b-8a58-e6cb6e7e0902';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 22,
    'accountability', 8,
    'role_interest_specificity', 18,
    'challenge_realism', 20),
  'narrative', 'Lowest of the tier by a wide margin, and the gap is substance, not writing - all four answers decline the question asked. Item 1 is a single sentence ("parted ways with the previous employer because I am looking to grow") against a resume carrying five-plus positions, and it does not say which employer; the resume itself shows three roles simultaneously running "to Present" (Wells Fargo, Gonzaba, and earlier overlap) and her answer resolves none of it - gaps papered over rather than explained. Item 2 would paste into any application in any industry: learn, expand skills, help others; no insurance, no agency, no own history. Item 3 is a softball with a vague self-directed twist (putting extra pressure on herself) and names no actual difficulty of the work. Item 5 is the clearest case: it is the humble-brag the low anchor describes almost word for word - "I am pretty good at analyzing situations and making the correct decision" - with no mistake named, no correction, no lesson. Zero-credit answers on the written personal-responsibility probe are the strongest single signal this layer produces. If she stays in process, items 1 and 5 must be re-asked live and answered concretely before anything else. Item 7 named a person (Aliyah Carmona) with no employer or contact - not a refusal, so no amber, but not checkable as given.',
  'scored_at', '2026-08-13T21:40:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = 'c9d4bfce-e8ef-4ce8-8bed-f7d6eb95cc70';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 66,
    'accountability', 70,
    'role_interest_specificity', 20,
    'challenge_realism', 22),
  'narrative', 'Carries the single most consequential finding in this tier: item 3 refers to learning the details of "Allstate''s insurance products," and item 2 sells the appeal of working from home. This is a State Farm agency and the seat is not remote - both answers were written for, or lifted from, a different application and never updated. Under the standing rule that polish earns nothing and only verifiable specifics score, these are the most fluent answers in the group and the least responsive: strip the competitor name and the remote-work premise and what remains is generic (make a positive difference, contribute to a team) plus the learning-curve softball. Commitment scores accordingly. Character is a different picture and is the reason she is not scored lower overall. Item 1 is the best-covered history in the tier - unemployment stated plainly, and the sheriff''s office, blood and tissue, and bar positions each given a distinct reason consistent with the resume, with no blame directed outward; the one soft spot is "personal reasons" on the law-enforcement exit. Item 5 shows genuine ownership with a concrete correction (told her supervisor, corrected the documentation, made sure everyone had accurate information) and a real lesson about verifying before acting, held below the high band because the underlying decision and its consequence are described abstractly for a thirty-year resume. Item 7 is checkable and points at exactly the right place - Comal County Sheriff''s Office, Adam Luna, with a number - which makes the vague "personal reasons" the first reference-check question. Ask directly whether this application is targeted or one of many.',
  'scored_at', '2026-08-13T21:40:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '728e594e-a7b1-4a73-b2b0-337f4d715fec';

COMMIT;
