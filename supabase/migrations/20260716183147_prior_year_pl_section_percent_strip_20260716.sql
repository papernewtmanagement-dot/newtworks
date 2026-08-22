-- Strip trailing " N% > N% > N%" pattern from prior_year_pl.section
-- Peter picked Option B 2026-07-16: percentages render at UI time from envelope_budget_targets, not stored in section.
UPDATE public.prior_year_pl
SET section = REGEXP_REPLACE(section, '\s+\d+%(\s*>\s*\d+%)*\s*$', '')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND section ~ '\s+\d+%';
