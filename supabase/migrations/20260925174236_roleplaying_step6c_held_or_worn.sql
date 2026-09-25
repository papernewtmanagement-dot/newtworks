-- Roleplaying step 6c: an item is held or worn, nothing more (Peter 2026-09-25). Held (in hand) → it blocks, with its
-- block strength on top of the Block skill, and if it has a weapon skill it attacks. Worn → it absorbs its absorb.
-- The role column goes; worn says which it is. Existing items: the dagger is held (and swings with the dagger skill),
-- everything else is worn.
ALTER TABLE public.rpg_items ADD COLUMN IF NOT EXISTS worn boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.rpg_items.worn IS 'true = worn on the body (absorbs its absorb); false = held in hand (blocks with its block, attacks with weapon_key). equipped says whether it is in use at all.';
ALTER TABLE public.rpg_items ALTER COLUMN block SET DEFAULT 1;
UPDATE public.rpg_items SET worn = (name NOT ILIKE 'dagger%' AND name NOT ILIKE 'sword%'), block = CASE WHEN block = 0 THEN 1 ELSE block END;
UPDATE public.rpg_items SET weapon_key = 'dagger' WHERE name ILIKE 'dagger%' AND weapon_key IS NULL;
ALTER TABLE public.rpg_items DROP COLUMN IF EXISTS role;
COMMENT ON COLUMN public.rpg_items.weapon_key IS 'The weapon skill a held item swings with (dagger, sword…); null for something that only blocks.';

UPDATE public.rpg_rules SET body = replace(replace(body,
   '2. Block: if the defender holds something that blocks (a shield, a weapon; the Shield of Faith against a spiritual attack), the attacker rolls again against Block × 2 (Block = Strength, Agility and Self-Control averaged, plus the shield''s block).',
   '2. Block: anything held in the hand can block (a shield best, a dagger a little; the Shield of Faith against a spiritual attack). The attacker rolls again against Block × 2 (Block = Strength, Agility and Self-Control averaged, plus what is held).'),
   '3. Hit: damage is die − Needed as always. Worn armor absorbs its absorb value first and takes that much itself',
   '3. Hit: damage is die − Needed as always. Anything worn absorbs its absorb value first and takes that much itself')
 WHERE key = 'attack_gates';

-- rpg_act: held blocks, worn absorbs, held with a weapon skill swings. In-place edits at three anchors.
DO $do$
DECLARE v_src text; a text[]; n text[]; i integer;
BEGIN
  v_src := pg_get_functiondef('public.rpg_act'::regproc);
  IF position('NOT i.worn' IN v_src) > 0 THEN RETURN; END IF;
  a := ARRAY['WHERE character_id = v_actor.character_id AND equipped AND role = ''weapon'' AND weapon_key = p_stat_key AND integrity_damage < integrity ORDER BY sort_order LIMIT 1;',
             'WHERE i.character_id = v_t.character_id AND i.equipped AND i.role IN (''shield'', ''weapon'') AND i.integrity_damage < i.integrity',
             'WHERE i.character_id = v_t.character_id AND i.equipped AND i.role = ''armor'' AND i.absorb > 0 AND i.integrity_damage < i.integrity ORDER BY i.absorb DESC LOOP'];
  n := ARRAY['WHERE character_id = v_actor.character_id AND equipped AND NOT worn AND weapon_key = p_stat_key AND integrity_damage < integrity ORDER BY sort_order LIMIT 1;',
             'WHERE i.character_id = v_t.character_id AND i.equipped AND NOT i.worn AND i.integrity_damage < i.integrity',
             'WHERE i.character_id = v_t.character_id AND i.equipped AND i.worn AND i.absorb > 0 AND i.integrity_damage < i.integrity ORDER BY i.absorb DESC LOOP'];
  FOR i IN 1..3 LOOP
    IF (length(v_src) - length(replace(v_src, a[i], ''))) / length(a[i]) <> 1 THEN RAISE EXCEPTION 'rpg_act anchor % not unique', i; END IF;
    v_src := replace(v_src, a[i], n[i]);
  END LOOP;
  EXECUTE v_src;
END $do$;
DO $do$ BEGIN
  IF position('NOT i.worn' IN pg_get_functiondef('public.rpg_act'::regproc)) = 0 THEN RAISE EXCEPTION 'rpg_act edit did not land'; END IF;
  IF position('''weapon''' IN pg_get_functiondef('public.rpg_act'::regproc)) > 0 THEN RAISE EXCEPTION 'a role check remains in rpg_act'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'rpg_items' AND column_name = 'role') THEN RAISE EXCEPTION 'role column remains'; END IF;
END $do$;
