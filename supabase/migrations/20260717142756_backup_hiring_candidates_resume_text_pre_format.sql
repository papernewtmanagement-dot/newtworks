-- Snapshot of resume_extracted_text before adding section separators for readability.
-- Reversible via: UPDATE hiring_candidates SET resume_extracted_text = b.resume_extracted_text
--                 FROM _bak_hiring_candidates_resume_text_2026_07_17 b WHERE hiring_candidates.id = b.id;
CREATE TABLE IF NOT EXISTS public._bak_hiring_candidates_resume_text_2026_07_17 AS
SELECT id, candidate_name, resume_extracted_text, NOW() AS backed_up_at
FROM public.hiring_candidates
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND resume_extracted_text IS NOT NULL
  AND LENGTH(TRIM(resume_extracted_text)) > 0;;