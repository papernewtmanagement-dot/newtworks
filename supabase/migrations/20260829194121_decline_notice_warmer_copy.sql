-- 2026-08-29 — Peter: make both decline letters more encouraging, work ethic and
-- all. Only the two message bodies change; every eligibility rule, the slot
-- claim, and the logging behaviour are byte-for-byte what shipped earlier today.
CREATE OR REPLACE FUNCTION public.send_one_candidate_decline_notice(
  p_agency_id uuid, p_candidate_id uuid
)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cand        RECORD;
  v_cutover     timestamptz;
  v_notice_id   uuid;
  v_subject     text;
  v_html        text;
  v_role_phrase text;
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

  IF v_cand.decline_reason = 'candidate_withdrew' THEN
    v_subject := 'Thanks for letting me know — Peter Story State Farm';
    v_html :=
      '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
      '<p>Thanks for letting me know you are stepping out of the process for ' ||
        v_role_phrase || ' at Peter Story State Farm. I appreciate you closing the ' ||
        'loop instead of going quiet. Plenty of people would have simply ' ||
        'disappeared. You did not — and doing the small courteous thing when there ' ||
        'is nothing in it for you is exactly the habit that makes someone worth ' ||
        'working with.</p>' ||
      '<p>Whatever you are chasing instead, I hope you go after it hard. The people ' ||
        'I have watched build something real were rarely the most naturally gifted ' ||
        'ones in the room. They were the ones who picked a direction and out-worked ' ||
        'the doubt — who kept showing up on the ordinary days, long after the ' ||
        'excitement wore off. That is a choice, not a talent, and it is available to ' ||
        'you every single morning.</p>' ||
      '<p>Our openings change through the year. If the timing is better later on, ' ||
        'please apply again. I would be glad to take another look.</p>' ||
      '<p>Go get it.</p>' ||
      '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';
  ELSE
    v_subject := 'Update on your application — Peter Story State Farm';
    v_html :=
      '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
      '<p>Thank you for applying for ' || v_role_phrase || ' at Peter Story State ' ||
        'Farm, and for the time and effort you put into the process. After thinking ' ||
        'it over, I have decided to move forward with other candidates for this ' ||
        'position.</p>' ||
      '<p>I want to be clear about what that does and does not mean. It means one ' ||
        'seat, one moment, one particular set of things I was weighing. It does not ' ||
        'mean you fell short as a person or as a professional. Those two things get ' ||
        'confused constantly, and they should not be.</p>' ||
      '<p>Here is what I have seen hold true over years of hiring: the people who go ' ||
        'on to do well are almost never the ones with the flawless resume. They are ' ||
        'the ones who keep showing up, who do the unglamorous work when nobody is ' ||
        'watching, and who get a little better every week without being asked to. ' ||
        'Talent opens a door. Work ethic is what walks through it and stays. That ' ||
        'part belongs entirely to you, and no hiring decision — mine or anyone ' ||
        'else''s — can touch it.</p>' ||
      '<p>So keep going. Send the next application. Ask the sharper question in the ' ||
        'next interview. Learn the thing you have been putting off. The effort you ' ||
        'are putting in right now compounds quietly, and it pays out on a schedule ' ||
        'you do not get to see in advance. The right fit is out there, and the work ' ||
        'you are doing to find it is not wasted.</p>' ||
      '<p>Our openings change through the year. If something opens that suits you, ' ||
        'please apply again — I would be glad to take another look.</p>' ||
      '<p>I wish you real success in whatever comes next.</p>' ||
      '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';
  END IF;

  v_pg_net_id := public.composio_send_email(p_agency_id, v_cand.email, v_subject, v_html);

  UPDATE public.candidate_decline_notices
     SET subject = v_subject, pg_net_request_id = v_pg_net_id, sent_at = NOW()
   WHERE id = v_notice_id;

  RETURN true;
END;
$function$;
