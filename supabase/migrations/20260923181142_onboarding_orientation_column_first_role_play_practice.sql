-- Peter 2026-09-23: the With Peter column goes first and is renamed Orientation. The Role Play column is
-- renamed Role Play & Practice. The Calls subcard moves to the bottom of that column and is renamed Practice
-- (Week 1 and Week 2 each had one). Column order comes from track_order; 0 puts Orientation left of Learn (1).
-- Template sync is held off for the three edits, then run once so live plans update in one pass.
SELECT set_config('app.onboarding_template_sync', 'off', true);

UPDATE public.onboarding_step_templates
   SET track = 'Orientation', track_order = 0
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND track = 'With Peter';

UPDATE public.onboarding_step_templates
   SET track = 'Role Play & Practice'
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND track = 'Role Play';

UPDATE public.onboarding_step_templates t
   SET title = 'Practice',
       track = 'Role Play & Practice',
       track_order = 3,
       sort_order = (SELECT COALESCE(max(o.sort_order), 0) + 10
                       FROM public.onboarding_step_templates o
                      WHERE o.agency_id = t.agency_id AND o.phase = t.phase
                        AND o.track = 'Role Play & Practice' AND o.id <> t.id)
 WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND t.template_key IN ('wk55_1_calls_s', 'wk55_1_calls_s_2');

SELECT set_config('app.onboarding_template_sync', '', true);
SELECT public.onboarding_sync_open_plans('126794dd-25ff-47d2-a436-724499733365');
