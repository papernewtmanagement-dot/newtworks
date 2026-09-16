-- CTS result storage collapses to ONE jsonb column.
--
-- Peter ruling 2026-09-16: the coaching hours and the overall score are
-- useless, and the whole read belongs in a single jsonb column on the
-- candidate. The seven sortable score columns shipped 2026-09-15 are dropped.
-- All seven were empty (506 candidates, zero results recorded), nothing
-- outside record_cts_result() referenced them, so this drops no data.
--
-- What stays on the table is process plumbing, not the read:
--   cts_invite_sent_at, cts_invite_pg_net_id  - did we send the letter
--   cts_completed_at                          - the gate; trg_dispatch_cts_result
--                                               fires when this goes not-null
--   cts_source, cts_recorded_by               - where the result came from
--   cts_result                                - the read, entire

ALTER TABLE public.hiring_candidates
  DROP COLUMN IF EXISTS cts_combined_score,
  DROP COLUMN IF EXISTS cts_only_score,
  DROP COLUMN IF EXISTS cts_ego_drive,
  DROP COLUMN IF EXISTS cts_empathy,
  DROP COLUMN IF EXISTS cts_coaching_hours,
  DROP COLUMN IF EXISTS cts_reliability,
  DROP COLUMN IF EXISTS cts_response_distortion;

COMMENT ON COLUMN public.hiring_candidates.cts_result IS
  'The whole CTS Sales Profile read, as the vendor reported it. Single column '
  'by Peter ruling 2026-09-16. Written only by record_cts_result().';

-- record_cts_result stays the ONLY writer of a result.
--
-- GUARD CHANGED. It used to refuse a payload with no combined_score, on the
-- reasoning that the report leads with that figure so its absence means a
-- failed read. That figure is now disregarded, so the guard moves to the
-- thing a real report always carries and a failed read never does: the nine
-- primary trait scores. Seven of nine is the floor - a genuine report has all
-- nine, and a read missing three has lost a block of the page.
CREATE OR REPLACE FUNCTION public.record_cts_result(
  p_candidate_id uuid,
  p_payload      jsonb,
  p_source       text DEFAULT 'manual',
  p_recorded_by  text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing timestamptz;
  v_name     text;
  v_traits   integer;
BEGIN
  IF p_source NOT IN ('drive_pdf','manual') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'source must be drive_pdf or manual');
  END IF;

  SELECT cts_completed_at, candidate_name INTO v_existing, v_name
  FROM public.hiring_candidates WHERE id = p_candidate_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'candidate not found');
  END IF;

  IF v_existing IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'action', 'skipped',
      'reason', 'a CTS result is already on this candidate',
      'recorded_at', v_existing);
  END IF;

  SELECT count(*) INTO v_traits
  FROM jsonb_each(COALESCE(p_payload->'primary_traits', '{}'::jsonb)) AS t(k, v)
  WHERE jsonb_typeof(v) = 'number';

  IF v_traits < 7 THEN
    RETURN jsonb_build_object('ok', false, 'error',
      format('payload carries %s of 9 primary trait scores, refusing to record a partial result', v_traits));
  END IF;

  UPDATE public.hiring_candidates
  SET cts_result       = p_payload,
      cts_source       = p_source,
      cts_recorded_by  = p_recorded_by,
      cts_completed_at = NOW()
  WHERE id = p_candidate_id;

  RETURN jsonb_build_object('ok', true, 'action', 'recorded',
    'candidate_id', p_candidate_id, 'name', v_name,
    'primary_traits_recorded', v_traits);
END;
$function$;

-- The Record CTS Result form on the candidate page calls this directly.
GRANT EXECUTE ON FUNCTION public.record_cts_result(uuid, jsonb, text, text) TO authenticated;
