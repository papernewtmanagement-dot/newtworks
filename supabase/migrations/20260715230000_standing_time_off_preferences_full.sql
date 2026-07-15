-- =====================================================================
-- Standing Time Off Preferences — session 2026-07-15
-- Applied via Supabase MCP earlier in this session. This mirror file
-- captures the byte-for-byte SQL for reproducibility.
-- =====================================================================

-- 1. Table + RLS
CREATE TABLE IF NOT EXISTS public.standing_time_off_preferences (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             UUID NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  team_member_id        UUID NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  day_of_week           TEXT NOT NULL,
  day_part              TEXT NOT NULL,
  pattern               TEXT NOT NULL,
  is_paid               BOOLEAN NOT NULL DEFAULT true,
  trigger_type          TEXT NOT NULL DEFAULT 'always',
  effective_from        DATE NOT NULL DEFAULT CURRENT_DATE,
  effective_until       DATE,
  approved_by_team_id   UUID REFERENCES public.team(id),
  approved_at           TIMESTAMPTZ,
  source_request_id     UUID REFERENCES public.time_off_requests(id) ON DELETE SET NULL,
  notes                 TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  archived_at           TIMESTAMPTZ,
  CONSTRAINT stop_day_of_week_check
    CHECK (day_of_week = ANY (ARRAY['monday','tuesday','wednesday','thursday','friday'])),
  CONSTRAINT stop_day_part_check
    CHECK (day_part = ANY (ARRAY['morning','afternoon','full'])),
  CONSTRAINT stop_pattern_check
    CHECK (pattern = ANY (ARRAY['off','remote'])),
  CONSTRAINT stop_trigger_type_check
    CHECK (trigger_type = ANY (ARRAY['always','wtw_won_prior_week']))
);

CREATE INDEX IF NOT EXISTS idx_stop_active
  ON public.standing_time_off_preferences (agency_id, team_member_id, day_of_week)
  WHERE archived_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_stop_agency
  ON public.standing_time_off_preferences (agency_id)
  WHERE archived_at IS NULL;

CREATE OR REPLACE FUNCTION public.tg_stop_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := NOW(); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS stop_touch_updated_at ON public.standing_time_off_preferences;
CREATE TRIGGER stop_touch_updated_at
  BEFORE UPDATE ON public.standing_time_off_preferences
  FOR EACH ROW EXECUTE FUNCTION public.tg_stop_touch_updated_at();

ALTER TABLE public.standing_time_off_preferences ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS stop_read ON public.standing_time_off_preferences;
CREATE POLICY stop_read ON public.standing_time_off_preferences
  FOR SELECT TO authenticated
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);
DROP POLICY IF EXISTS stop_write_admin ON public.standing_time_off_preferences;
CREATE POLICY stop_write_admin ON public.standing_time_off_preferences
  FOR ALL TO authenticated
  USING (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role IN ('owner','manager'))
  )
  WITH CHECK (
    agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid
    AND EXISTS (SELECT 1 FROM public.users u WHERE u.id = auth.uid() AND u.role IN ('owner','manager'))
  );

COMMENT ON TABLE  public.standing_time_off_preferences IS
  'Canonical home for recurring/standing time-off + remote patterns per teammate. Replaces the deprecated team.four_day_off_day text field. Auto-materialized into time_off_requests weekly by materialize_standing_time_off().';
COMMENT ON COLUMN public.standing_time_off_preferences.trigger_type IS
  '"always" = every week; "wtw_won_prior_week" = only weeks after we won Win the Week the prior week.';
COMMENT ON COLUMN public.standing_time_off_preferences.pattern IS
  '"off" = time off (paid or unpaid per is_paid); "remote" = still working, remotely, still paid.';
COMMENT ON COLUMN public.standing_time_off_preferences.day_part IS
  '"morning" = 8:30 AM - 1 PM CT; "afternoon" = 1 PM - 5:30 PM CT; "full" = full workday.';

-- 2. time_off_requests columns + CHECK extension + validation trigger
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
CREATE UNIQUE INDEX IF NOT EXISTS ux_tor_derived_pref_date
  ON public.time_off_requests (derived_from_standing_pref_id, start_date)
  WHERE derived_from_standing_pref_id IS NOT NULL;

