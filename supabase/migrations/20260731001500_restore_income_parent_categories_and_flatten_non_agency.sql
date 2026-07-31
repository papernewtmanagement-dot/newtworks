-- Restore old income parent category names on the agency P&L + flatten section
-- headers on non-agency entity P&Ls.
--
-- Mechanism: adds nullable `section_label_override` column to chart_of_accounts.
-- v_trial_balance's section_label now prefers that column, falling back to the
-- old subtype-based auto-computed label when NULL.
--
-- Plus: strips 'SF Commissions — ' prefix from the five 40xx account names per
-- Peter directive. Rename applies to both master and chart_of_accounts to keep
-- them in sync.

--------------------------------------------------------------------------------
-- Part 1: Schema — add optional section label override
--------------------------------------------------------------------------------

ALTER TABLE public.chart_of_accounts
  ADD COLUMN IF NOT EXISTS section_label_override TEXT;

--------------------------------------------------------------------------------
-- Part 2: Rename the five 40xx accounts — strip 'SF Commissions — ' prefix
--------------------------------------------------------------------------------

UPDATE public.account_master_codes
SET name = REPLACE(name, 'SF Commissions — ', '')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND code IN ('4010','4020','4021','4022','4023')
  AND name LIKE 'SF Commissions — %';

UPDATE public.chart_of_accounts
SET account_name = REPLACE(account_name, 'SF Commissions — ', '')
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND account_code IN ('4010','4020','4021','4022','4023')
  AND account_name LIKE 'SF Commissions — %';

--------------------------------------------------------------------------------
-- Part 3: PSS agency income — set section labels to the old parent names
--------------------------------------------------------------------------------

-- State Farm: personal-line commissions + SF bonuses
UPDATE public.chart_of_accounts
SET section_label_override = 'State Farm'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
  AND account_code IN ('4100','4101','4110','4111','4120','4121','4140');

-- Alliances - SF Comp: US Bank, Pet Insurance, NFIP Flood, general alliance placeholder
UPDATE public.chart_of_accounts
SET section_label_override = 'Alliances - SF Comp'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
  AND account_code IN ('4010','4025','4131','4200');

-- IPS - SF Comp: SFVC, IPSI Life, Variable Life Servicing, IPS Brokerage Trail
UPDATE public.chart_of_accounts
SET section_label_override = 'IPS - SF Comp'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id = 'b2222222-2222-2222-2222-222222222222'
  AND account_code IN ('4020','4021','4022','4023');

--------------------------------------------------------------------------------
-- Part 4: Non-agency entities — flatten P&L sections to Income / Expenses only
--------------------------------------------------------------------------------

UPDATE public.chart_of_accounts
SET section_label_override = CASE account_type
  WHEN 'income'  THEN 'Income'
  WHEN 'expense' THEN 'Expenses'
END
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND business_entity_id <> 'b2222222-2222-2222-2222-222222222222'
  AND account_type IN ('income','expense');

--------------------------------------------------------------------------------
-- Part 5: Rebuild v_trial_balance so section_label prefers the override
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW public.v_trial_balance AS
SELECT
  je.agency_id,
  coa.id AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  COALESCE(
    coa.section_label_override,
    initcap(replace(COALESCE(coa.account_subtype, coa.account_type), '_'::text, ' '::text))
  ) AS section_label,
  CASE
    WHEN je.source LIKE 'historical_import%'::text THEN 'historical'::text
    WHEN je.source = ANY (ARRAY['gl_entry_writer'::text, 'payroll_gl_writer'::text,
                                'bank_gl_writer'::text, 'cc_gl_writer'::text,
                                'document_processor'::text, 'document_processor_drainer'::text,
                                'claude_adjustment'::text]) THEN 'active'::text
    ELSE 'other'::text
  END AS source_bucket,
  date_trunc('month'::text, je.entry_date::timestamp without time zone)::date AS month_start,
  je.entry_date,
  SUM(jl.debit) AS total_debit,
  SUM(jl.credit) AS total_credit,
  CASE
    WHEN coa.account_type = 'income'::text AND je.source LIKE 'historical_import%'::text
      THEN SUM(jl.debit) - SUM(jl.credit)
    WHEN coa.account_type = ANY (ARRAY['asset'::text, 'expense'::text])
      THEN SUM(jl.debit) - SUM(jl.credit)
    ELSE SUM(jl.credit) - SUM(jl.debit)
  END AS net_balance,
  COUNT(DISTINCT je.id) AS entry_count
FROM public.journal_entries je
JOIN public.journal_lines jl  ON jl.journal_entry_id = je.id
JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name,
         coa.account_type, coa.account_subtype, coa.section_label_override,
         je.source,
         date_trunc('month'::text, je.entry_date::timestamp without time zone),
         je.entry_date;
