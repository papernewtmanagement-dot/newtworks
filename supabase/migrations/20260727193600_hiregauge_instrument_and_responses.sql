-- Two-table structure for reverse-engineering CTS scoring
-- 1) hiregauge_instrument_items = the instrument definition (agency-agnostic reference)
-- 2) hiregauge_candidate_responses = per-candidate raw answers, links back to hiring_candidates

CREATE TABLE IF NOT EXISTS public.hiregauge_instrument_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  section text NOT NULL CHECK (section IN ('instructions','vct','cognitive','cts')),
  item_number int NOT NULL,
  item_text text NOT NULL,
  choices jsonb,
  answer_key text,
  is_nonsense boolean NOT NULL DEFAULT false,
  retest_of_item_number int,
  hypothesized_trait text,
  reverse_coded boolean,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (section, item_number)
);

CREATE TABLE IF NOT EXISTS public.hiregauge_candidate_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  candidate_id uuid NOT NULL REFERENCES public.hiring_candidates(id) ON DELETE CASCADE,
  item_id uuid NOT NULL REFERENCES public.hiregauge_instrument_items(id) ON DELETE CASCADE,
  response_value numeric,
  response_label text,
  is_correct boolean,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (candidate_id, item_id)
);

CREATE INDEX IF NOT EXISTS idx_hg_responses_candidate ON public.hiregauge_candidate_responses(candidate_id);
CREATE INDEX IF NOT EXISTS idx_hg_responses_item ON public.hiregauge_candidate_responses(item_id);
CREATE INDEX IF NOT EXISTS idx_hg_items_section_num ON public.hiregauge_instrument_items(section, item_number);

ALTER TABLE public.hiregauge_instrument_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hiregauge_candidate_responses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS items_read ON public.hiregauge_instrument_items;
CREATE POLICY items_read ON public.hiregauge_instrument_items FOR SELECT USING (true);

DROP POLICY IF EXISTS items_write ON public.hiregauge_instrument_items;
CREATE POLICY items_write ON public.hiregauge_instrument_items FOR ALL USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS responses_agency ON public.hiregauge_candidate_responses;
CREATE POLICY responses_agency ON public.hiregauge_candidate_responses FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

COMMENT ON TABLE public.hiregauge_instrument_items IS 'Question catalog for the CTS-format assessment instrument. Agency-agnostic reference data. hypothesized_trait + reverse_coded columns hold reasoning about item->trait mapping (to be populated as reverse-engineering progresses).';
COMMENT ON TABLE public.hiregauge_candidate_responses IS 'Per-candidate raw answers to instrument items. FK to hiring_candidates (scored output). Pair of tables enables reverse-engineering scoring formulas from labeled input->output data.';
