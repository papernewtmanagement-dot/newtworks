-- Onboarding, Peter 2026-09-22 (Confluence follow-up).
-- * Week 2 is its own phase (57), no longer a column inside Weeks 1-2.
--   Week 1 and Week 2 open once Login is done, as Weeks 1-2 did (the import
--   had dropped that link to Login).
-- * The week phase blurbs were summaries that are not on Confluence; cleared.
-- * Links read as links: a label followed by a web address becomes the label
--   as a link; a web address shown as its own text shows the site name.
-- * Get System Access: "Request Access" is the link; the ABS path sits behind
--   the (i) on that line, one step per line.
CREATE OR REPLACE FUNCTION pg_temp.site_name(u text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE
    WHEN u ~* '^https?://([a-z0-9-]+\.)*(youtube\.com|youtu\.be)' THEN 'YouTube'
    WHEN u ~* '^https?://([a-z0-9-]+\.)*tiktok\.com' THEN 'TikTok'
    WHEN u ~* '^https?://([a-z0-9-]+\.)*facebook\.com' THEN 'Facebook'
    WHEN u ~* '^https?://([a-z0-9-]+\.)*c-span\.org' THEN 'C-SPAN'
    ELSE regexp_replace(substring(u from '^https?://([^/?#]+)'), '^www\.', '')
  END;
$f$;
-- "Label: [https://x](https://x)" -> "[Label](https://x)"
CREATE OR REPLACE FUNCTION pg_temp.fix1(s text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE m text[];
BEGIN
  IF s IS NULL THEN RETURN s; END IF;
  m := regexp_match(s, '^(.*[^[:space:]:])[[:space:]]*:?[[:space:]]+\[https?://[^]]*\]\((https?://[^)]+)\)(.*)$');
  IF m IS NOT NULL AND m[1] !~ '\]\(' THEN
    RETURN '[' || m[1] || '](' || m[2] || ')' || m[3];
  END IF;
  RETURN s;
END $f$;
-- any link still showing its web address as its text shows the site's name
CREATE OR REPLACE FUNCTION pg_temp.fix3(s text) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE m text[]; nxt text; guard int := 0;
BEGIN
  IF s IS NULL THEN RETURN s; END IF;
  WHILE s ~ '\[https?://[^]]*\]\(' AND guard < 20 LOOP
    guard := guard + 1;
    m := regexp_match(s, '\[(https?://[^]]*)\]\((https?://[^)]+)\)');
    EXIT WHEN m IS NULL;
    nxt := replace(s, '[' || m[1] || '](' || m[2] || ')', '[' || pg_temp.site_name(m[2]) || '](' || m[2] || ')');
    EXIT WHEN nxt = s;
    s := nxt;
  END LOOP;
  RETURN s;
END $f$;
CREATE OR REPLACE FUNCTION pg_temp.fix_line(s text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
  SELECT pg_temp.fix3(pg_temp.fix1(s));
$f$;
-- "Label:" followed by exactly one address line -> "[Label](address)"
CREATE OR REPLACE FUNCTION pg_temp.fix_items(a jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE arr text[]; outa text[] := '{}'; i int; n int; k int; m text[];
BEGIN
  IF a IS NULL OR jsonb_typeof(a) <> 'array' THEN RETURN a; END IF;
  arr := ARRAY(SELECT x FROM jsonb_array_elements_text(a) WITH ORDINALITY z(x, o) ORDER BY o);
  n := COALESCE(array_length(arr, 1), 0);
  FOR i IN 1..n LOOP
    m := regexp_match(arr[i], '^\[https?://[^]]*\]\((https?://[^)]+)\)(.*)$');
    k := COALESCE(array_length(outa, 1), 0);
    IF m IS NOT NULL AND k > 0 AND outa[k] ~ ':[[:space:]]*$' AND outa[k] !~ '\]\('
       AND (i = n OR arr[i + 1] !~ '^\[https?://') THEN
      outa[k] := '[' || regexp_replace(outa[k], '[[:space:]]*:[[:space:]]*$', '') || '](' || m[1] || ')' || m[2];
    ELSE
      outa := outa || pg_temp.fix1(arr[i]);
    END IF;
  END LOOP;
  RETURN COALESCE((SELECT jsonb_agg(pg_temp.fix3(x) ORDER BY o) FROM unnest(outa) WITH ORDINALITY z(x, o)), '[]'::jsonb);
END $f$;
CREATE OR REPLACE FUNCTION pg_temp.fix_subs(s jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $f$
BEGIN
  IF s IS NULL OR jsonb_typeof(s) <> 'array' THEN RETURN s; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(s) e WHERE jsonb_typeof(e) = 'object') THEN
    RETURN pg_temp.fix_items(s);
  END IF;
  RETURN (SELECT jsonb_agg(
            CASE
              WHEN jsonb_typeof(e) = 'object' THEN
                e || jsonb_build_object('items', pg_temp.fix_items(COALESCE(e -> 'items', '[]'::jsonb)))
                  || CASE WHEN e ->> 'group' IS NOT NULL
                          THEN jsonb_build_object('group', pg_temp.fix_line(e ->> 'group')) ELSE '{}'::jsonb END
                  || CASE WHEN jsonb_typeof(e -> 'info') = 'array'
                          THEN jsonb_build_object('info', (SELECT jsonb_agg(pg_temp.fix_line(x) ORDER BY o)
                                                           FROM jsonb_array_elements_text(e -> 'info') WITH ORDINALITY z(x, o)))
                          ELSE '{}'::jsonb END
              WHEN jsonb_typeof(e) = 'string' THEN to_jsonb(pg_temp.fix_line(e #>> '{}'))
              ELSE e
            END ORDER BY ord)
          FROM jsonb_array_elements(s) WITH ORDINALITY q(e, ord));
END $f$;

SELECT set_config('app.onboarding_template_sync', 'off', true);

UPDATE public.onboarding_phases SET name = 'Week 1', weeks_long = 1, blurb = NULL, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 55;
INSERT INTO public.onboarding_phases (agency_id, phase, name, blurb, stage, is_active, weeks_long)
SELECT '126794dd-25ff-47d2-a436-724499733365', 57, 'Week 2', NULL, 'ramp', true, 1
WHERE NOT EXISTS (SELECT 1 FROM public.onboarding_phases
                  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 57);
UPDATE public.onboarding_phases SET blurb = NULL, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase IN (60, 65, 70, 75);
UPDATE public.onboarding_phases
   SET blurb = 'Log in first. The other Setup cards, Week 1 and Week 2 open once Login is done.', updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 50;

UPDATE public.onboarding_step_templates SET phase = 57
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 55 AND track = 'Week 2';
UPDATE public.onboarding_step_templates
   SET track = NULL, track_order = 0,
       blocked_by = CASE WHEN 't_login' = ANY (COALESCE(blocked_by, '{}')) THEN blocked_by
                         ELSE array_append(COALESCE(blocked_by, '{}'), 't_login') END
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase IN (55, 57);

UPDATE public.onboarding_step_templates
   SET substeps = pg_temp.fix_subs(substeps), description = pg_temp.fix_line(description)
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND (substeps IS DISTINCT FROM pg_temp.fix_subs(substeps) OR description IS DISTINCT FROM pg_temp.fix_line(description));

UPDATE public.onboarding_step_templates
   SET description = replace(description,
         'ABS, Agent Telephony Request: https://notesforms001.opr.statefarm.org/sff/agent/w0058420.nsf/postform?CreateDocument&back&sffid=155795',
         'ABS, [Agent Telephony Request](https://notesforms001.opr.statefarm.org/sff/agent/w0058420.nsf/postform?CreateDocument&back&sffid=155795)')
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 't_call_flow';

UPDATE public.onboarding_step_templates
   SET substeps = jsonb_build_array(jsonb_build_object(
         'group', NULL,
         'items', jsonb_build_array('[Request Access](https://app.asp.ic1.statefarm/system-access-request/new)', 'Alias approved'),
         'item_info', jsonb_build_object('[Request Access](https://app.asp.ic1.statefarm/system-access-request/new)',
           jsonb_build_array('ABS', 'Manage the Business', 'Team Management', 'State Farm System Access/Termination',
                             'Connecting New Agent Team Members', 'Agent Team Members Who Have Never Had an Alias',
                             'Agent Team Member System Access Request'))))
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p0_ecrm_account';

-- A tick on the old "Request Access" line carries to the new one.
UPDATE public.team_onboarding_steps s
   SET substeps_done = COALESCE((
         SELECT jsonb_agg(CASE WHEN d = 'Request Access'
                               THEN '[Request Access](https://app.asp.ic1.statefarm/system-access-request/new)' ELSE d END)
         FROM jsonb_array_elements_text(s.substeps_done) d
         WHERE d <> 'https://app.asp.ic1.statefarm/system-access-request/new'), '[]'::jsonb)
 WHERE s.template_key = 'p0_ecrm_account'
   AND jsonb_typeof(s.substeps_done) = 'array'
   AND s.substeps_done ?| ARRAY['Request Access', 'https://app.asp.ic1.statefarm/system-access-request/new'];

SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
