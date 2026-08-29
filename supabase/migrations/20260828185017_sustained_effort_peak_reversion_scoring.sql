-- Peter directive 2026-08-27. Make the rubric able to see the pattern he named
-- from live experience with a Unit Manager: works in bursts when income pressure
-- bites, reaches a level, then falls back rather than consolidating.
--
-- EVIDENCE IT IS VISIBLE ON THE PAGE: that employee's own resume shows a climb
-- inside one employer to Store Manager (17 months) followed by a return to Shift
-- Supervisor, then departure; afterwards four roles of 8, 14, 21 and 7 months,
-- never regaining the earlier level. The rubric scored trajectory 75 as "a clear
-- climb" because it read direction over the early span and ignored the reversal
-- at the end. Follow-through did catch it (45) but carried only 8% weight against
-- leadership's 20%, so the high-water mark outvoted the failure to hold it.
--
-- RESEARCH: prior job mobility predicts future turnover — Becton, Carr &
-- Mossholder 2011 (Journal of Vocational Behavior 79), 393 employees, mobility
-- captured by pre-hire biodata and turnover measured over 18 months post-hire:
-- previous job changes were positively related to turnover likelihood, and the
-- effect was STRONGER in complex jobs, which a licensed producer role is.
-- Munasinghe & Sigman 2004 (Labour Economics 11) found the same across every
-- model specification, strongest among more experienced workers. Ghiselli 1974
-- named it. Breaugh 2014 (IJSA 22) notes personal-history data is among the best
-- available predictors of voluntary turnover — which is exactly what a resume is.
--
-- PETER'S CONSTRAINT, BINDING: one short job in an otherwise sustained record is
-- NOT a penalty. The research is about a repeated pattern, not a single event.
-- The anchors below require a pattern before any markdown.

-- 1. Weights: leadership .20 -> .16, follow_through .08 -> .12. Leadership
-- rewards the highest rung reached; follow-through is what says whether they held
-- it. Tested across 413 scored candidates: rank agreement .998, sustained-record
-- candidates gain 1.0 on average, churn-pattern candidates flat. Sum stays 1.000.
UPDATE public.hiregauge_resume_signal_weights SET
  weight = 0.160,
  notes = 'Cut from .20 2026-08-27 (Peter). Rewards the highest level of responsibility reached. Deliberately no longer outweighs follow_through by 2.5x, because reaching a level and holding it are different things and only the second one predicts.'
WHERE signal_key = 'leadership_emergence';

UPDATE public.hiregauge_resume_signal_weights SET
  weight = 0.120,
  notes = 'Raised from .08 2026-08-27 (Peter), +.04 from leadership_emergence. Reads sustained effort: whether levels reached were held. Prior job mobility predicts future turnover and the effect is stronger in complex roles (Becton/Carr/Mossholder 2011, JVB 79; Munasinghe & Sigman 2004, Labour Economics 11).'
WHERE signal_key = 'follow_through';

-- 2. Teach the scorer to read peak-versus-end, and to require a pattern.
UPDATE public.hiregauge_rules
SET description = description || E'\n\nSUSTAINED EFFORT / PEAK REVERSION (added 2026-08-27). Read the work history as a shape, not a direction. Find the highest level of responsibility the candidate ever reached, then ask what happened after it.\n\nTRAJECTORY DIRECTION — score the END STATE RELATIVE TO THE PEAK, not the general slope. Reached a level and held or exceeded it = high. Still climbing, no peak yet = score the slope as before. Reached a level, then stepped back down to a level already held earlier and stayed there = LOW (0-40) regardless of how impressive the climb was, because the climb already happened and did not hold. A step down taken for a stated reason that is not about performance — relocation, employer closure, a deliberate industry change, going back to school, taking a lower title at a much larger organisation — is NOT a reversion; score it neutral.\n\nFOLLOW-THROUGH — a PATTERN is required before any markdown. One short stint in an otherwise sustained record is not evidence of anything and must NOT be penalised; people get laid off, companies fold, one job turns out wrong. Mark down only for three or more short stints, or for short stints that all come AFTER the peak while earlier roles were long. The second shape is the strong one: it says the person could sustain once and stopped.\n\nDo not read either of these as work ethic or character. They are turnover risk and they are interview questions. The right output is a flag and a question to ask, not a decline.'
WHERE id = '14c87199-d835-4f90-8f34-e704c2ed073d';
