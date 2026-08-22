-- USPS Addresses API v3 integration
-- OAuth client-credentials → /addresses/v3/address validation
-- Credentials live in supabase_vault: 'usps_client_id', 'usps_client_secret'

-- 1. OAuth token cache (singleton row). USPS tokens valid 8h; we refresh inside 5 min of expiry.
CREATE TABLE IF NOT EXISTS public.usps_oauth_cache (
  id int PRIMARY KEY DEFAULT 1,
  access_token text NOT NULL,
  expires_at timestamptz NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT usps_oauth_cache_singleton CHECK (id = 1)
);

ALTER TABLE public.usps_oauth_cache ENABLE ROW LEVEL SECURITY;
-- No policies → service_role only. Function below is SECURITY DEFINER so it bypasses RLS.

COMMENT ON TABLE public.usps_oauth_cache IS
  'Singleton cache of USPS OAuth bearer token. Refreshed by validate_address() when within 5 min of expiry.';

-- 2. Validation function. Takes our column shape, returns standardized + DPV result.
CREATE OR REPLACE FUNCTION public.validate_address(
  p_address_line1 text,
  p_address_line2 text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_state text DEFAULT NULL,
  p_zip_code text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, vault, net, pg_temp
AS $func$
DECLARE
  v_client_id text;
  v_client_secret text;
  v_token text;
  v_expires_at timestamptz;
  v_oauth_req_id bigint;
  v_oauth_resp net.http_response_result;
  v_oauth_body jsonb;
  v_validate_params jsonb;
  v_zip_clean text;
  v_zip5 text;
  v_zip4 text;
  v_validate_req_id bigint;
  v_validate_resp net.http_response_result;
  v_validate_body jsonb;
  v_addr jsonb;
  v_info jsonb;
BEGIN
  -- Pull credentials from vault
  SELECT decrypted_secret INTO v_client_id
    FROM vault.decrypted_secrets WHERE name = 'usps_client_id' LIMIT 1;
  SELECT decrypted_secret INTO v_client_secret
    FROM vault.decrypted_secrets WHERE name = 'usps_client_secret' LIMIT 1;

  IF v_client_id IS NULL OR v_client_secret IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'USPS credentials not in vault. Add usps_client_id and usps_client_secret via vault.create_secret().'
    );
  END IF;

  -- Token cache check
  SELECT access_token, expires_at INTO v_token, v_expires_at
    FROM public.usps_oauth_cache WHERE id = 1;

  IF v_token IS NULL OR v_expires_at < (now() + interval '5 minutes') THEN
    -- Refresh: POST /oauth2/v3/token
    SELECT net.http_post(
      url := 'https://apis.usps.com/oauth2/v3/token',
      body := jsonb_build_object(
        'client_id', v_client_id,
        'client_secret', v_client_secret,
        'grant_type', 'client_credentials'
      ),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 10000
    ) INTO v_oauth_req_id;

    SELECT * INTO v_oauth_resp
      FROM net.http_collect_response(v_oauth_req_id, async := false);

    IF v_oauth_resp.status::text != 'SUCCESS' OR (v_oauth_resp.response).status_code != 200 THEN
      RETURN jsonb_build_object(
        'ok', false,
        'error', 'USPS OAuth failed',
        'net_status', v_oauth_resp.status::text,
        'net_message', v_oauth_resp.message,
        'http_status', (v_oauth_resp.response).status_code,
        'body', (v_oauth_resp.response).body
      );
    END IF;

    v_oauth_body := (v_oauth_resp.response).body::jsonb;
    v_token := v_oauth_body->>'access_token';
    v_expires_at := now() + ((v_oauth_body->>'expires_in')::int || ' seconds')::interval;

    INSERT INTO public.usps_oauth_cache (id, access_token, expires_at, updated_at)
    VALUES (1, v_token, v_expires_at, now())
    ON CONFLICT (id) DO UPDATE SET
      access_token = EXCLUDED.access_token,
      expires_at = EXCLUDED.expires_at,
      updated_at = EXCLUDED.updated_at;
  END IF;

  -- Build validation params. Split ZIP into 5/4 if hyphenated.
  v_validate_params := jsonb_build_object(
    'streetAddress', coalesce(p_address_line1, ''),
    'city', coalesce(p_city, ''),
    'state', coalesce(p_state, '')
  );

  IF p_address_line2 IS NOT NULL AND p_address_line2 != '' THEN
    v_validate_params := v_validate_params || jsonb_build_object('secondaryAddress', p_address_line2);
  END IF;

  IF p_zip_code IS NOT NULL THEN
    v_zip_clean := regexp_replace(p_zip_code, '\D', '', 'g');
    IF length(v_zip_clean) >= 9 THEN
      v_zip5 := substring(v_zip_clean from 1 for 5);
      v_zip4 := substring(v_zip_clean from 6 for 4);
      v_validate_params := v_validate_params
        || jsonb_build_object('ZIPCode', v_zip5)
        || jsonb_build_object('ZIPPlus4', v_zip4);
    ELSIF length(v_zip_clean) >= 5 THEN
      v_zip5 := substring(v_zip_clean from 1 for 5);
      v_validate_params := v_validate_params || jsonb_build_object('ZIPCode', v_zip5);
    END IF;
  END IF;

  -- GET /addresses/v3/address
  SELECT net.http_get(
    url := 'https://apis.usps.com/addresses/v3/address',
    params := v_validate_params,
    headers := jsonb_build_object(
      'Accept', 'application/json',
      'Authorization', 'Bearer ' || v_token
    ),
    timeout_milliseconds := 10000
  ) INTO v_validate_req_id;

  SELECT * INTO v_validate_resp
    FROM net.http_collect_response(v_validate_req_id, async := false);

  IF v_validate_resp.status::text != 'SUCCESS' OR (v_validate_resp.response).status_code != 200 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'error', 'USPS validation failed',
      'net_status', v_validate_resp.status::text,
      'net_message', v_validate_resp.message,
      'http_status', (v_validate_resp.response).status_code,
      'body', (v_validate_resp.response).body,
      'input', jsonb_build_object(
        'address_line1', p_address_line1,
        'address_line2', p_address_line2,
        'city', p_city,
        'state', p_state,
        'zip_code', p_zip_code
      )
    );
  END IF;

  v_validate_body := (v_validate_resp.response).body::jsonb;
  v_addr := v_validate_body->'address';
  v_info := v_validate_body->'additionalInfo';

  RETURN jsonb_build_object(
    'ok', true,
    'deliverable', (v_info->>'DPVConfirmation') IN ('Y','S'),
    'dpv_confirmation', v_info->>'DPVConfirmation',
    'business', v_info->>'business',
    'vacant', v_info->>'vacant',
    'cmra', v_info->>'DPVCMRA',
    'standardized', jsonb_build_object(
      'address_line1', v_addr->>'streetAddress',
      'address_line2', v_addr->>'secondaryAddress',
      'city', v_addr->>'city',
      'state', v_addr->>'state',
      'zip_code', CASE
        WHEN coalesce(v_addr->>'ZIPPlus4','') != ''
          THEN (v_addr->>'ZIPCode') || '-' || (v_addr->>'ZIPPlus4')
        ELSE v_addr->>'ZIPCode'
      END
    ),
    'matches', v_validate_body->'matches',
    'corrections', v_validate_body->'corrections',
    'input', jsonb_build_object(
      'address_line1', p_address_line1,
      'address_line2', p_address_line2,
      'city', p_city,
      'state', p_state,
      'zip_code', p_zip_code
    )
  );
END;
$func$;

COMMENT ON FUNCTION public.validate_address(text, text, text, text, text) IS
  'Validates a US address against USPS Addresses API v3. Returns ok+standardized+DPV result, or ok=false with error detail. Credentials in supabase_vault.';

REVOKE ALL ON FUNCTION public.validate_address(text, text, text, text, text) FROM public;
GRANT EXECUTE ON FUNCTION public.validate_address(text, text, text, text, text) TO service_role;
