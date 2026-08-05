-- 1. Fix week boundary: v_weekly_cash_position was Monday-anchored (Sunday-ending),
--    violates agency-wide Sunday->Saturday convention. Column names/order/types unchanged.
CREATE OR REPLACE VIEW public.v_weekly_cash_position AS
 WITH week_buckets AS (
         SELECT bank_register_preliminary.account_last4,
            bank_register_preliminary.account_label,
            bank_register_preliminary.account_type,
            ((bank_register_preliminary.txn_date
              + ((6 - EXTRACT(DOW FROM bank_register_preliminary.txn_date))::int))
             ::timestamp with time zone) AS week_ending,
            sum(
                CASE
                    WHEN bank_register_preliminary.direction = 'credit'::text THEN bank_register_preliminary.amount
                    ELSE 0::numeric
                END) AS credits,
            sum(
                CASE
                    WHEN bank_register_preliminary.direction = 'debit'::text THEN bank_register_preliminary.amount
                    ELSE 0::numeric
                END) AS debits,
            count(*) AS txn_count,
            count(*) FILTER (WHERE bank_register_preliminary.coding_status = ANY (ARRAY['needs_peter'::text, 'unclassified'::text])) AS uncoded_count
           FROM bank_register_preliminary
          WHERE bank_register_preliminary.agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND bank_register_preliminary.status <> 'void'::text
          GROUP BY bank_register_preliminary.account_last4, bank_register_preliminary.account_label, bank_register_preliminary.account_type,
                   ((bank_register_preliminary.txn_date + ((6 - EXTRACT(DOW FROM bank_register_preliminary.txn_date))::int))::timestamp with time zone)
        )
 SELECT wb.account_last4,
    wb.account_label,
    wb.account_type,
    wb.week_ending,
    wb.credits,
    wb.debits,
    wb.txn_count,
    wb.uncoded_count,
    pb.running_balance AS projected_end_of_week_balance
   FROM week_buckets wb
     LEFT JOIN LATERAL ( SELECT vp.running_balance
           FROM v_projected_account_balance vp
          WHERE vp.account_last4 = wb.account_last4 AND vp.txn_date <= wb.week_ending
          ORDER BY vp.txn_date DESC, vp.amount
         LIMIT 1) pb ON true
  ORDER BY wb.week_ending DESC, wb.account_last4;

-- 2. Internal handler for the Weekly Cash Snapshot recipe.
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
  v_row_count int;
  v_week_endings date[];
  v_max_week_ending date;
  v_subject text;
  v_body text;
  v_rows_html text := '';
  v_questions_html text := '';
  v_open_q_count int;
  v_unresolved jsonb := '[]'::jsonb;
  v_rec record;
  v_entity_id uuid;
  v_match_count int;
  v_email_id bigint;
  v_send_ok boolean := false;
BEGIN
  SELECT input_config INTO v_input_config FROM public.automation_recipes WHERE id = p_recipe_id;
  v_to := v_input_config->>'to';
  v_subject_template := v_input_config->>'subject_template';
  v_include_coding_questions := COALESCE((v_input_config->>'include_coding_questions')::boolean, true);

  SELECT count(*) INTO v_row_count FROM public.v_weekly_cash_position;
  IF v_row_count = 0 THEN
    RETURN jsonb_build_object('skipped', true, 'reason', 'v_weekly_cash_position returned zero rows');
  END IF;

  -- entity resolution pre-flight: exactly one match required per distinct (account_last4, account_type)
  FOR v_rec IN
    SELECT DISTINCT account_last4, account_type FROM public.v_weekly_cash_position
  LOOP
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

  SELECT array_agg(DISTINCT week_ending::date) INTO v_week_endings FROM public.v_weekly_cash_position;
  SELECT max(week_ending)::date INTO v_max_week_ending FROM public.v_weekly_cash_position;

  -- idempotency: replace, don't duplicate
  DELETE FROM public.bank_register_weekly_snapshot
   WHERE agency_id = p_agency_id AND week_ending = ANY(v_week_endings);

  FOR v_rec IN SELECT * FROM public.v_weekly_cash_position LOOP
    IF v_rec.account_type = 'credit_card' THEN
      SELECT ca.business_entity_id INTO v_entity_id FROM public.credit_accounts ca
        WHERE ca.is_active AND (ca.account_number_last4 = v_rec.account_last4
              OR ca.alternate_last4s::text ~ ('\m' || v_rec.account_last4 || '\M'))
        LIMIT 1;
    ELSE
      SELECT ba.business_entity_id INTO v_entity_id FROM public.bank_accounts ba
        WHERE ba.is_active AND ba.account_number_last4 = v_rec.account_last4
        LIMIT 1;
    END IF;

    INSERT INTO public.bank_register_weekly_snapshot
      (agency_id, week_ending, account_last4, account_label, account_type,
       total_credits, total_debits, txn_count, uncoded_count, closing_balance,
       business_entity_id, snapshot_generated_at, emailed_at)
    VALUES
      (p_agency_id, v_rec.week_ending::date, v_rec.account_last4, v_rec.account_label, v_rec.account_type,
       v_rec.credits, v_rec.debits, v_rec.txn_count, v_rec.uncoded_count, v_rec.projected_end_of_week_balance,
       v_entity_id, now(), NULL);
  END LOOP;

  -- compose email body
  v_rows_html := '<table border="1" cellpadding="6" cellspacing="0"><tr><th>Account</th><th>Last4</th><th>Type</th><th>Credits</th><th>Debits</th><th>Txns</th><th>Uncoded</th><th>Projected EOW Balance</th></tr>';
  FOR v_rec IN SELECT * FROM public.v_weekly_cash_position ORDER BY account_label LOOP
    v_rows_html := v_rows_html || format(
      '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>',
      v_rec.account_label, v_rec.account_last4, v_rec.account_type,
      to_char(v_rec.credits, 'FM$999,999,990.00'), to_char(v_rec.debits, 'FM$999,999,990.00'),
      v_rec.txn_count, v_rec.uncoded_count, to_char(v_rec.projected_end_of_week_balance, 'FM$999,999,990.00'));
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
    'rows_written', v_row_count,
    'week_endings', v_week_endings,
    'emailed', v_send_ok,
    'to', v_to,
    'email_request_id', v_email_id
  );
END;
$function$;

-- 3. Wire the recipe to the internal handler; drop the broken generic-Gmail path.
UPDATE public.automation_recipes
   SET internal_handler = 'weekly_cash_snapshot_run',
       composio_action = NULL,
       composio_connection = NULL
 WHERE id = 'c31fa37c-1044-45f1-a2ba-5477a860054a';
