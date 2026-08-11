-- Card 2113, equal-and-opposite adjacent-month straddle (packet-anticipated case).
-- Two STATE FARM INSURANCE charges ($189.85, $229.83), printed trans date 06/16, posted
-- 06/17 on the July statement (usb-07: "06/17 06/16 5687 ... $189.85", "06/17 06/16 3598
-- ... $229.83"). NOT printed on June's own statement at all. Currently held dated
-- 2026-06-16 (P6's own close day) -> phantom excess in P6, exact mirror shortfall in P7.
-- Both payment/credit sides already match printed exactly in both months; this move is
-- the entire fix. Pre-verified: P6 419.68->0.00, P7 -419.68->0.00.
UPDATE public.statements
SET transaction_date = DATE '2026-06-17',
    notes = trim(coalesce(notes,'') || ' Moved 2026-08-11 from printed trans date 2026-06-16: July statement (usb-07) prints this with posting date 06/17, the July cycle open date, and June''s own statement does not print it at all. Straddle policy per migration 20260809072327; printed trans date preserved here.')
WHERE id IN ('e79e0418-c031-4187-9ff3-357b5890b262', '38d8be72-0fe3-4967-8a76-cf8638d4bbd4')
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

UPDATE public.ledger l
SET entry_date = s.transaction_date
FROM public.statements s
WHERE l.statement_id = s.id
  AND s.id IN ('e79e0418-c031-4187-9ff3-357b5890b262', '38d8be72-0fe3-4967-8a76-cf8638d4bbd4');
