-- Distinguish paid lead sources from opportunity-type close-ratio rows
ALTER TABLE public.lead_source_quarterly
  ADD COLUMN IF NOT EXISTS source_type text DEFAULT 'lead_source';

ALTER TABLE public.lead_source_quarterly
  ADD CONSTRAINT lsq_source_type_chk 
    CHECK (source_type IN ('lead_source','opportunity_type'));

-- Marketing cost + close ratio fields. We do NOT store "best" columns;
-- best-ever and prior-period comparisons are computed from history when needed.
ALTER TABLE public.lead_source_quarterly
  ADD COLUMN IF NOT EXISTS total_hhs int,
  ADD COLUMN IF NOT EXISTS cost_total numeric(12,2),
  ADD COLUMN IF NOT EXISTS close_ratio numeric(6,4);

COMMENT ON COLUMN public.lead_source_quarterly.source_type IS 
  'lead_source = paid/organic lead provider (Referral, SF.com, EverQuote, etc). opportunity_type = quote channel (Curr Cust, Digital, Office, Winback, St-St) for close-ratio tracking';
COMMENT ON COLUMN public.lead_source_quarterly.total_hhs IS 
  'Total HHs contacted/engaged from this source this quarter (lead_source rows)';
COMMENT ON COLUMN public.lead_source_quarterly.cost_total IS 
  'Dollar cost paid for leads from this source this quarter (lead_source rows)';
COMMENT ON COLUMN public.lead_source_quarterly.close_ratio IS 
  'Quote-to-bind ratio for this opportunity type this quarter (opportunity_type rows). Decimal: 0.3571 = 35.71%';
