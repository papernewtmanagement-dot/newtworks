-- Peter 2026-09-19: an Online Review has to say where the review landed —
-- Google, Facebook or Yelp. It pays 5.00, the largest single activity, and
-- until now nothing on the record said which site to go and look at.
--
-- The rule sits on the activity in the point values table, next to the note
-- and ECRM requirements, so turning it on for another activity later is a
-- setting rather than a code change.

ALTER TABLE public.retention_activity_log
  ADD COLUMN IF NOT EXISTS review_platform text;

ALTER TABLE public.retention_activity_log
  DROP CONSTRAINT IF EXISTS retention_activity_log_review_platform_check;
ALTER TABLE public.retention_activity_log
  ADD CONSTRAINT retention_activity_log_review_platform_check
  CHECK (review_platform IS NULL OR review_platform IN ('google', 'facebook', 'yelp'));

ALTER TABLE public.retention_point_values
  ADD COLUMN IF NOT EXISTS requires_platform boolean NOT NULL DEFAULT false;

UPDATE public.retention_point_values
   SET requires_platform = true
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND activity_key = 'google_review';

-- rp_log_activity: require it, and store it.
DO $do$
DECLARE d text; old text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace AND proname = 'rp_log_activity';
  IF position('review_platform' in d) > 0 THEN RETURN; END IF;

  old := '    IF v.requires_ecrm AND v_url IS NULL THEN
      RAISE EXCEPTION ''% needs the ECRM link so it can be checked'', v.label;
    END IF;';
  IF position(old in d) = 0 THEN RAISE EXCEPTION 'rp_log_activity does not look the way this migration expects'; END IF;
  d := replace(d, old, old || '
    IF v.requires_platform AND NULLIF(btrim(COALESCE(item->>''review_platform'','''')), '''') IS NULL THEN
      RAISE EXCEPTION ''% needs the site it was left on: Google, Facebook or Yelp'', v.label;
    END IF;
    IF NULLIF(btrim(COALESCE(item->>''review_platform'','''')), '''') IS NOT NULL
       AND lower(btrim(item->>''review_platform'')) NOT IN (''google'', ''facebook'', ''yelp'') THEN
      RAISE EXCEPTION ''the review site has to be Google, Facebook or Yelp'';
    END IF;');

  IF position('policy_line, product_type, premium)' in d) = 0
     OR position('NULLIF(item->>''premium'','''')::numeric)' in d) = 0 THEN
    RAISE EXCEPTION 'rp_log_activity insert does not look the way this migration expects';
  END IF;
  d := replace(d, 'policy_line, product_type, premium)', 'policy_line, product_type, premium, review_platform)');
  d := replace(d, 'NULLIF(item->>''premium'','''')::numeric)',
                  'NULLIF(item->>''premium'','''')::numeric, NULLIF(lower(btrim(COALESCE(item->>''review_platform'',''''))), ''''))');
  EXECUTE d;
END $do$;

-- rp_edit_activity: let it be corrected, and stop it being cleared off
-- something that requires it.
DO $do$
DECLARE d text; old text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace AND proname = 'rp_edit_activity';
  IF position('review_platform' in d) > 0 THEN RETURN; END IF;

  old := '    save_reason  = CASE WHEN c ? ''save_reason'' THEN NULLIF(btrim(COALESCE(c->>''save_reason'','''')),'''') ELSE save_reason END,';
  IF position(old in d) = 0 THEN RAISE EXCEPTION 'rp_edit_activity does not look the way this migration expects'; END IF;
  d := replace(d, old, old || '
    review_platform = CASE WHEN c ? ''review_platform'' THEN NULLIF(lower(btrim(COALESCE(c->>''review_platform'',''''))),'''') ELSE review_platform END,');

  old := '  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_ecrm AND l.ecrm_url IS NULL) THEN
    RAISE EXCEPTION ''this one needs the ECRM link, so it cannot be cleared'';
  END IF;';
  IF position(old in d) = 0 THEN RAISE EXCEPTION 'rp_edit_activity ECRM guard is not where this migration expects'; END IF;
  d := replace(d, old, old || '
  IF EXISTS (SELECT 1 FROM public.retention_activity_log l
               JOIN public.retention_point_values v
                 ON v.agency_id = l.agency_id AND v.activity_key = l.activity_key
              WHERE l.id = p_id AND v.requires_platform AND l.review_platform IS NULL) THEN
    RAISE EXCEPTION ''this one needs the site the review was left on, so it cannot be cleared'';
  END IF;');
  EXECUTE d;
END $do$;

-- rp_entry_for_edit: hand the screen what is already stored.
DO $do$
DECLARE d text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO d FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace AND proname = 'rp_entry_for_edit';
  IF position('review_platform' in d) > 0 THEN RETURN; END IF;
  IF position('''save_reason'', l.save_reason' in d) = 0 THEN
    RAISE EXCEPTION 'rp_entry_for_edit does not look the way this migration expects';
  END IF;
  EXECUTE replace(d, '''save_reason'', l.save_reason',
                     '''review_platform'', l.review_platform, ''save_reason'', l.save_reason');
END $do$;

-- The spot-check needs to show which site, or checking a review means guessing.
CREATE OR REPLACE FUNCTION public.rp_spot_check_pool(p_week_end date)
RETURNS TABLE(id uuid, team_member_id uuid, first_name text, activity_key text, label text,
              occurred_on date, customer_label text, phone_last4 text, note text,
              ecrm_url text, points numeric)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH me AS (SELECT u.agency_id FROM public.users u WHERE u.auth_user_id = auth.uid() LIMIT 1),
  wk AS (SELECT public.rp_week_end(p_week_end) AS week_end)
  SELECT l.id, l.team_member_id, t.first_name, l.activity_key, v.label, l.occurred_on,
         l.customer_label, l.phone_last4,
         CASE WHEN l.review_platform IS NULL THEN l.note
              ELSE initcap(l.review_platform) || COALESCE(' — ' || l.note, '') END,
         l.ecrm_url, l.points
  FROM public.retention_activity_log l
  JOIN me ON me.agency_id = l.agency_id
  LEFT JOIN public.team_directory t ON t.id = l.team_member_id
  LEFT JOIN public.retention_point_values v
    ON v.activity_key = l.activity_key AND v.agency_id = (SELECT agency_id FROM me)
  WHERE public.is_agency_admin() AND l.source = 'manual' AND l.status = 'credited'
    AND l.verified_at IS NULL
    AND l.created_by IS NOT NULL
    AND l.created_by = l.team_member_id
    AND public.rp_week_end(l.occurred_on) = (SELECT week_end FROM wk);
$function$;

REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rp_spot_check_pool(date) FROM anon, authenticated;
