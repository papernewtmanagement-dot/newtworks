-- The digest built a long message into v_msg and then threw it away -- the
-- alert it used to feed was removed and the build was left behind. The
-- Telegram note is deliberately just a count and a link; that stays. Removing
-- the dead build so nobody reads it as the live text.

CREATE OR REPLACE FUNCTION public.production_change_digest_daily(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_day date := public.rp_today_central();
  v_n integer := 0;
  v_url text; v_tg text; v_prev bigint; v_chat bigint; v_res jsonb; v_new_msg_id bigint;
BEGIN
  SELECT count(*)::integer INTO v_n
    FROM public.production_changes_for_day(p_agency_id, v_day) d;
  v_n := COALESCE(v_n, 0);

  IF v_n = 0 THEN
    RETURN jsonb_build_object('ok', true, 'records_processed', 0, 'output_summary', 'no edits or removals today');
  END IF;

  v_url := 'https://newtworks.vercel.app/?tab=changes&day=' || v_day::text;

  -- Short note to the management channel. Count and a link, nothing else.
  v_tg := v_n || ' change' || CASE WHEN v_n = 1 THEN '' ELSE 's' END ||
          ' to production records today (' || to_char(v_day, 'Mon FMDD') || ').' || E'\n' || v_url;

  SELECT s.telegram_message_id, s.chat_id INTO v_prev, v_chat
    FROM public.production_change_digest_sends s
   WHERE s.agency_id = p_agency_id AND s.day = v_day;

  BEGIN
    IF v_prev IS NOT NULL AND v_chat IS NOT NULL THEN
      PERFORM public.telegram_edit_message_text(v_chat, v_prev, v_tg, NULL);
      UPDATE public.production_change_digest_sends
         SET change_count = v_n, updated_at = now()
       WHERE agency_id = p_agency_id AND day = v_day;
    ELSE
      v_res := public.telegram_send('admin', v_tg, p_agency_id);
      v_new_msg_id := NULLIF(v_res #>> '{result,message_id}', '')::bigint;
      INSERT INTO public.production_change_digest_sends (agency_id, day, chat_id, telegram_message_id, change_count)
      SELECT p_agency_id, v_day, r.chat_id, v_new_msg_id, v_n
        FROM public.telegram_routes r
       WHERE r.agency_id = p_agency_id AND r.route_key = 'admin' AND r.is_active
      ON CONFLICT (agency_id, day) DO UPDATE
        SET telegram_message_id = EXCLUDED.telegram_message_id,
            chat_id = EXCLUDED.chat_id, change_count = EXCLUDED.change_count, updated_at = now();
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- Telegram being down must never cost us the run.
    RAISE WARNING 'production_change_digest_daily telegram: %', SQLERRM;
  END;

  RETURN jsonb_build_object('ok', true, 'records_processed', v_n,
    'output_summary', v_n || ' edit/removal(s) summarized for ' || v_day::text);
END $function$;
