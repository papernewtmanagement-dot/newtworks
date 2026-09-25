-- Dewey, the Dashboard's billing explainer: saved customer worksheets (Peter 2026-09-25).
-- One worksheet per customer, keyed by first name, last initial and the last 4 of the
-- phone, the same household key the production log uses. The lines and the account
-- setup are stored exactly as the page holds them. Writes go through
-- billing_worksheet_save; the page reads through billing_worksheet_get and
-- billing_worksheet_list. Logins can also read their agency's rows directly, the way
-- the production log tables work, and family logins are blocked like everywhere else.
CREATE TABLE IF NOT EXISTS public.billing_worksheets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  customer_first_name text NOT NULL CHECK (btrim(customer_first_name) <> ''),
  customer_last_initial text NOT NULL CHECK (customer_last_initial ~ '^[A-Z]$'),
  phone_last4 text NOT NULL CHECK (phone_last4 ~ '^[0-9]{4}$'),
  customer_key text GENERATED ALWAYS AS (lower(btrim(customer_first_name)) || '|' || customer_last_initial || '|' || phone_last4) STORED,
  lines jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(lines) = 'array'),
  accounts jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(accounts) = 'object'),
  created_by uuid REFERENCES public.team(id),
  updated_by uuid REFERENCES public.team(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS billing_worksheets_customer_key_uq ON public.billing_worksheets (agency_id, customer_key);
CREATE INDEX IF NOT EXISTS billing_worksheets_recent_idx ON public.billing_worksheets (agency_id, updated_at DESC);

ALTER TABLE public.billing_worksheets ENABLE ROW LEVEL SECURITY;
CREATE POLICY billing_worksheets_auth_read ON public.billing_worksheets
  FOR SELECT TO authenticated USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
CREATE POLICY zz_block_family_login ON public.billing_worksheets AS RESTRICTIVE
  FOR ALL TO authenticated USING (NOT (SELECT auth_is_family())) WITH CHECK (NOT (SELECT auth_is_family()));

-- Save the worksheet for this customer. A second save for the same customer updates
-- the one row: the key is first name (any capitals), last initial and phone last 4.
CREATE OR REPLACE FUNCTION public.billing_worksheet_save(p_first text, p_initial text, p_phone4 text, p_lines jsonb, p_accounts jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_me uuid := public.current_team_member_id();
  v_agency uuid;
  v_first text := btrim(coalesce(p_first, ''));
  v_init text := upper(left(btrim(coalesce(p_initial, '')), 1));
  v_phone text := regexp_replace(coalesce(p_phone4, ''), '[^0-9]', '', 'g');
  v_row public.billing_worksheets;
BEGIN
  PERFORM public.require_login('staff');
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  IF v_agency IS NULL THEN
    RAISE EXCEPTION 'Sign in to save a worksheet.' USING ERRCODE = '42501';
  END IF;
  IF v_first = '' OR v_init !~ '^[A-Z]$' OR v_phone !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'A worksheet needs a first name, a last initial and the last 4 of the phone.';
  END IF;
  IF jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' OR jsonb_typeof(coalesce(p_accounts, '{}'::jsonb)) <> 'object' THEN
    RAISE EXCEPTION 'Worksheet lines must be a list and the accounts an object.';
  END IF;
  INSERT INTO public.billing_worksheets AS w
    (agency_id, customer_first_name, customer_last_initial, phone_last4, lines, accounts, created_by, updated_by)
  VALUES (v_agency, v_first, v_init, v_phone, coalesce(p_lines, '[]'::jsonb), coalesce(p_accounts, '{}'::jsonb), v_me, v_me)
  ON CONFLICT (agency_id, customer_key) DO UPDATE
    SET customer_first_name = EXCLUDED.customer_first_name,
        lines = EXCLUDED.lines,
        accounts = EXCLUDED.accounts,
        updated_by = EXCLUDED.updated_by,
        updated_at = now()
  RETURNING w.* INTO v_row;
  RETURN jsonb_build_object('ok', true, 'id', v_row.id, 'updated_at', v_row.updated_at);
END;
$function$;

-- The saved worksheet for one customer, or null when there is none.
CREATE OR REPLACE FUNCTION public.billing_worksheet_get(p_first text, p_initial text, p_phone4 text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid;
  v_key text := lower(btrim(coalesce(p_first, ''))) || '|' || upper(left(btrim(coalesce(p_initial, '')), 1))
                || '|' || regexp_replace(coalesce(p_phone4, ''), '[^0-9]', '', 'g');
  v_out jsonb;
BEGIN
  PERFORM public.require_login('staff');
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  IF v_agency IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT jsonb_build_object(
           'id', w.id, 'first', w.customer_first_name, 'initial', w.customer_last_initial, 'phone4', w.phone_last4,
           'lines', w.lines, 'accounts', w.accounts, 'updated_at', w.updated_at,
           'updated_by', (SELECT t.first_name FROM public.team t WHERE t.id = w.updated_by))
    INTO v_out
  FROM public.billing_worksheets w
  WHERE w.agency_id = v_agency AND w.customer_key = v_key;
  RETURN v_out;
END;
$function$;

-- Saved worksheets, newest first. A search matches the start of the first name.
CREATE OR REPLACE FUNCTION public.billing_worksheet_list(p_search text DEFAULT NULL, p_limit integer DEFAULT 25)
RETURNS TABLE(id uuid, first text, initial text, phone4 text, line_count integer, updated_at timestamptz, updated_by text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_agency uuid;
BEGIN
  PERFORM public.require_login('staff');
  SELECT u.agency_id INTO v_agency FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1;
  IF v_agency IS NULL THEN
    RETURN;
  END IF;
  RETURN QUERY
  SELECT w.id, w.customer_first_name, w.customer_last_initial, w.phone_last4, jsonb_array_length(w.lines)::integer,
         w.updated_at, (SELECT t.first_name FROM public.team t WHERE t.id = w.updated_by)
  FROM public.billing_worksheets w
  WHERE w.agency_id = v_agency
    AND (btrim(coalesce(p_search, '')) = '' OR w.customer_first_name ILIKE btrim(p_search) || '%')
  ORDER BY w.updated_at DESC
  LIMIT greatest(1, least(coalesce(p_limit, 25), 100));
END;
$function$;
