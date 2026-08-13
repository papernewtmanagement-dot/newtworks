-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-08 01:28:07 UTC (ledger name: payroll_dst_sync_label_map_open_questions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260708012807.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- ==========================================================================
-- 4. DST-safe cron sync: helper that shifts payroll/PFA crons based on CT DST state.
--    Scheduled daily so it self-corrects on the DST transition days automatically.
-- ==========================================================================
CREATE OR REPLACE FUNCTION public.apply_ct_cron_dst_sync()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $$
DECLARE
  v_is_cdt      boolean;
  v_hour_2am_ct int;
  v_hour_7am_ct int;
  v_changes     int := 0;
  v_expected_ingest text;
  v_expected_weekly text;
  v_expected_pfa    text;
  v_current_ingest  text;
  v_current_weekly  text;
  v_current_pfa     text;
BEGIN
  -- Compute current CT offset. During CDT (summer) America/Chicago is UTC-5; during CST it's UTC-6.
  v_is_cdt := (
    EXTRACT(TIMEZONE FROM (now() AT TIME ZONE 'America/Chicago'))
    = -5 * 3600
  );

  v_hour_2am_ct := CASE WHEN v_is_cdt THEN 7  ELSE 8  END;
  v_hour_7am_ct := CASE WHEN v_is_cdt THEN 12 ELSE 13 END;

  v_expected_ingest := format('0 %s * * *',       v_hour_2am_ct);
  v_expected_weekly := format('0 %s * * 0,1,2,3', v_hour_7am_ct);
  v_expected_pfa    := format('0 %s * * *',       v_hour_7am_ct);

  SELECT cron_expression INTO v_current_ingest FROM automation_recipes WHERE internal_handler='dispatch_payroll_email_parser' LIMIT 1;
  SELECT cron_expression INTO v_current_weekly FROM automation_recipes WHERE internal_handler='payroll_weekly_nag'           LIMIT 1;
  SELECT cron_expression INTO v_current_pfa    FROM automation_recipes WHERE internal_handler='pfa_monthly_nag'              LIMIT 1;

  IF v_current_ingest IS DISTINCT FROM v_expected_ingest THEN
    UPDATE automation_recipes SET cron_expression = v_expected_ingest, updated_at = now()
     WHERE internal_handler='dispatch_payroll_email_parser';
    v_changes := v_changes + 1;
  END IF;
  IF v_current_weekly IS DISTINCT FROM v_expected_weekly THEN
    UPDATE automation_recipes SET cron_expression = v_expected_weekly, updated_at = now()
     WHERE internal_handler='payroll_weekly_nag';
    v_changes := v_changes + 1;
  END IF;
  IF v_current_pfa IS DISTINCT FROM v_expected_pfa THEN
    UPDATE automation_recipes SET cron_expression = v_expected_pfa, updated_at = now()
     WHERE internal_handler='pfa_monthly_nag';
    v_changes := v_changes + 1;
  END IF;

  RETURN jsonb_build_object(
    'is_cdt', v_is_cdt,
    'expected_ingest', v_expected_ingest,
    'expected_weekly', v_expected_weekly,
    'expected_pfa', v_expected_pfa,
    'changes_applied', v_changes,
    'output_summary', format('DST sync ran (%s CT). %s recipe cron_expression change(s).', CASE WHEN v_is_cdt THEN 'CDT' ELSE 'CST' END, v_changes),
    'records_processed', v_changes
  );
END;
$$;

COMMENT ON FUNCTION public.apply_ct_cron_dst_sync IS
  'Ensures payroll/PFA cron_expressions match current CT DST state. Idempotent. Scheduled via pg_cron daily. Auto-shifts on 2026-11-01, 2027-03-14, etc.';

-- Register a pg_cron job to run this daily at 09:00 UTC (well after both DST transitions
-- which happen at 2am local = 7-8am UTC).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ct-cron-dst-sync-daily') THEN
    PERFORM cron.schedule('ct-cron-dst-sync-daily', '0 9 * * *',
      $inner$SELECT public.apply_ct_cron_dst_sync();$inner$);
  END IF;
END $$;


-- ==========================================================================
-- 6. Payroll label normalization map (SF payroll code → human-friendly name)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS public.payroll_label_map (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id        uuid REFERENCES public.agency(id),
  label            text NOT NULL,
  friendly_name    text,
  bucket           text NOT NULL CHECK (bucket IN ('earning','deduction','employer_tax','unknown')),
  notes            text,
  needs_review     boolean NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, label)
);

