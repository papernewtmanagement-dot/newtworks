-- Fixed FK: correct credit_account UUID is 50ba6422-c1a6-4e2b-bd5e-5c757fa86332

INSERT INTO public.credit_transactions
  (agency_id, credit_account_id, business_entity_id, transaction_date, description, amount,
   transaction_type, journal_entry_id, category, notes, posted_at)
SELECT
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  '50ba6422-c1a6-4e2b-bd5e-5c757fa86332'::uuid,
  (SELECT id FROM public.business_entities
    WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND name = 'Peter Story'),
  d.transaction_date, d.description, d.amount, d.transaction_type,
  NULL, 'PENDING_CLASSIFICATION', d.notes, NOW()
FROM (VALUES
  (DATE '2026-02-26', 'CREDIT ADJUSTMENT',    -493.01::numeric, 'credit',
   'Source unknown — likely rewards redemption, promo, or dispute credit. Needs classification.'),
  (DATE '2026-06-19', 'Credit Balance Refund', 493.01::numeric, 'charge',
   'AMEX refunded credit balance to Peter. Bank account of deposit unknown — needs classification.')
) AS d(transaction_date, description, amount, transaction_type, notes);
