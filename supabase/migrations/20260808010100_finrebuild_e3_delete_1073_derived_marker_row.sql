-- finrebuild_e3_delete_1073_derived_marker_row
-- D17: statement_balances row id dfd0c41c-3459-45c9-ae24-02d4d66c264a
-- (account_code 1073, source 'derived_from_real_statement_chain') has no
-- period start and no opening balance and is not a real statement — it
-- duplicated the real 6/24 close (closing_balance 30552.13, identical to
-- the real row f763eef7...->51039186 chain's 6/24 close). The other seven
-- 1073 rows (source us_bank_tithe_tax_zip_20260727) are real and stay.
DELETE FROM public.statement_balances
WHERE id = 'dfd0c41c-3459-45c9-ae24-02d4d66c264a';
