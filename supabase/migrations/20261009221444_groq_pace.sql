-- Groq pacing (2026-10-09). Groq allows this account 8,000 tokens a minute.
-- Every AI read books its tokens (prompt estimate + answer ceiling) here first
-- and is told how long to wait, so a burst is spread out instead of tripping
-- the cap. Bookings live in the agency's settings row 'groq_tpm_ledger' as
-- [[start_ms, tokens], ...]; the row lock makes concurrent callers queue.
-- Callers: _shared/llm.ts callGroqChat() via paceGroq().
CREATE OR REPLACE FUNCTION public.groq_pace(p_agency_id uuid, p_tokens integer, p_max_wait_ms integer DEFAULT 30000)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  -- 8,000 a minute less a margin for the token estimate running low.
  v_cap constant integer := 7600;
  v_window constant bigint := 60000;
  v_now bigint := floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint;
  v_need integer := least(greatest(coalesce(p_tokens, 1), 1), v_cap);
  v_raw text;
  v_entries jsonb := '[]'::jsonb;
  v_t bigint;
  v_used integer;
  v_oldest bigint;
  v_wait bigint;
BEGIN
  INSERT INTO settings (agency_id, setting_key, setting_value, setting_type, description, updated_by)
  VALUES (p_agency_id, 'groq_tpm_ledger', '[]', 'json',
          'Groq per-minute token bookings written by groq_pace(). Machine-written; safe to reset to [].', 'groq_pace')
  ON CONFLICT (agency_id, setting_key) DO NOTHING;

  SELECT setting_value INTO v_raw FROM settings
   WHERE agency_id = p_agency_id AND setting_key = 'groq_tpm_ledger'
   FOR UPDATE;

  BEGIN
    v_entries := coalesce(v_raw, '[]')::jsonb;
    IF jsonb_typeof(v_entries) <> 'array' THEN v_entries := '[]'::jsonb; END IF;
  EXCEPTION WHEN others THEN
    v_entries := '[]'::jsonb;  -- a hand-mangled ledger resets rather than blocking every read
  END;

  -- Drop bookings whose minute is over.
  SELECT coalesce(jsonb_agg(e ORDER BY (e->>0)::bigint), '[]'::jsonb) INTO v_entries
    FROM jsonb_array_elements(v_entries) e
   WHERE (e->>0)::bigint > v_now - v_window;

  -- First in, first out: start no earlier than now or the last booking.
  SELECT greatest(v_now, coalesce(max((e->>0)::bigint), v_now)) INTO v_t
    FROM jsonb_array_elements(v_entries) e;

  LOOP
    SELECT coalesce(sum((e->>1)::integer), 0), min((e->>0)::bigint) INTO v_used, v_oldest
      FROM jsonb_array_elements(v_entries) e
     WHERE (e->>0)::bigint > v_t - v_window AND (e->>0)::bigint <= v_t;
    EXIT WHEN v_used + v_need <= v_cap OR v_oldest IS NULL;
    v_t := v_oldest + v_window + 1;  -- wait for the oldest booking in the window to age out
  END LOOP;

  v_wait := v_t - v_now;
  IF v_wait > p_max_wait_ms THEN
    RETURN jsonb_build_object('wait_ms', 0, 'busy_ms', v_wait);  -- nothing booked
  END IF;

  v_entries := v_entries || jsonb_build_array(jsonb_build_array(v_t, v_need));
  UPDATE settings SET setting_value = v_entries::text, updated_at = now(), updated_by = 'groq_pace'
   WHERE agency_id = p_agency_id AND setting_key = 'groq_tpm_ledger';

  RETURN jsonb_build_object('wait_ms', v_wait, 'busy_ms', 0);
END
$function$;

REVOKE ALL ON FUNCTION public.groq_pace(uuid, integer, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.groq_pace(uuid, integer, integer) TO service_role;

