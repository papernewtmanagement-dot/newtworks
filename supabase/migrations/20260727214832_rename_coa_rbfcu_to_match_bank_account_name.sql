-- v_bank_balances joins bank_accounts → chart_of_accounts on account_name exact match.
-- Bank account row is "RBFCU Savings" (Peter's naming); COA row I created during pf4o
-- opening-balance setup was "RBFCU Primary Savings". Aligning COA to bank_accounts.
UPDATE public.chart_of_accounts
SET account_name = 'RBFCU Savings'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code = 'COA-PERSONAL-6596';
