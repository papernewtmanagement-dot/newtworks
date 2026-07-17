CREATE OR REPLACE FUNCTION public.pfa_record_customer_deposit(
  p_first_name text,
  p_last_initial text,
  p_policy_type text,
  p_amount numeric,
  p_check_number text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$;;