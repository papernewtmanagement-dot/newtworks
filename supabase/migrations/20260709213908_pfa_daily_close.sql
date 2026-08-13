-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-09 21:39:08 UTC (ledger name: pfa_daily_close) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260709213908.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ============================================================================
-- PFA Daily Close: team-facing "I'm done for today" button
--
-- One person per day (usually the retention lead) presses Close Day after
-- entering every deposit. Fires a Telegram summary to the team group and
-- LOCKS pfa_record_customer_deposit for the rest of the day.
-- ============================================================================

-- 1) pfa_daily_closes table
CREATE TABLE IF NOT EXISTS public.pfa_daily_closes (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id                 uuid NOT NULL,
  pfa_account_id            uuid NOT NULL REFERENCES public.pfa_accounts(id) ON DELETE RESTRICT,
  close_date                date NOT NULL,
  closed_by_team_member_id  uuid NOT NULL REFERENCES public.team(id) ON DELETE RESTRICT,
  deposit_count             integer NOT NULL CHECK (deposit_count > 0),
  total_amount              numeric(12,2) NOT NULL CHECK (total_amount > 0),
  deposit_ids               uuid[] NOT NULL,
  telegram_message_id       bigint,
  telegram_send_ok          boolean NOT NULL DEFAULT false,
  telegram_send_error       text,
  closed_at                 timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT pfa_daily_closes_one_per_day UNIQUE (agency_id, pfa_account_id, close_date)
);

CREATE INDEX IF NOT EXISTS pfa_daily_closes_agency_date_idx
  ON public.pfa_daily_closes (agency_id, close_date DESC);

ALTER TABLE public.pfa_daily_closes ENABLE ROW LEVEL SECURITY;

-- Admin-only reads (same pattern as the other pfa_* tables — team members
-- see the close through the summary RPC, not by SELECTing this table).
DROP POLICY IF EXISTS pfa_admin_only_closes ON public.pfa_daily_closes;
CREATE POLICY pfa_admin_only_closes ON public.pfa_daily_closes
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = pfa_daily_closes.agency_id)
  )
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.users u
      WHERE u.auth_user_id = auth.uid()
        AND u.role IN ('owner','manager')
        AND u.agency_id = pfa_daily_closes.agency_id)
  );

COMMENT ON TABLE public.pfa_daily_closes IS 'One row per team-pressed "Close Day" event. Locks further PFA deposit entries for that CT date and records the summary Telegram send.';


-- 2) Today-summary RPC — team-callable (SECURITY DEFINER). Returns today's
--    deposits (in CT) for the caller's agency, plus whether the day is closed.
CREATE OR REPLACE FUNCTION public.pfa_today_summary()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid       uuid;
  v_team_id        uuid;
  v_agency_id      uuid;
  v_pfa_account_id uuid;
  v_today          date;
  v_close_row      record;
  v_deposits       jsonb;
  v_total          numeric := 0;
  v_count          integer := 0;
