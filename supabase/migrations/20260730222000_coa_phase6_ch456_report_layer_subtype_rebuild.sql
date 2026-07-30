-- Phase 6 Chunks 4+5+6 — report layer rebuild
--
-- Ch4: v_trial_balance, v_balance_sheet, v_pl_rolled_up rebuilt.
--      Drop parent_account_name / parent_account_id from view output; add account_subtype and a
--      formatted section_label (INITCAP with underscores → spaces).
--      Rollups group by account_subtype instead of parent-folder name.
--
-- Ch5: get_pnl_history / get_pnl_history_for_entity / get_pnl_history_own_only / pnl_drill_transactions
--      Drop the RECURSIVE ancestry CTE. Section = INITCAP of COALESCE(account_subtype, account_type).
--      For pre-cutover rows, prior_year_pl.section still passes through as-is (historical labels
--      like "State Farm", "0004 MARKETING" preserved for years that pre-date subtype convention).
--
-- Ch6: compute_weekly_marketing_bonus keyed by account_subtype IN ('marketing','advertising')
--      instead of the '0003 MARKETING' parent-uuid lookup that goes away in Migration A/B.
--
-- All active COAs already have non-null account_subtype (guaranteed by Ch2). All active COAs
-- with parent_account_id != NULL (74 rows) still have their parents pointing at inactive folders,
-- so the rebuild breaks no active dependency — those parent chains are dead reads.

-- ============================================================
-- Ch4: v_trial_balance
-- ============================================================

DROP VIEW IF EXISTS public.v_pl_rolled_up CASCADE;
DROP VIEW IF EXISTS public.v_balance_sheet CASCADE;
DROP VIEW IF EXISTS public.v_trial_balance CASCADE;

CREATE VIEW public.v_trial_balance AS
SELECT
  je.agency_id,
  coa.id AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type), '_', ' ')) AS section_label,
  CASE
    WHEN je.source LIKE 'historical_import%' THEN 'historical'
    WHEN je.source IN ('gl_entry_writer','payroll_gl_writer','bank_gl_writer','cc_gl_writer',
                        'document_processor','document_processor_drainer','claude_adjustment') THEN 'active'
    ELSE 'other'
  END AS source_bucket,
  date_trunc('month', je.entry_date::timestamp)::date AS month_start,
  je.entry_date,
  SUM(jl.debit)  AS total_debit,
  SUM(jl.credit) AS total_credit,
  CASE
    WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN SUM(jl.debit) - SUM(jl.credit)
    WHEN coa.account_type IN ('asset','expense')                              THEN SUM(jl.debit) - SUM(jl.credit)
    ELSE SUM(jl.credit) - SUM(jl.debit)
  END AS net_balance,
  COUNT(DISTINCT je.id) AS entry_count
FROM public.journal_entries je
JOIN public.journal_lines   jl  ON jl.journal_entry_id = je.id
JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
GROUP BY je.agency_id, coa.id, coa.account_code, coa.account_name, coa.account_type,
         coa.account_subtype, je.source, date_trunc('month', je.entry_date::timestamp), je.entry_date;

-- ============================================================
-- v_balance_sheet — cumulative window over asset/liability/equity
-- ============================================================

