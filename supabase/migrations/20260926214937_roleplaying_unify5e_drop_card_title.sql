-- The card title only headed the printed d20 block, which is gone.
ALTER TABLE public.rpg_creatures DROP COLUMN IF EXISTS card_title;
