-- The 2026-05-27 to 2026-06-24 period on account 1011 (U.S. Bank 4335) reported a $5,309.90
-- reconciliation variance, recorded in the 2026-08-08 handoff as unaccounted movement. It is
-- not a missing transaction. All twelve rows for the period are present and match the statement
-- exactly; the period's own arithmetic ties (131,155.26 + 19,575.92 - 75,691.96 = 75,039.22).
--
-- The cause is one mislabelled field. The May 27 transfer of $2,654.95 out to account
-- 212004766755 is stored with the correct negative amount but transaction_type 'deposit'.
-- v_statement_reconciliation derives direction from transaction_type rather than from the sign
-- of the amount, so it added the money instead of subtracting it - a swing of exactly
-- 2 x 2,654.95 = 5,309.90, which is the reported variance to the penny.
--
-- The statement prints this line under "Other Withdrawals", so 'withdrawal' is correct.
--
-- A full sweep of statements for sign/type disagreement found this as the ONLY genuine case.
-- The 1,086 positive 'charge' and 18 negative 'credit' rows on card accounts are NOT errors:
-- card statements use the opposite convention, where a charge increases the balance owed.
-- Do not "fix" those.

UPDATE public.statements
SET transaction_type = 'withdrawal'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_id = '4dc792cf-c087-47f9-b9ea-cbf1c43421f6'
  AND transaction_date = DATE '2026-05-27'
  AND amount = -2654.95
  AND transaction_type = 'deposit';
