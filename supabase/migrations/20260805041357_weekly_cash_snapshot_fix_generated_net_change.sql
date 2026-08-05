CREATE OR REPLACE FUNCTION public.weekly_cash_snapshot_run(p_agency_id uuid, p_recipe_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'net', 'pg_catalog'
AS $function$
DECLARE
  v_input_config jsonb;
  v_to text;
  v_subject_template text;
  v_include_coding_questions boolean;
  v_raw_count int;
  v_week_endings date[];
  v_max_week_ending date;
  v_subject text;
  v_body text;
  v_disclosure_html text := '';
  v_rows_html text := '';
  v_questions_html text := '';
  v_open_q_count int;
  v_unresolved jsonb := '[]'::jsonb;
  v_rec record;
  v_agg record;
  v_entity_id uuid;
  v_account_name text;
  v_opening_balance numeric;
  v_anchor_balance numeric;
  v_match_count int;
  v_email_id bigint;
  v_send_ok boolean := false;
  v_rows_written int := 0;
  v_skip_accounts text[] := '{}';
  v_skip_details jsonb := '[]'::jsonb;
  v_skip_names text[] := '{}';
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_to := v_input_config->>'to';
  v_subject_template := v_input_config->>'subject_template';
  v_include_coding_questions := COALESCE((v_input_config->>'include_coding_questions')::boolean, true);

  SELECT count(*) INTO v_raw_count FROM public.v_weekly_cash_position;
  IF v_raw_count = 0 THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'v_weekly_cash_position returned zero rows');
  END IF;

  FOR v_rec IN SELECT DISTINCT account_last4, account_type FROM public.v_weekly_cash_position LOOP
    IF v_rec.account_type = 'credit_card' THEN
      SELECT count(*) INTO v_match_count FROM public.credit_accounts ca
        WHERE ca.is_active AND (ca.account_number_last4 = v_rec.account_last4
              OR ca.alternate_last4s::text ~ ('\m' || v_rec.account_last4 || '\M'));
    ELSE
      SELECT count(*) INTO v_match_count FROM public.bank_accounts ba
        WHERE ba.is_active AND ba.account_number_last4 = v_rec.account_last4;
    END IF;
    IF v_match_count <> 1 THEN
      v_unresolved := v_unresolved || jsonb_build_object('account_last4', v_rec.account_last4, 'account_type', v_rec.account_type, 'match_count', v_match_count);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_unresolved) > 0 THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'entity resolution ambiguous or unmatched', 'offenders', v_unresolved);
  END IF;

  FOR v_agg IN
    SELECT week_ending::date AS week_ending, account_last4, account_type
    FROM public.v_weekly_cash_position
    GROUP BY week_ending::date, account_last4, account_type
  LOOP
    IF v_agg.account_last4 = ANY(v_skip_accounts) THEN
      CONTINUE;
    END IF;
    SELECT vp.running_balance INTO v_opening_balance
      FROM public.v_projected_account_balance vp
      WHERE vp.account_last4 = v_agg.account_last4 AND vp.txn_date <= (v_agg.week_ending - 7)
      ORDER BY vp.txn_date DESC, vp.amount LIMIT 1;
    IF v_opening_balance IS NULL THEN
      SELECT s.balance INTO v_anchor_balance FROM public.account_starting_balances s
        WHERE s.agency_id = p_agency_id AND s.account_last4 = v_agg.account_last4 LIMIT 1;
      IF v_anchor_balance IS NULL THEN
        v_skip_accounts := array_append(v_skip_accounts, v_agg.account_last4);
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_skip_accounts, 1) > 0 THEN
    FOR v_rec IN SELECT DISTINCT account_last4, account_type FROM public.v_weekly_cash_position
      WHERE account_last4 = ANY(v_skip_accounts)
    LOOP
      IF v_rec.account_type = 'credit_card' THEN
        SELECT ca.account_name INTO v_account_name FROM public.credit_accounts ca
          WHERE ca.is_active AND (ca.account_number_last4 = v_rec.account_last4
                OR ca.alternate_last4s::text ~ ('\m' || v_rec.account_last4 || '\M')) LIMIT 1;
      ELSE
        SELECT ba.account_name INTO v_account_name FROM public.bank_accounts ba
          WHERE ba.is_active AND ba.account_number_last4 = v_rec.account_last4 LIMIT 1;
      END IF;
      v_account_name := COALESCE(v_account_name, v_rec.account_last4);
      v_skip_names := array_append(v_skip_names, v_account_name);
      v_skip_details := v_skip_details || jsonb_build_object('account_last4', v_rec.account_last4, 'account_name', v_account_name, 'reason', 'no prior-week balance and no account_starting_balances anchor');
    END LOOP;
    v_disclosure_html := format('<p style="color:#b00"><strong>Skipped (no balance anchor):</strong> %s</p>', array_to_string(v_skip_names, ', '));
  END IF;

  SELECT array_agg(DISTINCT week_ending::date) INTO v_week_endings
    FROM public.v_weekly_cash_position WHERE NOT (account_last4 = ANY(v_skip_accounts));
  SELECT max(week_ending)::date INTO v_max_week_ending
    FROM public.v_weekly_cash_position WHERE NOT (account_last4 = ANY(v_skip_accounts));

  IF v_week_endings IS NULL THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'all accounts skipped -- no balance anchor for any', 'skipped_accounts', v_skip_details);
  END IF;

  DELETE FROM public.bank_register_weekly_snapshot
   WHERE agency_id = p_agency_id AND week_ending = ANY(v_week_endings);

  v_rows_html := '<table border="1" cellpadding="6" cellspacing="0"><tr><th>Account</th><th>Last4</th><th>Type</th><th>Credits</th><th>Debits</th><th>Txns</th><th>Uncoded</th><th>Projected EOW Balance</th></tr>';

  FOR v_agg IN
    SELECT week_ending::date AS week_ending, account_last4, account_type,
           sum(credits) AS credits, sum(debits) AS debits,
           sum(txn_count)::int AS txn_count, sum(uncoded_count)::int AS uncoded_count,
           max(projected_end_of_week_balance) AS closing_balance
    FROM public.v_weekly_cash_position
    WHERE NOT (account_last4 = ANY(v_skip_accounts))
    GROUP BY week_ending::date, account_last4, account_type
    ORDER BY week_ending, account_last4
  LOOP
    IF v_agg.account_type = 'credit_card' THEN
      SELECT ca.business_entity_id, ca.account_name INTO v_entity_id, v_account_name
        FROM public.credit_accounts ca WHERE ca.is_active
        AND (ca.account_number_last4 = v_agg.account_last4 OR ca.alternate_last4s::text ~ ('\m' || v_agg.account_last4 || '\M'))
        LIMIT 1;
    ELSE
      SELECT ba.business_entity_id, ba.account_name INTO v_entity_id, v_account_name
        FROM public.bank_accounts ba WHERE ba.is_active AND ba.account_number_last4 = v_agg.account_last4
        LIMIT 1;
    END IF;

    SELECT vp.running_balance INTO v_opening_balance
      FROM public.v_projected_account_balance vp
      WHERE vp.account_last4 = v_agg.account_last4 AND vp.txn_date <= (v_agg.week_ending - 7)
      ORDER BY vp.txn_date DESC, vp.amount LIMIT 1;

    IF v_opening_balance IS NULL THEN
      SELECT s.balance INTO v_opening_balance FROM public.account_starting_balances s
        WHERE s.agency_id = p_agency_id AND s.account_last4 = v_agg.account_last4 LIMIT 1;
    END IF;

    INSERT INTO public.bank_register_weekly_snapshot
      (agency_id, week_ending, account_last4, account_label, account_type,
       opening_balance, closing_balance, total_credits, total_debits,
       txn_count, coded_count, uncoded_count, business_entity_id,
       snapshot_generated_at, emailed_at)
    VALUES
      (p_agency_id, v_agg.week_ending, v_agg.account_last4, v_account_name, v_agg.account_type,
       v_opening_balance, v_agg.closing_balance, v_agg.credits, v_agg.debits,
       v_agg.txn_count, (v_agg.txn_count - v_agg.uncoded_count), v_agg.uncoded_count, v_entity_id,
       now(), NULL);

    v_rows_written := v_rows_written + 1;

    v_rows_html := v_rows_html || format(
      '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      v_account_name, v_agg.account_last4, v_agg.account_type,
      to_char(v_agg.credits, 'FM$999,999,990.00'), to_char(v_agg.debits, 'FM$999,999,990.00'),
      v_agg.txn_count, v_agg.uncoded_count, to_char(v_agg.closing_balance, 'FM$999,999,990.00'));
  END LOOP;

  v_rows_html := v_rows_html || '</table>';

  IF v_include_coding_questions THEN
    SELECT count(*) INTO v_open_q_count FROM public.v_bank_register_coding_questions;
    v_questions_html := format('<p>Open coding questions: %s</p>', v_open_q_count);
    IF v_open_q_count > 0 THEN
      v_questions_html := v_questions_html || '<ul>';
      FOR v_rec IN SELECT * FROM public.v_bank_register_coding_questions ORDER BY txn_date DESC LIMIT 10 LOOP
        v_questions_html := v_questions_html || format('<li>%s -- %s -- %s (%s)</li>',
          v_rec.txn_date, v_rec.merchant, to_char(v_rec.amount, 'FM$999,999,990.00'), v_rec.coding_question);
      END LOOP;
      v_questions_html := v_questions_html || '</ul>';
    END IF;
  END IF;

  v_subject := replace(v_subject_template, '{week_ending}', to_char(v_max_week_ending, 'YYYY-MM-DD'));
  v_body := v_disclosure_html || v_rows_html || v_questions_html;

  BEGIN
    v_email_id := public.composio_send_email(p_agency_id, v_to, v_subject, v_body);
    v_send_ok := true;
  EXCEPTION WHEN OTHERS THEN
    v_send_ok := false;
  END;

  IF v_send_ok THEN
    UPDATE public.bank_register_weekly_snapshot
       SET emailed_at = now()
     WHERE agency_id = p_agency_id AND week_ending = ANY(v_week_endings);
  END IF;

  RETURN jsonb_build_object(
    'rows_written', v_rows_written,
    'week_endings', v_week_endings,
    'emailed', v_send_ok,
    'to', v_to,
    'email_request_id', v_email_id,
    'skipped_accounts', v_skip_details
  );
END;
$function$;