COMMENT ON TABLE public.payroll_label_map IS
  'Maps SurePayroll pay-code labels (as extracted by payroll-email-parser) to human-friendly names. Populated from observed labels on 2026-07-06 payroll; needs_review=true for SF-specific numeric codes that Peter should confirm.';

INSERT INTO public.payroll_label_map (agency_id, label, friendly_name, bucket, needs_review, notes)
VALUES
  -- Earnings — self-explanatory
  ('126794dd-25ff-47d2-a436-724499733365', 'REGULAR',     'Regular Pay (hourly)',    'earning',      false, 'Hourly wage for non-exempt team members'),
  ('126794dd-25ff-47d2-a436-724499733365', 'SALARY',      'Salary',                   'earning',      false, 'Salaried gross for exempt team members'),
  ('126794dd-25ff-47d2-a436-724499733365', 'PTO',         'PTO Pay',                  'earning',      false, 'Paid time off draw'),
  ('126794dd-25ff-47d2-a436-724499733365', '- O/TIME',    'Overtime',                 'earning',      false, 'Overtime hourly premium'),
  ('126794dd-25ff-47d2-a436-724499733365', 'LIFE *',      'Life Insurance (non-cash)','earning',      false, 'Non-cash imputed income for employer-paid life insurance; included in gross but not in net_pay per SF footnote'),
  ('126794dd-25ff-47d2-a436-724499733365', 'REIMB.',      'Reimbursement',            'earning',      false, 'Non-taxable reimbursement (mileage / expense)'),
  -- Earnings — SF numeric-prefixed codes; Peter to confirm exact meaning
  ('126794dd-25ff-47d2-a436-724499733365', '0Advnce',     NULL,                       'earning',      true,  'SF numeric code 0Advnce — likely draw against future comp; Peter to confirm'),
  ('126794dd-25ff-47d2-a436-724499733365', '1Health',     NULL,                       'earning',      true,  'SF numeric code 1Health — likely health-benefit-related; Peter to confirm'),
  ('126794dd-25ff-47d2-a436-724499733365', '2Serve',      NULL,                       'earning',      true,  'SF numeric code 2Serve — bonus/incentive; Peter to confirm'),
  ('126794dd-25ff-47d2-a436-724499733365', '3True',       NULL,                       'earning',      true,  'SF numeric code 3True — likely true-up adjustment; Peter to confirm'),
  ('126794dd-25ff-47d2-a436-724499733365', '4Manage',     NULL,                       'earning',      true,  'SF numeric code 4Manage — manager bonus/override; Peter to confirm'),
  ('126794dd-25ff-47d2-a436-724499733365', '5Goals',      NULL,                       'earning',      true,  'SF numeric code 5Goals — goals-based bonus; Peter to confirm'),
  ('126794dd-25ff-47d2-a436-724499733365', 'blank3',      NULL,                       'earning',      true,  'SF label "blank3" — unknown category; Peter to confirm or rename in SF'),
  -- Employee deductions
  ('126794dd-25ff-47d2-a436-724499733365', 'FED WTH',     'Federal Withholding',      'deduction',    false, 'Federal income tax withheld'),
  ('126794dd-25ff-47d2-a436-724499733365', 'FICA',        'Social Security (employee)','deduction',   false, '6.2% Social Security withheld'),
  ('126794dd-25ff-47d2-a436-724499733365', 'MEDFICA',     'Medicare (employee)',      'deduction',    false, '1.45% Medicare withheld'),
  ('126794dd-25ff-47d2-a436-724499733365', 'DENTAL',      'Dental Insurance',         'deduction',    false, 'Employee share of dental premium'),
  ('126794dd-25ff-47d2-a436-724499733365', 'MEDICAL',     'Medical Insurance',        'deduction',    false, 'Employee share of medical premium'),
  ('126794dd-25ff-47d2-a436-724499733365', 'VISION',      'Vision Insurance',         'deduction',    false, 'Employee share of vision premium'),
  ('126794dd-25ff-47d2-a436-724499733365', 'MISC 1T',     'Misc 1-Time',              'deduction',    false, 'One-time miscellaneous deduction'),
  ('126794dd-25ff-47d2-a436-724499733365', 'VACHILD',     'Virginia Child Support',   'deduction',    false, 'Court-ordered garnishment (VA-specific for Thomas Lynch)'),
  ('126794dd-25ff-47d2-a436-724499733365', 'STATE-VA',    'Virginia State Tax',       'deduction',    false, 'Virginia state income tax withheld'),
  ('126794dd-25ff-47d2-a436-724499733365', 'STATE-TX',    'Texas State Tax',          'deduction',    false, 'Texas has no state income tax; only appears if a TX employee has withholding'),
  -- Employer taxes
  ('126794dd-25ff-47d2-a436-724499733365', 'CO FICA',     'Employer Social Security', 'employer_tax', false, 'Company match, 6.2%'),
  ('126794dd-25ff-47d2-a436-724499733365', 'CO MEDC',     'Employer Medicare',        'employer_tax', false, 'Company match, 1.45%'),
  ('126794dd-25ff-47d2-a436-724499733365', 'CO UNEM-TX',  'TX Unemployment Insurance','employer_tax', false, 'Texas SUTA'),
  ('126794dd-25ff-47d2-a436-724499733365', 'CO UNEM-VA',  'VA Unemployment Insurance','employer_tax', false, 'Virginia SUTA'),
  ('126794dd-25ff-47d2-a436-724499733365', 'FUTA',        'Federal Unemployment (FUTA)','employer_tax', false, 'Federal FUTA — paid quarterly per prior op-rule'),
  ('126794dd-25ff-47d2-a436-724499733365', 'TX ETIA',     'TX Employment Training Assessment','employer_tax', false, 'Texas E&T assessment'),
  ('126794dd-25ff-47d2-a436-724499733365', 'TXEMPL',      'TX Employment-related (other)','employer_tax', false, 'TX-specific employer tax; Peter to confirm exact program'),
  ('126794dd-25ff-47d2-a436-724499733365', 'FEES',        'Payroll Processing Fees',  'employer_tax', false, 'SurePayroll processing fees (only appears in grand totals)')
