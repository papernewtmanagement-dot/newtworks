-- HireGauge role_fit v3 rebuild — step 1 correction:
-- ground-truth labels are candidate attributes, not a new table.
-- Reverses 20260722170936 (hiregauge_ground_truth_table) which violated
-- check_overlap_first — hiring_candidates already has retrospective_notes,
-- retrospective_verdict_override, char_*, res_*, fi_*, va_* etc, so gt_*
-- fits the existing source-of-assessment prefix convention.

DROP TABLE IF EXISTS public.hiregauge_ground_truth;

ALTER TABLE public.hiring_candidates
  ADD COLUMN IF NOT EXISTS gt_archetype              text,
  ADD COLUMN IF NOT EXISTS gt_best_fit_seat          text,
  ADD COLUMN IF NOT EXISTS gt_alt_seats              text[],
  ADD COLUMN IF NOT EXISTS gt_decline_category       text,
  ADD COLUMN IF NOT EXISTS gt_coaching_variant       text,
  ADD COLUMN IF NOT EXISTS gt_motivator_family       text,
  ADD COLUMN IF NOT EXISTS gt_character_floor_status text,
  ADD COLUMN IF NOT EXISTS gt_confidence             text,
  ADD COLUMN IF NOT EXISTS gt_extraction_notes       text,
  ADD COLUMN IF NOT EXISTS gt_extracted_at           timestamptz;

ALTER TABLE public.hiring_candidates
  DROP CONSTRAINT IF EXISTS chk_hc_gt_character_floor_status,
  DROP CONSTRAINT IF EXISTS chk_hc_gt_confidence;

ALTER TABLE public.hiring_candidates
  ADD CONSTRAINT chk_hc_gt_character_floor_status
    CHECK (gt_character_floor_status IS NULL
           OR gt_character_floor_status IN ('pass','consider','fail')),
  ADD CONSTRAINT chk_hc_gt_confidence
    CHECK (gt_confidence IS NULL
           OR gt_confidence IN ('high','medium','inferred'));

CREATE INDEX IF NOT EXISTS idx_hc_gt_archetype     ON public.hiring_candidates(gt_archetype);
CREATE INDEX IF NOT EXISTS idx_hc_gt_best_fit_seat ON public.hiring_candidates(gt_best_fit_seat);
