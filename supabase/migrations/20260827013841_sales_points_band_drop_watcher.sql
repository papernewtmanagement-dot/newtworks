-- Sales Points band drop watcher.
--
-- Handbook 02 Hours & Time Off (locked 2026-08-25): a teammate whose own rolling
-- thirteen-week Sales Points average falls into "Danger" goes on a signed improvement
-- plan measured on returning to "Good" within thirteen weeks. A teammate in "Caution"
-- gets a documented coaching conversation plus a weekly one-on-one until the rating
-- recovers. Nothing in the app watched for either, so a drop could sit unnoticed.
--
-- Peter's call 2026-08-26: alert only. No plan table, no new screen. The alert is
-- created automatically on the drop and he handles the conversation himself.
--
-- Two objects:
--   team_sales_points_rating_state  - one row per teammate holding the last rating seen,
--                                     so the watcher can tell a NEW drop from a rating
--                                     that has already been alerted on and is still low.
--   sales_points_band_drop_watcher  - the weekly automation handler.

CREATE TABLE IF NOT EXISTS public.team_sales_points_rating_state (
  agency_id       uuid        NOT NULL,
  team_member_id  uuid        NOT NULL,
  rating          text        NOT NULL,
  avg_13wk        numeric,
  rel_13wk        numeric,
  first_seen_at   timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (agency_id, team_member_id)
);

ALTER TABLE public.team_sales_points_rating_state ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='team_sales_points_rating_state'
      AND policyname='team_sales_points_rating_state_all'
  ) THEN
    CREATE POLICY team_sales_points_rating_state_all
      ON public.team_sales_points_rating_state
      FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);
  END IF;
END $$;

