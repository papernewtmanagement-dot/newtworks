-- Roleplaying step 5g: a quick move (1 beat) has no cooldown, so Bramblemaw can Claw twice in a turn.
UPDATE public.rpg_creature_actions SET cooldown_turns = 0 WHERE beats = 1 AND kind IN ('action', 'bonus_action', 'legendary') AND cooldown_turns = 1;
UPDATE public.rpg_rules SET body = replace(body, 'Each action also has a cooldown in turns: Claw is back next turn, Briar Roar three turns later.', 'Each action also has a cooldown in turns: a quick Claw has none, Bite is back next turn, Briar Roar three turns later.')
 WHERE key = 'turn_order';
DO $do$ BEGIN
  IF (SELECT cooldown_turns FROM public.rpg_creature_actions WHERE id = 'b0d44b36-f883-4776-bea2-175d85e3de5e') <> 0 THEN RAISE EXCEPTION 'Claw still has a cooldown'; END IF;
END $do$;
