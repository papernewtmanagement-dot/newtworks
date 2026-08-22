-- Tighten the dormancy definition. historical_uses was bulk-seeded during backfills before
-- last_used_at existed, so "historical_uses > 0 but last_used_at IS NULL" is ambiguous legacy
-- data, not a live signal -- excluding it from the flag avoids ~1/3 false-noise on rules that
-- may simply predate the tracking column. Skip rules (__SKIP__) are excluded outright: the
-- writer's skip-rule branch never stamps last_used_at/historical_uses at all (a separate gap,
-- noted for Peter, not fixed here since it touches statement_gl_writer itself).

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
    SELECT id, rule_name,
      CASE WHEN last_used_at IS NOT NULL THEN 'went_quiet' ELSE 'never_fired' END AS reason
    FROM public.gl_classification_rules
    WHERE agency_id = p_agency_id
      AND is_active = TRUE
      AND debit_account_code != '__SKIP__'
      AND created_at < now() - p_window
      AND (
        (last_used_at IS NOT NULL AND last_used_at < now() - p_window)
        OR (last_used_at IS NULL AND coalesce(historical_uses, 0) = 0)
      )
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
        CASE WHEN v_rule.reason = 'went_quiet'
          THEN 'Rule "' || v_rule.rule_name || '" matched transactions before but has gone quiet for the last ' || p_window::text || '. Check the merchant descriptor is still correct.'
          ELSE 'Rule "' || v_rule.rule_name || '" is active and has never matched a single transaction. Likely dead (wrong regex/scope) or a one-off historical rule that will never fire again - worth deactivating either way.'
        END,
        'gl_classification_rules', v_rule.id, FALSE, FALSE, now()
      );
      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', TRUE, 'new_alerts', v_count);
END;
$function$;
