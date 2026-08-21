-- Link credit_accounts to chart_of_accounts so the writer knows where to post the card side
ALTER TABLE credit_accounts ADD COLUMN IF NOT EXISTS chart_account_id uuid REFERENCES chart_of_accounts(id);

-- Seed from the existing legacy source credit card chart entries
INSERT INTO credit_accounts (agency_id, account_name, institution, account_type, is_active, chart_account_id)
SELECT 
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  coa.account_name,
  CASE 
    WHEN coa.account_name ILIKE '%AMEX%' THEN 'American Express'
    WHEN coa.account_name ILIKE '%Capital One%' THEN 'Capital One'
    WHEN coa.account_name ILIKE '%Chase%' THEN 'Chase'
    WHEN coa.account_name ILIKE '%SF Card%' THEN 'State Farm Federal Credit Union'
    WHEN coa.account_name ILIKE '%USBank%' OR coa.account_name ILIKE '%US Bank%' THEN 'US Bank'
    WHEN coa.account_name ILIKE '%Spark%' THEN 'Capital One Spark'
    WHEN coa.account_name ILIKE '%CITI%' THEN 'Citi'
    ELSE 'Unknown'
  END,
  'credit_card',
  TRUE,
  coa.id
FROM chart_of_accounts coa
WHERE coa.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  AND coa.chart_namespace = 'books_historical'
  AND coa.account_code IN ('COA-009','COA-010','COA-011','COA-012','COA-013','COA-014','COA-025','COA-026','COA-028')
  AND NOT EXISTS (
    SELECT 1 FROM credit_accounts ca 
    WHERE ca.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND ca.chart_account_id = coa.id
  );

SELECT account_name, institution, chart_account_id FROM credit_accounts 
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' ORDER BY account_name;
