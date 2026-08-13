-- Screen layer backfill, tier 2: active pipeline (team meet-and-greet + applied).
-- Planning-thread scoring against hiregauge_rules rule_type='screen_score_rubric'.
-- Signals + narrative + scored_at + scored_model only.

BEGIN;

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 55,
    'accountability', 58,
    'role_interest_specificity', 62,
    'challenge_realism', 72),
  'narrative', 'Recent finance graduate, and the profile reads like one - the commitment side is stronger than the character side, which inverts the pattern seen at interview stage. Item 3 is the second-best challenge answer in the backlog: he names product learning explicitly (staying current across a wide range of insurance and financial products AND explaining them simply), plus a genuine second difficulty in reading each client situation quickly. He does not reach rejection, licensing or pace. Item 2 names insurance and financial products and ties the interest to a verifiable credential (finance degree, May 2026, on the resume), weakened by the low-anchor filler about enjoying working with people. Item 1 is airtight but narrow - "I was a student worker, I left because I graduated" is clean, checkable and consistent with the assistant coaching role ending May 2026, but it covers one position when the resume carries more; the thinness is partly just a short history. Item 5 is an academic procrastination story: real ownership, a specific correction (built a schedule, prioritized, finished on time), and a genuine lesson about breaking work into smaller pieces, but the stakes are low and it is not a workplace decision, which caps it in the middle band. Interview probe: get a consequential mistake from a work setting, and test whether the finance interest survives contact with what this seat actually does day to day. Item 7 named an institution (Texas A&M University - San Antonio) with no person and no number - under-supplied rather than evasive, so no amber flag; get a named human and a phone number.',
  'scored_at', '2026-08-13T21:55:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '8a78220e-23f4-44b2-9f05-c9607b9e3e1f';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 90,
    'accountability', 78,
    'role_interest_specificity', 92,
    'challenge_realism', 55),
  'narrative', 'The strongest screen in the backlog, and by a clear margin. Item 1 explains every move with specifics that can be checked: she left State Farm claims because the role moved from remote to field work requiring roof climbing she is not comfortable doing - a concrete, honest limitation rather than a grievance; she left GEICO for State Farm because she had wanted to work there for years; she left the certified nursing assistant role for better pay as a single mother. Resume confirms State Farm Claim Specialist June 2022 to November 2025. Item 2 is the best role-interest answer this layer has scored: specific to State Farm, specific to agency work rather than insurance generally, anchored in growing up in her own father''s agency watching relationships get built, and it arrives independently at the exact insight this agency runs on - that most people do not know what coverage they carry or what is available to them. Family history is deep and verifiable (grandfather a deputy regional vice president, father and uncle agents, sister and mother both working for agencies). Item 5 is a real workplace mistake with a real consequence: she passed along incorrect guidance from a teammate to an insured, the claim stalled, and the agent had to chase it; she owned it to the agent with a timeline and reset expectations, and states the right correction (verify against additional resources rather than one colleague). Held below 80 because the original error came from the teammate and her share is the verification failure. Item 3 is the one soft spot - she names a genuinely hard part (fitting coverage to budget) and then pivots into a pitch for local-agent value instead of examining the difficulty; rejection, licensing and pace go unmentioned. Two compliance notes for whoever runs the interview: she is a FORMER State Farm employee who left in November 2025 and applied inbound, so the anti-raiding restriction is not in play; and her phrase about being an advocate on a claim needs the standard boundary conversation, since an agency can advocate and translate but never decide a claim. Item 7 is the best reference set received: employer plus two named people with numbers.',
  'scored_at', '2026-08-13T21:55:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = 'aa61f093-0312-4af3-a6d4-117d2344f87d';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 65,
    'accountability', 72,
    'role_interest_specificity', 76,
    'challenge_realism', 82),
  'narrative', 'Commitment is the strongest of any candidate in the backlog, which inverts the dominant pattern. Item 3 is the best challenge answer scored so far: he names the real difficulty - getting people past the assumption that you are just another insurance person after their money - and then names rejection outright, that some will listen and some will not and the job is being good at hearing no and continuing anyway. Rejection is the first hard part the anchor asks for and almost nobody in this backlog reached it. Item 2 backs the low-anchor opener about loving to help people with actual substance: he explains, from what he says is firsthand knowledge, why paying a monthly premium beats absorbing an accident out of pocket, and states plainly that he has been in sales a long time and is used to hearing no - consistent with the upselling and pass-selling on his resume. Item 1 covers all three jobs with dates and reasons that line up with the resume (Subway and Mother Earth Labs both ended for high school, aquarium since May 2024). His three current-job reasons - unsteady hours, schedules always late, no incentive for harder workers - point outward at the employer, but they are concrete and checkable rather than vague, and the third one is worth probing because it doubles as his stated motivation for a performance-paid seat. Item 5 is a fully owned operational error: he double-booked two field trips because he did not check the board where the first was already written, says plainly that this is what he messed up, fixed it by moving the second school an hour later with a comped tour guide, and states the correction. Modest consequence keeps it in the upper middle band. Writing mechanics are rough throughout and are not scored anywhere in this layer - standing doctrine, and the substance here is well above the presentation. Item 7 checkable: named person with a number.',
  'scored_at', '2026-08-13T21:55:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '35306110-64d9-470e-89ab-1c5aeb0cbea4';

UPDATE public.hiring_candidates SET screen_analysis = jsonb_build_object(
  'signals', jsonb_build_object(
    'job_history_candor', 78,
    'accountability', 76,
    'role_interest_specificity', 25,
    'challenge_realism', 48),
  'narrative', 'Split profile: strong character, weak commitment, and a hard collision with agency policy sitting underneath both. Item 1 is the cleanest chronology in the backlog - four positions, each with a reason, all confirmed by the resume, and three of the four end structurally rather than by choice (returned to school, temporary camp position ended, graduate assistantship ended with the degree). Only the most recent reason is the generic growth answer. Item 5 is complete on all three parts the anchor asks for: she relied on memory instead of logging newly enrolled clients on a busy day, details were lost, staff depended on that data; she owned it immediately, told the affected staff, spent the afternoon correcting the files, then confirmed access and answered their questions; and the stated correction is a durable rule she says she now follows - document digitally at the moment it happens rather than trusting recall. Commitment is where this falls apart. Item 2 is entirely about what the agency offers her - employment improvement, professional development, career growth - with insurance appearing only as the category the clients belong to; nothing about the work itself and nothing tied to her own history, so it would paste into any application at any employer with a training program. Item 3 names upset callers and de-escalation from her own phone experience, which is real, but she explicitly frames the role as a receptionist at an insurance firm - a front-desk phone seat. That is not what this seat is; every position in this agency participates in selling. She is describing, and preparing for, a different job. THE CRITICAL FINDING is item 6: she answered No to moving her insurance products to the agency. She is the only No in the entire backfilled set. Standing agency policy makes that commitment a condition at offer for every customer-touching seat, so this needs a direct conversation before she advances, independent of anything the screen score says - and the screen layer never auto-declines anyone. Item 7 checkable: named person with a number.',
  'scored_at', '2026-08-13T21:55:00Z',
  'scored_model', 'claude-opus-5')
WHERE id = '3366643c-7fb0-46cd-a019-f146b5ef47a5';

COMMIT;
