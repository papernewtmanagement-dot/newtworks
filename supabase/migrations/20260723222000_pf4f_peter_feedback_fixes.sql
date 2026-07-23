-- =====================================================================
-- Phase 4f: Peter feedback fixes
-- 1. Revert SafeRingZ (I never should have classified it — Peter didn't say)
-- 2. Buck & Doe -> PaperNewt Home Office Security (biz expense on personal card)
-- 3. Rename intercompany accounts to plain English (no jargon)
-- 4. Rename Personal Suspense -> Income/Expenses — Unclassified
-- 5. Deactivate PERSONAL-9130 (personal-side security — biz stays on PaperNewt)
-- 6. Fix get_pnl_history_own_only section duplication (fall back to subtype-derived section
--    when the account has no parent so leaf section != account_name)
-- =====================================================================

DO $pf4f$
DECLARE
  v_agency_id UUID := '126794dd-25ff-47d2-a436-724499733365';
  v_pers_id UUID := 'b3333333-3333-3333-3333-333333333333';
  v_pn_id   UUID := 'b1111111-1111-1111-1111-111111111111';
  v_susp_out_id      UUID;
  v_susp_in_id       UUID;
  v_safety_pers_id   UUID;
  v_reimb_pers_id    UUID;
  v_owed_to_peter_id UUID;
  v_pn_security_id   UUID;
  v_txn RECORD;
  v_new_je_id UUID;
  v_amt NUMERIC;
BEGIN
  SELECT id INTO v_susp_out_id      FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9999';
  SELECT id INTO v_susp_in_id       FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-8999';
  SELECT id INTO v_safety_pers_id   FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9130';
  SELECT id INTO v_reimb_pers_id    FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PERSONAL-9971';
  SELECT id INTO v_owed_to_peter_id FROM public.chart_of_accounts WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='COA-IC-003';

  UPDATE public.chart_of_accounts SET account_name='Business expenses paid from personal (owed back)'    WHERE id = v_reimb_pers_id;
  UPDATE public.chart_of_accounts SET account_name='Owed to Peter for personal-paid business expenses' WHERE id = v_owed_to_peter_id;
  UPDATE public.chart_of_accounts SET account_name='Income — Unclassified'                              WHERE id = v_susp_in_id;
  UPDATE public.chart_of_accounts SET account_name='Expenses — Unclassified'                            WHERE id = v_susp_out_id;

  UPDATE public.journal_lines SET account_id = v_susp_out_id
   WHERE journal_entry_id IN (SELECT id FROM public.journal_entries WHERE source='pf4_personal_backfill' AND business_entity_id = v_pers_id AND description ILIKE '%SP SAFERINGZ%')
     AND account_id = v_safety_pers_id;
  UPDATE public.journal_entries SET classification_status='pending_review', classified_by=NULL, classified_at=NULL
   WHERE source='pf4_personal_backfill' AND business_entity_id = v_pers_id AND description ILIKE '%SP SAFERINGZ%';

  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, account_subtype, chart_namespace, is_active, is_system)
  VALUES
    (v_agency_id, v_pn_id, 'PN-HOME-OFFICE-SECURITY', 'Home Office Security',
     'expense', 'facilities', 'active', true, false)
  ON CONFLICT (agency_id, chart_namespace, account_code) DO NOTHING;

  SELECT id INTO v_pn_security_id FROM public.chart_of_accounts
    WHERE agency_id=v_agency_id AND chart_namespace='active' AND account_code='PN-HOME-OFFICE-SECURITY';

  FOR v_txn IN
    SELECT ct.id AS ct_id, ct.transaction_date, ct.description, ct.amount, ct.journal_entry_id AS pers_je_id
    FROM public.credit_transactions ct
    WHERE ct.business_entity_id = v_pers_id AND ct.description ILIKE '%BUCK AND DOE%'
  LOOP
    v_amt := ABS(v_txn.amount);
    UPDATE public.journal_lines SET account_id = v_reimb_pers_id
     WHERE journal_entry_id = v_txn.pers_je_id AND account_id = v_safety_pers_id AND debit = v_amt;
    UPDATE public.journal_entries
       SET memo = COALESCE(memo || ' | ', '') || 'Personal CC used for PaperNewt Home Office Security',
           classified_by = 'pf4f_buck_and_doe', classified_at = NOW()
     WHERE id = v_txn.pers_je_id;
    INSERT INTO public.journal_entries
      (agency_id, business_entity_id, entry_date, entry_type, description, source, classification_status, created_by, memo)
    VALUES
      (v_agency_id, v_pn_id, v_txn.transaction_date, 'personal_paid_biz_expense',
       'PAPERNEWT HOME OFFICE SECURITY: ' || v_txn.description,
       'pf4f_buck_and_doe', 'classified', 'phase_4f_migration',
       'Buck & Doe on personal CC ' || v_txn.ct_id::text || '; PaperNewt owes Peter back')
    RETURNING id INTO v_new_je_id;
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_new_je_id, v_agency_id, v_pn_security_id, v_amt, 0, 'Home Office Security purchase (Buck & Doe)', v_pn_id);
    INSERT INTO public.journal_lines (journal_entry_id, agency_id, account_id, debit, credit, description, business_entity_id)
    VALUES (v_new_je_id, v_agency_id, v_owed_to_peter_id, 0, v_amt, 'Charged to Peter personal CC — reimbursable', v_pn_id);
  END LOOP;

  UPDATE public.chart_of_accounts
     SET is_active = false, account_name = 'Home Security & Safety [DEPRECATED — moved to PaperNewt]'
   WHERE id = v_safety_pers_id;
END $pf4f$;

CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
  WITH RECURSIVE ancestry AS (
    SELECT id AS leaf_id, id AS cur_id, account_name, parent_account_id
    FROM public.chart_of_accounts
    UNION ALL
    SELECT a.leaf_id, p.id, p.account_name, p.parent_account_id
    FROM public.chart_of_accounts p
    JOIN ancestry a ON a.parent_account_id = p.id
  ),
  coa_root AS (
    SELECT leaf_id, account_name AS root_name
    FROM ancestry WHERE parent_account_id IS NULL
  ),
  post_cutover AS (
    SELECT
      EXTRACT(year FROM je.entry_date)::int AS year,
      EXTRACT(month FROM je.entry_date)::int AS month,
      coa.account_name,
      coa.account_type::text AS account_type,
      COALESCE(NULLIF(r.root_name, coa.account_name),
               INITCAP(REPLACE(coa.account_subtype, '_', ' ')),
               'Other') AS section,
      CASE
        WHEN coa.account_type = 'income' AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income' THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je ON je.id = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    LEFT JOIN coa_root r ON r.leaf_id = coa.id
    WHERE coa.account_type IN ('income','expense') AND je.business_entity_id = p_entity_id
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name, coa.account_type, coa.account_subtype, r.root_name
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense') AND py.business_entity_id = p_entity_id
  ),
  combined AS (
    SELECT year, month, account_name, account_type, section, amount FROM post_cutover
    UNION ALL
    SELECT year, month, account_name, account_type, section, amount FROM pre_cutover
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;
