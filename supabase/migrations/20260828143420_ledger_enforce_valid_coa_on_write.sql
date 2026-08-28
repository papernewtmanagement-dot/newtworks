-- The ledger already had a foreign key on account_id, but the column allowed
-- NULL and nothing checked that the account it pointed at was usable. A row
-- could therefore land with no account at all, or on a retired account, or on
-- an account belonging to a different agency, or on one with no account_type
-- -- and any of those drop off the P&L silently.
--
-- Currently 0 rows violate any of this, so both changes apply clean.

ALTER TABLE public.ledger ALTER COLUMN account_id SET NOT NULL;

CREATE OR REPLACE FUNCTION public.tg_ledger_require_valid_coa()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_active   boolean;
  v_type     text;
  v_agency   uuid;
  v_code     text;
BEGIN
  SELECT coa.is_active, coa.account_type, coa.agency_id, coa.account_code
    INTO v_active, v_type, v_agency, v_code
  FROM public.chart_of_accounts coa
  WHERE coa.id = NEW.account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'ledger.account_id % does not exist in chart_of_accounts', NEW.account_id
      USING ERRCODE = '23514';
  END IF;

  IF v_active IS NOT TRUE THEN
    RAISE EXCEPTION
      'ledger cannot post to retired account % -- reactivate it or pick a live account', v_code
      USING ERRCODE = '23514';
  END IF;

  IF v_type IS NULL OR btrim(v_type) = '' THEN
    RAISE EXCEPTION
      'ledger cannot post to account % because it has no account_type, so it would not appear on the P&L', v_code
      USING ERRCODE = '23514';
  END IF;

  IF v_type NOT IN ('asset','liability','equity','income','expense') THEN
    RAISE EXCEPTION
      'ledger cannot post to account %: account_type "%" is not one of asset, liability, equity, income, expense', v_code, v_type
      USING ERRCODE = '23514';
  END IF;

  IF NEW.agency_id IS NOT NULL AND v_agency IS DISTINCT FROM NEW.agency_id THEN
    RAISE EXCEPTION
      'ledger row for agency % cannot post to account %, which belongs to a different agency', NEW.agency_id, v_code
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_ledger_require_valid_coa ON public.ledger;
CREATE TRIGGER trg_ledger_require_valid_coa
  BEFORE INSERT OR UPDATE OF account_id, agency_id ON public.ledger
  FOR EACH ROW EXECUTE FUNCTION public.tg_ledger_require_valid_coa();
