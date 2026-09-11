-- The deposit message uses the figure State Farm prints on the comp statement
-- (documents.stated_net_payable, from the ACTUAL DEPOSIT line), not a sum of
-- parsed lines. Aug 16-31 2026 proved a sum can be wrong: lines came to
-- 18,655.98, SF deposited 19,105.98 (a $450 CASH AWARD - LIFE the parser skips).
-- The summed figure is still stored alongside for comparison.
-- p_allow_fallback: when the printed figure is missing, send the summed figure
-- instead. Off by default until the processor writes stated_net_payable.
CREATE OR REPLACE FUNCTION public.comp_net_deposit_notice(
  p_agency_id uuid, p_year int, p_month int, p_day int, p_send boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_comp numeric; v_ded numeric; v_comp_n int; v_ded_n int;
  v_stated numeric; v_net numeric; v_label text; v_text text; v_id uuid; v_res jsonb;
  v_dry boolean := COALESCE(current_setting('newtworks.dry_run', true), '') = 'on';
  v_allow_fallback boolean := COALESCE(current_setting('newtworks.comp_notice_fallback', true), 'off') = 'on';
BEGIN
  SELECT
    COALESCE(SUM(amount) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%'), 0),
    COALESCE(SUM(amount) FILTER (WHERE comp_category LIKE 'deduction_%'), 0),
    COUNT(*) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%'),
    COUNT(*) FILTER (WHERE comp_category LIKE 'deduction_%')
  INTO v_comp, v_ded, v_comp_n, v_ded_n
  FROM comp_recap
  WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month
    AND period_day = p_day AND source_document_id IS NOT NULL;

  IF v_comp_n = 0 OR v_ded_n = 0 THEN
    RETURN jsonb_build_object('action', 'waiting', 'comp_rows', v_comp_n, 'deduction_rows', v_ded_n);
  END IF;

  SELECT MAX(d.stated_net_payable) INTO v_stated
  FROM documents d
  WHERE d.id IN (SELECT DISTINCT source_document_id FROM comp_recap
                 WHERE agency_id = p_agency_id AND period_year = p_year AND period_month = p_month
                   AND period_day = p_day AND source_document_id IS NOT NULL
                   AND COALESCE(comp_category,'') NOT LIKE 'deduction_%')
    AND d.stated_net_payable IS NOT NULL;

  IF v_stated IS NULL AND NOT v_allow_fallback THEN
    RETURN jsonb_build_object('action', 'waiting_for_stated_deposit', 'summed_net', v_comp - v_ded);
  END IF;

  v_net := COALESCE(v_stated, v_comp - v_ded);
  v_label := to_char(make_date(p_year, p_month, 1), 'Mon') || ' '
          || CASE WHEN p_day <= 15 THEN '1-15' ELSE '16-' || p_day END;
  v_text := '💰 Comp statement processed for ' || v_label || '.' || E'\n'
         || 'Net deposit: ' || to_char(v_net, 'FM$999,999,990.00');

  IF NOT p_send OR v_dry THEN
    RETURN jsonb_build_object('action', 'dry_run', 'stated_deposit', v_stated,
      'summed_net', v_comp - v_ded, 'net_deposit', v_net, 'message', v_text);
  END IF;

  INSERT INTO comp_deposit_notices (agency_id, period_year, period_month, period_day,
    comp_total, deduction_total, net_deposit, message_text)
  VALUES (p_agency_id, p_year, p_month, p_day, v_comp, v_ded, v_net, v_text)
  ON CONFLICT (agency_id, period_year, period_month, period_day) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('action', 'already_sent');
  END IF;

  BEGIN
    v_res := public.telegram_send('admin', v_text, p_agency_id);
    UPDATE comp_deposit_notices
       SET status = CASE WHEN (v_res->>'ok')::boolean IS TRUE THEN 'sent' ELSE 'failed' END,
           telegram_result = v_res,
           sent_at = CASE WHEN (v_res->>'ok')::boolean IS TRUE THEN now() END
     WHERE id = v_id;
  EXCEPTION WHEN OTHERS THEN
    UPDATE comp_deposit_notices SET status = 'failed',
           telegram_result = jsonb_build_object('error', SQLERRM)
     WHERE id = v_id;
  END;

  RETURN jsonb_build_object('action', 'sent', 'net_deposit', v_net, 'telegram', v_res);
END;
$function$;

UPDATE public.documents SET stated_net_payable = 19105.98
WHERE id = '4f5b7395-15e3-4c0a-9860-5a5a5b6989a6' AND stated_net_payable IS NULL;