-- Resume scoring revamp cleanup: correct over-applied early_career flags.
-- The original re-score sweep applied the corrected definition (Addendum 2:
-- work history under ~36 months) going forward, but did not retroactively
-- re-check every already-flagged candidate against it. This is that
-- re-check's write: unflag the subset that CLEARLY shows 5+ years of work
-- history. Set to false (not deleted) so the key and its history persist.
-- Data-only, additive/corrective — no other signal, status, or field touched.

UPDATE public.hiring_candidates
SET resume_analysis = jsonb_set(resume_analysis, '{early_career}', 'false'::jsonb)
WHERE id IN (
  '59e96740-c055-4765-9099-666d68759976', -- Celine Casanova   — continuous work history since 2018 (~8 yrs)
  'f1635140-665f-4f90-93bb-f60b31973017', -- Stephanie Castilla — continuous activity since 2020 (~6 yrs)
  'b0423f0b-ae68-4a82-84f3-2324030c956e', -- Caitlin Kuhlman   — continuous work history since 2020 (~6 yrs)
  '4ff74f25-bf39-4534-8400-31cefbaa596a', -- Alicia Racadag    — Grocery Bagger 2021-2025 (~4yr) + current job (~5 yrs)
  '069367dc-eeaf-4a00-a202-3e2e43760d53', -- Honor Smith       — business ownership Aug 2021-present (exactly 5 yrs)
  '5ce56bc6-1325-4104-884a-d9f9145dcf93'  -- Adrian Toler      — work history since 2017/2019 (~7-9 yrs)
)
AND resume_analysis->>'early_career' = 'true';
