CREATE OR REPLACE FUNCTION public.send_one_candidate_decline_notice(p_agency_id uuid, p_candidate_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ═══════════════════════════════════════════════════════════════════════════
-- The four decline letters are Peter-approved copy. As of 2026-09-12 the words
-- live in public.hiring_email_templates (keys decline_standard,
-- decline_withdrew, decline_no_show, decline_offer_rescinded) and Peter edits
-- them in the app under Team > Growth > Email Templates. They were seeded
-- verbatim from the locked copy that used to sit in this function.
--
-- Claude does not reword them — not for tone, not for length, not for
-- consistency with another template. They change when Peter changes them.
-- Reference copy also banked at persistent_memory.operational_rule
-- "Candidate decline letters — LOCKED Peter-approved copy 2026-08-29".
--
-- The eligibility rules below (who gets one, who is skipped) are ordinary code.
--
-- Which letter goes to whom:
--   candidate_withdrew          -> withdrawal letter (sends on the spot)
--   no_show                     -> no-show letter (Monday batch)
--   offer_rescinded             -> offer withdrawn letter (Monday batch). The
--                                  offer is named as CONTINGENT on purpose
--                                  (Peter 2026-09-11, legal) and the phone
--                                  call always happens before this email.
--   everything else that sends  -> standard letter (Monday batch)
-- ═══════════════════════════════════════════════════════════════════════════
DECLARE
  v_cand        RECORD;
  v_cutover     timestamptz;
  v_notice_id   uuid;
  v_subject     text;
  v_html        text;
  v_role_phrase text;
  v_key         text;
  v_pg_net_id   bigint;
BEGIN
  SELECT setting_value::timestamptz INTO v_cutover
  FROM public.settings
  WHERE agency_id = p_agency_id AND setting_key = 'decline_notice_cutover_at';

  IF v_cutover IS NULL THEN RETURN false; END IF;

  SELECT hc.id, hc.first_name, hc.email, hc.position, hc.decline_reason,
         hc.status, hc.is_test_candidate, hc.status_updated_at
    INTO v_cand
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id AND hc.agency_id = p_agency_id;

  IF NOT FOUND THEN RETURN false; END IF;
  IF v_cand.status IS DISTINCT FROM 'declined' THEN RETURN false; END IF;
  IF v_cand.is_test_candidate IS TRUE THEN RETURN false; END IF;
  IF v_cand.email IS NULL OR v_cand.email = '' THEN RETURN false; END IF;
  IF COALESCE(v_cand.status_updated_at, NOW()) < v_cutover THEN RETURN false; END IF;

  -- calibration_only: paper-only record, nobody applied, nobody to write to.
  -- former_team: a past employee, not an applicant — telling them we are going
  --   with other candidates would be false on its face.
  -- bounced_undeliverable: the mailbox already hard-bounced. The letter cannot
  --   land, and the failure notice would come straight back into the inbox the
  --   bounce recipe reads.
  IF COALESCE(v_cand.decline_reason, '') = ANY (ARRAY[
       'calibration_only', 'former_team', 'bounced_undeliverable'
     ]) THEN
    RETURN false;
  END IF;

  -- Claim the slot first. The unique index on candidate_id makes this the lock:
  -- if the row is already there, someone already sent, and we stop here.
  INSERT INTO public.candidate_decline_notices
    (agency_id, candidate_id, decline_reason, subject)
  VALUES (p_agency_id, v_cand.id, v_cand.decline_reason, 'pending')
  ON CONFLICT (candidate_id) DO NOTHING
  RETURNING id INTO v_notice_id;

  IF v_notice_id IS NULL THEN RETURN false; END IF;

  v_role_phrase := CASE
    WHEN v_cand.position IS NOT NULL AND v_cand.position <> ''
      THEN 'the <strong>' || v_cand.position || '</strong> role'
    ELSE 'a role'
  END;

  v_key := CASE v_cand.decline_reason
    WHEN 'candidate_withdrew' THEN 'decline_withdrew'
    WHEN 'no_show'            THEN 'decline_no_show'
    WHEN 'offer_rescinded'    THEN 'decline_offer_rescinded'
    ELSE 'decline_standard'
  END;

  SELECT r.subject, r.body_html INTO v_subject, v_html
  FROM public.render_hiring_email(p_agency_id, v_key, jsonb_build_object(
    'first_name',  COALESCE(NULLIF(v_cand.first_name, ''), 'there'),
    'role_phrase', v_role_phrase
  )) r;

  v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

  UPDATE public.candidate_decline_notices
     SET subject = v_subject, pg_net_request_id = v_pg_net_id, sent_at = NOW()
   WHERE id = v_notice_id;

  RETURN true;
END;
$function$;