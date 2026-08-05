-- Step 2c: backfill missing account_label on bank_register_preliminary from the account registry.
UPDATE public.bank_register_preliminary r
SET account_label = reg.account_name, updated_at = now()
FROM (
  SELECT 'credit_card'::text AS atype, ca.account_number_last4 AS l4,
         ca.account_name FROM public.credit_accounts ca WHERE ca.is_active
  UNION ALL
  SELECT 'credit_card', x.l4, ca.account_name
    FROM public.credit_accounts ca,
         LATERAL regexp_split_to_table(coalesce(ca.alternate_last4s::text,''),
                                       '[^0-9]+') x(l4)
   WHERE ca.is_active AND length(x.l4) = 4
  UNION ALL
  SELECT ba.account_type, ba.account_number_last4, ba.account_name
    FROM public.bank_accounts ba WHERE ba.is_active
) reg
WHERE (r.account_label IS NULL OR btrim(r.account_label) = '')
  AND r.account_last4 = reg.l4
  AND ((r.account_type = 'credit_card') = (reg.atype = 'credit_card'));

-- Step 3 rewrite: handler now uses registry account_name as canonical label,
-- aggregates by (week_ending, account_last4, account_type), computes opening_balance
-- via one-week-earlier lateral lookup, and coded_count = txn_count - uncoded_count.
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
  v_rows_html text := '';
  v_questions_html text := '';
  v_open_q_count int;
  v_unresolved jsonb := '[]'::jsonb;
  v_unresolved_ob jsonb := '[]'::jsonb;
  v_rec record;
  v_agg record;
  v_entity_id uuid;
  v_account_name text;
  v_opening_balance numeric;
  v_match_count int;
  v_email_id bigint;
  v_send_ok boolean := false;
  v_rows_written int := 0;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_to := v_input_config->>'to';
  v_subject_template := v_input_config->>'subject_template';
  v_include_coding_questions := COALESCE((v_input_config->>'include_coding_questions')::boolean, true);

  SELECT count(*) INTO v_raw_count FROM public.v_weekly_cash_position;
  IF v_raw_count = 0 THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'v_weekly_cash_position returned zero rows');
  END IF;

  -- pre-flight A: entity resolution, exactly one match required per distinct (account_last4, account_type)
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

  -- pre-flight B: opening_balance must resolve for every aggregated (week_ending, account_last4, account_type)
  FOR v_agg IN
    SELECT week_ending::date AS week_ending, account_last4, account_type
    FROM public.v_weekly_cash_position
    GROUP BY week_ending::date, account_last4, account_type
  LOOP
    SELECT vp.running_balance INTO v_opening_balance
      FROM public.v_projected_account_balance vp
      WHERE vp.account_last4 = v_agg.account_last4 AND vp.txn_date <= (v_agg.week_ending - 7)
      ORDER BY vp.txn_date DESC, vp.amount LIMIT 1;
    IF v_opening_balance IS NULL THEN
      v_unresolved_ob := v_unresolved_ob || jsonb_build_object('account_last4', v_agg.account_last4, 'account_type', v_agg.account_type, 'week_ending', v_agg.week_ending);
    END IF;
  END LOOP;
  IF jsonb_array_length(v_unresolved_ob) > 0 THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'no prior-week balance available for opening_balance', 'offenders', v_unresolved_ob);
  END IF;

  SELECT array_agg(DISTINCT week_ending::date) INTO v_week_endings FROM public.v_weekly_cash_position;
  SELECT max(week_ending)::date INTO v_max_week_ending FROM public.v_weekly_cash_position;

  DELETE FROM public.bank_register_weekly_snapshot
   WHERE agency_id = p_agency_id AND week_ending = ANY(v_week_endings);

  v_rows_html := '<table border="1" cellpadding="6" cellspacing="0"><tr><th>Account</th><th>Last4</th><th>Type</th><th>Credits</th><th>Debits</th><th>Txns</th><th>Uncoded</th><th>Projected EOW Balance</th></tr>';

  FOR v_agg IN
    SELECT week_ending::date AS week_ending, account_last4, account_type,
           sum(credits) AS credits, sum(debits) AS debits,
           sum(txn_count)::int AS txn_count, sum(uncoded_count)::int AS uncoded_count,
           max(projected_end_of_week_balance) AS closing_balance
    FROM public.v_weekly_cash_position
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

    INSERT INTO public.bank_register_weekly_snapshot
      (agency_id, week_ending, account_last4, account_label, account_type,
       opening_balance, closing_balance, total_credits, total_debits, net_change,
       txn_count, coded_count, uncoded_count, business_entity_id,
       snapshot_generated_at, emailed_at)
    VALUES
      (p_agency_id, v_agg.week_ending, v_agg.account_last4, v_account_name, v_agg.account_type,
       v_opening_balance, v_agg.closing_balance, v_agg.credits, v_agg.debits, NULL,
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
  v_body := v_rows_html || v_questions_html;

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
    'email_request_id', v_email_id
  );
END;
$function$;
