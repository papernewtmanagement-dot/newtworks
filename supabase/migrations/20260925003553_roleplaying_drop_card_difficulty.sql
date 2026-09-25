-- Roleplaying: Peter 2026-09-25 ruled 1A. rpg_card_difficulty(numeric) and rpg_settings.card_difficulty_offset have had no
-- caller since 20260925002256 (creature cards carry character-scale numbers; difficulties come from rpg_difficulty).
-- Callers are checked in the ledger before the drop; the migration fails if any remain.
DO $$
DECLARE v_callers text;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_callers
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname <> 'rpg_card_difficulty'
    AND pg_get_functiondef(p.oid) LIKE '%rpg_card_difficulty(%';
  IF v_callers IS NOT NULL THEN RAISE EXCEPTION 'rpg_card_difficulty still called by: %', v_callers; END IF;
END $$;

DROP FUNCTION IF EXISTS public.rpg_card_difficulty(numeric);

DELETE FROM public.rpg_settings
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'card_difficulty_offset';
