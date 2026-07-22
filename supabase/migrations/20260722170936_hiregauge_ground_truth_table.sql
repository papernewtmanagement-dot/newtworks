-- HireGauge role_fit v3 rebuild — step 1: ground truth extraction table
--
-- Stores Peter's labeled interpretation of each candidate's fit, extracted
-- from hiring_candidates.notes / claude_summary. Purpose: score any future
-- role_fit function against these labels to measure predictive accuracy.
--
-- Taxonomy fields (archetype, best_fit_seat, alt_seats, decline_category,
-- coaching_variant, motivator_family) are free text initially. Vocabulary
-- will be FK/CHECK-tightened after step 2 (hiregauge_archetypes) and step 3
-- (hiregauge_seats) codify the taxonomies from what actually appears here.

CREATE TABLE IF NOT EXISTS public.hiregauge_ground_truth (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                   uuid NOT NULL,
  candidate_id                uuid NOT NULL UNIQUE
                              REFERENCES public.hiring_candidates(id) ON DELETE CASCADE,

  archetype                   text,
  best_fit_seat               text,
  alt_seats                   text[],
  decline_category            text,
  coaching_variant            text,
  motivator_family            text,

  character_floor_status      text CHECK (character_floor_status IN ('pass','consider','fail')),
  source_field                text NOT NULL
                              CHECK (source_field IN ('notes','claude_summary','both')),
  confidence                  text NOT NULL
                              CHECK (confidence IN ('high','medium','inferred')),

  extraction_notes            text,
  extracted_from_length       integer,
  extracted_at                timestamptz NOT NULL DEFAULT now(),
  extractor_model             text DEFAULT 'claude-opus-4-7',

  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hgt_agency          ON public.hiregauge_ground_truth(agency_id);
CREATE INDEX IF NOT EXISTS idx_hgt_archetype       ON public.hiregauge_ground_truth(archetype);
CREATE INDEX IF NOT EXISTS idx_hgt_best_fit_seat   ON public.hiregauge_ground_truth(best_fit_seat);

ALTER TABLE public.hiregauge_ground_truth ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hgt_agency_isolation ON public.hiregauge_ground_truth;
CREATE POLICY hgt_agency_isolation ON public.hiregauge_ground_truth
  FOR ALL TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

DROP TRIGGER IF EXISTS tg_hgt_updated_at ON public.hiregauge_ground_truth;
CREATE TRIGGER tg_hgt_updated_at
  BEFORE UPDATE ON public.hiregauge_ground_truth
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
