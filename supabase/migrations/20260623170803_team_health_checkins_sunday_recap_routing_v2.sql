-- v2: drop is_proxy_submission from the UPDATE clause (it's a GENERATED ALWAYS column derived from team_id != submitted_by_team_id, so it auto-recomputes when submitted_by_team_id changes).
CREATE OR REPLACE FUNCTION public.route_health_checkin_sunday_recap()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_rerouted_date date;
  v_existing_id uuid;
BEGIN
  IF EXTRACT(DOW FROM NEW.log_date) = 0
     AND NEW.week_total_override IS NOT NULL
     AND NEW.week_total_override >= 2 THEN

    v_rerouted_date := NEW.log_date - 1;  -- prior Saturday

    SELECT id INTO v_existing_id
    FROM public.team_health_checkins
    WHERE agency_id = NEW.agency_id
      AND team_id   = NEW.team_id
      AND log_date  = v_rerouted_date
    ORDER BY submitted_at DESC NULLS LAST
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      UPDATE public.team_health_checkins
      SET hit_today                     = COALESCE(NEW.hit_today, hit_today),
          week_total_override           = NEW.week_total_override,
          raw_response                  = NEW.raw_response,
          parse_status                  = NEW.parse_status,
          telegram_user_id              = COALESCE(NEW.telegram_user_id, telegram_user_id),
          telegram_first_name           = COALESCE(NEW.telegram_first_name, telegram_first_name),
          submitted_by_team_id          = NEW.submitted_by_team_id,
          submitted_by_telegram_user_id = NEW.submitted_by_telegram_user_id,
          source_message_id             = COALESCE(NEW.source_message_id, source_message_id),
          submitted_at                  = NEW.submitted_at
      WHERE id = v_existing_id;
      RETURN NULL;
    END IF;

    NEW.log_date        := v_rerouted_date;
    NEW.week_start_date := v_rerouted_date - 6;
  END IF;

  RETURN NEW;
END;
$fn$;