ALTER TABLE public.time_off_requests
  DROP CONSTRAINT IF EXISTS time_off_requests_request_type_check;
ALTER TABLE public.time_off_requests
  ADD CONSTRAINT time_off_requests_request_type_check
  CHECK (request_type = ANY (ARRAY[
    'time_off_full_day','time_off_half_day','sick','remote_day','remote_half_day',
    'four_day_off_change','standing_time_off_preference'
  ]));

CREATE OR REPLACE FUNCTION public.tg_tor_validate_standing_pref()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_day JSONB;
BEGIN
  IF NEW.request_type <> 'standing_time_off_preference' THEN RETURN NEW; END IF;
  IF NEW.standing_pref_days IS NULL OR jsonb_typeof(NEW.standing_pref_days) <> 'array' THEN
    RAISE EXCEPTION 'standing_time_off_preference request requires standing_pref_days (jsonb array)';
  END IF;
  IF jsonb_array_length(NEW.standing_pref_days) = 0 THEN
    RAISE EXCEPTION 'standing_pref_days must contain at least one day entry';
  END IF;
  IF NEW.standing_pref_trigger IS NULL OR NEW.standing_pref_trigger NOT IN ('always','wtw_won_prior_week') THEN
    RAISE EXCEPTION 'standing_pref_trigger must be "always" or "wtw_won_prior_week"';
  END IF;
  IF NEW.standing_pref_is_paid IS NULL THEN RAISE EXCEPTION 'standing_pref_is_paid must be set'; END IF;
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
  'When set, this concrete time-off request was auto-generated from a standing preference. Idempotent via ux_tor_derived_pref_date.';

-- 3. Materialize-on-approval trigger
CREATE OR REPLACE FUNCTION public.tg_tor_materialize_standing_pref()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_day JSONB;
  v_new_pref_id UUID;
  v_pref_ids UUID[] := ARRAY[]::UUID[];
BEGIN
  IF NEW.request_type <> 'standing_time_off_preference' THEN RETURN NEW; END IF;
  IF NEW.status <> 'approved' THEN RETURN NEW; END IF;
  IF OLD.status = 'approved' THEN RETURN NEW; END IF;
  IF NEW.resulting_standing_pref_ids IS NOT NULL
     AND array_length(NEW.resulting_standing_pref_ids, 1) > 0 THEN RETURN NEW; END IF;

  FOR v_day IN SELECT jsonb_array_elements(NEW.standing_pref_days) LOOP
    INSERT INTO public.standing_time_off_preferences (
      agency_id, team_member_id, day_of_week, day_part, pattern, is_paid,
      trigger_type, effective_from, approved_by_team_id, approved_at,
      source_request_id, notes
    ) VALUES (
      NEW.agency_id, NEW.requester_team_id,
      v_day->>'day_of_week', v_day->>'day_part', v_day->>'pattern',
      NEW.standing_pref_is_paid, NEW.standing_pref_trigger,
      COALESCE(NEW.start_date, CURRENT_DATE),
      NEW.decided_by_team_id, COALESCE(NEW.decided_at, NOW()),
      NEW.id, NEW.notes
    ) RETURNING id INTO v_new_pref_id;
    v_pref_ids := array_append(v_pref_ids, v_new_pref_id);
  END LOOP;

  UPDATE public.time_off_requests SET resulting_standing_pref_ids = v_pref_ids WHERE id = NEW.id;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS tor_materialize_standing_pref ON public.time_off_requests;
CREATE TRIGGER tor_materialize_standing_pref
  AFTER UPDATE ON public.time_off_requests
  FOR EACH ROW
  WHEN (NEW.status = 'approved' AND (OLD.status IS DISTINCT FROM NEW.status))
  EXECUTE FUNCTION public.tg_tor_materialize_standing_pref();

