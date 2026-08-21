-- Store the 13-week cycle anchor in settings so cycle math is data-driven.
-- Current anchor: 2026-04-05 (Sunday) → 2026-07-04 (Saturday), then every 91 days after.

INSERT INTO public.settings (agency_id, setting_key, setting_value, description)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'cycle_anchor_date',
  '2026-04-05',
  '13-week cycle anchor (Sunday). All cycles run Sun→Sat for 91 days. Helper public.current_cycle_info() derives current cycle from this.'
)
ON CONFLICT (agency_id, setting_key) DO NOTHING;

-- Helper function returning cycle info for any date.
CREATE OR REPLACE FUNCTION public.current_cycle_info(p_agency_id uuid, p_today date DEFAULT NULL)
RETURNS TABLE (
  cycle_start date,
  cycle_end date,
  week_of_cycle int,
  week_ending_saturday date,
  prior_week_ending_saturday date
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $func$
DECLARE
  v_anchor date;
  v_today date;
  v_days_since_anchor int;
  v_cycles_completed int;
  v_days_into_cycle int;
  v_week int;
  v_cycle_start date;
BEGIN
  v_today := COALESCE(p_today, (now() AT TIME ZONE 'America/Chicago')::date);

  SELECT setting_value::date INTO v_anchor
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'cycle_anchor_date';
  IF v_anchor IS NULL THEN v_anchor := '2026-04-05'::date; END IF;

  v_days_since_anchor := v_today - v_anchor;
  v_cycles_completed := v_days_since_anchor / 91;
  v_cycle_start := v_anchor + (v_cycles_completed * 91);
  v_days_into_cycle := v_today - v_cycle_start;
  v_week := (v_days_into_cycle / 7) + 1;

  cycle_start := v_cycle_start;
  cycle_end := v_cycle_start + 90;
  week_of_cycle := v_week;
  week_ending_saturday := v_cycle_start + (v_week * 7) - 1;
  prior_week_ending_saturday := week_ending_saturday - 7;

  RETURN NEXT;
END;
$func$;

-- Verify
SELECT * FROM public.current_cycle_info('126794dd-25ff-47d2-a436-724499733365'::uuid);
