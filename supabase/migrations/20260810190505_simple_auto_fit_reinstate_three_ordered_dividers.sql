-- Reinstates the three horizontal dividing lines Peter ordered on Simple Auto FIT
-- (between Death and the Advanced Product Situations FAQ, below that FAQ, and below
-- the discount expanders). They were first added 2026-08-10 03:44 as *** (the only
-- divider form the then-live manuals_no_hr_divider CHECK constraint permitted) and
-- were stripped again by a later same-day pass. That constraint has since been
-- dropped (migration 20260810182343) on the same Peter directive, so they go back
-- in as --- to match PAP Appraisers and Roofer Referrals.
--
-- All three anchors verified unique before writing. The third divider is placed on
-- this page rather than at the head of the shared FIT Closer - Auto & Home fragment
-- so it applies only where it was ordered, and does not appear on Simple Home FIT.

UPDATE public.manuals
SET content = replace(
                replace(
                  replace(content,
                    E'*[Embedded excerpt from: Auto Death Benefit Bridge the Gap]*\n\n</details>\n\n<details>\n<summary>FAQ: Advanced Product Situations</summary>',
                    E'*[Embedded excerpt from: Auto Death Benefit Bridge the Gap]*\n\n</details>\n\n---\n\n<details>\n<summary>FAQ: Advanced Product Situations</summary>'),
                  E'</details>\n\n{{say: And of course, I\'ve got all the discounts added on that apply here.}}',
                  E'</details>\n\n---\n\n{{say: And of course, I\'ve got all the discounts added on that apply here.}}'),
                E'</details>\n\n*[Embedded excerpt from: FIT Closer - Auto & Home]*',
                E'</details>\n\n---\n\n*[Embedded excerpt from: FIT Closer - Auto & Home]*'),
    version = COALESCE(version, 0) + 1,
    updated_at = now()
WHERE id = 'cc8c1ad5-4482-4c45-90a2-184148d8c52c'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';