-- Worst to best. Used to decide whether a move is a drop or a recovery.
CREATE OR REPLACE FUNCTION public.sales_points_rating_ordinal(p_rating text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_rating
    WHEN 'Danger'  THEN 1
    WHEN 'Caution' THEN 2
    WHEN 'Good'    THEN 3
    WHEN 'Great'   THEN 4
    WHEN 'Elite'   THEN 5
    ELSE NULL END;
$$;

CREATE OR REPLACE FUNCTION public.sales_points_band_drop_watcher(
  p_agency_id uuid,
  p_recipe_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_member        RECORD;
  v_avg           numeric;
  v_weight        numeric;
  v_rel           numeric;
  v_rating        text;
  v_prior         text;
  v_mod_ref       text;
  v_dropped       integer := 0;
  v_recovered     integer := 0;
  v_dropped_names text[] := '{}';
  v_recov_names   text[] := '{}';
  v_summary       text;
BEGIN
  FOR v_member IN
    SELECT t.id, t.first_name, t.last_name, t.role_level, t.role_category, t.hire_date
    FROM public.team t
    WHERE t.agency_id = p_agency_id
      AND t.archived_at IS NULL
      AND t.role_level IN ('Account Manager','Unit Manager','Section Manager','Office Manager')
      -- Same probation rule the time off eligibility check uses: no rating until
      -- there are thirteen weeks of history to average.
      AND t.hire_date IS NOT NULL
      AND FLOOR((CURRENT_DATE - t.hire_date) / 7.0) >= 13
  LOOP
    v_avg := public.team_member_sales_points_avg_13wk(v_member.id);
    CONTINUE WHEN v_avg IS NULL;

    -- Retention seats carry half the requirement, so their points are read against
    -- half the scale before the band is looked up. Same weighting as time_off_check_eligibility.
    v_weight := CASE WHEN v_member.role_category = 'Retention' THEN 0.5 ELSE 1.0 END;
    v_rel    := ROUND(v_avg / v_weight, 2);
    v_rating := public.compute_sales_points_rating(p_agency_id, v_rel);
    CONTINUE WHEN v_rating IS NULL;

    SELECT s.rating INTO v_prior
    FROM public.team_sales_points_rating_state s
    WHERE s.agency_id = p_agency_id AND s.team_member_id = v_member.id;

    v_mod_ref := 'sales_points_band:' || v_member.id::text;

    -- A DROP into Danger or Caution. First sighting counts as a drop too, so a rating
    -- that is already low when this first runs does not go unreported.
    IF v_rating IN ('Danger','Caution')
       AND (v_prior IS NULL
            OR public.sales_points_rating_ordinal(v_rating)
               < public.sales_points_rating_ordinal(v_prior))
    THEN
      INSERT INTO public.alerts (agency_id, alert_type, severity, title, message,
                                 module_reference, related_id, is_read, is_resolved)
      SELECT p_agency_id,
             'sales_points_band_drop',
             CASE WHEN v_rating = 'Danger' THEN 'critical' ELSE 'warning' END,
             v_member.first_name || ' ' || v_member.last_name
               || ' dropped to ' || v_rating || ' on Sales Points',
             v_member.first_name || '''s thirteen-week Sales Points average is '
               || ROUND(v_avg, 0) || ' a week'
               || CASE WHEN v_weight <> 1.0
                       THEN ' (' || ROUND(v_rel, 0) || ' against the retention half-scale)'
                       ELSE '' END
               || ', a ' || v_rating || ' rating'
               || CASE WHEN v_prior IS NOT NULL THEN ', down from ' || v_prior ELSE '' END
               || '. '
               || CASE WHEN v_rating = 'Danger'
                       THEN 'Handbook: signed improvement plan, measured on getting back to Good within thirteen weeks. Unlimited paid time off pauses until the rating recovers. Pay is not cut.'
                       ELSE 'Handbook: documented coaching conversation plus a weekly one-on-one until the rating recovers.' END,
             v_mod_ref, v_member.id, false, false
      WHERE NOT EXISTS (
        SELECT 1 FROM public.alerts a
        WHERE a.agency_id = p_agency_id
          AND a.module_reference = v_mod_ref
          AND a.is_resolved = false
      );
      v_dropped := v_dropped + 1;
      v_dropped_names := v_dropped_names || (v_member.first_name || ' (' || v_rating || ')');
    END IF;

    -- Back to Good or better: close out the open alert so the list stays honest.
    IF v_rating IN ('Good','Great','Elite')
       AND EXISTS (SELECT 1 FROM public.alerts a
                   WHERE a.agency_id = p_agency_id
                     AND a.module_reference = v_mod_ref
                     AND a.is_resolved = false)
    THEN
      UPDATE public.alerts
      SET is_resolved = true, resolved_at = now()
      WHERE agency_id = p_agency_id
        AND module_reference = v_mod_ref
        AND is_resolved = false;
      v_recovered := v_recovered + 1;
      v_recov_names := v_recov_names || (v_member.first_name || ' (' || v_rating || ')');
    END IF;

    INSERT INTO public.team_sales_points_rating_state
      (agency_id, team_member_id, rating, avg_13wk, rel_13wk, updated_at)
    VALUES (p_agency_id, v_member.id, v_rating, ROUND(v_avg, 2), v_rel, now())
    ON CONFLICT (agency_id, team_member_id) DO UPDATE
      SET rating = EXCLUDED.rating,
          avg_13wk = EXCLUDED.avg_13wk,
          rel_13wk = EXCLUDED.rel_13wk,
          updated_at = now();
  END LOOP;

  v_summary := CASE
    WHEN v_dropped = 0 AND v_recovered = 0 THEN 'No Sales Points band changes this week.'
    ELSE trim(both ' ' FROM
         CASE WHEN v_dropped > 0
              THEN 'Dropped: ' || array_to_string(v_dropped_names, ', ') || '. ' ELSE '' END
      || CASE WHEN v_recovered > 0
              THEN 'Recovered to Good or better: ' || array_to_string(v_recov_names, ', ') || '.' ELSE '' END)
  END;

  RETURN jsonb_build_object(
    'records_processed', v_dropped + v_recovered,
    'dropped', v_dropped,
    'recovered', v_recovered,
    'output_summary', v_summary
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION public.sales_points_rating_ordinal(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sales_points_band_drop_watcher(uuid, uuid) TO anon, authenticated;
GRANT SELECT ON public.team_sales_points_rating_state TO anon, authenticated;
