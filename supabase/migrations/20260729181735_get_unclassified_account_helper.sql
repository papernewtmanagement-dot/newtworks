-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-29 18:17:35 UTC (ledger name: get_unclassified_account_helper) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260729181735.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Helper: given an entity + type, return the *Unclassified account id.
-- Creates the account on the fly if the entity doesn't have one yet (for future entities).
CREATE OR REPLACE FUNCTION public.get_unclassified_account_id(
  p_agency_id uuid,
  p_entity_id uuid,
  p_account_type text DEFAULT 'expense'
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_slug text;
  v_code text;
BEGIN
  IF p_entity_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_account_id
  FROM public.chart_of_accounts
  WHERE agency_id = p_agency_id
    AND business_entity_id = p_entity_id
    AND account_name = '*Unclassified'
    AND account_type = p_account_type
    AND is_active = true
  LIMIT 1;

  IF v_account_id IS NOT NULL THEN
    RETURN v_account_id;
  END IF;

  -- Create if missing
  SELECT UPPER(slug) INTO v_slug FROM public.business_entities WHERE id = p_entity_id;
  IF v_slug IS NULL THEN RETURN NULL; END IF;

  v_code := 'COA-UNCL-' || v_slug || CASE WHEN p_account_type = 'income' THEN '-INC' ELSE '' END;

  INSERT INTO public.chart_of_accounts
    (agency_id, business_entity_id, account_code, account_name, account_type, is_active, created_at)
  VALUES
    (p_agency_id, p_entity_id, v_code, '*Unclassified', p_account_type, true, NOW())
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_account_id;

  IF v_account_id IS NULL THEN
    SELECT id INTO v_account_id FROM public.chart_of_accounts
    WHERE agency_id = p_agency_id AND account_code = v_code LIMIT 1;
  END IF;

  RETURN v_account_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.get_unclassified_account_id(uuid, uuid, text) TO authenticated;
