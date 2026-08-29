-- Peter 2026-08-28: the sales-points rating bands take the agency's own
-- vocabulary. Caution -> Casual, Good -> Rock, Great -> Rockstar,
-- Elite -> Rock Legend. Danger is unchanged.
--
-- These names are not display-only. compute_sales_points_rating reads them
-- out of sales_points_band_config and three other functions compare against
-- the literal strings, so renaming the rows alone would have silently
-- broken all three -- most seriously time_off_check_eligibility, which
-- gates time off on the rating. Those literals are updated in the same
-- migration, by exact string replacement against the live definition, with
-- an assertion that no old band name survives anywhere in the body.
--
-- team_sales_points_ratings already displayed 'Rockstar' for Great and
-- 'Rock Legend' for Elite, so its mapping becomes a pass-through.

UPDATE public.sales_points_band_config
   SET rating_name = CASE rating_name
         WHEN 'Caution' THEN 'Casual'
         WHEN 'Good'    THEN 'Rock'
         WHEN 'Great'   THEN 'Rockstar'
         WHEN 'Elite'   THEN 'Rock Legend'
         ELSE rating_name END,
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND rating_name IN ('Caution','Good','Great','Elite');

DO $mig$
DECLARE
  r record;
  v_def text;
  v_new text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('sales_points_band_drop_watcher',
                         'team_sales_points_ratings',
                         'time_off_check_eligibility')
  LOOP
    v_def := pg_get_functiondef(r.oid);
    v_new := v_def;

    -- Longest patterns first so a shorter one cannot eat part of a longer.
    v_new := replace(v_new, $q$IN ('Good','Great','Elite')$q$,    $q$IN ('Rock','Rockstar','Rock Legend')$q$);
    v_new := replace(v_new, $q$IN ('Good', 'Great', 'Elite')$q$,  $q$IN ('Rock', 'Rockstar', 'Rock Legend')$q$);
    v_new := replace(v_new, $q$IN ('Great','Elite')$q$,           $q$IN ('Rockstar','Rock Legend')$q$);
    v_new := replace(v_new, $q$IN ('Great', 'Elite')$q$,          $q$IN ('Rockstar', 'Rock Legend')$q$);
    v_new := replace(v_new, $q$IN ('Danger','Caution')$q$,        $q$IN ('Danger','Casual')$q$);
    v_new := replace(v_new, $q$IN ('Danger', 'Caution')$q$,       $q$IN ('Danger', 'Casual')$q$);
    v_new := replace(v_new, $q$= 'Great' THEN 'Rockstar'$q$,      $q$= 'Rockstar' THEN 'Rockstar'$q$);
    v_new := replace(v_new, $q$= 'Elite' THEN 'Rock Legend'$q$,   $q$= 'Rock Legend' THEN 'Rock Legend'$q$);
    v_new := replace(v_new, $q$= 'Elite'$q$,                      $q$= 'Rock Legend'$q$);
    v_new := replace(v_new, $q$= 'Great'$q$,                      $q$= 'Rockstar'$q$);
    v_new := replace(v_new, $q$rating_name = 'Good'$q$,           $q$rating_name = 'Rock'$q$);
    v_new := replace(v_new, $q$= 'Caution'$q$,                    $q$= 'Casual'$q$);

    IF v_new = v_def THEN
      RAISE EXCEPTION 'Band rename: % had band literals but none were replaced', r.proname;
    END IF;

    IF v_new ~ $q$'(Caution|Good|Great|Elite)'$q$ THEN
      RAISE EXCEPTION 'Band rename: % still contains an old band name after replacement', r.proname;
    END IF;

    EXECUTE v_new;
  END LOOP;
END
$mig$;
