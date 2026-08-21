-- v16-equivalent fix at the data layer: any health entry inserted on a Sunday
-- with week_total_override >= 2 is logically impossible as a new-week claim
-- (only 1 day has elapsed) and is treated as a recap of the just-ended week.
-- We re-anchor log_date to the prior Saturday and adjust week_start_date.
-- Mid-week impossible totals (e.g. 5/5 on Wed) are NOT auto-rerouted — they
-- pass through unchanged and the team can correct them visibly.
--
-- This lives at the DB layer (not in the Telegram edge function) so every
-- writer — Telegram bot, BCC UI, manual SQL, future automations — gets the
-- correct routing for free. The bot's v16 edge-function deploy is now
-- optional/aesthetic (it would add a "(credited to last week)" suffix to the
-- ack message); behavior is correct without it.

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

    -- If a row already exists for this team at the rerouted date,
    -- update it in place and skip the INSERT (avoids duplicate rows).
    SELECT id INTO v_existing_id
    FROM public.team_health_checkins
    WHERE agency_id = NEW.agency_id
      AND team_id   = NEW.team_id
      AND log_date  = v_rerouted_date
    ORDER BY submitted_at DESC NULLS LAST
    LIMIT 1;

    IF v_existing_id IS NOT NULL THEN
      UPDATE public.team_health_checkins
      SET hit_today                       = COALESCE(NEW.hit_today, hit_today),
          week_total_override             = NEW.week_total_override,
          raw_response                    = NEW.raw_response,
          parse_status                    = NEW.parse_status,
          telegram_user_id                = COALESCE(NEW.telegram_user_id, telegram_user_id),
          telegram_first_name             = COALESCE(NEW.telegram_first_name, telegram_first_name),
          submitted_by_team_id            = NEW.submitted_by_team_id,
          submitted_by_telegram_user_id   = NEW.submitted_by_telegram_user_id,
          source_message_id               = COALESCE(NEW.source_message_id, source_message_id),
          submitted_at                    = NEW.submitted_at,
          is_proxy_submission             = COALESCE(NEW.is_proxy_submission, is_proxy_submission)
      WHERE id = v_existing_id;
      RETURN NULL;  -- swallow the INSERT; the UPDATE above is the durable write
    END IF;

    -- No existing row at the rerouted date — just retarget this INSERT.
    NEW.log_date        := v_rerouted_date;
    NEW.week_start_date := v_rerouted_date - 6;  -- Saturday's DOW=6, so -6 = prior Sunday (week_start)
  END IF;

  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_health_checkin_sunday_recap ON public.team_health_checkins;

CREATE TRIGGER trg_health_checkin_sunday_recap
BEFORE INSERT ON public.team_health_checkins
FOR EACH ROW
EXECUTE FUNCTION public.route_health_checkin_sunday_recap();

COMMENT ON FUNCTION public.route_health_checkin_sunday_recap() IS
  'Re-anchors Sunday health-checkin INSERTs with week_total_override>=2 to the prior Saturday. Sunday submissions with running total >=2 are logically impossible new-week claims (only day 1 elapsed). Mid-week impossible totals pass through unchanged.';
