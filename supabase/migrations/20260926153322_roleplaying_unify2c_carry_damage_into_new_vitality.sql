-- Roleplaying: Physical Vitality moved from the fruits (nine Spiritual Traits ÷ 2) to the Body (3 × Toughness + 2 × Strength)
-- in unify2b. Damage already carried is scaled to the new pool so nobody's state changes: Zaboo had 25 of 30 gone and
-- now has 13 of 16 gone. Rounded down, so nobody ends up worse off than before.
UPDATE public.rpg_characters c
   SET vitality_damage = floor(c.vitality_damage * (3 * (c.inputs->>'TO')::numeric + 2 * (c.inputs->>'ST')::numeric)
                               / nullif(floor(((c.inputs->>'LO')::numeric + (c.inputs->>'JO')::numeric + (c.inputs->>'PE')::numeric + (c.inputs->>'PA')::numeric + (c.inputs->>'KI')::numeric
                                             + (c.inputs->>'GO')::numeric + (c.inputs->>'FA')::numeric + (c.inputs->>'GE')::numeric + (c.inputs->>'SC')::numeric) / 2), 0))::integer
 WHERE c.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND c.vitality_damage > 0
   AND c.inputs ?& ARRAY['TO','ST','LO','JO','PE','PA','KI','GO','FA','GE','SC'];

DO $g$
BEGIN
  IF EXISTS (SELECT 1 FROM public.rpg_characters c
              WHERE c.vitality_damage > 3 * (c.inputs->>'TO')::numeric + 2 * (c.inputs->>'ST')::numeric) THEN
    RAISE EXCEPTION 'a character carries more damage than its new vitality';
  END IF;
END $g$;
