-- =========================================================================
-- Wrapup ingest — phase 1 (2026-07-21)
-- =========================================================================
-- Adds the storage column, the throttle log for public nag emails, and a
-- runtime rubric extractor that pulls the six required items directly
-- from the Daily Wrap-up manual (canonical source per Peter directive
-- 2026-07-21).
-- =========================================================================

-- 1. Storage column for the organized wrapup content, one string per
--    (team_member_id, week_ending_date). LLM rewrites this on each ingest.
ALTER TABLE public.weekly_cpr_team_detail
  ADD COLUMN IF NOT EXISTS wrapup_text text;

-- 2. Throttle log for missing-items nag emails. One row per public-nag
--    fire; identical (team_member_id, week, missing-set) will NOT re-fire.
CREATE TABLE IF NOT EXISTS public.wrapup_nag_log (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id             uuid NOT NULL,
  team_member_id        uuid NOT NULL REFERENCES public.team(id) ON DELETE CASCADE,
  week_ending_date      date NOT NULL,
  missing_items_hash    text NOT NULL,
  missing_items         jsonb NOT NULL,
  sent_at               timestamptz NOT NULL DEFAULT now(),
  gmail_message_id      text,
  trigger_email_id      text
);

CREATE INDEX IF NOT EXISTS idx_wrapup_nag_log_dedupe
  ON public.wrapup_nag_log (agency_id, team_member_id, week_ending_date, missing_items_hash);

CREATE INDEX IF NOT EXISTS idx_wrapup_nag_log_recent
  ON public.wrapup_nag_log (agency_id, sent_at DESC);

ALTER TABLE public.wrapup_nag_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS wrapup_nag_log_agency_isolation ON public.wrapup_nag_log;
CREATE POLICY wrapup_nag_log_agency_isolation ON public.wrapup_nag_log
  FOR ALL
  USING (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid)
  WITH CHECK (agency_id = '126794dd-25ff-47d2-a436-724499733365'::uuid);

-- 3. Runtime rubric extractor. Pulls the "## Weekly wrap-up email" section
--    out of the Daily Wrap-up manual and returns it as raw markdown. The
--    LLM parses items 1-6 from the returned text; that keeps a single
--    source of truth in the manuals row Peter maintains.
CREATE OR REPLACE FUNCTION public.get_wrapup_checklist_text(p_agency_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_content   text;
  v_start_pos int;
  v_end_pos   int;
  v_section   text;
BEGIN
  SELECT content INTO v_content
  FROM public.manuals
  WHERE agency_id = p_agency_id
    AND manual_type = 'processes'
    AND title = 'Daily Wrap-up'
    AND is_active = true
  LIMIT 1;

  IF v_content IS NULL THEN
    RAISE EXCEPTION 'Daily Wrap-up manual row not found for agency %', p_agency_id;
  END IF;

  v_start_pos := position('## Weekly wrap-up email' IN v_content);
  IF v_start_pos = 0 THEN
    RAISE EXCEPTION 'Weekly wrap-up section marker not found in Daily Wrap-up content';
  END IF;

  v_section := substring(v_content FROM v_start_pos);
  v_end_pos := position('</details>' IN v_section);
  IF v_end_pos > 0 THEN
    v_section := trim(substring(v_section FROM 1 FOR v_end_pos - 1));
  END IF;

  RETURN v_section;
END;
$$;

COMMENT ON FUNCTION public.get_wrapup_checklist_text(uuid) IS
  'Returns the six-item Weekly wrap-up email checklist as raw markdown from the Daily Wrap-up manuals row. Ingestor feeds this to the LLM as the coverage rubric.';

-- 4. Deterministic hash helper for the nag-log throttle. Given a jsonb
--    array of missing item labels, returns md5 of the sorted lowercased
--    labels joined by '|'. Same missing set → same hash regardless of order.
CREATE OR REPLACE FUNCTION public.wrapup_missing_items_hash(p_missing jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT md5(
    coalesce(
      (SELECT string_agg(lower(elem), '|' ORDER BY lower(elem))
         FROM jsonb_array_elements_text(p_missing) AS elem),
      ''
    )
  );
$$;
