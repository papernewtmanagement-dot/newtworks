-- =========================================================================
-- A ramp phase opens when the phase before it ends
-- =========================================================================
-- I stored a flat "days after the start date" on every phase, which meant the
-- whole ramp was pinned to a fixed calendar and each number was mine to
-- invent. It should chain: the first week opens on the start date and every
-- phase after that opens when the one before it finishes.
--
-- So a ramp phase now stores how long it lasts, not when it starts, and the
-- opening date is worked out by adding up the phases in front of it. Change
-- one phase from two weeks to three and everything downstream moves on its
-- own, in one place.
--
-- Pre-start phases are different in kind — they hang backwards off the start
-- date rather than following one another — so they keep a day offset.
-- =========================================================================

ALTER TABLE public.onboarding_phases
  ADD COLUMN IF NOT EXISTS weeks_long integer;

COMMENT ON COLUMN public.onboarding_phases.weeks_long IS
  'How many weeks this ramp phase lasts. The phase opens when every ramp phase before it has run its length. Leave empty on the final open-ended phase and on anything that is not a ramp phase.';
COMMENT ON COLUMN public.onboarding_phases.days_from_start IS
  'Only used by phases that are not part of the ramp — the pre-start work that hangs backwards off the start date. Ramp phases are worked out from weeks_long instead.';

UPDATE public.onboarding_phases SET weeks_long = v.w
FROM (VALUES (50,0),(55,2),(60,2),(65,4),(70,5),(75,NULL)) AS v(p,w)
WHERE onboarding_phases.agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND onboarding_phases.phase = v.p;

UPDATE public.onboarding_phases SET days_from_start = NULL
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND stage = 'ramp';


-- The one place that answers "when does this step open?"
CREATE OR REPLACE FUNCTION public.onboarding_phase_opens_on(
  p_agency_id  uuid,
  p_phase      integer,
  p_start_date date
) RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT CASE
           WHEN p_start_date IS NULL THEN NULL
           WHEN ph.stage = 'ramp' THEN
             p_start_date + 7 * COALESCE((
               SELECT sum(prior.weeks_long)::int
               FROM public.onboarding_phases prior
               WHERE prior.agency_id = p_agency_id
                 AND prior.stage     = 'ramp'
                 AND prior.phase     < p_phase
             ), 0)
           ELSE p_start_date + COALESCE(ph.days_from_start, 0)
         END
  FROM public.onboarding_phases ph
  WHERE ph.agency_id = p_agency_id AND ph.phase = p_phase;
$function$;

COMMENT ON FUNCTION public.onboarding_phase_opens_on(uuid, integer, date) IS
  'The date a phase opens for a given start date. Ramp phases chain off the lengths of the phases in front of them; pre-start phases hang backwards off the start date. Every caller uses this — the open-step notice and the task due date both.';
