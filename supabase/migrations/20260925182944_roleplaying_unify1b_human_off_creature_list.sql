-- Roleplaying unification, step 1 follow-up (Peter 2026-09-25): Human stays off the players' Creatures page.
-- Human is the players' own card, not a creature they have met, so it starts hidden like every other card. Anyone may
-- still make a character from it; any other card has to be shown to players first (the game master may use any card).
-- Before this, Show/Hide on the Human card also switched character-making on and off for the kids.
UPDATE public.rpg_creatures SET shown_to_players = false
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'human';

CREATE OR REPLACE FUNCTION public.rpg_new_character(p_name text, p_kid_id uuid DEFAULT NULL::uuid, p_is_npc boolean DEFAULT false, p_template_key text DEFAULT 'human'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Makes a character from a card. Its inputs come from rpg_roll_inputs(card): a Human rolls every trait d100 ÷ 10,
-- rounded up (a 47 makes 5); a card with ranges or fixed numbers rolls inside them.
-- Anyone may make a Human (the players' own card). Players may use another card once it has been shown to them;
-- the game master may use any card on the list.
DECLARE
  v_id      uuid;
  v_n       integer;
  v_key     text;
  v_active  boolean;
  v_shown   boolean;
  v_palette text[] := ARRAY['#737A59','#A88B5F','#5E7A77','#6E5B7A','#A87A75','#255C99','#2E8B57','#D4A017'];
BEGIN
  PERFORM public.require_login('family');
  IF NOT public.rpg_can_play() THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'name required'; END IF;
  SELECT key, is_active, shown_to_players INTO v_key, v_active, v_shown
    FROM public.rpg_creatures
   WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = coalesce(p_template_key, 'human');
  IF v_key IS NULL OR NOT v_active THEN RAISE EXCEPTION 'that card is not on the list'; END IF;
  IF v_key <> 'human' AND NOT v_shown AND NOT public.family_is_parent() THEN
    RAISE EXCEPTION 'that card has not been shown to players';
  END IF;
  SELECT count(*) INTO v_n FROM public.rpg_characters WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365';
  INSERT INTO public.rpg_characters (name, kid_id, is_npc, template_key, inputs, color)
  VALUES (btrim(p_name), p_kid_id, coalesce(p_is_npc, false), v_key, public.rpg_roll_inputs(v_key), v_palette[(v_n % 8) + 1])
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;

DO $g$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.rpg_new_character(text, uuid, boolean, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rpg_new_character lost its grant';
  END IF;
  IF (SELECT shown_to_players FROM public.rpg_creatures
       WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND key = 'human') THEN
    RAISE EXCEPTION 'Human is still on the players'' Creatures page';
  END IF;
END $g$;

NOTIFY pgrst, 'reload schema';
