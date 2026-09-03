-- When a team member is marked inactive or given an end date, their hiring
-- pipeline record moves to Former, not Declined. Declined means "never hired".
-- Someone who worked here and left is a different thing entirely.
--
-- The decline-letter sender (send_one_candidate_decline_notice) refuses any row
-- whose status is not 'declined', and separately refuses decline_reason
-- 'former_team'. Setting both here means a departure can never produce a
-- rejection letter to a past employee.

CREATE OR REPLACE FUNCTION public.team_departure_marks_candidate_former()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Link by team_member_id when it is set, otherwise fall back to an exact
  -- first+last name match inside the same agency. The link is written back so
  -- the name fallback is only ever needed once per person.
  UPDATE public.hiring_candidates hc
     SET status            = 'former',
         decline_reason    = COALESCE(hc.decline_reason, 'former_team'),
         final_decision    = CASE WHEN hc.final_decision = 'no_hire'
                                  THEN NULL ELSE hc.final_decision END,
         team_member_id    = NEW.id,
         status_updated_at = NOW()
   WHERE hc.agency_id = NEW.agency_id
     AND hc.status IS DISTINCT FROM 'former'
     AND (
           hc.team_member_id = NEW.id
        OR (hc.team_member_id IS NULL
            AND lower(hc.first_name) = lower(NEW.first_name)
            AND lower(hc.last_name)  = lower(NEW.last_name))
         );
  RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_team_departure_marks_candidate_former ON public.team;

CREATE TRIGGER trg_team_departure_marks_candidate_former
AFTER UPDATE OF is_active, end_date ON public.team
FOR EACH ROW
WHEN (
  (NEW.is_active IS NOT TRUE AND OLD.is_active IS TRUE)
  OR (NEW.end_date IS NOT NULL AND OLD.end_date IS NULL)
)
EXECUTE FUNCTION public.team_departure_marks_candidate_former();
