-- Correction: the entire Financials module is PaperNewt LLC (S-Corp parent).
-- All new entity-scoped rows should default to PaperNewt (b1111111), not PSSF.
-- This replaces the earlier default which stamped b2222222.

CREATE OR REPLACE FUNCTION public.tg_default_business_entity_from_agency()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.business_entity_id IS NULL
     AND NEW.agency_id = '126794dd-25ff-47d2-a436-724499733365' THEN
    NEW.business_entity_id := 'b1111111-1111-1111-1111-111111111111';
  END IF;
  RETURN NEW;
END;
$$;

-- Payroll-specific override trigger is now redundant (default IS PaperNewt).
-- Drop it to keep the schema clean.
DROP TRIGGER IF EXISTS trg_default_business_entity_id_zpapernewt ON public.payroll_runs;
DROP TRIGGER IF EXISTS trg_default_business_entity_id_zpapernewt ON public.payroll_detail;
DROP FUNCTION IF EXISTS public.tg_default_payroll_to_papernewt();;