-- Roleplaying: Peter 2026-09-24 (after 20260924233245): Difficulty itself is the variable. One roll formula, always:
--   Needed = 100 × Difficulty ÷ (Difficulty + Skill)          skill 5 vs difficulty 5 → 50
-- The doubling is not in the roll formula; it is how an opponent's difficulty is derived:
--   a fixed challenge (a wall, a lock, a jump) has its own difficulty rating;
--   a defender who cannot act (asleep, bound, unaware): Difficulty = their skill;
--   an opponent who can act (defending, resisting, hiding): Difficulty = their skill × 2, for their skill and their will to use it.
--   skill 5 vs an opponent of skill 5 → difficulty 10 → 66.67 (lands about one time in three)
-- So rpg_needed goes back to two arguments (the opposed flag added an hour ago is removed; nothing ships against it yet),
-- rpg_difficulty(skill, can_act) derives a defender's difficulty from one saved setting (opponent_will_multiplier = 2),
-- and the roll log's difficulty column carries the derived number, so no opposed column is ever needed on rpg_rolls.
-- Peter also ruled: the admin manual page "Roleplaying" is updated any time a rule changes. A statement trigger on
-- rpg_rules now writes that page from the rule cards (rpg_manual_page_sync), so it cannot be forgotten.

-- 1. The one number the doubling comes from.
INSERT INTO public.rpg_settings (agency_id, key, value, label)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'opponent_will_multiplier', 2,
       'An opponent who can act: Difficulty = their skill × this (their skill and their will to use it)'
WHERE NOT EXISTS (SELECT 1 FROM public.rpg_settings
                  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'opponent_will_multiplier');

-- 2. rpg_difficulty: the difficulty a defender presents.
CREATE OR REPLACE FUNCTION public.rpg_difficulty(p_skill numeric, p_can_act boolean DEFAULT true)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- A defender's difficulty: their skill × opponent_will_multiplier when they can act (skill and will), their skill when they cannot.
-- skill 5, can act → 10; skill 5, asleep → 5. The play engine and the Rules tab calculator both call this; nothing re-implements it.
SELECT public.require_login('family');
  SELECT greatest(coalesce(p_skill, 0), 0) * CASE WHEN p_can_act THEN public.rpg_setting('opponent_will_multiplier') ELSE 1 END;
$function$;

COMMENT ON FUNCTION public.rpg_difficulty(numeric, boolean) IS
'Difficulty a defender presents: skill × opponent_will_multiplier (2) when they can act, skill × 1 when they cannot. Peter 2026-09-24. Feed the result to rpg_needed.';

-- 3. rpg_needed back to (skill, difficulty): one formula, always. The three-argument version is replaced.
DROP FUNCTION IF EXISTS public.rpg_needed(numeric, numeric, boolean);

CREATE OR REPLACE FUNCTION public.rpg_needed(p_skill numeric, p_difficulty numeric)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Needed = the lowest d100 result that counts. One formula, always: 100 × D ÷ (D + S).
--   5 vs 5 → 50; 5 vs 10 → 66.67; 5 vs 15 → 75; 15 vs 5 → 25.
-- An opponent's difficulty is derived first by rpg_difficulty (skill × 2 when they can act), then passed in here.
-- Difficulty 0 is no challenge → 0 (any roll counts, teaches nothing). Skill 0 → 100 (only a 100 counts).
-- Critical = 100 − (100 − Needed) × crit_chance (unchanged).
SELECT public.require_login('family');
  WITH n AS (
    SELECT CASE WHEN coalesce(p_difficulty, 0) <= 0 THEN 0::numeric
                ELSE 100 * p_difficulty / (p_difficulty + greatest(coalesce(p_skill, 0), 0))
           END AS needed
  )
  SELECT jsonb_build_object(
    'needed',   round(needed, 2),
    'critical', round(100 - ((100 - needed) * public.rpg_setting('crit_chance')), 2))
  FROM n;
$function$;

COMMENT ON FUNCTION public.rpg_needed(numeric, numeric) IS
'Needed = lowest d100 result that counts = 100·D/(D+S). One formula, always; an opponent''s D comes from rpg_difficulty. Peter 2026-09-24. Sheet, Rules tab calculator and rpg_roll all call this; nothing re-implements it.';

