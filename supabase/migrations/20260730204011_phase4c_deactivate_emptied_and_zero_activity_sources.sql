-- Phase 4c: Deactivate all chart_of_accounts rows that are either
-- (a) now emptied by the Phase 4b reclassification, or
-- (b) zero-activity COA-SUB rows carried over from prior structure.

-- Safety check first: every COA-SUB row should have zero journal_lines.
DO $$
DECLARE
  v_bad integer;
BEGIN
  SELECT COUNT(*) INTO v_bad
  FROM public.chart_of_accounts coa
  WHERE coa.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND (coa.account_code LIKE 'COA-SUB-%'
         OR coa.account_code IN ('COA-PN-001','COA-PN-002','6311','6315'))
    AND EXISTS (
      SELECT 1 FROM public.journal_lines jl WHERE jl.account_id = coa.id
    );
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'Refusing to deactivate — % source rows still have journal_lines', v_bad;
  END IF;
END $$;

-- Deactivate every COA-SUB-###, both PN legacy rows, and PSS SaaS legacy rows.
UPDATE public.chart_of_accounts
SET is_active = false
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = true
  AND (account_code LIKE 'COA-SUB-%'
       OR account_code IN ('COA-PN-001','COA-PN-002','6311','6315'));
