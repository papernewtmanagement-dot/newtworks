INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  timezone, internal_handler, output_table, is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365', 'Statement reconciliation check',
  'Compares each bank and credit card statement closing balance to the ledger balance as of that close date; alerts on gaps.',
  'cron', '0 7 * * 0', 'America/Chicago', 'fn_check_statement_reconciliation', 'alerts', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes WHERE recipe_name = 'Statement reconciliation check'
);
