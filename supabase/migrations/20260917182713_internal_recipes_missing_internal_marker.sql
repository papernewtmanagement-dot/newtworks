-- The runner decides between "call a database function" and "call Composio" by
-- looking at composio_action = 'INTERNAL'. Six recipes had an internal_handler
-- set but no marker, so the runner walked past the internal branch and died on
-- "has no composio_connection set". Every run of all six has failed since the
-- day it was created. Onboarding — open step notices is why Alvi never got a
-- notice about Bryson's checklist.
UPDATE public.automation_recipes
SET composio_action = 'INTERNAL',
    updated_at      = now()
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND internal_handler IS NOT NULL
  AND composio_action IS DISTINCT FROM 'INTERNAL';