-- 4. Weekly materialization RPC
CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(
  p_agency_id UUID DEFAULT '126794dd-25ff-47d2-a436-724499733365'::uuid,
  p_week_start DATE DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_week_start DATE; v_week_end DATE; v_prior_sat DATE; v_won_prior BOOLEAN;
  v_created INT := 0; v_skipped_dup INT := 0; v_skipped_trig INT := 0;
  v_pref RECORD; v_target_date DATE; v_dow_int INT;
  v_partial TEXT; v_request_type TEXT; v_new_id UUID;
BEGIN
  IF p_week_start IS NOT NULL THEN
    v_week_start := p_week_start;
  ELSE
    v_week_start := (CURRENT_DATE + (((1 - EXTRACT(ISODOW FROM CURRENT_DATE)::INT + 7) % 7))::INT)::DATE;
    IF v_week_start <= CURRENT_DATE THEN v_week_start := v_week_start + 7; END IF;
  END IF;
  IF EXTRACT(ISODOW FROM v_week_start) <> 1 THEN
    RAISE EXCEPTION 'p_week_start must be a Monday, got % (isodow=%)', v_week_start, EXTRACT(ISODOW FROM v_week_start);
  END IF;
  v_week_end := v_week_start + 4;
  v_prior_sat := v_week_start - 2;

  SELECT won_the_week INTO v_won_prior FROM public.weekly_cpr_reports
  WHERE agency_id = p_agency_id AND week_ending_date = v_prior_sat;

  FOR v_pref IN
    SELECT p.id, p.team_member_id, p.day_of_week, p.day_part, p.pattern,
           p.is_paid, p.trigger_type, p.effective_from, p.effective_until
    FROM public.standing_time_off_preferences p
    WHERE p.agency_id = p_agency_id AND p.archived_at IS NULL
      AND p.effective_from <= v_week_end
      AND (p.effective_until IS NULL OR p.effective_until >= v_week_start)
  LOOP
    IF v_pref.trigger_type = 'wtw_won_prior_week' AND COALESCE(v_won_prior, false) = false THEN
      v_skipped_trig := v_skipped_trig + 1; CONTINUE;
    END IF;
    v_dow_int := CASE v_pref.day_of_week
      WHEN 'monday' THEN 0 WHEN 'tuesday' THEN 1 WHEN 'wednesday' THEN 2
      WHEN 'thursday' THEN 3 WHEN 'friday' THEN 4 END;
    v_target_date := v_week_start + v_dow_int;
    IF v_target_date < v_pref.effective_from THEN v_skipped_trig := v_skipped_trig + 1; CONTINUE; END IF;
    IF v_pref.effective_until IS NOT NULL AND v_target_date > v_pref.effective_until THEN
      v_skipped_trig := v_skipped_trig + 1; CONTINUE;
    END IF;

    IF v_pref.pattern = 'off' THEN
      IF v_pref.day_part = 'full' THEN v_request_type := 'time_off_full_day'; v_partial := 'none';
      ELSE v_request_type := 'time_off_half_day'; v_partial := v_pref.day_part; END IF;
    ELSE
      IF v_pref.day_part = 'full' THEN v_request_type := 'remote_day'; v_partial := 'none';
      ELSE v_request_type := 'remote_half_day'; v_partial := v_pref.day_part; END IF;
    END IF;

    BEGIN
      INSERT INTO public.time_off_requests (
        agency_id, requester_team_id, request_type, start_date, end_date, partial_day,
        notes, status, is_paid, is_planned, submitted_at, decided_at, decision_note,
        derived_from_standing_pref_id, decision_notified_at
      ) VALUES (
        p_agency_id, v_pref.team_member_id, v_request_type, v_target_date, v_target_date, v_partial,
        'Auto-generated from standing preference. Trigger: ' || v_pref.trigger_type
          || CASE WHEN v_pref.trigger_type='wtw_won_prior_week'
                  THEN ' (prior week ' || v_prior_sat::text || ' won)' ELSE '' END,
        'approved', v_pref.is_paid, true, NOW(), NOW(),
        'Auto-approved via standing preference', v_pref.id, NOW()
      ) RETURNING id INTO v_new_id;
      v_created := v_created + 1;
    EXCEPTION WHEN unique_violation THEN v_skipped_dup := v_skipped_dup + 1; END;
  END LOOP;

  RETURN jsonb_build_object(
    'week_start', v_week_start, 'week_end', v_week_end, 'prior_cpr_sat', v_prior_sat,
    'won_prior_week', v_won_prior, 'created', v_created,
    'skipped_dup', v_skipped_dup, 'skipped_trigger', v_skipped_trig
  );
END $$;

CREATE OR REPLACE FUNCTION public.materialize_standing_time_off(p_agency_id UUID, p_recipe_id UUID)
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT public.materialize_standing_time_off(p_agency_id, NULL::date);
$$;

COMMENT ON FUNCTION public.materialize_standing_time_off(uuid, date) IS
  'For a target work week (Mon-Fri), materializes concrete time_off_requests from standing_time_off_preferences. Gates wtw_won_prior_week prefs on weekly_cpr_reports.won_the_week for the prior CPR week. Idempotent via ux_tor_derived_pref_date. Pre-stamps decision_notified_at to suppress email spam. Calendar dispatch runs normally. Default p_week_start = next Monday.';

-- 5. Sunday PM automation recipe (0 20 * * 0 UTC)
INSERT INTO public.automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  composio_action, internal_handler, is_active
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  'Standing Time Off Materialize (Sunday)',
  'Sunday PM. Reads standing_time_off_preferences, evaluates wtw_won_prior_week trigger against prior CPR outcome, INSERTs concrete auto-approved time_off_requests for the upcoming Mon-Fri work week. Idempotent via ux_tor_derived_pref_date.',
  'cron', '0 20 * * 0', 'INTERNAL', 'materialize_standing_time_off', true
);

