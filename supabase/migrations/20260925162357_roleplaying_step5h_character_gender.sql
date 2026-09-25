-- Roleplaying step 5h: characters have a gender (Peter 2026-09-25). The Shadowkin (Elliott) is male; Karen (Becca),
-- Zaboo (Bella) and Plu Plu the Gremlin Princess (Olive) are female.
ALTER TABLE public.rpg_characters ADD COLUMN IF NOT EXISTS gender text CHECK (gender IN ('male', 'female'));
COMMENT ON COLUMN public.rpg_characters.gender IS 'male or female; the log and the sheet use it for he/she.';
UPDATE public.rpg_characters c SET gender = CASE WHEN k.name = 'Elliott' THEN 'male' ELSE 'female' END
  FROM public.family_kids k WHERE k.id = c.kid_id AND c.gender IS NULL;
DO $do$ BEGIN
  IF (SELECT count(*) FROM public.rpg_characters WHERE gender IS NULL AND kid_id IS NOT NULL) > 0 THEN RAISE EXCEPTION 'a character has no gender'; END IF;
END $do$;
