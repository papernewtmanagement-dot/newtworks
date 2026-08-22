-- Step 1a of pipeline repair (2026-07-31)
-- Helper function used by rewritten writers to find the entity-scoped
-- unclassified/suspense account. Replaces prior global COA-SUSP lookup that
-- broke after chart-of-accounts renumbering.

CREATE OR REPLACE FUNCTION public.get_entity_unclassified_account(
  p_agency_id uuid,
  p_business_entity_id uuid,
  p_direction text DEFAULT 'expense'  -- 'expense' | 'income'
) RETURNS uuid
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_business_entity_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF p_direction = 'income' THEN
    -- 0002 = *Unclassified Income (present on all entities)
    SELECT id INTO v_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND business_entity_id = p_business_entity_id
      AND account_code = '0002'
      AND is_active = TRUE
    LIMIT 1;
  ELSE
    -- Expense direction: prefer 0003 (business unclassified), else 0004 (personal unclassified)
    SELECT id INTO v_id FROM chart_of_accounts
    WHERE agency_id = p_agency_id
      AND business_entity_id = p_business_entity_id
      AND account_code IN ('0003','0004')
      AND is_active = TRUE
    ORDER BY account_code
    LIMIT 1;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.get_entity_unclassified_account(uuid, uuid, text) IS
'Returns the entity-scoped unclassified account for suspense/pending-review journal entries. Replaces prior global COA-SUSP lookup that broke after chart-of-accounts renumbering (2026-07-31).';
