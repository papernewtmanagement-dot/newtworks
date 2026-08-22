-- Split personal suspense into income-side + expense-side so P&L shows GROSS not NET.
-- 9999 stays as the expense-side (outflows awaiting classification).
-- 8999 new: income-side (inflows awaiting classification — payroll, interest, refunds, etc.).

INSERT INTO public.chart_of_accounts
  (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365',
   'b3333333-3333-3333-3333-333333333333',
   'PERSONAL-8999',
   'Personal Suspense — Inflows',
   'income',
   'suspense',
   'active',
   true,
   true)
ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

-- Also rename the existing 9999 for clarity
UPDATE public.chart_of_accounts
   SET account_name = 'Personal Suspense — Outflows'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND chart_namespace = 'active'
   AND account_code = 'PERSONAL-9999';

-- Move CR-side (inflow) lines from 9999 to 8999 on pf4 backfill JEs.
-- These are lines where a money-IN txn put the "other side" as CR on 9999.
UPDATE public.journal_lines jl
   SET account_id = (SELECT id FROM public.chart_of_accounts
                     WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                       AND chart_namespace = 'active'
                       AND account_code = 'PERSONAL-8999')
 WHERE jl.journal_entry_id IN (
   SELECT id FROM public.journal_entries
    WHERE source = 'pf4_personal_backfill'
      AND classification_status = 'pending_review'
 )
   AND jl.account_id = (SELECT id FROM public.chart_of_accounts
                        WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                          AND chart_namespace = 'active'
                          AND account_code = 'PERSONAL-9999')
   AND jl.credit > 0;