CREATE VIEW public.v_balance_sheet AS
SELECT
  je.agency_id,
  coa.id AS account_id,
  coa.account_code,
  coa.account_name,
  coa.account_type,
  coa.account_subtype,
  INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type), '_', ' ')) AS section_label,
  je.entry_date AS as_of_date,
  SUM(jl.debit)  OVER (PARTITION BY je.agency_id, coa.id ORDER BY je.entry_date
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_debit,
  SUM(jl.credit) OVER (PARTITION BY je.agency_id, coa.id ORDER BY je.entry_date
                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_credit,
  CASE
    WHEN coa.account_type IN ('asset','expense') THEN
      SUM(jl.debit - jl.credit) OVER (PARTITION BY je.agency_id, coa.id ORDER BY je.entry_date
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
    ELSE
      SUM(jl.credit - jl.debit) OVER (PARTITION BY je.agency_id, coa.id ORDER BY je.entry_date
                                       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
  END AS net_balance
FROM public.journal_entries je
JOIN public.journal_lines   jl  ON jl.journal_entry_id = je.id
JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
WHERE coa.account_type IN ('asset','liability','equity');

-- ============================================================
-- v_pl_rolled_up — rolls up income/expense by account_subtype
-- ============================================================

CREATE VIEW public.v_pl_rolled_up AS
WITH leaf_balances AS (
  SELECT
    v.agency_id,
    v.account_id,
    v.account_code,
    v.account_name,
    v.account_type,
    v.account_subtype,
    -- section_label is the subtype (title-cased), falling back to account_type
    v.section_label AS rollup_section,
    v.source_bucket,
    v.month_start,
    SUM(v.net_balance) AS period_balance
  FROM public.v_trial_balance v
  WHERE v.account_type IN ('income','expense')
  GROUP BY v.agency_id, v.account_id, v.account_code, v.account_name, v.account_type,
           v.account_subtype, v.section_label, v.source_bucket, v.month_start
)
SELECT
  agency_id,
  rollup_section AS parent_account,   -- column name preserved for frontend compat
  account_type,
  source_bucket,
  month_start,
  to_char(month_start::timestamp, 'YYYY-MM') AS month_label,
  SUM(period_balance) AS total,
  COUNT(DISTINCT account_id) AS account_count
FROM leaf_balances
GROUP BY agency_id, rollup_section, account_type, source_bucket, month_start;

-- ============================================================
-- Ch5: P&L history functions — drop recursive ancestry, use account_subtype
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_pnl_history()
 RETURNS json LANGUAGE sql STABLE
AS $function$
  WITH src AS (
    -- Post-cutover: journal rows carry account_subtype directly.
    SELECT
      v.year::int  AS year,
      v.month::int AS month,
      v.account_name,
      v.account_type::text AS account_type,
      INITCAP(REPLACE(COALESCE(v.account_subtype, v.account_type), '_', ' ')) AS section,
      v.amount
    FROM public.v_income_statement v
    WHERE v.account_id IS NOT NULL

    UNION ALL

    -- Pre-cutover: prior_year_pl.section pass-through (historical labels).
    SELECT
      v.year::int,
      v.month::int,
      v.account_name,
      v.account_type::text,
      COALESCE(v.account_subtype, 'Uncategorized') AS section,
      v.amount
    FROM public.v_income_statement v
    WHERE v.account_id IS NULL
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM src GROUP BY year, month, account_name, account_type, section
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
    SELECT
      EXTRACT(year  FROM je.entry_date)::int AS year,
      EXTRACT(month FROM je.entry_date)::int AS month,
      coa.account_name,
      coa.account_type::text AS account_type,
      INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' ')) AS section,
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
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name, coa.account_type, coa.account_subtype
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense')
      AND py.business_entity_id = ANY (SELECT id FROM descendants)
  ),
  combined AS (
    SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;

CREATE OR REPLACE FUNCTION public.get_pnl_history_own_only(p_entity_id uuid)
 RETURNS json LANGUAGE sql STABLE
AS $function$
  WITH post_cutover AS (
    SELECT
      EXTRACT(year  FROM je.entry_date)::int AS year,
      EXTRACT(month FROM je.entry_date)::int AS month,
      coa.account_name,
      coa.account_type::text AS account_type,
      INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' ')) AS section,
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
    GROUP BY je.entry_date, je.source, coa.id, coa.account_name, coa.account_type, coa.account_subtype
  ),
  pre_cutover AS (
    SELECT py.period_year AS year, py.period_month AS month, py.account_name,
           LOWER(py.section_type) AS account_type, COALESCE(py.section, 'Uncategorized') AS section, py.amount
    FROM public.prior_year_pl py
    WHERE LOWER(py.section_type) IN ('income','expense') AND py.business_entity_id = p_entity_id
  ),
  combined AS (
    SELECT * FROM post_cutover UNION ALL SELECT * FROM pre_cutover
  )
  SELECT COALESCE(json_agg(t ORDER BY t.year, t.month, t.account_type, t.section, t.account_name), '[]'::json)
  FROM (
    SELECT year, month, account_name, account_type, section, SUM(amount)::numeric AS amount
    FROM combined GROUP BY year, month, account_name, account_type, section
  ) t;
$function$;

CREATE OR REPLACE FUNCTION public.pnl_drill_transactions(
  p_entity_id uuid, p_account_name text, p_section text, p_account_type text,
  p_from_date date, p_to_date date
)
 RETURNS TABLE(source text, je_id uuid, line_id uuid, pyp_id uuid, entry_date date, amount numeric,
               description text, memo text, reference_number text, je_source text,
               classification_status text, account_id uuid, account_code text, account_name text,
               document_id uuid, created_at timestamptz)
 LANGUAGE sql STABLE
AS $function$
  WITH journal_side AS (
    SELECT
      'journal'::text AS source, je.id AS je_id, jl.id AS line_id, NULL::uuid AS pyp_id, je.entry_date,
      CASE
        WHEN coa.account_type = 'income'  AND je.source LIKE 'historical_import%' THEN COALESCE(jl.debit,0) - COALESCE(jl.credit,0)
        WHEN coa.account_type = 'income'  THEN COALESCE(jl.credit,0) - COALESCE(jl.debit,0)
        WHEN coa.account_type = 'expense' THEN COALESCE(jl.debit,0) - COALESCE(jl.credit,0)
        ELSE 0
      END AS amount,
      COALESCE(jl.description, je.description) AS description, je.memo, je.reference_number,
      je.source AS je_source, je.classification_status,
      coa.id AS account_id, coa.account_code, coa.account_name,
      je.document_id, je.created_at
    FROM public.journal_lines jl
    JOIN public.journal_entries je   ON je.id  = jl.journal_entry_id
    JOIN public.chart_of_accounts coa ON coa.id = jl.account_id
    WHERE je.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND coa.business_entity_id = p_entity_id
      AND coa.account_type = p_account_type
      AND coa.account_name = p_account_name
      AND INITCAP(REPLACE(COALESCE(coa.account_subtype, coa.account_type::text), '_', ' ')) = p_section
      AND je.entry_date BETWEEN p_from_date AND p_to_date
  ),
  pyp_side AS (
    SELECT
      'prior_year_pl'::text, NULL::uuid, NULL::uuid, py.id,
      COALESCE(py.period_start, make_date(py.period_year, py.period_month, 1)),
      py.amount, NULL::text, NULL::text, NULL::text, 'prior_year_pl_import'::text, NULL::text,
      NULL::uuid, NULL::text, py.account_name, py.source_document_id, py.imported_at
    FROM public.prior_year_pl py
    WHERE py.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
      AND py.business_entity_id = p_entity_id
      AND LOWER(py.section_type) = LOWER(p_account_type)
      AND py.account_name = p_account_name
      AND COALESCE(py.section, 'Uncategorized') = p_section
      AND make_date(py.period_year, py.period_month, 1) BETWEEN date_trunc('month', p_from_date)::date
                                                             AND date_trunc('month', p_to_date)::date
  )
  SELECT * FROM journal_side UNION ALL SELECT * FROM pyp_side
  ORDER BY entry_date DESC, created_at DESC;
$function$;

-- ============================================================
-- Ch6: compute_weekly_marketing_bonus — subtype-based scope
-- ============================================================
-- Old: WHERE coa.id = v_mktg_root_id OR coa.parent_account_id = v_mktg_root_id (single '0003 MARKETING' parent)
-- New: WHERE coa.account_subtype IN ('marketing','advertising')
--      Preserves ONLY expense-side accounts (marketing/advertising subtypes exist only on expense).

CREATE OR REPLACE FUNCTION public.compute_weekly_marketing_bonus(p_agency_id uuid, p_week_end_date date DEFAULT NULL::date)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_week_end DATE;
  v_quarter_start DATE;
  v_quarter_end DATE;
  v_weeks_in_qtd INT;
  v_pool_basis JSONB;
  v_total_basis NUMERIC;
  v_scorecard_ontime NUMERIC;
  v_basis_ex_scorecard NUMERIC;
  v_envelope_annual NUMERIC;
  v_envelope_quarterly NUMERIC;
  v_envelope_qtd NUMERIC;
  v_spend_qtd NUMERIC;
  v_underspend_qtd NUMERIC;
  v_total_bare_min_qtd NUMERIC;
  v_adjusted_underspend_qtd NUMERIC;
  v_pool_qtd NUMERIC;
  v_total_points_qtd NUMERIC;
  v_people JSONB;
  v_result JSONB;
BEGIN
  v_week_end := COALESCE(
    p_week_end_date,
    (CURRENT_DATE + ((6 - EXTRACT(DOW FROM CURRENT_DATE)::int + 7) % 7))::date
  );

  v_quarter_start := date_trunc('quarter', v_week_end::timestamp)::date;
  v_quarter_end   := (v_quarter_start + INTERVAL '3 months - 1 day')::date;
  v_weeks_in_qtd  := LEAST(13, CEIL(((v_week_end - v_quarter_start) + 1)::numeric / 7.0)::int);

  v_pool_basis         := public.compute_pool_basis_and_envelope(p_agency_id, v_week_end);
  v_total_basis        := COALESCE((v_pool_basis->'basis'->>'total_basis_annual')::numeric, 0);
  v_scorecard_ontime   := COALESCE((v_pool_basis->'basis'->>'on_time_scorecard_dollars')::numeric, 0);
  v_basis_ex_scorecard := v_total_basis - v_scorecard_ontime;

  v_envelope_annual    := ROUND(v_total_basis * 0.10, 2);
  v_envelope_quarterly := ROUND(v_envelope_annual / 4.0, 2);
  v_envelope_qtd       := ROUND(v_envelope_quarterly * v_weeks_in_qtd / 13.0, 2);

  -- Subtype-based scope (post-Phase-6). Includes 'marketing' and 'advertising'.
  SELECT COALESCE(SUM(jl.debit - jl.credit), 0)
  INTO v_spend_qtd
  FROM public.chart_of_accounts coa
  JOIN public.journal_lines   jl ON jl.account_id = coa.id
  JOIN public.journal_entries je ON je.id = jl.journal_entry_id
  WHERE coa.agency_id = p_agency_id
    AND coa.account_type = 'expense'
    AND coa.account_subtype IN ('marketing','advertising')
    AND coa.is_active = TRUE
    AND je.agency_id = p_agency_id
    AND je.entry_date >= v_quarter_start
    AND je.entry_date <= v_week_end;

  v_spend_qtd := ROUND(COALESCE(v_spend_qtd, 0), 2);
  v_underspend_qtd := GREATEST(0, v_envelope_qtd - v_spend_qtd);

  SELECT COALESCE(SUM(points), 0)
  INTO v_total_points_qtd
  FROM public.marketing_points
  WHERE agency_id = p_agency_id
    AND week_end_date >= v_quarter_start
    AND week_end_date <= v_week_end;

  v_total_bare_min_qtd := v_total_points_qtd;

  v_adjusted_underspend_qtd := GREATEST(0, v_underspend_qtd - v_total_bare_min_qtd);
  v_pool_qtd := ROUND(v_adjusted_underspend_qtd * 0.50, 2);

  WITH person_points AS (
    SELECT
      team_member_id,
      SUM(points)                  AS points_qtd,
      SUM(points_reviews)          AS reviews_qtd,
      SUM(points_referrals_quoted) AS quoted_qtd,
      SUM(points_referrals_sold)   AS sold_qtd,
      COALESCE(SUM(CASE WHEN week_end_date = v_week_end THEN points END), 0) AS points_this_week
    FROM public.marketing_points
    WHERE agency_id = p_agency_id
      AND week_end_date >= v_quarter_start
      AND week_end_date <= v_week_end
    GROUP BY team_member_id
  )
  SELECT jsonb_agg(
    jsonb_build_object(
      'team_member_id',      t.id,
      'name',                t.first_name || ' ' || COALESCE(t.last_name, ''),
      'points_qtd',          COALESCE(pp.points_qtd, 0),
      'points_this_week',    COALESCE(pp.points_this_week, 0),
      'reviews_qtd',         COALESCE(pp.reviews_qtd, 0),
      'quoted_qtd',          COALESCE(pp.quoted_qtd, 0),
      'sold_qtd',            COALESCE(pp.sold_qtd, 0),
      'bare_min_qtd',        COALESCE(pp.points_qtd, 0),
      'share_pct',           CASE WHEN v_total_points_qtd > 0
                                  THEN ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * 100.0, 2)
                                  ELSE 0 END,
      'bonus_share_qtd',     CASE WHEN v_total_points_qtd > 0
                                  THEN ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * v_pool_qtd, 2)
                                  ELSE 0 END,
      'total_marketing_qtd', CASE WHEN v_total_points_qtd > 0
                                  THEN COALESCE(pp.points_qtd, 0)
                                       + ROUND(COALESCE(pp.points_qtd, 0) / v_total_points_qtd * v_pool_qtd, 2)
                                  ELSE COALESCE(pp.points_qtd, 0) END
    )
    ORDER BY COALESCE(pp.points_qtd, 0) DESC, t.first_name
  )
  INTO v_people
  FROM public.team t
  LEFT JOIN person_points pp ON pp.team_member_id = t.id
  WHERE t.agency_id = p_agency_id
    AND t.is_active = true
    AND COALESCE(t.is_admin_backoffice, false) = false
    AND t.archived_at IS NULL
    AND COALESCE(t.is_test_user, false) = false
    AND (t.role_level IS NULL OR t.role_level != 'Owner')
    AND t.category = 'agency';

  v_result := jsonb_build_object(
    'agency_id',      p_agency_id,
    'week_end_date',  v_week_end,
    'quarter_start',  v_quarter_start,
    'quarter_end',    v_quarter_end,
    'weeks_in_qtd',   v_weeks_in_qtd,
    'basis', jsonb_build_object(
      'total_basis_annual',        v_total_basis,
      'scorecard_ontime_included', v_scorecard_ontime,
      'basis_ex_scorecard_annual', v_basis_ex_scorecard,
      'source', 'compute_pool_basis_and_envelope total_basis_annual (Scorecard included per 2026-07-12 directive; AIPP not in basis)'
    ),
    'envelope', jsonb_build_object(
      'annual',       v_envelope_annual,
      'quarterly',    v_envelope_quarterly,
      'qtd_target',   v_envelope_qtd,
      'pct_of_basis', 0.10
    ),
    'spend', jsonb_build_object(
      'qtd',              v_spend_qtd,
      'scope',            'account_subtype IN (marketing, advertising)',
      'source',           'sum(debit - credit) on active expense COAs with marketing/advertising subtype (QTD)'
    ),
    'pool', jsonb_build_object(
      'underspend_qtd',          v_underspend_qtd,
      'total_bare_min_qtd',      v_total_bare_min_qtd,
      'adjusted_underspend_qtd', v_adjusted_underspend_qtd,
      'team_share_pct',          0.50,
      'pool_qtd',                v_pool_qtd,
      'total_points_qtd',        v_total_points_qtd
    ),
    'people',       COALESCE(v_people, '[]'::jsonb),
    'computed_at',  NOW()
  );

  RETURN v_result;
END;
$function$;
