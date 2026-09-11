-- =====================================================================
-- send_one_candidate_decline_notice: two more letters, no-show and offer withdrawn
--
-- Peter 2026-09-11: every hand-picked decline reason gets its own letter, the
-- way a withdrawal already does. Didn't meet standard keeps the standard
-- letter locked 2026-08-29 (it also covers the resume and assessment
-- auto-declines). no_show and offer_rescinded get the two new letters below,
-- approved and locked by Peter the same day ("lock both in").
--
-- Offer withdrawn letter, two rulings from Peter that are load-bearing:
--   1. The offer is called a CONTINGENT offer. Legal purposes. Do not drop
--      the word.
--   2. The phone call always comes first, so the letter reads as written
--      confirmation of that call and does not invite a reply.
-- The letter does not acknowledge anything the candidate may have given up
-- on the strength of the offer; the whole point of "contingent" is that
-- nothing was promised until the conditions cleared.
--
-- Eligibility and send timing are unchanged: withdrawals send on the spot
-- (trg_candidate_decline_notice), everything else goes in the Monday 8am
-- batch (recipe "Send Candidate Decline Notices"). calibration_only,
-- former_team and bounced_undeliverable still never send.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.send_one_candidate_decline_notice(p_agency_id uuid, p_candidate_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ═══════════════════════════════════════════════════════════════════════════
-- LOCKED COPY — Peter-approved 2026-08-29, verbatim, his words: "Those are
-- great. Lock them in." Two more letters (no-show, offer withdrawn) added
-- 2026-09-11 at Peter's direction and locked the same way ("lock both in").
--
-- The four message bodies below are NOT to be reworded, tightened, shortened,
-- "improved", regenerated, or restructured. Not for tone, not for length, not
-- for consistency with some other template, not because a later model would
-- phrase it differently. They change ONLY when Peter explicitly asks for a
-- change to the decline letters.
--
-- The eligibility rules around them (who gets one, who is skipped) are ordinary
-- code and may be changed as needed. This lock covers the words.
--
-- Reference copy also banked at persistent_memory.operational_rule
-- "Candidate decline letters — LOCKED Peter-approved copy 2026-08-29".
-- Restore from there if these ever drift.
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
    -- ── LOCKED: withdrawal letter ──
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
  ELSIF v_cand.decline_reason = 'no_show' THEN
    -- ── LOCKED: no-show letter (Peter-approved 2026-09-11) ──
    v_subject := 'Update on your application — Peter Story State Farm';
    v_html :=
      '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
      '<p>We had a time set aside to meet for ' || v_role_phrase || ' at Peter Story ' ||
        'State Farm, and it did not happen. I am not going to assume the worst. ' ||
        'Things come up, phones die, days get away from people.</p>' ||
      '<p>I do have to be straight with you. I have closed your application for now. ' ||
        'Showing up is the first thing I look for in anyone I hire, and the interview ' ||
        'is the first place I get to see it. There is no way around that.</p>' ||
      '<p>None of this says anything about what you are capable of. If you want a job ' ||
        'like this, the fix is not complicated. Pick the next thing, put it on your ' ||
        'calendar, and be there ten minutes early. Do that a few times in a row and ' ||
        'doors open.</p>' ||
      '<p>If something real got in the way and you still want this, apply again and ' ||
        'tell me what happened. I would be glad to take another look.</p>' ||
      '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';
  ELSIF v_cand.decline_reason = 'offer_rescinded' THEN
    -- ── LOCKED: offer withdrawn letter (Peter-approved 2026-09-11) ──
    v_subject := 'Update on your offer — Peter Story State Farm';
    v_html :=
      '<p>Hi ' || COALESCE(NULLIF(v_cand.first_name, ''), 'there') || ',</p>' ||
      '<p>This confirms what we talked about by phone. The contingent offer for ' ||
        v_role_phrase || ' at Peter Story State Farm is withdrawn. I know that is ' ||
        'hard to read, and I did not make the decision lightly.</p>' ||
      '<p>A door closing rarely says much about the person on the other side of it. ' ||
        'The work you did to earn that offer was real, and it goes with you. Nothing ' ||
        'about this changes that.</p>' ||
      '<p>I wish you real success in what comes next.</p>' ||
      '<p>&mdash; Peter Story<br>Peter Story State Farm</p>';
  ELSE
    -- ── LOCKED: standard decline letter ──
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