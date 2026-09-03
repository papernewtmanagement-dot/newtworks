-- Companion to decline_notices_weekly_monday_withdrawals_immediate.
-- This sweep used to be a daily backstop behind an immediate per-row send.
-- As of 2026-09-02 it IS the sender for every decline except withdrawals, and
-- it runs weekly on Monday morning. Only the summary wording changes here;
-- the selection logic already does exactly the right thing.

CREATE OR REPLACE FUNCTION public.send_candidate_decline_notices(p_agency_id uuid, p_recipe_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sent            int := 0;
  v_errors          int := 0;
  v_skipped_no_addr int := 0;
  v_cutover         timestamptz;
  v_cand            RECORD;
  v_error_details   jsonb := '[]'::jsonb;
BEGIN
  SELECT setting_value::timestamptz INTO v_cutover
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'decline_notice_cutover_at';

  IF v_cutover IS NULL THEN
    RETURN jsonb_build_object(
      'error', 'decline_notice_cutover_at missing — refusing to send',
      'ran_at', NOW(), 'records_processed', 0,
      'output_summary', 'ERROR: settings.decline_notice_cutover_at missing — refusing to send');
  END IF;

  SELECT COUNT(*) INTO v_skipped_no_addr
  FROM public.hiring_candidates hc
  WHERE hc.agency_id = p_agency_id
    AND hc.status = 'declined'
    AND hc.is_test_candidate IS NOT TRUE
    AND hc.status_updated_at >= v_cutover
    AND (hc.email IS NULL OR hc.email = '')
    AND COALESCE(hc.decline_reason,'') <> ALL (ARRAY['calibration_only','former_team','bounced_undeliverable'])
    AND NOT EXISTS (SELECT 1 FROM public.candidate_decline_notices n WHERE n.candidate_id = hc.id);

  FOR v_cand IN
    SELECT hc.id
    FROM public.hiring_candidates hc
    WHERE hc.agency_id = p_agency_id
      AND hc.status = 'declined'
      AND hc.status_updated_at >= v_cutover
      AND NOT EXISTS (SELECT 1 FROM public.candidate_decline_notices n WHERE n.candidate_id = hc.id)
    ORDER BY hc.status_updated_at
  LOOP
    BEGIN
      IF public.send_one_candidate_decline_notice(p_agency_id, v_cand.id) THEN
        v_sent := v_sent + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object('candidate_id', v_cand.id, 'error', SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'sent', v_sent,
    'errors', v_errors,
    'error_details', v_error_details,
    'skipped_no_address', v_skipped_no_addr,
    'ran_at', NOW(),
    'records_processed', v_sent,
    'output_summary', v_sent || ' decline letter(s) sent in the weekly Monday batch, ' ||
      v_errors || ' error(s)' ||
      CASE WHEN v_skipped_no_addr > 0
        THEN ' (' || v_skipped_no_addr || ' have no email address on file)' ELSE '' END
  );
END;
$function$;
