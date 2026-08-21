-- Phase 2a: Database-side safety net so existing code keeps working.
-- BEFORE INSERT trigger: if business_entity_id is NULL but agency_id is set, auto-populate from agency mapping.
-- Rule: agency_id = PSF agency UUID → business_entity_id = PSF entity UUID.
-- PaperNewt-only writes must NULL out agency_id and set business_entity_id explicitly.

CREATE OR REPLACE FUNCTION public.tg_default_business_entity_from_agency()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.business_entity_id IS NULL AND NEW.agency_id IS NOT NULL THEN
    IF NEW.agency_id = '126794dd-25ff-47d2-a436-724499733365' THEN
      NEW.business_entity_id := 'b2222222-2222-2222-2222-222222222222';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.tg_default_business_entity_from_agency() IS
'Phase 2 dual-write safety net. Auto-populates business_entity_id on INSERT when only agency_id was provided. Maps PSF agency UUID → PSF entity UUID. Drop once all frontend/functions write business_entity_id directly.';

-- Attach to all 15 entity-aware tables
DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.journal_entries;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.journal_entries
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.journal_lines;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.journal_lines
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.chart_of_accounts;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.chart_of_accounts
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.account_starting_balances;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.account_starting_balances
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.opening_balances;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.opening_balances
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.envelope_budget_targets;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.envelope_budget_targets
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_accounts;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.bank_accounts
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_account_map;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.bank_account_map
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_transactions;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.bank_transactions
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_register_preliminary;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.bank_register_preliminary
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.bank_register_weekly_snapshot;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.bank_register_weekly_snapshot
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.credit_accounts;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.credit_accounts
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.credit_transactions;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.credit_transactions
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.payroll_runs;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.payroll_runs
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();

DROP TRIGGER IF EXISTS trg_default_business_entity_id ON public.payroll_detail;
CREATE TRIGGER trg_default_business_entity_id BEFORE INSERT ON public.payroll_detail
  FOR EACH ROW EXECUTE FUNCTION public.tg_default_business_entity_from_agency();
