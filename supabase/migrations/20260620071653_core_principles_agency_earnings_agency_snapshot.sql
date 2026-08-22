-- Tier C: surgical replacement on the 'Agency Earnings' core principle.
-- Two text swaps; everything else byte-identical.
UPDATE public.core_principles
SET content = replace(
    replace(content,
      'Live data in `agency`, `aipp_tracking`, `comp_recap`, `sf_program_targets`, `sf_on_time_snapshot`, `producer_production` answers most questions.',
      'Live data in `agency`, `aipp_tracking`, `comp_recap`, `sf_program_targets`, `agency_snapshot`, `producer_production` answers most questions.'),
    '- **`sf_on_time_snapshot`** holds raw YTD production/lapse/credits/IPS values — primary input to the runtime on-time SMVC + Scorecard computations.',
    '- **`agency_snapshot`** holds the merged book-of-business snapshot — stock (premium $, PIF, household count) AND flow (YTD new/lost per LOB, life paid-for count + premium, IPS new money). The flow columns are the primary input to the runtime on-time SMVC + Scorecard computations. Replaces `book_snapshot` + `sf_on_time_snapshot` (merged + dropped 2026-06-20).'),
    updated_at = NOW()
WHERE id = '24d10e20-db5a-42ca-a2c3-8362b8aa86c1'
  AND title = 'Agency Earnings — How State Farm Pays the Agency';
