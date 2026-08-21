-- Time Clock module: kiosk-style clock in/out for hourly staff.
-- Schema: one entry per continuous block of work (clock_in -> clock_out).
-- Lunches show as gaps between blocks. Sun -> Sat work week.

-- 1. pgcrypto for PIN hashing
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 2. PIN hash column on staff
ALTER TABLE staff ADD COLUMN IF NOT EXISTS time_clock_pin_hash text;

-- 3. Entries table
CREATE TABLE IF NOT EXISTS time_clock_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES agency(id),
  staff_id uuid NOT NULL REFERENCES staff(id),
  clock_in_at timestamptz NOT NULL,
  clock_out_at timestamptz,
  notes text,
  source text NOT NULL DEFAULT 'kiosk'
    CHECK (source IN ('kiosk','admin_create','admin_edit')),
  edited_by_user_id uuid REFERENCES users(id),
  edited_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_clock_entries_in_before_out
    CHECK (clock_out_at IS NULL OR clock_out_at > clock_in_at)
);

CREATE INDEX IF NOT EXISTS idx_time_clock_entries_staff_in
  ON time_clock_entries(staff_id, clock_in_at DESC);
CREATE INDEX IF NOT EXISTS idx_time_clock_entries_open
  ON time_clock_entries(staff_id) WHERE clock_out_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_time_clock_entries_agency_in
  ON time_clock_entries(agency_id, clock_in_at DESC);

-- 4. Touch trigger
CREATE OR REPLACE FUNCTION time_clock_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_time_clock_entries_touch ON time_clock_entries;
CREATE TRIGGER trg_time_clock_entries_touch
  BEFORE UPDATE ON time_clock_entries
  FOR EACH ROW EXECUTE FUNCTION time_clock_touch_updated_at();

-- 5. PIN hashing helper (agency-id-salted SHA-256)
CREATE OR REPLACE FUNCTION time_clock_hash_pin(p_agency_id uuid, p_pin text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT encode(digest(p_agency_id::text || ':' || p_pin, 'sha256'), 'hex');
$$;

-- 6. Kiosk punch RPC (verify PIN + toggle clock state)
CREATE OR REPLACE FUNCTION time_clock_punch(p_staff_id uuid, p_pin text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff staff%ROWTYPE;
  v_open time_clock_entries%ROWTYPE;
  v_now  timestamptz := now();
  v_hours numeric;
BEGIN
  SELECT * INTO v_staff FROM staff WHERE id = p_staff_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_staff');
  END IF;
  IF v_staff.is_active IS NOT TRUE OR v_staff.archived_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'inactive_staff');
  END IF;
  IF v_staff.pay_type <> 'HOURLY' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_hourly');
  END IF;
  IF v_staff.time_clock_pin_hash IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_not_set');
  END IF;
  IF v_staff.time_clock_pin_hash <> time_clock_hash_pin(v_staff.agency_id, p_pin) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_pin');
  END IF;

  SELECT * INTO v_open
  FROM time_clock_entries
  WHERE staff_id = p_staff_id AND clock_out_at IS NULL
  ORDER BY clock_in_at DESC
  LIMIT 1;

  IF FOUND THEN
    UPDATE time_clock_entries SET clock_out_at = v_now WHERE id = v_open.id;
    v_hours := EXTRACT(EPOCH FROM (v_now - v_open.clock_in_at)) / 3600.0;
    RETURN jsonb_build_object(
      'ok', true,
      'action', 'clock_out',
      'staff_name', v_staff.first_name || ' ' || v_staff.last_name,
      'at', v_now,
      'hours_this_block', round(v_hours::numeric, 2)
    );
  ELSE
    INSERT INTO time_clock_entries (agency_id, staff_id, clock_in_at, source)
    VALUES (v_staff.agency_id, p_staff_id, v_now, 'kiosk');
    RETURN jsonb_build_object(
      'ok', true,
      'action', 'clock_in',
      'staff_name', v_staff.first_name || ' ' || v_staff.last_name,
      'at', v_now
    );
  END IF;
END;
$$;

-- 7. Admin PIN set/reset RPC
CREATE OR REPLACE FUNCTION time_clock_set_pin(p_staff_id uuid, p_pin text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff staff%ROWTYPE;
BEGIN
  IF p_pin !~ '^\d{4}$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'pin_must_be_4_digits');
  END IF;
  SELECT * INTO v_staff FROM staff WHERE id = p_staff_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown_staff');
  END IF;
  UPDATE staff
  SET time_clock_pin_hash = time_clock_hash_pin(v_staff.agency_id, p_pin),
      updated_at = now()
  WHERE id = p_staff_id;
  RETURN jsonb_build_object('ok', true);
END;
$$;

-- 8. Status view: who's currently on the clock (hourly staff only)
CREATE OR REPLACE VIEW v_time_clock_status AS
SELECT
  s.id            AS staff_id,
  s.agency_id,
  s.first_name,
  s.last_name,
  s.pay_rate,
  (s.time_clock_pin_hash IS NOT NULL) AS pin_set,
  e.id            AS open_entry_id,
  e.clock_in_at,
  (e.id IS NOT NULL) AS is_clocked_in,
  CASE WHEN e.clock_in_at IS NULL THEN NULL
       ELSE round((EXTRACT(EPOCH FROM (now() - e.clock_in_at)) / 3600.0)::numeric, 2)
  END AS hours_this_block
FROM staff s
LEFT JOIN time_clock_entries e
  ON e.staff_id = s.id AND e.clock_out_at IS NULL
WHERE s.is_active = true
  AND s.pay_type  = 'HOURLY'
  AND s.archived_at IS NULL;

-- 9. RLS
ALTER TABLE time_clock_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS time_clock_entries_anon_read ON time_clock_entries;
CREATE POLICY time_clock_entries_anon_read
  ON time_clock_entries FOR SELECT TO anon USING (true);

DROP POLICY IF EXISTS time_clock_entries_authenticated_read ON time_clock_entries;
CREATE POLICY time_clock_entries_authenticated_read
  ON time_clock_entries FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS time_clock_entries_authenticated_write ON time_clock_entries;
CREATE POLICY time_clock_entries_authenticated_write
  ON time_clock_entries FOR ALL TO authenticated
  USING (true) WITH CHECK (true);

-- 10. Grants
GRANT EXECUTE ON FUNCTION time_clock_punch(uuid, text)   TO anon, authenticated;
GRANT EXECUTE ON FUNCTION time_clock_set_pin(uuid, text) TO authenticated;
GRANT SELECT ON v_time_clock_status TO anon, authenticated;

COMMENT ON TABLE time_clock_entries IS 'Hourly staff clock-in/out blocks. One row per continuous work block. Lunches = gaps. Week boundary = Sun 00:00 -> Sat 23:59.';
COMMENT ON FUNCTION time_clock_punch IS 'Kiosk RPC: verifies PIN, toggles clock state, returns {ok, action, staff_name, at, hours_this_block?}.';
COMMENT ON FUNCTION time_clock_set_pin IS 'Admin RPC: hashes and stores a 4-digit PIN for an hourly staff member.';
