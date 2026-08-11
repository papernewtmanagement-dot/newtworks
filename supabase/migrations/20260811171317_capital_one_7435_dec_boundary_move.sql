-- Two more boundary items for card 2172: printed trans dates Dec 27/28 2025, posted
-- Dec 29 (Jan's cycle open day) per co-01.txt. Currently held at trans date, outside
-- Jan's period range (12/29-01/28) entirely -> contributed to nothing. Pre-verified:
-- moving both into Jan's range brings Jan to exact zero (-44.62 -> 0.00).
UPDATE public.statements
SET transaction_date = DATE '2025-12-29',
    notes = trim(coalesce(notes,'') || ' Moved 2026-08-11 from printed trans date: Jan statement (co-01) prints this with posting date 12/29, the Jan cycle open date. Straddle policy per migration 20260809072327; printed trans date preserved here.')
WHERE id IN ('ff75b958-6e8e-41cf-ae48-b44087e47fac','9f0caae7-1080-4e0e-bbd6-c2ba904a60cb')
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.ledger l
SET entry_date = s.transaction_date
FROM public.statements s
WHERE l.statement_id = s.id
  AND s.id IN ('ff75b958-6e8e-41cf-ae48-b44087e47fac','9f0caae7-1080-4e0e-bbd6-c2ba904a60cb');
