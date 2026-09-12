-- Correction. rebuild_leaderboards_from_entries shipped with ORDER BY record_value DESC,
-- set_at ASC, which gives a tie to whoever set it FIRST. The original wipe-and-reinsert in
-- audit_weekly_leaderboard_crossings ordered by record_value DESC, set_at DESC, so the newest
-- performance took the higher slot on a tie. That was shipped behaviour and was not something
-- anyone asked to change. Restoring it.
--
-- No visible effect today: no category currently has a tie, and the rebuild reproduced the
-- board exactly either way. This only matters the first time two figures land equal.
CREATE OR REPLACE FUNCTION public.rebuild_leaderboards_from_entries(p_agency_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rows int := 0;
BEGIN
  DELETE FROM public.leaderboards WHERE agency_id = p_agency_id;

  WITH ranked AS (
    SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.category
                                   ORDER BY e.record_value DESC, e.set_at DESC) AS rn
    FROM public.leaderboard_entries e
    WHERE e.agency_id = p_agency_id
  ), ins AS (
    INSERT INTO public.leaderboards
      (agency_id, category, tier, team_member_id, record_value,
       record_period_label, record_week_ending, set_at, notes)
    SELECT p_agency_id, r.category, r.rn::int, r.team_member_id, r.record_value,
           r.record_period_label, r.record_week_ending, r.set_at, r.notes
    FROM ranked r WHERE r.rn <= 3
    RETURNING 1
  )
  SELECT COUNT(*)::int INTO v_rows FROM ins;

  RETURN jsonb_build_object('rebuilt', true, 'leaderboard_rows', v_rows, 'ran_at', now());
END;
$function$;