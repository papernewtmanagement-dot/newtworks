-- roleplaying_unify9c_drop_set_input
-- Sheet redesign, step 3 (Peter 2026-09-28, "defaults" = 4A): a rolled trait moves only three ways, the whole-sheet
-- re-roll (rpg_reroll_character), an event (rpg_adjust_trait, +1 or −1 with the Spirit pair rules) and play through
-- the trickle (rpg_trickle → rpg_add_skill_points → rpg_move_trait). The by-hand setter rpg_set_input, which typed a
-- number straight into the rolled value past the pair rules and the root cap, is dropped. Callers checked before the
-- drop: no database function reads it (pg_proc), the only page that called it (src/modules/Roleplaying.jsx) stopped in
-- commit 3b140f8c, no edge function is part of the game.
DO $do$
DECLARE v_callers text;
BEGIN
  SELECT string_agg(p.proname, ', ') INTO v_callers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname <> 'rpg_set_input'
     AND pg_get_functiondef(p.oid) LIKE '%rpg_set_input(%';
  IF v_callers IS NOT NULL THEN RAISE EXCEPTION 'rpg_set_input still called by: %', v_callers; END IF;
END $do$;
DROP FUNCTION IF EXISTS public.rpg_set_input(uuid, text, integer);
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'rpg_set_input') THEN
    RAISE EXCEPTION 'rpg_set_input still exists';
  END IF;
END $do$;
