-- Point-in-time copies of hiring_candidates.resume_analysis, taken before a
-- parser backfill rewrites roles[] so the write is reversible. First use:
-- the v4_2026_08_26 resume tenure parser backfill (417 candidates).
CREATE TABLE IF NOT EXISTS public.resume_analysis_snapshots (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id     uuid NOT NULL,
  candidate_id  uuid NOT NULL REFERENCES public.hiring_candidates(id) ON DELETE CASCADE,
  label         text NOT NULL,
  taken_at      timestamptz NOT NULL DEFAULT now(),
  resume_analysis jsonb
);
CREATE INDEX IF NOT EXISTS resume_analysis_snapshots_candidate_idx ON public.resume_analysis_snapshots (candidate_id, taken_at DESC);
CREATE INDEX IF NOT EXISTS resume_analysis_snapshots_label_idx ON public.resume_analysis_snapshots (agency_id, label);
ALTER TABLE public.resume_analysis_snapshots ENABLE ROW LEVEL SECURITY;

INSERT INTO public.resume_analysis_snapshots (agency_id, candidate_id, label, resume_analysis)
SELECT agency_id, id, 'pre_tenure_parser_v4_2026_08_26', resume_analysis
FROM public.hiring_candidates
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND resume_extracted_text IS NOT NULL;
