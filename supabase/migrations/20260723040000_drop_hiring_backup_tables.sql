-- Drop 2 orphaned backup tables: zero references anywhere.
-- Confirmed pre-drop: no rows read from either table by any pg function, view, trigger,
-- frontend file, or edge function.
-- Approved by Peter 2026-07-23 in the Batch 1 hiring schema cleanup pass.

DROP TABLE IF EXISTS public._bak_hiring_candidates_resume_text_2026_07_17;
DROP TABLE IF EXISTS public._lss_change_snapshot;
