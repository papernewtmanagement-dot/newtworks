-- Comp net deposit notice (Peter 2026-09-10).
-- When BOTH the State Farm compensation statement and the deduction statement
-- for a pay period are in comp_recap, send one message with the net deposit
-- to the Paper Newt Management Telegram group (route 'admin', paper_newt bot).
-- Net deposit = compensation statement rows minus deduction statement rows.
-- Checked against real bank deposits: Jul 1-15 27,707.13 - 384.39 = 27,322.74,
-- Aug 1-15 20,289.97 - 1,272.14 = 19,017.83. Both match the deposit to the penny.

CREATE TABLE IF NOT EXISTS public.comp_deposit_notices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  period_year int NOT NULL,
  period_month int NOT NULL,
  period_day int NOT NULL,
  comp_total numeric NOT NULL,
  deduction_total numeric NOT NULL,
  net_deposit numeric NOT NULL,
  message_text text,
  status text NOT NULL DEFAULT 'pending',   -- pending | sent | failed | dry_run | seeded
  telegram_result jsonb,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (agency_id, period_year, period_month, period_day)
);
ALTER TABLE public.comp_deposit_notices ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.comp_net_deposit_notice(
  p_agency_id uuid, p_year int, p_month int, p_day int, p_send boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_comp numeric; v_ded numeric; v_comp_n int; v_ded_n int;
  v_net numeric; v_label text; v_text text; v_id uuid; v_res jsonb;
  v_dry boolean := COALESCE(current_setting('newtworks.dry_run', true), '') = 'on';
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

  v_net := v_comp - v_ded;
  v_label := to_char(make_date(p_year, p_month, 1), 'Mon') || ' '
          || CASE WHEN p_day <= 15 THEN '1-15' ELSE '16-' || p_day END;
  v_text := '💰 Comp statement processed for ' || v_label || '.' || E'\n'
         || 'Net deposit: ' || to_char(v_net, 'FM$999,999,990.00');

  IF NOT p_send OR v_dry THEN
    RETURN jsonb_build_object('action', 'dry_run', 'comp_total', v_comp,
      'deduction_total', v_ded, 'net_deposit', v_net, 'message', v_text);
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

CREATE OR REPLACE FUNCTION public.tg_notify_comp_net_deposit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
BEGIN
  FOR r IN
    SELECT DISTINCT agency_id, period_year, period_month, period_day
    FROM new_rows
    WHERE source_document_id IS NOT NULL
      AND period_year IS NOT NULL AND period_month IS NOT NULL AND period_day IS NOT NULL
  LOOP
    -- Only current statements. A reprocessed old statement never re-sends.
    CONTINUE WHEN make_date(r.period_year, r.period_month, r.period_day) < v_today - 45;
    BEGIN
      PERFORM public.comp_net_deposit_notice(r.agency_id, r.period_year, r.period_month, r.period_day, true);
    EXCEPTION WHEN OTHERS THEN
      NULL; -- a failed notice must never roll back the statement rows
    END;
  END LOOP;
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_notify_comp_net_deposit ON public.comp_recap;
CREATE TRIGGER trg_notify_comp_net_deposit
  AFTER INSERT ON public.comp_recap
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION public.tg_notify_comp_net_deposit();

-- Periods already processed inside the 45-day window are marked so a reprocess
-- does not send a late message for them.
INSERT INTO public.comp_deposit_notices (agency_id, period_year, period_month, period_day,
  comp_total, deduction_total, net_deposit, status)
SELECT agency_id, period_year, period_month, period_day,
  SUM(amount) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%'),
  SUM(amount) FILTER (WHERE comp_category LIKE 'deduction_%'),
  SUM(amount) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%')
    - SUM(amount) FILTER (WHERE comp_category LIKE 'deduction_%'),
  'seeded'
FROM public.comp_recap
WHERE source_document_id IS NOT NULL AND period_day IS NOT NULL
  AND make_date(period_year, period_month, period_day) >= (now() AT TIME ZONE 'America/Chicago')::date - 45
GROUP BY agency_id, period_year, period_month, period_day
HAVING COUNT(*) FILTER (WHERE comp_category LIKE 'deduction_%') > 0
   AND COUNT(*) FILTER (WHERE COALESCE(comp_category,'') NOT LIKE 'deduction_%') > 0
ON CONFLICT (agency_id, period_year, period_month, period_day) DO NOTHING;