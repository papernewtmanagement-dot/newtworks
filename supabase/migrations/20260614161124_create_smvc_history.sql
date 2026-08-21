CREATE TABLE IF NOT EXISTS public.smvc_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  as_of_date date NOT NULL,
  this_period_smvc numeric(6,4) NOT NULL,
  last_period_smvc numeric(6,4),
  base_rate numeric(6,4) NOT NULL DEFAULT 0.08,
  effective_rate numeric(6,4) GENERATED ALWAYS AS (base_rate + this_period_smvc) STORED,
  delta_smvc numeric(6,4) GENERATED ALWAYS AS (this_period_smvc - last_period_smvc) STORED,
  dollar_impact numeric(12,2),
  source text NOT NULL DEFAULT 'cpr_weekly',
  notes text,
  created_at timestamptz DEFAULT NOW(),
  UNIQUE (agency_id, as_of_date)
);

COMMENT ON TABLE public.smvc_history IS 'Weekly snapshot of P&C SMVC rate. Tracks this-period vs last-period trajectory and the dollar impact of the delta on book renewals.';
COMMENT ON COLUMN public.smvc_history.this_period_smvc IS 'Current SMVC rate, e.g. 0.0241 for 2.41%';
COMMENT ON COLUMN public.smvc_history.dollar_impact IS 'Annualized $ impact of the delta from last period; positive = gain, negative = loss';

CREATE INDEX IF NOT EXISTS smvc_history_agency_date_idx 
  ON public.smvc_history (agency_id, as_of_date DESC);

ALTER TABLE public.smvc_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY smvc_history_anon_read ON public.smvc_history 
  FOR SELECT TO anon USING (true);
CREATE POLICY smvc_history_auth_all ON public.smvc_history 
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT ON public.smvc_history TO anon;
GRANT ALL ON public.smvc_history TO authenticated;
