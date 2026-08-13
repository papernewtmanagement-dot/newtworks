-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 22:31:50 UTC (ledger name: pfa_column_name_fixes_and_ela_backfill) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709223150.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- FIX 1: pfa_monthly_nag used wrong column names against pfa_bank_statements.
--        The table has pfa_account_id (not agency_id) and statement_period_end
--        (not statement_ending_date). Recompute via pfa_accounts join.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.pfa_monthly_nag(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_stmt_end_date     date := (date_trunc('month', current_date) - interval '1 day')::date;
  v_month_key         text := to_char(v_stmt_end_date, 'YYYY-MM');
  v_month_name        text := to_char(v_stmt_end_date, 'FMMonth YYYY');
  v_mod_ref           text := 'pfa_statement_ingest:' || v_month_key;
  v_due_date          date := (date_trunc('month', current_date) + interval '9 days')::date;
  v_pfa_account_id    uuid;
  v_existing_alert_id uuid;
  v_statement_id      uuid;
  v_peter_tg          bigint;
  v_tg_resp           jsonb;
  v_dm_text           text;
  v_action_taken      text;
BEGIN
  SELECT ttm.telegram_user_id INTO v_peter_tg
  FROM public.team_telegram_map ttm
  JOIN public.team t ON t.id = ttm.team_id
  WHERE t.first_name='Peter' AND t.last_name='Story' LIMIT 1;
  v_peter_tg := COALESCE(v_peter_tg, 7778113542);

  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = p_agency_id AND is_active = true
  LIMIT 1;

  IF v_pfa_account_id IS NULL THEN
    RETURN jsonb_build_object('records_processed', 0,
      'output_summary', 'No active PFA account for agency; skipping.');
  END IF;

  -- Fixed: query by pfa_account_id + statement_period_end
  SELECT id INTO v_statement_id
  FROM public.pfa_bank_statements
  WHERE pfa_account_id = v_pfa_account_id
    AND statement_period_end = v_stmt_end_date
  LIMIT 1;

  SELECT id INTO v_existing_alert_id
  FROM public.alerts
  WHERE agency_id = p_agency_id
    AND module_reference = v_mod_ref
    AND COALESCE(is_resolved, false) = false
  LIMIT 1;

  IF v_statement_id IS NOT NULL THEN
    IF v_existing_alert_id IS NOT NULL THEN
      UPDATE public.alerts
      SET is_resolved = true, resolved_at = now()
      WHERE id = v_existing_alert_id;
      RETURN jsonb_build_object(
        'records_processed', 1,
        'output_summary', format('Statement %s ingested; alert auto-resolved.', v_month_key),
        'month', v_month_key, 'statement_id', v_statement_id
      );
    END IF;
    RETURN jsonb_build_object(
      'records_processed', 0,
      'output_summary', format('Statement %s ingested; no alert to resolve.', v_month_key)
    );
  END IF;

  IF v_existing_alert_id IS NULL THEN
    IF extract(day from current_date) <= 10 THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, due_date, created_at)
      VALUES (p_agency_id, 'pfa_statement_ingest', 'warning',
        format('Send Frost PFA statement for %s', v_month_name),
        format('Forward the Frost Bank PFA statement PDF for %s to paper.newt.management@gmail.com. Newtworks will auto-reconcile and email SF. This alert auto-resolves when the statement lands.', v_month_name),
        v_mod_ref, false, false, v_due_date, now());
      v_action_taken := 'alert_created_and_dm_sent';
    ELSE
      RETURN jsonb_build_object('records_processed', 0,
        'output_summary', format('No statement for %s and past day 10; skipping.', v_month_key));
    END IF;
  ELSE
    v_action_taken := 'dm_resent';
  END IF;

  v_dm_text := format(
    E'📄 PFA statement reminder\n\nThe Frost Bank PFA statement for %s hasn''t been received yet. Forward the statement PDF to paper.newt.management@gmail.com.\n\nOnce ingested, Newtworks auto-reconciles and emails the printout to SF. This alert auto-resolves when the statement lands.',
    v_month_name);
  v_tg_resp := public.telegram_send_message_v2(v_peter_tg, v_dm_text, 'paper_newt');

  RETURN jsonb_build_object(
    'records_processed', 1,
    'output_summary', format('%s for PFA statement %s. Telegram DM ok=%s',
      v_action_taken, v_month_key, COALESCE((v_tg_resp->>'ok')::text, 'unknown')),
    'month', v_month_key, 'due_date', v_due_date, 'telegram_response', v_tg_resp
  );
END;
$function$;

-- ============================================================================
-- FIX 2: Backfill the July 2 Ela U. deposit (predates Newtworks PFA — real
--        deposit that happened, needs a ledger row so the July recon works).
--        Attributed to Peter as prepared_by. Deposit + paired State Farm EFT.
-- ============================================================================
DO $$
DECLARE
  v_pfa_account_id uuid;
  v_peter_team_id  uuid;
  v_deposit_id     uuid;
  v_eft_id         uuid;
BEGIN
  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND is_active = true
  LIMIT 1;

  SELECT id INTO v_peter_team_id
  FROM public.team
  WHERE first_name = 'Peter' AND last_name = 'Story'
    AND archived_at IS NULL
  LIMIT 1;

  -- Skip if already present (idempotent)
  IF EXISTS (
    SELECT 1 FROM public.pfa_transactions
    WHERE pfa_account_id = v_pfa_account_id
      AND transaction_date = '2026-07-02'
      AND transaction_number = '593978'
      AND customer_name = 'Ela U.'
  ) THEN
    RAISE NOTICE 'Ela U. 7/2 deposit already exists; skipping.';
    RETURN;
  END IF;

  INSERT INTO public.pfa_transactions (
    pfa_account_id, transaction_date, transaction_type, transaction_number,
    debit_amount, credit_amount, cleared,
    customer_name, policy_type,
    prepared_by_team_member_id, imported_from_excel, notes
  ) VALUES (
    v_pfa_account_id, '2026-07-02', 'Deposit', '593978',
    NULL, 896.20, false,
    'Ela U.', 'fire',
    v_peter_team_id, false,
    'Backfilled 2026-07-09 — predates Newtworks PFA rollout.'
  )
  RETURNING id INTO v_deposit_id;

  INSERT INTO public.pfa_transactions (
    pfa_account_id, transaction_date, transaction_type,
    debit_amount, credit_amount, cleared,
    customer_name, policy_type,
    prepared_by_team_member_id, imported_from_excel, notes
  ) VALUES (
    v_pfa_account_id, '2026-07-02', 'State Farm EFT',
    896.20, NULL, false,
    'Ela U.', 'fire',
    v_peter_team_id, false,
    'Backfilled 2026-07-09 — paired with deposit ' || v_deposit_id
  )
  RETURNING id INTO v_eft_id;

  RAISE NOTICE 'Backfilled Ela U. deposit % + EFT %', v_deposit_id, v_eft_id;
END $$;

-- Show what got inserted for confirmation
SELECT id, transaction_date, transaction_type, customer_name,
       policy_type, debit_amount, credit_amount, transaction_number,
       (prepared_by_team_member_id IS NOT NULL) AS has_preparer
FROM public.pfa_transactions
WHERE transaction_date = '2026-07-02'
  AND customer_name = 'Ela U.'
ORDER BY transaction_type;
