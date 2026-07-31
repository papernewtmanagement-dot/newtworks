-- 20260731000600: PN 0003 suspense sweep + PSS expense section restoration
-- + get_pnl_history growth tag routing + prior_year_pl section normalization
-- Peter directive 2026-07-31: restore 5 expense sections on agency P&L.

-- Part A: PN 0003 suspense sweep to 3050 S-Corp Distributions
DO $mig1$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pn_entity uuid;
  v_pn_0003 uuid;
  v_pn_3050 uuid;
  v_reclass_id uuid;
  v_row_count int;
  v_total numeric;
BEGIN
  SELECT id INTO v_pn_entity FROM business_entities
    WHERE agency_id = v_agency AND slug = 'papernewt';
  SELECT id INTO v_pn_0003 FROM chart_of_accounts
    WHERE agency_id = v_agency AND business_entity_id = v_pn_entity
      AND account_code = '0003' AND is_active = true;

  INSERT INTO chart_of_accounts (
    agency_id, business_entity_id, account_code, account_name,
    account_type, account_subtype, is_active, section_label_override
  )
  SELECT v_agency, v_pn_entity, '3050', 'S-Corp Distributions',
         'equity', 'distribution', true, NULL
  WHERE NOT EXISTS (
    SELECT 1 FROM chart_of_accounts
    WHERE agency_id = v_agency AND business_entity_id = v_pn_entity
      AND account_code = '3050'
  );
  UPDATE chart_of_accounts SET is_active = true, account_name = 'S-Corp Distributions'
   WHERE agency_id = v_agency AND business_entity_id = v_pn_entity AND account_code = '3050';
  SELECT id INTO v_pn_3050 FROM chart_of_accounts
    WHERE agency_id = v_agency AND business_entity_id = v_pn_entity AND account_code = '3050';

  SELECT COUNT(*), COALESCE(SUM(debit - credit), 0)
    INTO v_row_count, v_total
    FROM journal_lines WHERE agency_id = v_agency AND account_id = v_pn_0003;

  INSERT INTO account_reclassifications (
    agency_id, from_account_id, to_account_id,
    from_account_code, from_account_name, from_business_entity_id,
    filter_description, journal_line_count, total_amount,
    performed_at, performed_by, notes
  ) VALUES (
    v_agency, v_pn_0003, v_pn_3050,
    '0003', '*Unclassified Expense — Business', v_pn_entity,
    'All journal_lines on PaperNewt 0003 *Unclassified Expense — Business (AMEX Discretionary card)',
    v_row_count, v_total, NOW(), 'claude',
    'Sweep aged PN 0003 suspense ($8,221 aged 238d) to 3050 S-Corp Distributions. '
    ||'AMEX Discretionary card (2141) is Peter''s personal-charge pipe; economically '
    ||'these are shareholder distributions, not agency expenses. Amex Cash Rebate '
    ||'credits ($250.65) net into the distribution.'
  ) RETURNING id INTO v_reclass_id;

  UPDATE journal_lines jl
     SET account_id = v_pn_3050,
         original_account_id = COALESCE(jl.original_account_id, v_pn_0003),
         original_account_code = COALESCE(jl.original_account_code, '0003'),
         original_account_name = COALESCE(jl.original_account_name, '*Unclassified Expense — Business'),
         reclassification_id = v_reclass_id
   WHERE jl.agency_id = v_agency AND jl.account_id = v_pn_0003;
END $mig1$;

-- Part B: PSS expense section_label_override — 5-section restoration
DO $mig2$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_pss_entity uuid;
BEGIN
  SELECT id INTO v_pss_entity FROM business_entities
    WHERE agency_id = v_agency AND slug = 'pss';

  UPDATE chart_of_accounts SET section_label_override = 'Admin'
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code IN (
       '6210','6220','6240','6250','6270','6280',
       '6310','6320','6330',
       '6510','6520','6530',
       '6610','6620',
       '6810','6850','6860',
       '6910','6940','6941','6945','6950','6960'
     );

  UPDATE chart_of_accounts SET section_label_override = 'Team'
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code IN (
       '6010','6020','6030','6060',
       '6110','6115','6120','6160','6180',
       '6710','6720','6740','6750'
     );

  UPDATE chart_of_accounts SET section_label_override = 'Marketing'
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code IN ('6400','6410','6470');

  UPDATE chart_of_accounts SET section_label_override = NULL
   WHERE agency_id = v_agency AND business_entity_id = v_pss_entity
     AND account_code = '0003';
