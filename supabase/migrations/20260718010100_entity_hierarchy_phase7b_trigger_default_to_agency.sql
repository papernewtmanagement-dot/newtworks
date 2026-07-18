-- Phase 7b: flip default entity trigger so NEW activity starts as agency data
-- per Peter directive 2026-07-17. Table-specific default preserves the
-- two-entity payroll convention:
--   payroll_runs + payroll_detail → PaperNewt (S-Corp employer of record)
--   everything else               → Peter Story State Farm (agency)
--
-- Function name kept as tg_default_business_entity_from_agency so the 15
-- existing triggers on tables (BEFORE INSERT) continue to fire without
-- re-installation.

CREATE OR REPLACE FUNCTION public.tg_default_business_entity_from_agency()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.business_entity_id IS NULL
     AND NEW.agency_id = '126794dd-25ff-47d2-a436-724499733365' THEN
    -- Payroll tables stay PaperNewt (two-entity payroll convention: PaperNewt
    -- is the S-Corp employer of record; payroll routes there structurally).
    -- Everything else routes to Peter Story State Farm — the operating
    -- agency, where day-to-day activity actually happens.
    IF TG_TABLE_NAME IN ('payroll_runs', 'payroll_detail') THEN
      NEW.business_entity_id := 'b1111111-1111-1111-1111-111111111111'; -- PaperNewt
    ELSE
      NEW.business_entity_id := 'b2222222-2222-2222-2222-222222222222'; -- Peter Story State Farm
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.tg_default_business_entity_from_agency() IS
'BEFORE INSERT trigger fallback for entity attribution. Fires on any row with NULL business_entity_id. Table-specific default: payroll_runs/payroll_detail → PaperNewt (S-Corp employer of record per two-entity payroll convention), everything else → Peter Story State Farm (agency, per Peter directive 2026-07-17). Explicit business_entity_id at INSERT time bypasses the trigger — writers with source-aware routing should set entity_id directly.';
