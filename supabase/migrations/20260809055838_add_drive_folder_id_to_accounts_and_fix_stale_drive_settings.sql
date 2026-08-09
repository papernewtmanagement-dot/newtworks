ALTER TABLE public.accounts ADD COLUMN IF NOT EXISTS drive_folder_id text;

WITH map(account_code, folder_id) AS (
  VALUES
    ('1011','1_2uptz-9l3L1OB2OcmOFBIrHu9EG1i8e'),
    ('1012','1g27vc36Er0brfi0vsMtOSDbKeOTGJ4Oy'),
    ('1070','1lpTVrTtliLvfrdTpOhjoKNsjYWbUW2gV'),
    ('1071','1l1lQC2L4Ipd_Dwhy2fAhxOMa3QAR29ig'),
    ('1072','1pNjtyo_9dlscbz7_4WHnIGzBnE1wTsy8'),
    ('1073','1Ungtz5m7hr2Sa9AQFq5njPTl60VeXiNK'),
    ('1075','1v8EPBuqFwMOtjt43h3zZpJFtRZA8tigI'),
    ('1076','1a5lqT42G8D-fIWVGT_2lGT-wDzNwhL57'),
    ('2110','1Ym0K44v1dpExoJSL9Hi87gT6DiM6gwjv'),
    ('2113','180uRRbxwbXWCrHn-6m9d0Vmo5muLeuAR'),
    ('2140','1GRovl02Nx9KEkwuigQaxj6SKvAY3Fwhh'),
    ('2141','1L1FxdDvOT17dP9ZtFBBMEuwTCOtf_rsW'),
    ('2170','1d-bcu5v9gmhFG8y2sp7cstgOQezZLrWr'),
    ('2171','1Pw4Qa3WZe4vO4h-MBETw-zjGcecL-Xa0'),
    ('2172','1Pj8s-RWI5mcT0Zl1Kv7z3BglRjrtWz2p'),
    ('2173','14A0UVTGgOs44qVQ5RaQtCH2vrQ7HsyFD')
)
UPDATE public.accounts a
SET drive_folder_id = map.folder_id
FROM map
JOIN public.chart_of_accounts coa ON coa.account_code = map.account_code
WHERE a.chart_account_id = coa.id
  AND a.agency_id = '126794dd-25ff-47d2-a436-724499733365';

INSERT INTO public.settings (agency_id, setting_key, setting_value, setting_type, description, updated_at, created_at)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'drive_comp_deduct_folder_id', '1agu9cJRNHOfWKxhLrapYqFRoMSd1r4um', 'string', 'Drive folder ID for the top-level "Comp - Deduct" folder. Comp recaps + deduction statements both file here (merged 2026-08-09; Gmail Label_25 for Deductions was retired same day, both types now archive to Label_24 "Comp-Deduct").', now(), now()),
  ('126794dd-25ff-47d2-a436-724499733365', 'drive_payroll_folder_id', '1KCCUl9q2p23cYSjTyZehEjjEfpNBF-uh', 'string', 'Drive folder ID for Team/Payroll. Payroll doc types (adp_payroll, surepayroll_payroll) file here.', now(), now())
ON CONFLICT DO NOTHING;

UPDATE public.settings
SET setting_value = '1O9eR3wuNc5mGzZIZPE-1X9l_H52oehm6',
    description = 'Drive folder ID for the fallback "Documents" root (recreated 2026-08-09; prior root was deleted in Peter''s Drive reorg and this setting was pointing at a dead folder). Only used for doc types with no specific folder mapping: commission_report, team_production, archive_bundle, skip.',
    updated_at = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key = 'drive_newtworks_root_folder_id';

DELETE FROM public.settings
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND setting_key IN (
    'drive_2025_folder_id','drive_2025_annual_folder_id','drive_2025_prior_books_reports_folder_id',
    'drive_2026_folder_id','drive_2026_annual_folder_id','drive_2026_payroll_folder_id','drive_2026_prior_books_reports_folder_id'
  );
