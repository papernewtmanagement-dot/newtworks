-- Step 2: purge 100 legacy COA-* rules, rebuild to numeric COA codes.
-- Per session_note 2026-07-31 — Pipeline repair Step 2, 10 decisions:
--   1. Fuel COA-SUB-007: strip COA-024 source filter, remap to 6810
--   2. SF commission COA-SUB-058: deactivate (comp_recap is truth)
--   3. Life stipends: Leslie (SUB-042) & John/Tommy (SUB-074) → 6110 Employee Benefits
--   4. Auto loan COA-SUB-084 → 2540 Vehicle Loan Payable
--   5. Payroll+MyChildSupport COA-SUB-078 → 6010 Staff Wages, dedupe TOMMY-CHILD to MINED envelope
--   6. Tithe COA-SUB-043: deactivate (personal, not business P&L)
--   7. Airbnb COA-SUB-002 → 6850 Business Travel
--   8. Scopely/Schlitterbahn split (COA-SUB-004): Scopely → 6720; Schlitterbahn/Alamo/Tiburon/etc → 6160
--      Plus COA-SUB-075 Employee Meals → 6160
--   9. Streaming COA-SUB-010 → 6310 Software & SaaS
--   10. Audible/Agency Network split (COA-SUB-017): Audible → 6750; Agcy Network → 6310

-- =====================================
-- DEACTIVATE (4 rules)
-- COA-SUB-043 tithe (2), COA-SUB-058 SF commission (1), afbba800 TOMMY-CHILD dedupe (1)
-- =====================================
UPDATE public.gl_classification_rules
SET is_active = FALSE, updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND (
    debit_account_code IN ('COA-SUB-043','COA-SUB-058')
    OR credit_account_code IN ('COA-SUB-043','COA-SUB-058')
    OR id = 'afbba800-6984-4f82-94a6-2723eb9c7c93'::uuid
  );

-- =====================================
-- MAP+STRIP: COA-SUB-007 fuel — remap to 6810 and strip COA-024 source filter (2 rules)
-- =====================================
UPDATE public.gl_classification_rules
SET debit_account_code = '6810',
    credit_account_code = '__SOURCE__',
    match_source_account = NULL,
    updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = TRUE
  AND debit_account_code = 'COA-SUB-007';

-- =====================================
-- SPLIT COA-SUB-004: Scopely → 6720, Schlitterbahn/Tiburon/etc → 6160
-- =====================================
UPDATE public.gl_classification_rules
SET debit_account_code = '6720', credit_account_code = '__SOURCE__', updated_at = NOW()
WHERE id = '8e433065-b667-4330-a047-4ec82e15bbab'::uuid;

UPDATE public.gl_classification_rules
SET debit_account_code = '6160', credit_account_code = '__SOURCE__', updated_at = NOW()
WHERE id IN (
  'a2bb3a06-ff08-406a-86ab-4c5112beb6ad'::uuid,
  '3d857b50-90e5-4509-863b-2fc06394ebaa'::uuid
);

-- =====================================
-- SPLIT COA-SUB-017: Audible → 6750, Agcy Network → 6310
-- =====================================
UPDATE public.gl_classification_rules
SET debit_account_code = '6750', credit_account_code = '__SOURCE__', updated_at = NOW()
WHERE id = '11114540-88a1-40a2-8f70-8fa0e380add1'::uuid;

UPDATE public.gl_classification_rules
SET debit_account_code = '6310', credit_account_code = '__SOURCE__', updated_at = NOW()
WHERE id = '7a5ba41e-a4a6-49a7-8042-08c5320a0585'::uuid;

-- =====================================
-- SPLIT COA-SUB-078: remaining active (Payroll + MyChildSupport MINED) → 6010
-- afbba800 already deactivated above
-- =====================================
UPDATE public.gl_classification_rules
SET debit_account_code = '6010', credit_account_code = '__SOURCE__', updated_at = NOW()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND is_active = TRUE
  AND debit_account_code = 'COA-SUB-078';

-- =====================================
-- STRAIGHT MAPS (87 rules across 34 legacy codes)
-- =====================================
UPDATE public.gl_classification_rules r
SET debit_account_code = m.new_dr,
    credit_account_code = m.new_cr,
    updated_at = NOW()
FROM (VALUES
  ('COA-SUB-001','6240','__SOURCE__'),
  ('COA-SUB-002','6850','__SOURCE__'),
  ('COA-SUB-008','6860','__SOURCE__'),
  ('COA-SUB-010','6310','__SOURCE__'),
  ('COA-SUB-012','6910','__SOURCE__'),
  ('COA-SUB-014','6720','__SOURCE__'),
  ('COA-SUB-016','6940','__SOURCE__'),
  ('COA-SUB-021','6310','__SOURCE__'),
  ('COA-SUB-023','6710','__SOURCE__'),
  ('COA-SUB-028','6320','__SOURCE__'),
  ('COA-SUB-029','6510','__SOURCE__'),
  ('COA-SUB-031','6860','__SOURCE__'),
  ('COA-SUB-037','6210','__SOURCE__'),
  ('COA-SUB-039','6720','__SOURCE__'),
  ('COA-SUB-041','6320','__SOURCE__'),
  ('COA-SUB-042','6110','__SOURCE__'),
  ('COA-SUB-046','6270','__SOURCE__'),
  ('COA-SUB-047','6280','__SOURCE__'),
  ('COA-SUB-048','6400','__SOURCE__'),
  ('COA-SUB-049','6400','__SOURCE__'),
  ('COA-SUB-052','6410','__SOURCE__'),
  ('COA-SUB-053','6410','__SOURCE__'),
  ('COA-SUB-055','6400','__SOURCE__'),
  ('COA-SUB-056','6400','__SOURCE__'),
  ('COA-SUB-073','6710','__SOURCE__'),
  ('COA-SUB-074','6110','__SOURCE__'),
  ('COA-SUB-075','6160','__SOURCE__'),
  ('COA-SUB-077','6110','__SOURCE__'),
  ('COA-SUB-079','6180','__SOURCE__'),
  ('COA-SUB-081','6720','__SOURCE__'),
  ('COA-SUB-084','2540','__SOURCE__'),
  ('COA-SUB-090','9800','__SOURCE__'),
  ('COA-016','__SOURCE__','4025'),
  ('COA-017','__SOURCE__','4010')
) AS m(legacy_code, new_dr, new_cr)
WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND r.is_active = TRUE
  AND (r.debit_account_code = m.legacy_code OR r.credit_account_code = m.legacy_code);