ON CONFLICT (agency_id, label) DO NOTHING;


-- ==========================================================================
-- 3. open_questions bookkeeping — remove resolved, add current pending
-- ==========================================================================
UPDATE public.persistent_memory
SET content = E'**Currently open questions / decisions pending Peter''s input:**\n\n' ||
             E'1. **Payroll label review (7 codes)** — SurePayroll uses numeric-prefixed labels (0Advnce, 1Health, 2Serve, 3True, 4Manage, 5Goals, blank3) whose exact business meaning I inferred but couldn''t confirm. Rows in `payroll_label_map` with `needs_review=true` need Peter to fill in `friendly_name` when he next audits payroll. Not blocking parser or CPR wiring.\n' ||
             E'2. **DST cron transitions handled automatically** — `apply_ct_cron_dst_sync()` runs daily at 09:00 UTC via pg_cron job `ct-cron-dst-sync-daily`. RESOLVED, no action needed on 2026-11-01 or 2027-03-14.\n' ||
             E'3. **Composio doc-processor race for SF payroll** — Handled at DB layer via unique constraint `ux_payroll_runs_agency_period`. Doc-processor will silently fail on constraint violation for SF payroll emails and mark its documents row as errored; payroll-email-parser wins. No further action.\n' ||
             E'4. **Gusto migration 2027-01-01** — When Peter switches from SurePayroll to Gusto, the `payroll-email-parser` will need a new sender/format branch. Flag: come back to this in November 2026 to prep.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category = 'open_questions'
  AND is_active = true;

SELECT 'apply_ct_cron_dst_sync + label_map + open_questions all migrated' AS status;
