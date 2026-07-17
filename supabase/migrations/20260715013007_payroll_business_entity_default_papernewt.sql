-- Any manual INSERT into payroll_runs/payroll_detail with NULL business_entity_id
-- should default to PaperNewt LLC (employer of record). The existing agency-wide
-- trigger stamps b2222222 (Peter Story State Farm); override it on these two
-- tables specifically with a payroll-scoped trigger that fires later.

CREATE OR REPLACE FUNCTION public.tg_default_payroll_to_papernewt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Only stamp if not set OR set to the agency-wide default (b2222222).
  -- This lets us override the general-purpose trigger for these two tables.
  IF NEW.agency_id = '126794dd-25ff-47d2-a436-724499733365'
     AND (NEW.business_entity_id IS NULL 
          OR NEW.business_entity_id = 'b2222222-2222-2222-2222-222222222222') THEN
    NEW.business_entity_id := 'b1111111-1111-1111-1111-111111111111';
  END IF;
  RETURN NEW;
END;
$$;

-- Fire AFTER the existing default trigger (alphabetical order matters in PG).
-- Existing name: trg_default_business_entity_id. Ours must sort after it.
DROP TRIGGER IF EXISTS trg_default_business_entity_id_zpapernewt ON public.payroll_runs;
CREATE TRIGGER trg_default_business_entity_id_zpapernewt
  BEFORE INSERT ON public.payroll_runs
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_payroll_to_papernewt();

DROP TRIGGER IF EXISTS trg_default_business_entity_id_zpapernewt ON public.payroll_detail;
CREATE TRIGGER trg_default_business_entity_id_zpapernewt
  BEFORE INSERT ON public.payroll_detail
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_payroll_to_papernewt();;