-- Peter ruling 2026-09-11: "If a leaderboard record was created in error for an open week,
-- then it should be deleted when we fix the error."
--
-- The problem. audit_weekly_leaderboard_crossings builds the top 3 by wiping every row for a
-- category and re-inserting the best 3 from (existing rows + the new candidate). Whatever got
-- pushed into 4th place is destroyed. So deleting a wrong record could not simply restore the
-- record it displaced - that record no longer existed anywhere.
--
-- The fix. Keep every record-setting performance in an append-only ledger. leaderboards
-- becomes the top 3 derived from that ledger, rebuilt on demand. Deleting a wrong entry now
-- brings the displaced record back on its own, with nothing to restore by hand.
--
-- leaderboards keeps its exact shape and column names, so LeaderboardsSection, the banner and
-- the goals count all read it unchanged.
CREATE TABLE IF NOT EXISTS public.leaderboard_entries (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id           uuid NOT NULL,
  category            text NOT NULL,
  team_member_id      uuid NOT NULL,
  record_value        numeric NOT NULL,
  record_period_label text NOT NULL,
  record_week_ending  date,
  set_at              timestamptz NOT NULL DEFAULT now(),
  notes               text
);

-- One entry per person per category per period. A weekly period label is that week's date, so
-- this is the natural key already in use.
CREATE UNIQUE INDEX IF NOT EXISTS leaderboard_entries_natural_key
  ON public.leaderboard_entries (agency_id, category, team_member_id, record_period_label);

CREATE INDEX IF NOT EXISTS leaderboard_entries_week_idx
  ON public.leaderboard_entries (agency_id, record_week_ending);

ALTER TABLE public.leaderboard_entries ENABLE ROW LEVEL SECURITY;

DO $rls$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname='public' AND tablename='leaderboard_entries'
                   AND policyname='leaderboard_entries_read') THEN
    CREATE POLICY leaderboard_entries_read ON public.leaderboard_entries
      FOR SELECT TO anon, authenticated USING (true);
  END IF;
END
$rls$;

-- Seed the ledger from whatever is on the board today so nothing already earned is lost.
INSERT INTO public.leaderboard_entries
  (agency_id, category, team_member_id, record_value, record_period_label, record_week_ending, set_at, notes)
SELECT l.agency_id, l.category, l.team_member_id, l.record_value, l.record_period_label,
       l.record_week_ending, COALESCE(l.set_at, now()), l.notes
FROM public.leaderboards l
ON CONFLICT (agency_id, category, team_member_id, record_period_label) DO NOTHING;

-- Rebuild the board: top 3 per category, by value, ties broken by who set it first.
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
                                   ORDER BY e.record_value DESC, e.set_at ASC) AS rn
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

GRANT EXECUTE ON FUNCTION public.rebuild_leaderboards_from_entries(uuid) TO anon, authenticated;