-- Card 2113 (US Bank Business Cash Rewards 3447), three-month combined straddle fix.
-- Grunt packet rev4, THE ONE LAW: pre-verified all three touched months zero exactly.
--
-- 1. STATE FARM INSURANCE $93.99, printed trans date 03/18, posted 03/19 on the April
--    statement (usb-04, line "03/19 03/18 3591 STATE FARM INSURANCE ... $93.99").
--    Currently held dated 2026-03-18 (P3's own close day) -> phantom excess in P3.
--    Belongs to P4 per the bank's own posting date. Moves P3 328.45->0 contribution: -93.99.
UPDATE public.statements
SET transaction_date = DATE '2026-03-19',
    notes = trim(coalesce(notes,'') || ' Moved 2026-08-11 from printed trans date 2026-03-18: April statement (usb-04) prints this with posting date 03/19, the April cycle open date. Straddle policy per migration 20260809072327; printed trans date preserved here.')
WHERE id = '1ffb8728-aba3-498d-a2c5-d46e82843b45'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 2. STATE FARM INSURANCE $189.85 and $232.59, printed trans date 04/16, posted 04/17 on
--    the May statement (usb-05, lines "04/17 04/16 8880 ... $189.85" and "04/17 04/16 6301
--    ... $232.59"). Currently held dated 2026-04-16 (P4's own close day) -> phantom excess
--    in P4. Belong to P5 per the bank's own posting date.
UPDATE public.statements
SET transaction_date = DATE '2026-04-17',
    notes = trim(coalesce(notes,'') || ' Moved 2026-08-11 from printed trans date 2026-04-16: May statement (usb-05) prints this with posting date 04/17, the May cycle open date. Straddle policy per migration 20260809072327; printed trans date preserved here.')
WHERE id IN ('fcaff77b-3b15-4411-9ab6-ec44b33df5df', 'bb286396-a6a4-42b9-80fd-2a5caaf5d0b4')
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. Keep ledger entry dates in step with the moved statement rows.
UPDATE public.ledger l
SET entry_date = s.transaction_date
FROM public.statements s
WHERE l.statement_id = s.id
  AND s.id IN ('1ffb8728-aba3-498d-a2c5-d46e82843b45','fcaff77b-3b15-4411-9ab6-ec44b33df5df','bb286396-a6a4-42b9-80fd-2a5caaf5d0b4');
