INSERT INTO automation_recipes
 (agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, output_table, input_config, is_active)
VALUES (
 '126794dd-25ff-47d2-a436-724499733365',
 'Monthly Close Checklist Generator',
 'On the 1st of each month at 9:00 AM CDT, generates the prior month''s close checklist in monthly_close_checklist from the account template in input_config. Idempotent: skips a (period_year, period_month) that already has rows. Drives the existing Monthly Close Monitor, which then tracks completion and fires overdue alerts. Account template reflects ACTIVE accounts verified 2026-05-22: US Bank Income/Expenses, SF Cards (Peter/Alvi), comp recaps, deductions, Heartland payroll, producer production report. Loans excluded (all zero balance 4/30/26). Personal cards excluded from monthly close (year-end CPA review instead).',
 'cron', '0 14 1 * *',
 'INTERNAL','monthly_close_generator','monthly_close_checklist',
 '{
   "generate_for": "previous_month",
   "skip_if_exists": true,
   "items": [
     {"doc_category":"comp_recap_daily","doc_label":"SF Daily Comp Recaps — full month","expected_offset_days":3},
     {"doc_category":"payroll","doc_label":"Payroll Reports — Heartland (all runs)","expected_offset_days":3},
     {"doc_category":"deduction_statement","doc_label":"SF Deduction Statement","expected_offset_days":5},
     {"doc_category":"production_report","doc_label":"Producer Production Report (new premium Auto/Fire/Health by producer)","expected_offset_days":5},
     {"doc_category":"bank_statement","doc_label":"US Bank — Income/Deposit account statement","expected_offset_days":8,"account_code":"COA-007"},
     {"doc_category":"bank_statement","doc_label":"US Bank — Expenses account statement","expected_offset_days":8,"account_code":"COA-006"},
     {"doc_category":"cc_statement","doc_label":"SF Card — Peter — statement","expected_offset_days":10,"account_code":"COA-014"},
     {"doc_category":"cc_statement","doc_label":"SF Card — Alvi — statement","expected_offset_days":10,"account_code":"COA-013"},
     {"doc_category":"reconciliation","doc_label":"Reconcile COMP_RECAP to GL before closing","expected_offset_days":10},
     {"doc_category":"review","doc_label":"Review imported transactions — flag uncategorized / suspense items","expected_offset_days":10}
   ]
 }'::jsonb,
 true
);
