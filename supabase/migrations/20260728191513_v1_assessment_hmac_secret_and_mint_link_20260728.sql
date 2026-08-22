-- Newtworks v1 adaptive assessment — public signed link infrastructure
-- Step 10.1 of frontend build. Non-destructive additive migration.

-- 1) HMAC secret used to sign candidate assessment links.
--    Cryptographically random 256-bit value. Rotation = replace this row = invalidate every outstanding link.
INSERT INTO public.settings (agency_id, setting_key, setting_value, description)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'v1_assessment_hmac_secret',
  '9ce9ce5c6ceccd77b0186108e589652ce7deebde68aa1646ee8fcbf523c399ae',
  'HMAC-SHA256 secret used to sign public Newtworks v1 assessment links. Rotating this row invalidates every outstanding link. Read only from server-side (edge functions, SECURITY DEFINER SQL). Never expose in client code or plaintext logs.'
)
ON CONFLICT (agency_id, setting_key) DO NOTHING;

-- 2) SQL helper: derive the token given a candidate id.
--    SECURITY DEFINER so callers do not need direct access to public.settings.
CREATE OR REPLACE FUNCTION public.compute_v1_assessment_token(p_candidate_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
  v_secret text;
  v_mac    bytea;
BEGIN
  SELECT setting_value INTO v_secret
  FROM public.settings
  WHERE setting_key = 'v1_assessment_hmac_secret'
    AND agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid;

  IF v_secret IS NULL THEN
    RAISE EXCEPTION 'v1_assessment_hmac_secret not configured';
  END IF;

  v_mac := extensions.hmac(p_candidate_id::text::bytea, v_secret::bytea, 'sha256');
  RETURN substr(encode(v_mac, 'hex'), 1, 32);
END;
$fn$;

REVOKE ALL ON FUNCTION public.compute_v1_assessment_token(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.compute_v1_assessment_token(uuid) TO authenticated;

-- 3) Admin-callable mint function: returns the full relative URL path.
--    Frontend prepends window.location.origin when displaying to Peter.
CREATE OR REPLACE FUNCTION public.mint_v1_assessment_link(p_candidate_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
  v_exists boolean;
  v_token  text;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.hiring_candidates
    WHERE id = p_candidate_id
      AND agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
  ) INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION 'candidate % not found in this agency', p_candidate_id;
  END IF;

  v_token := public.compute_v1_assessment_token(p_candidate_id);
  RETURN '/assess/' || p_candidate_id::text || '/' || v_token;
END;
$fn$;

REVOKE ALL ON FUNCTION public.mint_v1_assessment_link(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mint_v1_assessment_link(uuid) TO authenticated;

-- 4) Verify function used by the edge function.
--    Constant-time comparison to prevent timing oracles.
CREATE OR REPLACE FUNCTION public.verify_v1_assessment_token(p_candidate_id uuid, p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $fn$
DECLARE
  v_expected text;
BEGIN
  IF p_token IS NULL OR length(p_token) <> 32 THEN
    RETURN false;
  END IF;

  v_expected := public.compute_v1_assessment_token(p_candidate_id);

  RETURN (
    SELECT bool_and(substr(v_expected, i, 1) = substr(lower(p_token), i, 1))
    FROM generate_series(1, 32) AS i
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.verify_v1_assessment_token(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_v1_assessment_token(uuid, text) TO authenticated, service_role;
