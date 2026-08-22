-- 1. Trigger: reject a gl_classification_rules write that would silently fail to match or resolve.
-- Sentinels __SKIP__ (skip rule, both sides) and __SOURCE__ (this side unused for this direction) are exempt
-- from the "must be a live account" check -- they are intentional, not dead codes.

CREATE OR REPLACE FUNCTION public.validate_gl_classification_rule()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  -- debit_account_code must be a live account, unless it's a sentinel
  IF NEW.debit_account_code NOT IN ('__SKIP__', '__SOURCE__') THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.chart_of_accounts
      WHERE agency_id = NEW.agency_id AND account_code = NEW.debit_account_code AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'gl_classification_rules "%": debit_account_code % is not a live account in chart_of_accounts', NEW.rule_name, NEW.debit_account_code;
    END IF;
  END IF;

  -- credit_account_code must be a live account, unless it's a sentinel
  IF NEW.credit_account_code NOT IN ('__SKIP__', '__SOURCE__') THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.chart_of_accounts
      WHERE agency_id = NEW.agency_id AND account_code = NEW.credit_account_code AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'gl_classification_rules "%": credit_account_code % is not a live account in chart_of_accounts', NEW.rule_name, NEW.credit_account_code;
    END IF;
  END IF;

  -- __SKIP__ must be set on both sides together, never just one
  IF (NEW.debit_account_code = '__SKIP__') <> (NEW.credit_account_code = '__SKIP__') THEN
    RAISE EXCEPTION 'gl_classification_rules "%": __SKIP__ must be set on both debit_account_code and credit_account_code, not just one', NEW.rule_name;
  END IF;

  -- __SOURCE__ on both sides means the rule can never resolve to anything, in either direction
  IF NEW.debit_account_code = '__SOURCE__' AND NEW.credit_account_code = '__SOURCE__' THEN
    RAISE EXCEPTION 'gl_classification_rules "%": debit_account_code and credit_account_code cannot both be __SOURCE__ - the rule would never resolve', NEW.rule_name;
  END IF;

  -- match_source_account, if set, must be a live account code (not a stale scope like COA-006)
  IF NEW.match_source_account IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.chart_of_accounts
    WHERE agency_id = NEW.agency_id AND account_code = NEW.match_source_account AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'gl_classification_rules "%": match_source_account % is not a live account in chart_of_accounts', NEW.rule_name, NEW.match_source_account;
  END IF;

  -- \b in a Postgres regex is the backspace character, not a word boundary -- \y is the word boundary
  IF NEW.match_payee_regex IS NOT NULL AND position('\b' in NEW.match_payee_regex) > 0 THEN
    RAISE EXCEPTION 'gl_classification_rules "%": match_payee_regex contains \b (Postgres backspace, not a word boundary) - use \y instead', NEW.rule_name;
  END IF;

  IF NEW.match_memo_regex IS NOT NULL AND position('\b' in NEW.match_memo_regex) > 0 THEN
    RAISE EXCEPTION 'gl_classification_rules "%": match_memo_regex contains \b (Postgres backspace, not a word boundary) - use \y instead', NEW.rule_name;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validate_gl_classification_rule ON public.gl_classification_rules;
CREATE TRIGGER trg_validate_gl_classification_rule
BEFORE INSERT OR UPDATE ON public.gl_classification_rules
FOR EACH ROW EXECUTE FUNCTION public.validate_gl_classification_rule();

-- 2. Audit: alert when an active rule has matched nothing over a rolling window.
-- Gives new rules a grace period (created_at) before flagging them as dormant, so a rule written
-- today for a merchant that hasn't shown up on a statement yet doesn't get flagged tomorrow.

CREATE OR REPLACE FUNCTION public.audit_dormant_gl_classification_rules(
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_window interval DEFAULT interval '30 days'
)
RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_rule record;
  v_count int := 0;
BEGIN
  FOR v_rule IN
    SELECT id, rule_name
    FROM public.gl_classification_rules
    WHERE agency_id = p_agency_id
      AND is_active = TRUE
      AND created_at < now() - p_window
      AND (last_used_at IS NULL OR last_used_at < now() - p_window)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.alerts
      WHERE agency_id = p_agency_id
        AND module_reference = 'gl_classification_rules'
        AND related_id = v_rule.id
        AND is_resolved = FALSE
    ) THEN
      INSERT INTO public.alerts (
        agency_id, alert_type, severity, title, message,
        module_reference, related_id, is_read, is_resolved, created_at
      ) VALUES (
        p_agency_id, 'dormant_gl_rule', 'warning',
        'Ledger rule not matching: ' || v_rule.rule_name,
        'Rule "' || v_rule.rule_name || '" is active but has not matched a transaction in the last ' || p_window::text || '. It may be dead (deleted account code, stale source scope, or a bad regex) - check it before trusting it.',
        'gl_classification_rules', v_rule.id, FALSE, FALSE, now()
      );
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', TRUE, 'new_alerts', v_count);
END;
$function$;

-- run daily, right after the suspense aging check
SELECT cron.schedule(
  'gl_rule_dormancy_audit_daily',
  '30 13 * * *',
  $$SELECT public.audit_dormant_gl_classification_rules('126794dd-25ff-47d2-a436-724499733365'::uuid);$$
);
