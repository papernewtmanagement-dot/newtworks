-- Card 2172 (Capital One Personal 7435), three-month combined straddle fix.
-- Grunt packet rev4, THE ONE LAW: pre-verified all three touched months zero exactly.
--
-- 1. Three AMAZON MKTPL charges, printed trans date Jan 28, posted Jan 29 on the Feb
--    statement (co-02: "Jan 28 Jan 29 ... $23.76", "$70.48", "$20.56"). Currently held
--    dated 2026-01-28 (Jan's own close day) -> phantom excess in Jan. Belong to Feb per
--    the bank's own posting date.
UPDATE public.statements
SET transaction_date = DATE '2026-01-29',
    notes = trim(coalesce(notes,'') || ' Moved 2026-08-11 from printed trans date 2026-01-28: Feb statement prints these with posting date 01/29, the Feb cycle open date. Straddle policy per migration 20260809072327; printed trans date preserved here.')
WHERE account_id = '0ed39c01-7280-446f-ab3b-a6e11e5e8cca'
  AND transaction_date = '2026-01-28'
  AND amount IN (23.76, 70.48, 20.56)
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2. AMAZON MKTPL*1I4L01363 $25.32, printed trans date Feb 25, posted Feb 26 on the March
--    statement (co-03: "Feb 25 Feb 26 ... $25.32"). Currently held dated 2026-02-25 (Feb's
--    own close day) -> phantom excess in Feb. Belongs to March per the bank's posting date.
UPDATE public.statements
SET transaction_date = DATE '2026-02-26',
    notes = trim(coalesce(notes,'') || ' Moved 2026-08-11 from printed trans date 2026-02-25: March statement prints this with posting date 02/26, the March cycle open date. Straddle policy per migration 20260809072327; printed trans date preserved here.')
WHERE account_id = '0ed39c01-7280-446f-ab3b-a6e11e5e8cca'
  AND transaction_date = '2026-02-25'
  AND amount = 25.32
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. Keep ledger entry dates in step with the moved statement rows.
UPDATE public.ledger l
SET entry_date = s.transaction_date
FROM public.statements s
WHERE l.statement_id = s.id
  AND s.account_id = '0ed39c01-7280-446f-ab3b-a6e11e5e8cca'
  AND s.transaction_date IN ('2026-01-29','2026-02-26')
  AND s.amount IN (23.76, 70.48, 20.56, 25.32);
