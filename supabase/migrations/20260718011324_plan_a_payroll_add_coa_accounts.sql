-- Plan A payroll: 5 new chart_of_accounts rows
-- 3 agency-side (b2222222): growth budget, team budget, reimbursements-pending
-- 2 PaperNewt-side (b1111111): payroll expense, payroll cash placeholder
-- All in chart_namespace='historical' to match current payroll_gl_writer expectations.

INSERT INTO public.chart_of_accounts
  (agency_id, account_code, account_name, account_type, account_subtype,
   parent_account_id, chart_namespace, business_entity_id, is_active, is_system)
VALUES
  -- Agency-side: nest under COA-020 "0002 TEAM" (same parent as Payroll Costs)
  ('126794dd-25ff-47d2-a436-724499733365', 'COA-SUB-086',
   'Payroll — Growth Budget', 'expense', NULL,
   'f8e41f72-c02f-4ce3-ae45-1e85cc7ccadc'::uuid, 'historical',
   'b2222222-2222-2222-2222-222222222222'::uuid, true, false),

  ('126794dd-25ff-47d2-a436-724499733365', 'COA-SUB-087',
   'Payroll — Team Budget', 'expense', NULL,
   'f8e41f72-c02f-4ce3-ae45-1e85cc7ccadc'::uuid, 'historical',
   'b2222222-2222-2222-2222-222222222222'::uuid, true, false),

  -- Agency-side: reimbursements-pending, top-level (not under Team)
  ('126794dd-25ff-47d2-a436-724499733365', 'COA-SUB-088',
   'Reimbursements — pending categorization', 'expense', NULL,
   NULL, 'historical',
   'b2222222-2222-2222-2222-222222222222'::uuid, true, false),

  -- PaperNewt-side: payroll expense (Peter + Leslie land here)
  ('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-001',
   'Payroll Expense (PaperNewt)', 'expense', NULL,
   NULL, 'historical',
   'b1111111-1111-1111-1111-111111111111'::uuid, true, false),

  -- PaperNewt-side: cash source placeholder (Peter maps to actual bank later)
  ('126794dd-25ff-47d2-a436-724499733365', 'COA-PN-002',
   'Payroll Cash — unmapped (PaperNewt)', 'asset', NULL,
   NULL, 'historical',
   'b1111111-1111-1111-1111-111111111111'::uuid, true, false);
