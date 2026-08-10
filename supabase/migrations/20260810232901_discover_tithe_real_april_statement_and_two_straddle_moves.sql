-- Real April 2026 Discover Tithe statement (Discover card ending 3208, account 2171),
-- received from Peter via chat upload 2026-08-10 and read directly.
-- Printed: period 03/28/2026-04/27/2026, previous 3,566.38, payments/credits -3,566.38,
-- purchases +5,571.79, fees 0, interest 0, new balance 5,571.79. Exactly six lines.
--
-- VERIFICATION RESULT: all six printed lines were ALREADY in statements with correct dates,
-- amounts and types (source_document_id da0e7cfd-fa87-4d2c-9505-94b82794d291 — the file named
-- "Discover Tithe CC 26-04.pdf", which is a mid-cycle activity export but carried the April
-- lines correctly). NO transaction was ever missing from this card.
--
-- ROOT CAUSE of the four failing periods (Feb +1000, Mar -1000, Apr +1000, May -1000, where
-- variance = computed close minus printed close): two recurring $1,000 donations are
-- trans-dated one day BEFORE the next cycle opens, so they sit in the earlier period while
-- Discover counts them in the later one. Proof: the real April statement prints six lines and
-- the held 2026-04-27 GIV*CHRIST COMMUNITY CHU $1,000 is not one of them (printed purchases
-- total 5,571.79 = 566.38+1000+1000+1000+2005.41 exactly); the May period is short exactly
-- $1,000 and holds no May-cycle Christ Community donation. Same shape on the Feb/Mar pair:
-- Feb holds TWO Reasonable Faith $1,000 rows (01/29 and 02/27) while Mar holds none.
--
-- POLICY (decided by planning thread 2026-08-10, same as migration 20260809072327 on card
-- 3447): boundary straddles store under the bank's cycle; the printed trans date is preserved
-- in notes. Discover prints trans dates only, so the stored date is the cycle open date.

-- 1. File the real April statement.
INSERT INTO public.documents
  (id, agency_id, file_name, upload_source, processing_status, source_account_code,
   uploaded_at, processed_at, notes, extracted_text)
VALUES
  ('f3a9c7e1-4b2d-4e8a-9f61-2c8d5b0a7e93',
   '126794dd-25ff-47d2-a436-724499733365',
   'Discover Tithe CC 26-04 statement.pdf',
   'chat_upload', 'processed', '2171',
   NOW(), NOW(),
   'Real April 2026 billing statement, received from Peter via chat 2026-08-10. Named distinctly because Discover Tithe CC 26-04.pdf (da0e7cfd) is a mid-cycle activity export, kept as-is. Verification-only: all six printed lines already existed in statements; zero rows added. Drive copy pending — 1.5MB PDF exceeds the inline upload path.',
   'DISCOVER MORE CARD ENDING IN 3208. Period 03/28/2026-04/27/2026. Previous Balance 3,566.38; Payments and Credits -3,566.38; Purchases +5,571.79; Fees 0.00; Interest 0.00; New Balance 5,571.79. Transactions: 04/04 INTERNET PAYMENT - THANK YOU -3,566.38; 03/29 NPO* VAULT FOSTERING C 6159530083 TX 566.38; 03/29 REASONABLE FAITH 4349442618 TX 1,000.00; 04/01 GIV*CHRIST COMMUNITY CHU 210-318-3353 TX 1,000.00; 04/02 PAYPAL *ACTMIN 888-221-1161 CA 1,000.00; 04/09 AMAZON MKTPL*BY2AT2NM2 AMZN.COM/BILLWA 2,005.41.');

-- 2. Reasonable Faith $1,000, printed trans date 02/27 — belongs to the 02/28-03/27 cycle.
UPDATE public.statements
SET transaction_date = DATE '2026-02-28',
    notes = trim(coalesce(notes,'') ||
      ' Moved 2026-08-10 from printed trans date 2026-02-27: Discover counts this donation in the 2026-02-28..2026-03-27 cycle (Feb period ran +1000 and Mar -1000, equal and opposite). Straddle policy per migration 20260809072327; printed date preserved here.')
WHERE id = '36c89d5e-57c5-4652-8cb8-5a579ca2466e'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 3. Christ Community $1,000, printed trans date 04/27 — belongs to the 04/28-05/27 cycle.
UPDATE public.statements
SET transaction_date = DATE '2026-04-28',
    notes = trim(coalesce(notes,'') ||
      ' Moved 2026-08-10 from printed trans date 2026-04-27: the real April statement (documents f3a9c7e1-4b2d-4e8a-9f61-2c8d5b0a7e93) prints exactly six lines and this is not one of them; the May period was short exactly 1000. Straddle policy per migration 20260809072327; printed date preserved here.')
WHERE id = '5017fe73-536e-49f6-9323-68db8a32f7ff'
  AND agency_id = '126794dd-25ff-47d2-a436-724499733365';

-- 4. Keep the ledger's dates in step with canon for the two moved rows.
UPDATE public.ledger l
SET entry_date = s.transaction_date
FROM public.statements s
WHERE l.statement_id = s.id
  AND s.id IN ('36c89d5e-57c5-4652-8cb8-5a579ca2466e',
               '5017fe73-536e-49f6-9323-68db8a32f7ff');