BEGIN
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT t.id, t.agency_id
    INTO v_team_id, v_agency_id
  FROM public.team t
  JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = v_auth_uid
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false;
  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'no active team member for authenticated user' USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = v_agency_id AND is_active = true
  LIMIT 1;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;

  -- Is the day already closed?
  SELECT
    dc.id, dc.deposit_count, dc.total_amount, dc.closed_at,
    dc.telegram_send_ok, dc.telegram_send_error,
    tm.first_name AS closed_by_first_name
  INTO v_close_row
  FROM public.pfa_daily_closes dc
  LEFT JOIN public.team tm ON tm.id = dc.closed_by_team_member_id
  WHERE dc.agency_id = v_agency_id
    AND dc.pfa_account_id = v_pfa_account_id
    AND dc.close_date = v_today
  LIMIT 1;

  -- Today's Deposit rows (paired SF EFT rows excluded — we want customer-side entries)
  SELECT
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', t.id,
        'customer_name', t.customer_name,
        'policy_type', t.policy_type,
        'amount', t.credit_amount,
        'check_number', t.transaction_number,
        'entered_at', t.created_at,
        'entered_by', tm.first_name
      )
      ORDER BY t.created_at
    ), '[]'::jsonb),
    COALESCE(SUM(t.credit_amount), 0),
    COALESCE(COUNT(*), 0)
  INTO v_deposits, v_total, v_count
  FROM public.pfa_transactions t
  LEFT JOIN public.team tm ON tm.id = t.prepared_by_team_member_id
  WHERE t.pfa_account_id = v_pfa_account_id
    AND t.transaction_date = v_today
    AND t.transaction_type = 'Deposit'
    AND t.imported_from_excel = false
    AND t.prepared_by_team_member_id IS NOT NULL;

  RETURN jsonb_build_object(
    'today',           v_today,
    'day_closed',      (v_close_row.id IS NOT NULL),
    'close', CASE WHEN v_close_row.id IS NOT NULL THEN
      jsonb_build_object(
        'id', v_close_row.id,
        'deposit_count', v_close_row.deposit_count,
        'total_amount', v_close_row.total_amount,
        'closed_at', v_close_row.closed_at,
        'closed_by', v_close_row.closed_by_first_name,
        'telegram_send_ok', v_close_row.telegram_send_ok,
        'telegram_send_error', v_close_row.telegram_send_error
      )
      ELSE NULL END,
    'deposits',        v_deposits,
    'deposit_count',   v_count,
    'total_amount',    v_total
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_today_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_today_summary() TO authenticated;


-- 3) Close-day RPC. Team-callable.
CREATE OR REPLACE FUNCTION public.pfa_close_day()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid          uuid;
  v_team_id           uuid;
  v_agency_id         uuid;
  v_first_name        text;
  v_pfa_account_id    uuid;
  v_today             date;
  v_today_label       text;
  v_deposit_ids       uuid[];
  v_deposit_count     int;
  v_total             numeric := 0;
  v_close_id          uuid;
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

  SELECT t.id, t.agency_id, t.first_name
    INTO v_team_id, v_agency_id, v_first_name
  FROM public.team t
  JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = v_auth_uid
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false;
  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'no active team member for authenticated user' USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = v_agency_id AND is_active = true
  LIMIT 1;
  IF v_pfa_account_id IS NULL THEN
    RAISE EXCEPTION 'no active PFA account for agency %', v_agency_id;
  END IF;

  v_today := (now() AT TIME ZONE 'America/Chicago')::date;
  v_today_label := to_char(v_today, 'FMDy FMMon FMDD');  -- "Thu Jul 9"

  -- Reject if already closed (also enforced by UNIQUE constraint, but this is a clearer error).
  IF EXISTS (
    SELECT 1 FROM public.pfa_daily_closes
    WHERE agency_id = v_agency_id AND pfa_account_id = v_pfa_account_id AND close_date = v_today
  ) THEN
    RAISE EXCEPTION 'day already closed' USING ERRCODE = 'P0001';
  END IF;

  -- Collect today's Deposit rows
  SELECT
    COALESCE(array_agg(t.id ORDER BY t.created_at), ARRAY[]::uuid[]),
    COALESCE(SUM(t.credit_amount), 0),
    COALESCE(COUNT(*), 0)
  INTO v_deposit_ids, v_total, v_deposit_count
  FROM public.pfa_transactions t
  WHERE t.pfa_account_id = v_pfa_account_id
    AND t.transaction_date = v_today
    AND t.transaction_type = 'Deposit'
    AND t.imported_from_excel = false
    AND t.prepared_by_team_member_id IS NOT NULL;

  IF v_deposit_count = 0 THEN
    RAISE EXCEPTION 'no deposits to close for today' USING ERRCODE = 'P0001';
  END IF;

  -- Insert the close row FIRST (source of truth even if Telegram later fails)
  INSERT INTO public.pfa_daily_closes (
    agency_id, pfa_account_id, close_date, closed_by_team_member_id,
    deposit_count, total_amount, deposit_ids
  ) VALUES (
    v_agency_id, v_pfa_account_id, v_today, v_team_id,
    v_deposit_count, v_total, v_deposit_ids
  )
  RETURNING id INTO v_close_id;

  -- Build the per-line message body (one line per deposit)
  FOR v_row IN
    SELECT
      customer_name, policy_type, credit_amount, transaction_number
    FROM public.pfa_transactions
    WHERE id = ANY(v_deposit_ids)
    ORDER BY created_at
  LOOP
    v_line_items := v_line_items
      || E'\n• $' || trim(to_char(v_row.credit_amount, 'FM999,999,990.00'))
      || ' · ' || v_row.customer_name
      || ' · ' || initcap(v_row.policy_type)
      || CASE WHEN v_row.transaction_number IS NOT NULL AND btrim(v_row.transaction_number) <> ''
              THEN ' · #' || v_row.transaction_number ELSE '' END;
  END LOOP;

  v_msg := E'📋 PFA deposits closed for today (' || v_today_label || E')'
    || v_line_items
    || E'\n\nTotal: $' || trim(to_char(v_total, 'FM999,999,990.00'))
    || ' across ' || v_deposit_count || ' deposit' || CASE WHEN v_deposit_count = 1 THEN '' ELSE 's' END || '.'
    || E'\nReady for the SF-side final deposit — cross-check against $' || trim(to_char(v_total, 'FM999,999,990.00')) || '.'
    || E'\n\n— ' || v_first_name;

  -- Fire the Telegram send to the team group via pjsagencybot.
  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = v_agency_id AND setting_key = 'telegram_team_group_chat_id';

  IF v_chat_id IS NOT NULL THEN
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
  ELSE
    v_tg_error := 'telegram_team_group_chat_id not set';
  END IF;

  UPDATE public.pfa_daily_closes
  SET telegram_message_id = v_tg_msg_id,
      telegram_send_ok    = v_tg_ok,
      telegram_send_error = v_tg_error
  WHERE id = v_close_id;

  RETURN jsonb_build_object(
    'ok', true,
    'close_id', v_close_id,
    'close_date', v_today,
    'closed_by', v_first_name,
    'deposit_count', v_deposit_count,
    'total_amount', v_total,
    'telegram_send_ok', v_tg_ok,
    'telegram_send_error', v_tg_error
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_close_day() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_close_day() TO authenticated;


-- 4) Add day-lock check to pfa_record_customer_deposit — once the day is
--    closed, further deposits for the same CT date are rejected.
CREATE OR REPLACE FUNCTION public.pfa_record_customer_deposit(
  p_first_name    text,
  p_last_initial  text,
  p_policy_type   text,
  p_amount        numeric,
  p_check_number  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_auth_uid              uuid;
  v_team_id               uuid;
  v_agency_id             uuid;
  v_team_first_name       text;
  v_pfa_account_id        uuid;
  v_customer_name         text;
  v_first_normalized      text;
  v_last_initial_normalized text;
  v_deposit_id            uuid;
  v_eft_id                uuid;
  v_today                 date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_chat_id               bigint;
  v_msg                   text;
BEGIN
  v_auth_uid := auth.uid();
  IF v_auth_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT t.id, t.agency_id, t.first_name
    INTO v_team_id, v_agency_id, v_team_first_name
  FROM public.team t
  JOIN public.users u ON u.id = t.user_id
  WHERE u.auth_user_id = v_auth_uid
    AND t.archived_at IS NULL
    AND t.is_admin_backoffice = false;
  IF v_team_id IS NULL THEN
    RAISE EXCEPTION 'no active team member for authenticated user' USING ERRCODE = '42501';
  END IF;

  v_first_normalized := btrim(COALESCE(p_first_name, ''));
  IF v_first_normalized = '' THEN
    RAISE EXCEPTION 'first_name required';
  END IF;
  IF v_first_normalized ~ '\.' THEN
    RAISE EXCEPTION 'first_name must not contain a period';
  END IF;
  IF length(v_first_normalized) > 40 THEN
    RAISE EXCEPTION 'first_name too long (max 40 chars)';
  END IF;

  v_last_initial_normalized := btrim(COALESCE(p_last_initial, ''));
  IF v_last_initial_normalized !~ '^[A-Za-z]$' THEN
    RAISE EXCEPTION 'last_initial must be a single letter A-Z';
  END IF;
  v_last_initial_normalized := upper(v_last_initial_normalized);

  IF p_policy_type IS NULL OR p_policy_type NOT IN ('auto','fire','life','health','billing') THEN
    RAISE EXCEPTION 'policy_type must be one of: auto, fire, life, health, billing';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be > 0';
  END IF;
  IF p_amount > 100000 THEN
    RAISE EXCEPTION 'amount unreasonably large (> $100,000) — verify before entering';
  END IF;

  v_customer_name := v_first_normalized || ' ' || v_last_initial_normalized || '.';

  SELECT id INTO v_pfa_account_id
  FROM public.pfa_accounts
  WHERE agency_id = v_agency_id AND is_active = true
  LIMIT 1;
  IF v_pfa_account_id IS NULL THEN
    RAISE EXCEPTION 'no active PFA account for agency %', v_agency_id;
  END IF;

  -- NEW: reject if today already closed.
  IF EXISTS (
    SELECT 1 FROM public.pfa_daily_closes
    WHERE agency_id = v_agency_id
      AND pfa_account_id = v_pfa_account_id
      AND close_date = v_today
  ) THEN
    RAISE EXCEPTION 'today''s PFA deposits are already closed; enter this deposit tomorrow' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.pfa_transactions (
    pfa_account_id, transaction_date, transaction_type, transaction_number,
    debit_amount, credit_amount, cleared,
    customer_name, policy_type,
    prepared_by_team_member_id, imported_from_excel
  ) VALUES (
    v_pfa_account_id, v_today, 'Deposit', NULLIF(btrim(COALESCE(p_check_number, '')), ''),
    NULL, round(p_amount, 2), false,
    v_customer_name, p_policy_type,
    v_team_id, false
  )
  RETURNING id INTO v_deposit_id;

  INSERT INTO public.pfa_transactions (
    pfa_account_id, transaction_date, transaction_type,
    debit_amount, credit_amount, cleared,
    customer_name, policy_type,
    prepared_by_team_member_id, imported_from_excel
  ) VALUES (
    v_pfa_account_id, v_today, 'State Farm EFT',
    round(p_amount, 2), NULL, false,
    v_customer_name, p_policy_type,
    v_team_id, false
  )
  RETURNING id INTO v_eft_id;

  SELECT setting_value::bigint INTO v_chat_id
  FROM public.settings
  WHERE agency_id = v_agency_id AND setting_key = 'paper_newt_management_group_chat_id';

  IF v_chat_id IS NOT NULL THEN
    v_msg := format(
      E'💰 New PFA deposit\n\nAmount: $%s\nCustomer: %s\nPolicy type: %s\nEntered by: %s\nCheck #: %s\nDate: %s',
      to_char(p_amount, 'FM999,999,990.00'),
      v_customer_name,
      p_policy_type,
      v_team_first_name,
      COALESCE(NULLIF(btrim(COALESCE(p_check_number, '')), ''), '—'),
      to_char(v_today, 'MM-DD-YYYY')
    );
    BEGIN
      PERFORM public.telegram_send_message_v2(v_chat_id, v_msg, 'paper_newt');
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'PFA deposit % logged, Telegram DM failed: %', v_deposit_id, SQLERRM;
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'deposit_id', v_deposit_id,
    'eft_id', v_eft_id,
    'customer_name', v_customer_name,
    'amount', round(p_amount, 2),
    'policy_type', p_policy_type,
    'prepared_by', v_team_first_name,
    'transaction_date', v_today
  );
END;
$$;

REVOKE ALL ON FUNCTION public.pfa_record_customer_deposit(text, text, text, numeric, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pfa_record_customer_deposit(text, text, text, numeric, text) TO authenticated;
