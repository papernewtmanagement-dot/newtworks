-- Dual-path fork of assessment_commitment. SCORING IS DUAL-PATH per standing
-- Peter instruction (serving stays single-path — do not collapse the two).
-- OLD path preserved byte-for-byte:
--   (deadline_motivation + recognition_drive + independent_spirit) / 3
-- NEW path per Peter's locked Commitment definition (persistent_memory
-- "COMMITMENT construct — Peter's locked definition (4 parts)", 2026-08-04):
-- the assessment can honestly measure only part 1, role attitude
-- (enterprising — vocational interest congruence; Van Iddekinge, Roth, Putka &
-- Lanivich 2011 JAP 96(6); Nye, Su, Rounds & Drasgow 2012 PPS 7(4)) and part of
-- part 3, motivation type (achievement_striving; Vinchur, Schippmann, Switzer &
-- Roth 1998 JAP 83(4), rho .41 on objective sales). Parts 2 (company/product
-- buy-in) and 4 (motivation level) deliberately live on the interview and resume
-- layers, which already carry Commitment's heaviest weights by design.
-- Unit weights per Wainer 1976 / Ree, Earles & Teachout 1994.
-- Path markers per dual-path rule: achievement_striving = new instrument,
-- deadline_motivation = old instrument. Never use assertiveness/compassion as
-- markers (they serve both instruments).
CREATE OR REPLACE FUNCTION public.assessment_commitment(p_candidate_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
    WHEN hc.achievement_striving IS NOT NULL THEN
      round((hc.enterprising + hc.achievement_striving)::numeric / 2.0, 2)
    WHEN hc.deadline_motivation IS NOT NULL THEN
      round((hc.deadline_motivation + hc.recognition_drive + hc.independent_spirit)::numeric / 3.0, 2)
    ELSE NULL
  END
  FROM public.hiring_candidates hc
  WHERE hc.id = p_candidate_id;
$function$;

COMMENT ON FUNCTION public.assessment_commitment(uuid) IS
'Dual-path Commitment (assessment layer). New instrument: mean(enterprising, achievement_striving) — the only two Commitment parts the assessment can honestly measure per Peter''s locked 2026-08-04 definition; buy-in and motivation level live on interview/resume layers. Old instrument: mean(deadline_motivation, recognition_drive, independent_spirit), unchanged. Marker: achievement_striving = new path, deadline_motivation = old path.';
