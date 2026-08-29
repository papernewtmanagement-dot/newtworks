-- Reverts migration 20260828204500. Peter was telling me which performer
-- nickname sits under each band header on the Earning Potential chart; he
-- was not renaming the bands. The band names are and remain Danger,
-- Caution, Good, Great, Elite. The nicknames are chart annotations only and
-- live in the frontend, not in this table.
--
-- Restores sales_points_band_config and puts the literal comparisons in the
-- three dependent functions back the way they were, with a per-function
-- assertion that the exact original expressions are present again.

UPDATE public.sales_points_band_config
   SET rating_name = CASE rating_name
         WHEN 'Casual'      THEN 'Caution'
         WHEN 'Rock'        THEN 'Good'
         WHEN 'Rockstar'    THEN 'Great'
         WHEN 'Rock Legend' THEN 'Elite'
         ELSE rating_name END,
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND rating_name IN ('Casual','Rock','Rockstar','Rock Legend');

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

    -- Reverse of the forward migration, longest patterns first.
    v_new := replace(v_new, $q$= 'Rockstar' THEN 'Rockstar'$q$,       $q$= 'Great' THEN 'Rockstar'$q$);
    v_new := replace(v_new, $q$= 'Rock Legend' THEN 'Rock Legend'$q$, $q$= 'Elite' THEN 'Rock Legend'$q$);
    v_new := replace(v_new, $q$IN ('Rock','Rockstar','Rock Legend')$q$,   $q$IN ('Good','Great','Elite')$q$);
    v_new := replace(v_new, $q$IN ('Rock', 'Rockstar', 'Rock Legend')$q$, $q$IN ('Good', 'Great', 'Elite')$q$);
    v_new := replace(v_new, $q$IN ('Rockstar','Rock Legend')$q$,      $q$IN ('Great','Elite')$q$);
    v_new := replace(v_new, $q$IN ('Rockstar', 'Rock Legend')$q$,     $q$IN ('Great', 'Elite')$q$);
    v_new := replace(v_new, $q$IN ('Danger','Casual')$q$,             $q$IN ('Danger','Caution')$q$);
    v_new := replace(v_new, $q$IN ('Danger', 'Casual')$q$,            $q$IN ('Danger', 'Caution')$q$);
    v_new := replace(v_new, $q$rating_name = 'Rock'$q$,               $q$rating_name = 'Good'$q$);
    v_new := replace(v_new, $q$= 'Rock Legend'$q$,                    $q$= 'Elite'$q$);
    v_new := replace(v_new, $q$= 'Rockstar'$q$,                       $q$= 'Great'$q$);
    v_new := replace(v_new, $q$= 'Casual'$q$,                         $q$= 'Caution'$q$);

    -- Exact expressions that must be back, per function.
    IF r.proname = 'sales_points_band_drop_watcher'
       AND NOT (v_new LIKE $q$%IN ('Danger','Caution')%$q$
                AND v_new LIKE $q$%IN ('Good','Great','Elite')%$q$) THEN
      RAISE EXCEPTION 'Revert failed: sales_points_band_drop_watcher';
    END IF;

    IF r.proname = 'team_sales_points_ratings'
       AND NOT (v_new LIKE $q$%= 'Great' THEN 'Rockstar'%$q$
                AND v_new LIKE $q$%= 'Elite' THEN 'Rock Legend'%$q$) THEN
      RAISE EXCEPTION 'Revert failed: team_sales_points_ratings';
    END IF;

    IF r.proname = 'time_off_check_eligibility'
       AND NOT (v_new LIKE $q$%IN ('Good', 'Great', 'Elite')%$q$
                AND v_new LIKE $q$%IN ('Great', 'Elite')%$q$
                AND v_new LIKE $q$%= 'Elite'%$q$
                AND v_new LIKE $q$%rating_name = 'Good'%$q$) THEN
      RAISE EXCEPTION 'Revert failed: time_off_check_eligibility';
    END IF;

    IF v_new LIKE $q$%'Casual'%$q$ THEN
      RAISE EXCEPTION 'Revert failed: % still references Casual', r.proname;
    END IF;

    EXECUTE v_new;
  END LOOP;
END
$mig$;
