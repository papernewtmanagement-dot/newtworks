-- Seat bars re-anchoring under pool-percentile scale (v5.2 side effect).
-- Planning-thread decision 2026-08-14 (Peter approved via *Ass Confirm successor thread):
-- retention_support floor moved from 50 (percent-correct-era value, now meaningless as
-- pool percentile since it fails half of every pool by construction) to 25 (catches
-- genuine bottom-tail pool standing without punishing the pctl-26 cluster twice, given
-- ability is already one of 27 weighted inputs and the absolute 62.5% reasoning-floor
-- gate is untouched). Ceiling unchanged at 80 -> above_band_max_discount unchanged at 0.15.
UPDATE hiregauge_role_ideal_ranges
SET intelligence_ideal_min = 25,
    updated_at = now(),
    updated_by = 'claude_planning_thread_2026-08-14',
    notes = notes || E'\n\n2026-08-14 RE-ANCHOR (v5.2 pool-percentile side effect): floor moved 50->25. ' ||
      'Prior value (50) was authored under percent-correct scale where it never bound (pool ' ||
      'range was 63-94% correct). Under pool-percentile scale, floor=50 fails half of every ' ||
      'pool by construction -- not a considered risk tolerance, an artifact. Research basis: ' ||
      'ability-performance is monotonic with no natural cliff (Coward & Sackett 1990 JAP ' ||
      '75:297-300; Arneson, Sackett & Beatty 2011 Psych Sci 22:1000-1006), so any floor is a ' ||
      'business choice not a scientific cutoff; ability is supportive not dominant for these ' ||
      'roles and already weighted in the fit sum (Hunter & Hunter 1984; Vinchur, Schippmann, ' ||
      'Switzer & Roth 1998; Frei & McDaniel 1998); the 16-item GMA subtest only produces 6 ' ||
      'possible raw scores so adjacent percentile bands (e.g. pctl 26 vs 51) are one missed ' ||
      'question apart, not reliably different ability levels (Nunnally & Bernstein 1994); pool ' ||
      'is n=31 self-selected finishers, refresh at n>=50. Ceiling held at 80 (Ganzach 1998; ' ||
      'Maltarich, Nyberg & Reilly 2010; Erdogan et al. 2011 boredom/flight-risk logic still ' ||
      'applies at this seat''s complexity level). Peter approved in *Ass Confirm successor ' ||
      'thread 2026-08-14. Tracked in open_questions "Seat bars re-anchoring under pool-percentile scale".'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND role_category = 'retention_support'
  AND role_level = 'default';
