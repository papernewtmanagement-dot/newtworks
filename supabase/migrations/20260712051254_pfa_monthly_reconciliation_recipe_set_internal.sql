-- The PFA Monthly Reconciliation recipe was born with composio_action=NULL, so
-- automation-runner v42 skips the INTERNAL branch and falls through to the
-- Composio branch, which errors out with "no composio_connection set."
-- Its sibling (PFA Monthly Nag) has composio_action='INTERNAL' and runs fine.
-- Set it to match. Handler is 'pfa_monthly_reconciliation' (no dispatch_ prefix)
-- so runner will call run_internal_recipe RPC — pure-SQL synchronous path.
UPDATE public.automation_recipes
   SET composio_action = 'INTERNAL',
       updated_at = NOW()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND recipe_name = 'PFA Monthly Reconciliation'
   AND internal_handler = 'pfa_monthly_reconciliation';

-- Also resolve the stacked-up failure alert so the alerts panel is clean.
UPDATE public.alerts
   SET is_resolved = true,
       resolved_at = NOW()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND title = 'Recipe failed: PFA Monthly Reconciliation'
   AND COALESCE(is_resolved, false) = false;