-- 6. Backfill Stephanie / John / Tommy; retire team.four_day_off_day for active users
DO $$
DECLARE v_steph UUID; v_john UUID; v_tommy UUID; v_peter UUID;
BEGIN
  SELECT id INTO v_steph  FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND first_name='Stephanie' AND last_name='Rogers';
  SELECT id INTO v_john   FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND first_name='John' AND last_name='Kostov';
  SELECT id INTO v_tommy  FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND first_name='Thomas' AND last_name='Lynch';
  SELECT id INTO v_peter  FROM public.team WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'::uuid AND role_level='Owner' AND is_admin_backoffice=false LIMIT 1;

  INSERT INTO public.standing_time_off_preferences
    (agency_id, team_member_id, day_of_week, day_part, pattern, is_paid, trigger_type, effective_from, approved_by_team_id, approved_at, notes)
  VALUES
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'monday',    'morning',   'remote', true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Mon AM, off Mon PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'monday',    'afternoon', 'off',    true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Mon AM, off Mon PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'wednesday', 'morning',   'remote', true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Wed AM, off Wed PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_steph, 'wednesday', 'afternoon', 'off',    true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from Stephanie 7/13 request. Work remotely Wed AM, off Wed PM, when prior week won WtW.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_john,  'friday',    'full',      'off',    true, 'wtw_won_prior_week', '2026-07-20', v_peter, NOW(), 'Backfill from John 7/2 approved request. WtW-won-prior-week Friday off (family visit day). Retires prior team.four_day_off_day="wednesday".'),
    ('126794dd-25ff-47d2-a436-724499733365', v_tommy, 'tuesday',   'afternoon', 'off',    true, 'always',             '2026-07-20', v_peter, NOW(), 'Backfill from team.four_day_off_day="tuesday_pm+thursday_pm". Standing pattern, no WtW gate.'),
    ('126794dd-25ff-47d2-a436-724499733365', v_tommy, 'thursday',  'afternoon', 'off',    true, 'always',             '2026-07-20', v_peter, NOW(), 'Backfill from team.four_day_off_day="tuesday_pm+thursday_pm". Standing pattern, no WtW gate.');

  UPDATE public.team SET four_day_off_day = NULL
   WHERE id IN (v_john, v_tommy, v_steph) AND four_day_off_day IS NOT NULL;
END $$;

COMMENT ON COLUMN public.team.four_day_off_day IS
  'DEPRECATED 2026-07-15. Use standing_time_off_preferences table instead. Column retained temporarily for legacy reads; nulled out for John, Tommy, Steph on 2026-07-15 backfill. Do not write to this column in new code.';
