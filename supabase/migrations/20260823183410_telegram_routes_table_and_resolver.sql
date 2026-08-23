CREATE TABLE IF NOT EXISTS public.telegram_routes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  route_key text NOT NULL,
  bot text NOT NULL,
  chat_id bigint NOT NULL,
  audience text NOT NULL,
  notes text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS telegram_routes_agency_key_uniq
  ON public.telegram_routes (agency_id, route_key);

COMMENT ON TABLE public.telegram_routes IS
  'One row per Telegram destination. Automations name a route_key instead of typing in a chat id and picking a bot. Add a route here, never a chat id in code.';

ALTER TABLE public.telegram_routes ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='telegram_routes' AND policyname='telegram_routes_read') THEN
    CREATE POLICY telegram_routes_read ON public.telegram_routes
      FOR SELECT TO authenticated USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='telegram_routes' AND policyname='telegram_routes_service_all') THEN
    CREATE POLICY telegram_routes_service_all ON public.telegram_routes
      FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

INSERT INTO public.telegram_routes (agency_id, route_key, bot, chat_id, audience, notes)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365', 'admin',    'paper_newt', -5518666399, 'Peter and admin/back-office only', 'Paper Newt Management group. Default for anything not explicitly meant for the whole team.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'team',     'pjsagency',  -5377408548, 'Whole agency team',                 'PJS Agency group. Everyone on the team reads this.'),
  ('126794dd-25ff-47d2-a436-724499733365', 'peter_dm', 'paper_newt',   7778113542, 'Peter only, direct message',        'Direct message to Peter.')
ON CONFLICT (agency_id, route_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.telegram_send(
  p_route_key text,
  p_text text,
  p_agency_id uuid DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_parse_mode text DEFAULT NULL,
  p_reply_to_message_id bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_bot text;
  v_chat_id bigint;
  v_valid text;
BEGIN
  SELECT bot, chat_id INTO v_bot, v_chat_id
  FROM public.telegram_routes
  WHERE agency_id = p_agency_id AND route_key = p_route_key AND is_active = true;

  IF v_bot IS NULL THEN
    SELECT string_agg(route_key, ', ' ORDER BY route_key) INTO v_valid
    FROM public.telegram_routes
    WHERE agency_id = p_agency_id AND is_active = true;
    RAISE EXCEPTION
      'telegram_send: no active route named %. Nothing was sent. Valid routes: %',
      COALESCE(p_route_key, '(null)'), COALESCE(v_valid, '(none configured)');
  END IF;

  RETURN public.telegram_send_message_v2(v_chat_id, p_text, v_bot, p_parse_mode, p_reply_to_message_id);
END;
$function$;

COMMENT ON FUNCTION public.telegram_send(text, text, uuid, text, bigint) IS
  'Send a Telegram message by naming a destination from telegram_routes. Unknown route = hard error, nothing sent. Use this instead of telegram_send_message / telegram_send_message_v2 in all new automations.';
