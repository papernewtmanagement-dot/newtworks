-- Drop stored res_verdict column from hiring_candidates.
-- Peter directive 2026-07-18: verdict is derived data (composite band thresholds),
-- must be computed on view, not persisted. Stored verdicts drift from composite
-- exactly as observed today with Priscilla (7.00->6.91, stored 'pass' should be
-- 'consider') and Cassandra (5.03->4.86, stored 'consider' should be 'decline').
--
-- Verdict now computed in CandidateDetail.jsx renderResumeLayer + Results matrix
-- from res_composite via the config bands (>=7.0 pass, >=5.0 consider, <5.0 decline).
--
-- Consumer audit clean before drop (2026-07-18):
--   Frontend: only src/components/CandidateDetail.jsx line 260 read the column —
--             now derives verdict from composite instead (commit 80dc9736).
--   DB: zero functions/views reference res_verdict. hiregauge_three_construct_verdict
--       RPCs compute their own resume_verdict output from composite; they do not
--       read the stored column.

ALTER TABLE public.hiring_candidates DROP COLUMN IF EXISTS res_verdict;
