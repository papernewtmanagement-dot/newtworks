-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-09 07:09:54 UTC (ledger name: rename_bank_register_to_cash_register_and_drop_personal_register) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260809070954.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.

-- ============================================================
-- 1. Rename bank_register_preliminary -> cash_register_preliminary
--    (matches the "Cash Register" module name it feeds; ALTER TABLE
--    RENAME preserves RLS policies, indexes, FKs, and triggers)
-- ============================================================
ALTER TABLE public.bank_register_preliminary RENAME TO cash_register_preliminary;

-- Cosmetic rename of the dependent view (its FROM clause auto-updates to the
-- new table name via catalog OID resolution, no need to recreate it)
ALTER VIEW public.v_bank_register_coding_questions RENAME TO v_cash_register_coding_questions;

-- ============================================================
-- 2. Recreate the two functions whose SOURCE TEXT hardcodes the old
--    table name (renaming the table alone does not fix embedded name
--    references inside plpgsql body text)
-- ============================================================
DROP FUNCTION IF EXISTS public.apply_coding_rule_to_register_row(uuid);

CREATE FUNCTION public.apply_coding_rule_to_cash_register_row(p_row_id uuid)
 RETURNS TABLE(matched boolean, rule_id uuid, rule_name text, confidence text, applied boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_row public.cash_register_preliminary%ROWTYPE;
  v_rule public.txn_coding_rules%ROWTYPE;
BEGIN
  SELECT * INTO v_row FROM public.cash_register_preliminary WHERE id = p_row_id;
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::text, NULL::text, false;
    RETURN;
  END IF;

  IF v_row.reconciled_journal_entry_id IS NOT NULL THEN
    RETURN QUERY SELECT false, NULL::uuid, NULL::text, NULL::text, false;
    RETURN;
  END IF;

  SELECT r.* INTO v_rule
  FROM public.txn_coding_rules r
  WHERE r.agency_id = v_row.agency_id
    AND r.is_active = true
    AND (r.match_direction    IS NULL OR r.match_direction    = v_row.direction)
    AND (r.match_account_last4 IS NULL OR r.match_account_last4 = v_row.account_last4)
    AND (
      r.match_merchant IS NULL
      OR (
        v_row.merchant IS NOT NULL
        AND CASE COALESCE(r.match_merchant_mode, 'contains')
          WHEN 'exact'      THEN UPPER(v_row.merchant) = UPPER(r.match_merchant)
          WHEN 'startswith' THEN UPPER(v_row.merchant) LIKE UPPER(r.match_merchant) || '%'
          ELSE                    UPPER(v_row.merchant) LIKE '%' || UPPER(r.match_merchant) || '%'
        END
      )
    )
    AND (r.match_amount_min IS NULL OR v_row.amount >= r.match_amount_min)
    AND (r.match_amount_max IS NULL OR v_row.amount <= r.match_amount_max)
  ORDER BY
      (CASE WHEN r.match_merchant       IS NOT NULL THEN 1 ELSE 0 END
     + CASE WHEN r.match_account_last4  IS NOT NULL THEN 1 ELSE 0 END
     + CASE WHEN r.match_amount_min     IS NOT NULL THEN 1 ELSE 0 END
     + CASE WHEN r.match_amount_max     IS NOT NULL THEN 1 ELSE 0 END) DESC,
      CASE r.confidence WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0 END DESC,
      r.rule_name
  LIMIT 1;

  IF NOT FOUND THEN
    UPDATE public.cash_register_preliminary
       SET coding_status = COALESCE(coding_status, 'unclassified'),
           updated_at    = NOW()
     WHERE id = p_row_id;
    RETURN QUERY SELECT false, NULL::uuid, NULL::text, NULL::text, false;
    RETURN;
  END IF;

  UPDATE public.cash_register_preliminary
     SET suggested_debit_account  = v_rule.debit_account,
         suggested_credit_account = v_rule.credit_account,
         suggested_rule_id        = v_rule.id,
         suggested_confidence     = v_rule.confidence,
         applied_rule_id          = CASE WHEN v_rule.confidence = 'high' THEN v_rule.id ELSE applied_rule_id END,
         coding_status            = CASE
                                      WHEN v_rule.confidence = 'high'   THEN 'auto_classified'
                                      ELSE 'needs_peter'
                                    END,
         updated_at               = NOW()
   WHERE id = p_row_id;

  UPDATE public.txn_coding_rules
     SET usage_count     = COALESCE(usage_count, 0) + 1,
         last_matched_at = NOW()
   WHERE id = v_rule.id;

  RETURN QUERY SELECT true, v_rule.id, v_rule.rule_name, v_rule.confidence, (v_rule.confidence = 'high');
END;
$function$;

GRANT EXECUTE ON FUNCTION public.apply_coding_rule_to_cash_register_row(uuid) TO service_role;

-- ============================================================
-- 3. Trigger function + trigger, repointed to the new names
-- ============================================================
DROP TRIGGER IF EXISTS trg_bank_register_apply_coding_rules ON public.cash_register_preliminary;
DROP FUNCTION IF EXISTS public.tg_bank_register_apply_coding_rules();

CREATE FUNCTION public.tg_cash_register_apply_coding_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  PERFORM public.apply_coding_rule_to_cash_register_row(NEW.id);
  RETURN NEW;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.tg_cash_register_apply_coding_rules() TO authenticated, service_role;

CREATE TRIGGER trg_cash_register_apply_coding_rules
  AFTER INSERT ON public.cash_register_preliminary
  FOR EACH ROW EXECUTE FUNCTION public.tg_cash_register_apply_coding_rules();

-- ============================================================
-- 4. Delete the personal register entirely: recipe (+ its run log,
--    required first — FK is NO ACTION) and the table itself.
-- ============================================================
DELETE FROM public.automation_run_log
WHERE recipe_id = '85241192-e665-4c06-aa66-87f7c1e1cbb4';

DELETE FROM public.automation_recipes
WHERE id = '85241192-e665-4c06-aa66-87f7c1e1cbb4';

DROP TABLE public.personal_register_preliminary;

-- ============================================================
-- 5. Fix the Cash Register (formerly Bank Alert) ingestor recipe:
--    - rename for clarity
--    - output_table -> cash_register_preliminary
--    - drop "in:inbox" from the Gmail query: real US Bank alert emails
--      (confirmed live, as recent as 2026-08-06) are landing UNREAD but
--      OUTSIDE inbox, so "in:inbox" was silently matching zero messages
--      every run for days
--    - archive_label_ids_to_add is the key the runner code actually reads
--      (gmail_labels / universal_archive_label_names / drive_folders /
--      drive_parent_folder_id_setting were never read by any code path —
--      pure dead config, some pointing at Drive/Gmail structure that no
--      longer exists post-reorg). Route archived alerts to the live
--      "Accounts/Alerts" label (Label_10) per Peter's direction.
--    - on_conflict_column (singular) was never read by the writer either;
--      the real key is on_conflict_columns (plural) / unique_on. Fixed.
-- ============================================================
UPDATE public.automation_recipes
SET recipe_name = 'Cash Register Alert Ingestor',
    output_table = 'cash_register_preliminary',
    input_config = jsonb_build_object(
      'dedupe_by', 'source_message_id',
      'gl_firewall', true,
      'gmail_query', 'from:usbank@notifications.usbank.com newer_than:14d',
      'max_results', 10,
      'output_table', 'cash_register_preliminary',
      'apply_coding_rules', true,
      'coding_rules_table', 'txn_coding_rules',
      'archive_after_parse', true,
      'archive_label_ids_to_add', jsonb_build_array('Label_10')
    ),
    output_config = jsonb_build_object(
      'account_labels', jsonb_build_object(
        '3439', 'US Bank Business CC ...3439',
        '3977', 'US Bank Business Checking ...3977',
        '4335', 'US Bank Business Checking ...4335',
        '4676', 'US Bank Business CC ...4676'
      ),
      'default_status', 'unreconciled',
      'on_conflict_columns', jsonb_build_array('source_message_id'),
      'auto_flag_possible_transfer', jsonb_build_object(
        'rule', 'same_day_same_amount_opposite_direction',
        'enabled', true,
        'do_not_net', true,
        'set_status', 'possible_transfer',
        'account_pair', jsonb_build_array('3977', '4335')
      )
    ),
    updated_at = now()
WHERE id = '24628de9-e206-4dea-b51c-bc40721e404d';

UPDATE public.automation_recipes
SET output_table = 'cash_register_preliminary', updated_at = now()
WHERE id = '21ad2829-5796-4b5b-b11e-b2dce8b839c8';