-- 4. The manual page follows the rule cards. Written from rpg_rules whenever a rule is inserted, updated or deleted.
CREATE OR REPLACE FUNCTION public.rpg_manual_page_sync()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Writes the admin manual page "Roleplaying" (manuals id d2ed2aac-1621-4ce2-860c-095ecfc15ade) from rpg_rules in card order.
-- Peter 2026-09-24: the manual page is updated any time we make a change. The page is a mirror; the cards are the source.
DECLARE v_n integer;
BEGIN
  UPDATE public.manuals m SET
    content = '*This page is written from the game''s rule cards and updates itself whenever a rule changes.*' || E'\n\n' ||
              coalesce((SELECT string_agg('## ' || r.title || E'\n\n' || r.body, E'\n\n' ORDER BY r.sort_order, r.key)
                        FROM public.rpg_rules r WHERE r.agency_id = m.agency_id), ''),
    version = coalesce(m.version, 0) + 1,
    updated_at = now()
  WHERE m.id = 'd2ed2aac-1621-4ce2-860c-095ecfc15ade';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN RAISE WARNING 'rpg_manual_page_sync: manual page d2ed2aac-1621-4ce2-860c-095ecfc15ade not found'; END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpg_rules_sync_manual_page()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public.rpg_manual_page_sync();
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS rpg_rules_sync_manual_page ON public.rpg_rules;
CREATE TRIGGER rpg_rules_sync_manual_page
  AFTER INSERT OR UPDATE OR DELETE ON public.rpg_rules
  FOR EACH STATEMENT EXECUTE FUNCTION public.rpg_rules_sync_manual_page();

