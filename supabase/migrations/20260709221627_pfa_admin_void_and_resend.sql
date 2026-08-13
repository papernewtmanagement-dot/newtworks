-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 22:16:27 UTC (ledger name: pfa_admin_void_and_resend) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709221627.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- PFA admin: soft-void deposits + resend failed close Telegram
-- ============================================================================

-- 1) Void columns on pfa_transactions (soft-delete pattern; keeps audit trail)
ALTER TABLE public.pfa_transactions
  ADD COLUMN IF NOT EXISTS voided_at         timestamptz,
  ADD COLUMN IF NOT EXISTS voided_by_team_id uuid REFERENCES public.team(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS void_reason       text;

CREATE INDEX IF NOT EXISTS pfa_transactions_voided_idx
  ON public.pfa_transactions (pfa_account_id, voided_at) WHERE voided_at IS NOT NULL;

COMMENT ON COLUMN public.pfa_transactions.voided_at IS 'Non-null = row is voided (soft delete). Excluded from ledger totals, running balance, and reconciliation.';

-- 2) Void RPC — owner/manager only. Voids the Deposit row AND its paired State Farm EFT.
CREATE OR REPLACE FUNCTION public.pfa_void_deposit(
  p_deposit_id uuid,
  p_reason     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid       uuid;
  v_agency_id      uuid;
  v_team_id        uuid;
  v_role           text;
  v_deposit        record;
  v_eft_id         uuid;
  v_reason_clean   text;
  v_voided_ids     uuid[] := ARRAY[]::uuid[];
BEGIN
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Owner/manager only
  SELECT u.agency_id, u.role INTO v_agency_id, v_role
  FROM public.users u
  WHERE u.auth_user_id = v_auth_uid;
  IF v_role NOT IN ('owner','manager') THEN
    RAISE EXCEPTION 'only owner or manager can void a deposit' USING ERRCODE = '42501';
  END IF;

  -- Look up the caller's team row (for audit trail)
  SELECT t.id INTO v_team_id
  FROM public.team t
  WHERE t.user_id = (SELECT id FROM public.users WHERE auth_user_id = v_auth_uid)
    AND t.archived_at IS NULL
  LIMIT 1;

  v_reason_clean := btrim(COALESCE(p_reason, ''));
  IF length(v_reason_clean) < 3 THEN
    RAISE EXCEPTION 'void reason is required (min 3 chars)';
  END IF;
  IF length(v_reason_clean) > 500 THEN
    RAISE EXCEPTION 'void reason too long (max 500 chars)';
  END IF;

  -- Load the deposit row + verify agency + not already voided + not cleared
  SELECT
    t.id, t.pfa_account_id, t.transaction_date, t.transaction_type,
    t.credit_amount, t.cleared, t.voided_at, t.customer_name,
    a.agency_id
  INTO v_deposit
  FROM public.pfa_transactions t
  JOIN public.pfa_accounts a ON a.id = t.pfa_account_id
  WHERE t.id = p_deposit_id;

  IF v_deposit.id IS NULL THEN
    RAISE EXCEPTION 'deposit not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_deposit.agency_id <> v_agency_id THEN
    RAISE EXCEPTION 'not authorized for this deposit' USING ERRCODE = '42501';
  END IF;
  IF v_deposit.transaction_type <> 'Deposit' THEN
    RAISE EXCEPTION 'row is not a Deposit (type=%)', v_deposit.transaction_type USING ERRCODE = 'P0001';
  END IF;
  IF v_deposit.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'deposit already voided' USING ERRCODE = 'P0001';
  END IF;
  IF v_deposit.cleared THEN
    RAISE EXCEPTION 'cannot void a deposit that has already cleared the bank' USING ERRCODE = 'P0001';
  END IF;

  -- Also block voiding a row from a day that's already closed (would invalidate the close total)
  IF EXISTS (
    SELECT 1 FROM public.pfa_daily_closes
    WHERE agency_id = v_agency_id
      AND pfa_account_id = v_deposit.pfa_account_id
      AND close_date = v_deposit.transaction_date
  ) THEN
    RAISE EXCEPTION 'cannot void a deposit from a day that has already been closed' USING ERRCODE = 'P0001';
  END IF;

  -- Find the paired State Farm EFT row (same account, same date, same amount, uncleared, not voided)
  SELECT id INTO v_eft_id
  FROM public.pfa_transactions
  WHERE pfa_account_id = v_deposit.pfa_account_id
    AND transaction_date = v_deposit.transaction_date
    AND transaction_type = 'State Farm EFT'
    AND debit_amount = v_deposit.credit_amount
    AND cleared = false
    AND voided_at IS NULL
    AND customer_name = v_deposit.customer_name
    AND id <> v_deposit.id
  ORDER BY created_at
  LIMIT 1;

  -- Void the deposit row
  UPDATE public.pfa_transactions
  SET voided_at = now(), voided_by_team_id = v_team_id, void_reason = v_reason_clean
  WHERE id = v_deposit.id;
  v_voided_ids := array_append(v_voided_ids, v_deposit.id);

  -- Void its paired EFT if we found one
  IF v_eft_id IS NOT NULL THEN
    UPDATE public.pfa_transactions
    SET voided_at = now(), voided_by_team_id = v_team_id, void_reason = v_reason_clean
    WHERE id = v_eft_id;
    v_voided_ids := array_append(v_voided_ids, v_eft_id);
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'voided_ids', v_voided_ids,
    'paired_eft_found', v_eft_id IS NOT NULL,
    'deposit_id', v_deposit.id,
    'eft_id', v_eft_id,
    'reason', v_reason_clean
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_void_deposit(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_void_deposit(uuid, text) TO authenticated;

COMMENT ON FUNCTION public.pfa_void_deposit IS 'Owner/manager only. Soft-voids a Deposit + its paired State Farm EFT. Refuses if cleared, already voided, or from a closed day. Void reason is required.';


-- 3) Resend Telegram RPC for a close row whose original Telegram send failed
CREATE OR REPLACE FUNCTION public.pfa_resend_close_telegram(p_close_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid          uuid;
  v_agency_id         uuid;
  v_role              text;
  v_close             record;
  v_first_name        text;
  v_chat_id           bigint;
  v_line_items        text := '';
  v_row               record;
  v_msg               text;
  v_tg_resp           jsonb;
  v_tg_ok             boolean := false;
  v_tg_msg_id         bigint;
  v_tg_error          text;
BEGIN
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT u.agency_id, u.role INTO v_agency_id, v_role
  FROM public.users u
  WHERE u.auth_user_id = v_auth_uid;
  IF v_role NOT IN ('owner','manager') THEN
    RAISE EXCEPTION 'only owner or manager can resend close notifications' USING ERRCODE = '42501';
  END IF;

  SELECT
    dc.id, dc.agency_id, dc.close_date, dc.deposit_ids,
    dc.deposit_count, dc.total_amount, dc.telegram_send_ok,
    tm.first_name AS closed_by
  INTO v_close
  FROM public.pfa_daily_closes dc
  LEFT JOIN public.team tm ON tm.id = dc.closed_by_team_member_id
  WHERE dc.id = p_close_id;

  IF v_close.id IS NULL THEN
    RAISE EXCEPTION 'close not found' USING ERRCODE = 'P0001';
  END IF;
  IF v_close.agency_id <> v_agency_id THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  v_first_name := COALESCE(v_close.closed_by, 'team member');

  -- Rebuild the per-line message
  FOR v_row IN
    SELECT customer_name, policy_type, credit_amount, transaction_number
    FROM public.pfa_transactions
    WHERE id = ANY(v_close.deposit_ids)
    ORDER BY created_at
  LOOP
    v_line_items := v_line_items
      || E'\n• $' || trim(to_char(v_row.credit_amount, 'FM999,999,990.00'))
      || ' · ' || v_row.customer_name
      || ' · ' || initcap(v_row.policy_type)
      || CASE WHEN v_row.transaction_number IS NOT NULL AND btrim(v_row.transaction_number) <> ''
              THEN ' · #' || v_row.transaction_number ELSE '' END;
  END LOOP;

  v_msg := E'📋 PFA deposits closed for ' || to_char(v_close.close_date, 'FMDy FMMon FMDD')
    || ' (resend)'
    || v_line_items
    || E'\n\nTotal: $' || trim(to_char(v_close.total_amount, 'FM999,999,990.00'))
    || ' across ' || v_close.deposit_count || ' deposit' || CASE WHEN v_close.deposit_count = 1 THEN '' ELSE 's' END || '.'
    || E'\nReady for the SF-side final deposit — cross-check against $' || trim(to_char(v_close.total_amount, 'FM999,999,990.00')) || '.'
    || E'\n\n— ' || v_first_name;

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = v_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_chat_id IS NULL THEN
    RAISE EXCEPTION 'telegram_team_group_chat_id not set';
  END IF;

  BEGIN
    v_tg_resp := public.telegram_send_message_v2(v_chat_id, v_msg, 'pjsagency');
    v_tg_ok := COALESCE((v_tg_resp->>'ok')::boolean, false);
    IF v_tg_ok THEN
      v_tg_msg_id := (v_tg_resp->'result'->>'message_id')::bigint;
    ELSE
      v_tg_error := COALESCE(v_tg_resp->>'error', v_tg_resp::text);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_tg_ok := false;
    v_tg_error := SQLERRM;
  END;

  UPDATE public.pfa_daily_closes
  SET telegram_message_id = v_tg_msg_id,
      telegram_send_ok    = v_tg_ok,
      telegram_send_error = v_tg_error
  WHERE id = v_close.id;

  RETURN jsonb_build_object(
    'ok', v_tg_ok,
    'close_id', v_close.id,
    'telegram_message_id', v_tg_msg_id,
    'telegram_send_error', v_tg_error
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_resend_close_telegram(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_resend_close_telegram(uuid) TO authenticated;
