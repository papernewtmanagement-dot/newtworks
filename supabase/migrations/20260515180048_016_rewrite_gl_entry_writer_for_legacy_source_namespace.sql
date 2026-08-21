-- =========================================================================
-- gl_entry_writer — rewrite for books_historical namespace + cutover gating
-- =========================================================================
-- Changes from the original (migration 011):
--   1. All chart_of_accounts lookups now filter by chart_namespace 
--      (reads gl_chart_namespace from settings; defaults to 'books_historical')
--   2. Account resolution by account_name not account_code (books_historical codes are
--      opaque COA-NNN strings; names like "4005 State Farm" survive Task 3
--      sub-account expansion)
--   3. Cutover gate: skips any comp_recap row where the resolved entry_date
--      is before gl_cutover_date (default 2026-05-01)
--   4. Sub-account-aware revenue lookup: tries "<parent>:<comp_category>"
--      first (e.g. "4005 State Farm:01 - P&C - NEW"), falls back to parent
--      "4005 State Farm" if no sub-account exists yet. This means it works
--      today (with only the parent in the chart) AND keeps working after
--      Task 3 adds sub-accounts — no second pass needed.
--   5. Skipped rows are counted and reported so the run log explains WHY
--      nothing posted on a given run.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.gl_entry_writer(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_count             INTEGER := 0;
  v_skipped_cutover   INTEGER := 0;
  v_skipped_no_acct   INTEGER := 0;
  v_unposted          RECORD;
  v_revenue_acct_id   UUID;
  v_cash_acct_id      UUID;
  v_namespace         TEXT;
  v_cutover_date      DATE;
  v_cash_acct_name    TEXT;
  v_sf_parent_name    TEXT;
  v_entry_date        DATE;
  v_revenue_acct_name TEXT;
  v_entry_id          UUID;
  v_now               TIMESTAMPTZ := NOW();
BEGIN
  -- ---------------------------------------------------------------------
  -- Read config from settings (with sane defaults if any key is missing)
  -- ---------------------------------------------------------------------
  SELECT setting_value INTO v_namespace
    FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'gl_chart_namespace'
   LIMIT 1;
  IF v_namespace IS NULL THEN v_namespace := 'books_historical'; END IF;

  SELECT setting_value::date INTO v_cutover_date
    FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'gl_cutover_date'
   LIMIT 1;
  IF v_cutover_date IS NULL THEN v_cutover_date := DATE '2026-05-01'; END IF;

  SELECT setting_value INTO v_cash_acct_name
    FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'gl_default_cash_account_name'
   LIMIT 1;
  IF v_cash_acct_name IS NULL THEN v_cash_acct_name := 'US Bank - Income'; END IF;

  SELECT setting_value INTO v_sf_parent_name
    FROM public.settings
   WHERE agency_id = p_agency_id AND setting_key = 'gl_default_sf_revenue_account_name'
   LIMIT 1;
  IF v_sf_parent_name IS NULL THEN v_sf_parent_name := '4005 State Farm'; END IF;

  -- ---------------------------------------------------------------------
  -- Resolve the cash-side account once (it's the same for every comp row)
  -- ---------------------------------------------------------------------
  SELECT id INTO v_cash_acct_id
    FROM public.chart_of_accounts
   WHERE agency_id = p_agency_id
     AND chart_namespace = v_namespace
     AND account_name = v_cash_acct_name
   LIMIT 1;

  IF v_cash_acct_id IS NULL THEN
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary',
      'Aborted: chart_of_accounts has no account_name=' || v_cash_acct_name ||
      ' in chart_namespace=' || v_namespace
    );
  END IF;

  -- ---------------------------------------------------------------------
  -- Walk unposted comp_recap rows
  -- ---------------------------------------------------------------------
  FOR v_unposted IN
    SELECT id, period_year, period_month, comp_type, comp_category, amount,
           description, is_aipp_eligible, is_scoreboard_eligible
      FROM public.comp_recap
     WHERE agency_id = p_agency_id
       AND posted_at IS NULL
       AND amount IS NOT NULL AND amount != 0
       AND period_year IS NOT NULL AND period_month IS NOT NULL
     ORDER BY period_year, period_month, id
     LIMIT 500
  LOOP
    v_entry_date := MAKE_DATE(v_unposted.period_year, v_unposted.period_month, 1);

    -- CUTOVER GATE: pre-cutover comp_recap rows live for audit/archive
    -- but never become journal entries. Document-archive rule in
    -- persistent_memory.accounting_rules.
    IF v_entry_date < v_cutover_date THEN
      UPDATE public.comp_recap
         SET posted_at = v_now,
             notes = COALESCE(notes, '') || ' [pre-cutover archive — not posted to GL]'
       WHERE id = v_unposted.id;
      v_skipped_cutover := v_skipped_cutover + 1;
      CONTINUE;
    END IF;

    -- Revenue account: try sub-account first (parent:category), fall back to parent.
    -- Once Task 3 inserts sub-accounts, the first lookup will hit.
    -- Until then, the fallback to "4005 State Farm" keeps us functional.
    v_revenue_acct_id := NULL;

    IF v_unposted.comp_category IS NOT NULL AND length(trim(v_unposted.comp_category)) > 0 THEN
      v_revenue_acct_name := v_sf_parent_name || ':' || v_unposted.comp_category;
      SELECT id INTO v_revenue_acct_id
        FROM public.chart_of_accounts
       WHERE agency_id = p_agency_id
         AND chart_namespace = v_namespace
         AND account_name = v_revenue_acct_name
       LIMIT 1;
    END IF;

    -- Fallback: parent account
    IF v_revenue_acct_id IS NULL THEN
      SELECT id INTO v_revenue_acct_id
        FROM public.chart_of_accounts
       WHERE agency_id = p_agency_id
         AND chart_namespace = v_namespace
         AND account_name = v_sf_parent_name
       LIMIT 1;
      v_revenue_acct_name := v_sf_parent_name;
    END IF;

    IF v_revenue_acct_id IS NULL THEN
      v_skipped_no_acct := v_skipped_no_acct + 1;
      CONTINUE;  -- leave posted_at NULL so a fix can retry this row later
    END IF;

    -- Post the journal entry — both sides resolved, no COA-SUSP
    INSERT INTO public.journal_entries (
      agency_id, entry_date, entry_type, source, description, created_by, created_at
    )
    VALUES (
      p_agency_id,
      v_entry_date,
      'comp_revenue',
      'gl_entry_writer',
      COALESCE(v_unposted.description,
               COALESCE(v_unposted.comp_type, '') || ' ' || COALESCE(v_unposted.comp_category, '')),
      'gl_entry_writer',
      v_now
    )
    RETURNING id INTO v_entry_id;

    UPDATE public.journal_entries
       SET reference_number = 'comp_recap:' || v_unposted.id::text
     WHERE id = v_entry_id;

    INSERT INTO public.journal_lines (
      journal_entry_id, agency_id, account_id, debit, credit, description, created_at
    ) VALUES
      (v_entry_id, p_agency_id, v_cash_acct_id, v_unposted.amount, 0,
       'Cash receipt: ' || COALESCE(v_unposted.comp_category, v_unposted.comp_type, ''),
       v_now),
      (v_entry_id, p_agency_id, v_revenue_acct_id, 0, v_unposted.amount,
       v_revenue_acct_name,
       v_now);

    UPDATE public.comp_recap SET posted_at = v_now WHERE id = v_unposted.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'records_processed', v_count,
    'output_summary',
    v_count || ' journal entries posted; ' ||
    v_skipped_cutover || ' pre-cutover rows archived (not posted); ' ||
    v_skipped_no_acct || ' rows skipped (no matching revenue account in ' || v_namespace || ' namespace)'
  );
END;
$function$;