END $mig2$;

-- Part C: Normalize prior_year_pl.section on PSS to Peter's 5-section scheme
UPDATE public.prior_year_pl
SET section = CASE section
  WHEN '0001 ADMINISTRATION'      THEN 'Admin'
  WHEN '0003 TEAM'                THEN 'Team'
  WHEN '0003a Mortgage Marketing' THEN 'Marketing'
  WHEN '0004 MARKETING'           THEN 'Marketing'
  WHEN '0005 DISCRETIONARY'       THEN 'Admin'
  WHEN '0006 PERSONAL'            THEN 'Personal'
  ELSE section
END
WHERE section IN (
  '0001 ADMINISTRATION','0003 TEAM','0003a Mortgage Marketing',
  '0004 MARKETING','0005 DISCRETIONARY','0006 PERSONAL'
);

-- Part D: get_pnl_history_own_only + get_pnl_history_for_entity with Growth tag routing
CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
RETURNS json LANGUAGE sql STABLE
AS $function$
  WITH post_cutover AS (
    SELECT EXTRACT(year FROM je.entry_date)::int AS year,
           EXTRACT(month FROM je.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           CASE
             WHEN coa.account_type = 'expense'
              AND EXISTS (
                SELECT 1 FROM public.transaction_tags tt
                 WHERE tt.journal_line_id = jl.id
                   AND tt.tag_key   = 'budget_category'
                   AND tt.tag_value = 'growth'
              )
             THEN 'Growth'
             ELSE COALESCE(
               coa.section_label_override,
               INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
             )
           END AS section,
      CASE
        WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income'  THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je   ON je.id  = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = p_entity_id
    GROUP BY je.entry_date, je.source, jl.id, coa.id, coa.account_name,
             coa.account_type, coa.account_subtype, coa.section_label_override
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense') AND py.business_entity_id = p_entity_id
  ),
  combined AS (SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover)
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;

CREATE OR REPLACE FUNCTION public.get_pnl_history_for_entity(p_entity_id uuid)
RETURNS json LANGUAGE sql STABLE
AS $function$
  WITH RECURSIVE descendants AS (
    SELECT id FROM public.business_entities WHERE id = p_entity_id
    UNION ALL
    SELECT e.id FROM public.business_entities e JOIN descendants d ON e.parent_entity_id = d.id
  ),
  post_cutover AS (
    SELECT EXTRACT(year FROM je.entry_date)::int AS year,
           EXTRACT(month FROM je.entry_date)::int AS month,
           coa.account_name, coa.account_type::text AS account_type,
           CASE
             WHEN coa.account_type = 'expense'
              AND EXISTS (
                SELECT 1 FROM public.transaction_tags tt
                 WHERE tt.journal_line_id = jl.id
                   AND tt.tag_key   = 'budget_category'
                   AND tt.tag_value = 'growth'
              )
             THEN 'Growth'
             ELSE COALESCE(
               coa.section_label_override,
               INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' '))
             )
           END AS section,
      CASE
        WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
        WHEN coa.account_type = 'income'  THEN SUM(jl.credit) - SUM(jl.debit)
        WHEN coa.account_type = 'expense' THEN SUM(jl.debit) - SUM(jl.credit)
        ELSE 0::numeric
      END AS amount
    FROM public.journal_lines jl
    JOIN public.journal_entries je   ON je.id  = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE coa.account_type IN ('income','expense')
      AND coa.business_entity_id = ANY (SELECT id FROM descendants)
    GROUP BY je.entry_date, je.source, jl.id, coa.id, coa.account_name,
             coa.account_type, coa.account_subtype, coa.section_label_override
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense')
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
  ),
  combined AS (SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover)
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;
