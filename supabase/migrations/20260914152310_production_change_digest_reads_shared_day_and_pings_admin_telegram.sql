-- The daily digest now reads production_changes_for_day, so the alert and the Changes tab are
-- built from one query. It also drops a short count into the management Telegram channel with
-- a link to that day on the tab.
--
-- Re-running the recipe does NOT post a second message. The first send is remembered here and
-- every later run EDITS that same message in place, the same way the alert is updated in place.
CREATE TABLE IF NOT EXISTS public.production_change_digest_sends (
  agency_id           uuid NOT NULL,
  day                 date NOT NULL,
  chat_id             bigint,
  telegram_message_id bigint,
  change_count        integer,
  sent_at             timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, day)
);
ALTER TABLE public.production_change_digest_sends ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS admin_read_production_change_digest_sends ON public.production_change_digest_sends;
CREATE POLICY admin_read_production_change_digest_sends ON public.production_change_digest_sends
  FOR SELECT USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid AND public.is_agency_admin());

CREATE OR REPLACE FUNCTION public.production_change_digest_daily(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_day date := public.rp_today_central();
  v_ref text; v_lines text[]; v_msg text; v_n integer := 0; v_id uuid;
  v_url text; v_tg text; v_prev bigint; v_chat bigint; v_res jsonb; v_new_msg_id bigint;
BEGIN
  v_ref := 'production:change_digest:' || v_day::text;

  SELECT count(*)::integer, array_agg(d.line ORDER BY d.changed_at)
    INTO v_n, v_lines
    FROM public.production_changes_for_day(p_agency_id, v_day) d;
  v_n := COALESCE(v_n, 0);

  IF v_n = 0 THEN
    RETURN jsonb_build_object('ok', true, 'records_processed', 0, 'output_summary', 'no edits or removals today');
  END IF;

  v_url := 'https://newtworks.vercel.app/?tab=changes&day=' || v_day::text;

  v_msg := v_n || ' change' || CASE WHEN v_n = 1 THEN '' ELSE 's' END ||
           ' to production records on ' || to_char(v_day, 'Mon FMDD') || E':\n\n' ||
           array_to_string(v_lines, E'\n') ||
           E'\n\nThe full before-and-after is on the Changes tab.';

  SELECT id INTO v_id FROM public.alerts
   WHERE agency_id = p_agency_id AND module_reference = v_ref LIMIT 1;

  IF v_id IS NULL THEN
    INSERT INTO public.alerts (id, agency_id, alert_type, severity, title, message, module_reference, is_read, is_resolved, created_at)
    VALUES (gen_random_uuid(), p_agency_id, 'production_change_digest', 'low',
            'Production edits and removals — ' || to_char(v_day, 'Mon FMDD'), v_msg, v_ref, false, false, now());
  ELSE
    UPDATE public.alerts SET message = v_msg, is_read = false, is_resolved = false WHERE id = v_id;
  END IF;

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
    -- Telegram being down must never cost us the alert, which is already written.
    RAISE WARNING 'production_change_digest_daily telegram: %', SQLERRM;
  END;

  RETURN jsonb_build_object('ok', true, 'records_processed', v_n,
    'output_summary', v_n || ' edit/removal(s) summarized for ' || v_day::text);
END $function$;