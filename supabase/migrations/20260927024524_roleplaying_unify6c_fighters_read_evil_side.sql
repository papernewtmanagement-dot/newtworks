-- Roleplaying unify6c: a fighter's numbers include the evil side of a Spirit pair now that it reads how far it wins
-- (unify6b). It was left out because it always read 0; the sanctify roll against the Bramblemaw's Fascination with
-- Evil needs it (12, so difficulty 24).
DO $$
DECLARE
  v text := pg_get_functiondef('public.rpg_participant_values(uuid,text[])'::regprocedure);
  a text := E'                WHERE (p_keys IS NULL OR k = ANY (p_keys))\n                  AND NOT EXISTS (SELECT 1 FROM public.rpg_stat_definitions d WHERE d.key = k AND d.side = ''evil'') LOOP';
  b text := E'                WHERE (p_keys IS NULL OR k = ANY (p_keys)) LOOP';
BEGIN
  IF (length(v) - length(replace(v, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rpg_participant_values anchor not found exactly once'; END IF;
  EXECUTE replace(v, a, b);
END $$;
