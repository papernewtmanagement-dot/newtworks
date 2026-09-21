-- A new hire added before their start date gets their Newtworks login invite
-- on the morning of that start date instead of the moment they are added.
ALTER TABLE public.team ADD COLUMN IF NOT EXISTS login_invite_due date;
COMMENT ON COLUMN public.team.login_invite_due IS
  'Date the Newtworks login invite goes out (7 a.m. Central, hourly tick). NULL = nothing waiting. Cleared by invite-team-member once sent.';

-- If the start date moves while an invite is waiting, the invite moves with it.
CREATE OR REPLACE FUNCTION public.team_follow_start_date_for_invite()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.login_invite_due IS NOT NULL
     AND OLD.login_invite_due IS NOT NULL
     AND NEW.login_invite_due = OLD.login_invite_due
     AND NEW.start_date IS DISTINCT FROM OLD.start_date
     AND NEW.start_date IS NOT NULL THEN
    NEW.login_invite_due := NEW.start_date;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_team_follow_start_date_for_invite ON public.team;
CREATE TRIGGER trg_team_follow_start_date_for_invite
  BEFORE UPDATE OF start_date ON public.team
  FOR EACH ROW EXECUTE FUNCTION public.team_follow_start_date_for_invite();

-- Hourly: from 7 a.m. Central on the due date, hand each waiting hire to
-- invite-team-member. That function sends, links, and clears login_invite_due,
-- so a failed send simply stays due and is retried on the next tick.
CREATE OR REPLACE FUNCTION public.send_due_login_invites()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_local  timestamp := now() AT TIME ZONE 'America/Chicago';
  v_row    record;
  v_sent   integer := 0;
BEGIN
  IF extract(hour FROM v_local) < 7 THEN
    RETURN 0;
  END IF;

  FOR v_row IN
    SELECT t.id, t.agency_id
    FROM public.team t
    WHERE t.login_invite_due IS NOT NULL
      AND t.login_invite_due <= v_local::date
      AND t.email_personal IS NOT NULL
      AND t.archived_at IS NULL
  LOOP
    PERFORM net.http_post(
      url     := public.get_setting(v_row.agency_id, 'supabase_url') || '/functions/v1/invite-team-member',
      headers := public.edge_fn_headers(),
      body    := jsonb_build_object(
        'scheduled',      true,
        'shared_secret',  public.get_setting(v_row.agency_id, 'automation_runner_cron_secret'),
        'team_member_id', v_row.id
      ),
      timeout_milliseconds := 60000
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION public.send_due_login_invites() FROM PUBLIC, anon, authenticated;

-- Ride the existing hourly tick. No new cron job.
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'automation-runner-tick'),
  command := $cmd$
    SELECT public.run_due_automation_recipes();
    SELECT public.resweep_failed_automation_dispatches();
    SELECT public.team_checkin_sweep_weekend_eod();
    SELECT public.send_due_login_invites();
  $cmd$
);