-- 5. The three rule cards, in one statement (one trigger fire), Difficulty as the variable throughout.
UPDATE public.rpg_rules r SET body = v.body, updated_at = now()
FROM (VALUES
 ('roll_check', 'Roll a d100. The result has to reach the Needed number.
Needed is the lowest die result that counts. One formula, always:
Needed = 100 × Difficulty ÷ (Difficulty + Skill).
*Skill 5 against difficulty 5 needs 50 or more. That lands about half the time.*
*Skill 5 against difficulty 15 needs 75 or more. Skill 15 against difficulty 5 needs 25 or more.*

Where Difficulty comes from:
A fixed challenge (a wall, a lock, a jump) has its own difficulty rating.
A defender who cannot act (asleep, bound, unaware): Difficulty = their skill.
An opponent who can act (defending, resisting, hiding): Difficulty = their skill × 2. You are fighting their skill and their will to use it, and avoiding a hit is easier than landing one.
*Skill 5 against an opponent of skill 5: difficulty 10, needs 67 or more. That lands about one time in three.*
*Skill 10 against skill 5: difficulty 10, needs 50 or more. Skill 5 against skill 10: difficulty 20, needs 80 or more.*

Critical = 100 − (100 − Needed) × Critical Chance. Critical Chance is 10%.
*Needed 67: a roll of 97 or more is a critical.*
At or above Critical is a critical success (C). At or above Needed is a success (Y). Below Needed fails.
A skill of 0 needs a 100. A difficulty of 0 is no challenge: any roll succeeds.
Difficulty is 5 unless the game master sets another.'),
 ('skill_gain', 'Every roll of a skill pays skill points, whether it succeeds or fails. That includes the additional rolls after a critical roll.

Skill points = the die result × Needed ÷ 100. Needed is the lowest die result that counts on that roll (see Roll Check).
*Skill 10 against an opponent of skill 5 (difficulty 10, Needed 50): a roll of 40 pays 20 points, a roll of 90 pays 45.*
*Skill 5 against skill 10 (difficulty 20, Needed 80): a roll of 60 misses but still pays 48. A roll of 90 pays 72.*
*Skill 5 against skill 5 (difficulty 10, Needed 67): a roll of 90 pays about 60.*
Easy targets teach little and hard targets teach the most. A roll can never pay more than the die shows.
A skill of 0 (Needed 100) learns fastest. A difficulty of 0 (Needed 0) teaches nothing.

A skill will increase to the next level when skill points have been earned equal to 1000 times the sum of the old level AND the new level. *For example, advancing to level 12 will require 23k skill points (11k skill points + 12k skill points).* At equal skill a roll pays about 34 points on average, so level 1 to level 2 (3,000 points) takes about 90 rolls.

Characters can train in a skill by using that skill, though time and resources may limit training. *For example, hunger may set in or training with a tutor may cost money.*

Abilities, strengths, and attributes can only be increased through special means.'),
 ('damage', 'The attacker rolls once against the defender''s difficulty (their skill × 2 when they can act, see Roll Check). The defender does not roll.

Damage = the die result − Needed, rounded down, and at least 1 on any hit that lands. A critical prompts an additional roll, and that roll''s result adds to the damage.
*Skill 5 against an opponent of skill 5 (difficulty 10, Needed 67): a roll of 80 does 13 damage. A roll of 68 does 1.*
*Skill 10 against skill 5 (difficulty 10, Needed 50): a roll of 90 does 40.*
*Skill 5 against skill 10 (difficulty 20, Needed 80): a roll of 95 does 15.*
Damage comes off Physical Vitality. At 0 the character is down until healed.')
) AS v(key, body)
WHERE r.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND r.key = v.key;

-- 6. Guards: one two-argument rpg_needed, the same callers as before, the ladder, the derived difficulty, and the manual page written.
DO $$
DECLARE v_n integer; v_callers text; v_5v5 numeric; v_5v10 numeric; v_15v5 numeric; v_s0 numeric; v_d0 numeric;
        v_dact numeric; v_dstill numeric; v_via numeric; v_page text;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'rpg_needed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'expected exactly one rpg_needed, found %', v_n; END IF;
  IF (SELECT pg_get_function_identity_arguments(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'rpg_needed') <> 'p_skill numeric, p_difficulty numeric' THEN
    RAISE EXCEPTION 'rpg_needed signature is not (skill, difficulty)';
  END IF;

  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_callers
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname <> 'rpg_needed'
    AND pg_get_functiondef(p.oid) LIKE '%public.rpg_needed(%';
  IF v_callers IS DISTINCT FROM 'rpg_roll, rpg_sheet' THEN
    RAISE EXCEPTION 'rpg_needed callers changed: %', coalesce(v_callers, '(none)');
  END IF;

  PERFORM set_config('request.jwt.claims', '{"sub":"dc9a6291-6d79-410b-9870-ff5d0c81a7f0","role":"authenticated"}', true);
  v_5v5   := (public.rpg_needed(5, 5)->>'needed')::numeric;
  v_5v10  := (public.rpg_needed(5, 10)->>'needed')::numeric;
  v_15v5  := (public.rpg_needed(15, 5)->>'needed')::numeric;
  v_s0    := (public.rpg_needed(0, 5)->>'needed')::numeric;
  v_d0    := (public.rpg_needed(5, 0)->>'needed')::numeric;
  v_dact  := public.rpg_difficulty(5);
  v_dstill := public.rpg_difficulty(5, false);
  v_via   := (public.rpg_needed(5, public.rpg_difficulty(5))->>'needed')::numeric;
  IF v_5v5 <> 50 OR v_5v10 <> 66.67 OR v_15v5 <> 25 OR v_s0 <> 100 OR v_d0 <> 0 OR v_dact <> 10 OR v_dstill <> 5 OR v_via <> 66.67 THEN
    RAISE EXCEPTION 'ladder wrong: 5v5=% 5v10=% 15v5=% s0=% d0=% dact=% dstill=% via=%', v_5v5, v_5v10, v_15v5, v_s0, v_d0, v_dact, v_dstill, v_via;
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT content INTO v_page FROM public.manuals WHERE id = 'd2ed2aac-1621-4ce2-860c-095ecfc15ade';
  IF v_page IS NULL OR position('Needed = 100 × Difficulty ÷ (Difficulty + Skill).' in v_page) = 0
     OR position('## Creature Cards at the Table' in v_page) = 0 THEN
    RAISE EXCEPTION 'manual page was not written from the rule cards';
  END IF;
END $$;
