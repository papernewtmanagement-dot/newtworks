UPDATE public.automation_recipes
SET is_active = false
WHERE recipe_name = 'Statement reconciliation check'
  AND internal_handler = 'fn_check_statement_reconciliation';
