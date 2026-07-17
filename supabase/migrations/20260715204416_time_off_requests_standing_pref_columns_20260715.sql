-- Extensions to time_off_requests to carry a standing-pref proposal through
-- the existing voting/approval pipeline. When approved, a trigger materializes
-- one standing_time_off_preferences row per day in standing_pref_days.

-- 1. Add columns
ALTER TABLE public.time_off_requests
  ADD COLUMN IF NOT EXISTS standing_pref_days JSONB,
  ADD COLUMN IF NOT EXISTS standing_pref_trigger TEXT,
  ADD COLUMN IF NOT EXISTS standing_pref_is_paid BOOLEAN,
  ADD COLUMN IF NOT EXISTS derived_from_standing_pref_id UUID
    REFERENCES public.standing_time_off_preferences(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS resulting_standing_pref_ids UUID[];

CREATE INDEX IF NOT EXISTS idx_tor_derived_from_pref
  ON public.time_off_requests (derived_from_standing_pref_id, start_date)
  WHERE derived_from_standing_pref_id IS NOT NULL;

-- Idempotency for auto-generated rows: one row per (pref, target date)
CREATE UNIQUE INDEX IF NOT EXISTS ux_tor_derived_pref_date
  ON public.time_off_requests (derived_from_standing_pref_id, start_date)
  WHERE derived_from_standing_pref_id IS NOT NULL;

-- 2. Extend request_type CHECK to accept 'standing_time_off_preference'
ALTER TABLE public.time_off_requests
  DROP CONSTRAINT IF EXISTS time_off_requests_request_type_check;

ALTER TABLE public.time_off_requests
  ADD CONSTRAINT time_off_requests_request_type_check
  CHECK (request_type = ANY (ARRAY[
    'time_off_full_day',
    'time_off_half_day',
    'sick',
    'remote_day',
    'remote_half_day',
    'four_day_off_change',        -- kept for legacy rows; deprecated (see standing_pref)
    'standing_time_off_preference'
  ]));

-- 3. Validation trigger on standing pref rows: enforce shape at insert/update
CREATE OR REPLACE FUNCTION public.tg_tor_validate_standing_pref()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
  v_day JSONB;
BEGIN
  IF NEW.request_type <> 'standing_time_off_preference' THEN
    RETURN NEW;
  END IF;

  IF NEW.standing_pref_days IS NULL OR jsonb_typeof(NEW.standing_pref_days) <> 'array' THEN
    RAISE EXCEPTION 'standing_time_off_preference request requires standing_pref_days (jsonb array)';
  END IF;

  IF jsonb_array_length(NEW.standing_pref_days) = 0 THEN
    RAISE EXCEPTION 'standing_pref_days must contain at least one day entry';
  END IF;

  IF NEW.standing_pref_trigger IS NULL
     OR NEW.standing_pref_trigger NOT IN ('always','wtw_won_prior_week') THEN
    RAISE EXCEPTION 'standing_pref_trigger must be "always" or "wtw_won_prior_week"';
  END IF;

  IF NEW.standing_pref_is_paid IS NULL THEN
    RAISE EXCEPTION 'standing_pref_is_paid must be set';
  END IF;

  -- Validate each day entry
  FOR v_day IN SELECT jsonb_array_elements(NEW.standing_pref_days) LOOP
    IF (v_day->>'day_of_week') NOT IN ('monday','tuesday','wednesday','thursday','friday') THEN
      RAISE EXCEPTION 'invalid day_of_week in standing_pref_days: %', v_day->>'day_of_week';
    END IF;
    IF (v_day->>'day_part') NOT IN ('morning','afternoon','full') THEN
      RAISE EXCEPTION 'invalid day_part in standing_pref_days: %', v_day->>'day_part';
    END IF;
    IF (v_day->>'pattern') NOT IN ('off','remote') THEN
      RAISE EXCEPTION 'invalid pattern in standing_pref_days: %', v_day->>'pattern';
    END IF;
  END LOOP;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tor_validate_standing_pref ON public.time_off_requests;
CREATE TRIGGER tor_validate_standing_pref
  BEFORE INSERT OR UPDATE ON public.time_off_requests
  FOR EACH ROW EXECUTE FUNCTION public.tg_tor_validate_standing_pref();

COMMENT ON COLUMN public.time_off_requests.standing_pref_days IS
  'JSONB array of {day_of_week, day_part, pattern} objects. Only populated when request_type=standing_time_off_preference. On approval, materialized into standing_time_off_preferences rows via tg_tor_materialize_standing_pref.';
COMMENT ON COLUMN public.time_off_requests.derived_from_standing_pref_id IS
  'When set, this concrete time-off request was auto-generated from a standing preference. Idempotent via ux_tor_derived_pref_date.';;