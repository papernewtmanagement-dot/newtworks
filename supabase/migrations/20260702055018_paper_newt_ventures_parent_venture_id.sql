ALTER TABLE public.paper_newt_ventures
  ADD COLUMN IF NOT EXISTS parent_venture_id UUID REFERENCES public.paper_newt_ventures(id);
CREATE INDEX IF NOT EXISTS idx_pnv_parent ON public.paper_newt_ventures(parent_venture_id);