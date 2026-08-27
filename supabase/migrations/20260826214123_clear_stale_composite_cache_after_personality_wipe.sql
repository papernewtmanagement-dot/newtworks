-- Fix for a gap in today's wipes (fc_quad_go_live_and_retire_pairs, retire_old_assessment_bank_and_stint3):
-- clearing assessment_completed_at took those candidates OUT of hiregauge_refresh_scoring_cache's
-- target set, so their cached composite / protocol-validity values from the old personality
-- system were never recomputed and kept showing on the kanban. Clear the cache for every
-- candidate with no completed assessment; the next completion (finalize) repopulates it.
UPDATE public.hiring_candidates
SET cached_assessment_composite = NULL,
    cached_protocol_validity_v = NULL,
    cached_protocol_validity_label = NULL,
    cached_scoring_version = NULL,
    cached_at = NULL
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND assessment_completed_at IS NULL
  AND (cached_assessment_composite IS NOT NULL
       OR cached_protocol_validity_v IS NOT NULL
       OR cached_protocol_validity_label IS NOT NULL
       OR cached_scoring_version IS NOT NULL);
