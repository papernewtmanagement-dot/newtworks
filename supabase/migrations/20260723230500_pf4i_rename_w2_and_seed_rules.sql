-- =====================================================================
-- Phase 4i: Rename W2 accounts + seed 39 gl_classification_rules for personal patterns
-- Naming: "W2 - <Company>" convention per Peter
-- Rule structure: __SOURCE__ placeholder for the txn's source account (bank/CC),
-- confidence enum ('exact'|'high'|'medium'|'low'|'suspense'), match_direction ('debit'|'credit'|'both')
-- =====================================================================

UPDATE public.chart_of_accounts SET account_name = 'W2 - PaperNewt LLC'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND chart_namespace = 'active' AND account_code = 'COA-PERSONAL-8110';
UPDATE public.chart_of_accounts SET account_name = 'W2 - Gloelle LLC'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND chart_namespace = 'active' AND account_code = 'COA-PERSONAL-8120';

INSERT INTO public.gl_classification_rules
  (agency_id, rule_name, match_priority, match_payee_regex, match_direction,
   debit_account_code, credit_account_code, sub_category_label, confidence, source, is_active)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'PaperNewt LLC PAYROLL -> W2 (Peter)',   100, '(?i)PAPERNEWT\s+LLC\s+PAYROLL',      'credit', '__SOURCE__', 'COA-PERSONAL-8110', 'W2 - PaperNewt LLC',              'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Gloele LLC PAYROLL -> W2 (Marie)',       100, '(?i)GLOELE\s+LLC\s+PAYROLL',         'credit', '__SOURCE__', 'COA-PERSONAL-8120', 'W2 - Gloelle LLC',                'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'CD INT TRANSFER -> Investment Income',   100, '(?i)CD\s+INT\s+TRANSFER',            'credit', '__SOURCE__', 'COA-PERSONAL-8200', 'Interest & Investment Income',    'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Family Protect Sv -> Foster Care',       100, '(?i)FAMILY\s+PROTCT\s+SV',           'credit', '__SOURCE__', 'COA-PERSONAL-8400', 'Foster Care Income (nontaxable)', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Credit Balance Refund -> Other Income',  100, '(?i)Credit\s+Balance\s+Refund',      'credit', '__SOURCE__', 'COA-PERSONAL-8300', 'Other Personal Income',           'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'State Farm Insurance -> Personal Insurance', 100, '(?i)STATE\s+FARM\s+INSURANCE',   'debit', 'COA-PERSONAL-9600', '__SOURCE__', 'Personal Insurance',   'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Mortgage Serv CT -> Housing',           100, '(?i)MORTGAGE\s+SERV\s+CT',           'debit', 'COA-PERSONAL-9100', '__SOURCE__', 'Housing',              'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'CPS Energy -> Home Utilities',          100, '(?i)CITY\s+PUBLIC\s+SRV',            'debit', 'COA-PERSONAL-9110', '__SOURCE__', 'Home Utilities',       'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'SA Water -> Home Utilities',            100, '(?i)SA\s+WATER\s+SYSTEM',            'debit', 'COA-PERSONAL-9110', '__SOURCE__', 'Home Utilities',       'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Republic Services -> Home Utilities',   100, '(?i)REPUBLIC\s+SERVICES\s+TRASH',    'debit', 'COA-PERSONAL-9110', '__SOURCE__', 'Home Utilities',       'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'H-E-B Curbside -> Groceries',           100, '(?i)HEB\s+CURBSIDE',                 'debit', 'COA-PERSONAL-9200', '__SOURCE__', 'Groceries',            'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'H-E-B in-store -> Groceries',           100, '(?i)H-E-B\s*#',                      'debit', 'COA-PERSONAL-9200', '__SOURCE__', 'Groceries',            'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Sams Club -> Groceries',                100, '(?i)SAMS\s*CLUB',                    'debit', 'COA-PERSONAL-9200', '__SOURCE__', 'Groceries',            'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'SamsClub (alt) -> Groceries',           100, '(?i)SAMSCLUB',                       'debit', 'COA-PERSONAL-9200', '__SOURCE__', 'Groceries',            'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bexar Vehicle Reg -> Auto Maintenance', 100, '(?i)BEXAR\s+VEHREG',                 'debit', 'COA-PERSONAL-9320', '__SOURCE__', 'Auto Maintenance',     'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Texas.gov service fee -> Auto Maint',   100, '(?i)TEXAS\.GOV',                     'debit', 'COA-PERSONAL-9320', '__SOURCE__', 'Auto Maintenance',     'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'SA Taekwondo -> Kids',                  100, '(?i)SANANTONIOEXPERTTAEKW',          'debit', 'COA-PERSONAL-9400', '__SOURCE__', 'Kids',                 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Champions Cheer -> Kids',               100, '(?i)Champions\s+Cheer',              'debit', 'COA-PERSONAL-9400', '__SOURCE__', 'Kids',                 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Live Oak Periodontics -> Medical',      100, '(?i)LIVE\s+OAK\s+PERIODONTICS',      'debit', 'COA-PERSONAL-9500', '__SOURCE__', 'Medical & Health',     'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'TPC Dental Care -> Medical',            100, '(?i)TPC\s+DENTAL\s+CARE',            'debit', 'COA-PERSONAL-9500', '__SOURCE__', 'Medical & Health',     'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Davids Lawn -> Home Maintenance',       100, '(?i)DAVIDS\s+LAWN\s+SERVICES',       'debit', 'COA-PERSONAL-9120', '__SOURCE__', 'Home Maintenance',     'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Cinch Home Service -> Home Maint',      100, '(?i)CCM\*CINCH\s+HOME\s+SERVICE',    'debit', 'COA-PERSONAL-9120', '__SOURCE__', 'Home Maintenance',     'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Amazon Marketplace -> Discretionary',   100, '(?i)AMAZON\s+MKTPL',                 'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Amazon.com -> Discretionary',           100, '(?i)Amazon\.com\*',                  'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'PlayStation -> Discretionary',          100, '(?i)PLAYSTATION',                    'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Google TV -> Discretionary',            100, '(?i)GOOGLE\*?TV',                    'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Rover -> Discretionary',                100, '(?i)ROVER\.COM',                     'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Dons Tropical Pets -> Discretionary',   100, '(?i)Dons\s+Tropical\s+Pets',         'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Pure Mana CBD -> Discretionary',        100, '(?i)PURE\s+MANA\s+CBD',              'debit', 'COA-PERSONAL-9800', '__SOURCE__', 'Discretionary',        'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'IRS Tax Payment -> Personal Tax',       100, '(?i)IRS\s+USATAXPYMT',               'debit', 'COA-PERSONAL-9900', '__SOURCE__', 'Personal Income Tax',  'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Internet Banking Transfer To -> Internal Transfers',   100, '(?i)Internet\s+Banking\s+Transfer\s+To',   'debit',  'COA-PERSONAL-9990', '__SOURCE__', 'Internal Transfers', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Internet Banking Transfer From -> Internal Transfers', 100, '(?i)Internet\s+Banking\s+Transfer\s+From', 'credit', '__SOURCE__', 'COA-PERSONAL-9990', 'Internal Transfers', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank paying Cap One -> Internal Transfers',        100, '(?i)Electronic\s+Withdrawal\s+To\s+CAPITAL\s+ONE', 'debit',  'COA-PERSONAL-9990', '__SOURCE__', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank paying Cap One ACH -> Internal Transfers',    100, '(?i)ACH\s+W/D\s+CAPITAL\s+ONE',                     'debit',  'COA-PERSONAL-9990', '__SOURCE__', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Bank paying US Bank 8847 -> Internal Transfers',   100, '(?i)U\.S\.\s+BANK\s+WEB\s+PYMT\s+8847',             'debit',  'COA-PERSONAL-9990', '__SOURCE__', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'Mobile pay to CC 8847 -> Internal Transfers',      100, '(?i)Mobile\s+Banking\s+Payment\s+To\s+Credit\s+Card\s+8847', 'debit', 'COA-PERSONAL-9990', '__SOURCE__', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'CC payment received (Cap One) -> Internal Transfers',       100, '(?i)CAPITAL\s+ONE\s+ONLINE\s+PYMT',   'credit', '__SOURCE__', 'COA-PERSONAL-9990', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'CC payment received (Mobile Thank You) -> Internal Transfers',  100, '(?i)MOBILE\s+PAYMENT\s+THANK\s+YOU',  'credit', '__SOURCE__', 'COA-PERSONAL-9990', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'CC payment received (Internet Thank You) -> Internal Transfers', 100, '(?i)INTERNET\s+PAYMENT\s+THANK\s+YOU', 'credit', '__SOURCE__', 'COA-PERSONAL-9990', 'CC Payment', 'exact', 'pf4i_personal_seed', true),
  ('126794dd-25ff-47d2-a436-724499733365', 'CC payment received (generic Thank You) -> Internal Transfers', 90,  '(?i)^PAYMENT\s+THANK\s+YOU$',        'credit', '__SOURCE__', 'COA-PERSONAL-9990', 'CC Payment', 'exact', 'pf4i_personal_seed', true);
