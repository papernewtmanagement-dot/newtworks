-- Coffee and Donuts and Daily Wrap-up invite State Farm addresses only (Peter
-- 2026-09-25: "These invites don't go to personal emails, just to SF emails").
-- The Daily Kickoff keeps both addresses (his 2026-09-17 rule).
ALTER TABLE public.agency_huddle_config
  ADD COLUMN IF NOT EXISTS invite_personal_email boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.agency_huddle_config.invite_personal_email IS
  'true: each teammate is invited at their State Farm AND personal address (Daily Kickoff, Peter 2026-09-17). false: State Farm address only (Coffee and Donuts, Daily Wrap-up, Peter 2026-09-25).';

UPDATE public.agency_huddle_config
SET invite_personal_email = false
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND meeting_key IN ('coffee_and_donuts', 'daily_wrap_up');

-- The worker adds the personal address only when the meeting asks for it.
-- The next sync then takes the personal addresses off both series quietly:
-- each person is still on under their State Farm address, so no one gets a
-- taken-off note.
DO $patch$
DECLARE
  p record;
  v_def text;
  v_count int;
BEGIN
  FOR p IN
    SELECT * FROM (VALUES
      (1,
       '-- their start date) under both their State Farm and personal address.',
       '-- their start date) under their State Farm address, plus their personal' || E'\n'
         || '  -- address when the meeting has invite_personal_email on (Daily Kickoff).'),
      (2,
       'WHERE NULLIF(btrim(COALESCE(et.email_personal,'''')),'''') IS NOT NULL',
       'WHERE v.invite_personal_email' || E'\n'
         || '      AND NULLIF(btrim(COALESCE(et.email_personal,'''')),'''') IS NOT NULL')
    ) AS t(ord, old_text, new_text)
    ORDER BY ord
  LOOP
    v_def := pg_get_functiondef('public.huddle_calendar_sync_meeting(uuid,text)'::regprocedure);
    v_count := (length(v_def) - length(replace(v_def, p.old_text, ''))) / length(p.old_text);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'anchor % found % times, expected 1', p.ord, v_count;
    END IF;
    EXECUTE replace(v_def, p.old_text, p.new_text);
  END LOOP;
END
$patch$;
