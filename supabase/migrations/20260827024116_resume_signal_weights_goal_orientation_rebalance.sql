-- Peter directive 2026-08-26. Resume goal_orientation weight cut from .20 to .08;
-- the 12 points move to the two signals that read checkable life-history facts
-- (interpersonal_substrate .10 -> .16, autonomy .06 -> .12).
--
-- WHY: goal_orientation on a free-form resume only fires when a candidate
-- volunteers numbers nobody asked for. 68% of the 413-candidate pool scores <=30
-- on it, and it correlates .58 with content_effort (which is deliberately
-- zero-weighted per Cole et al. 2009). It measures whether someone thought to
-- write numbers down, not whether they hit goals.
--
-- Goal orientation is NOT removed. Numbers on a resume remain real evidence, just
-- weak evidence: McDaniel, Schmidt & Hunter 1988 (Personnel Psychology 41) put
-- unstructured training-and-experience point-method at .11 vs behavioural-
-- consistency (structured accomplishment description) at .45. The .08 keeps the
-- weak evidence; the new structured screener accomplishment question carries the
-- strong version. A blank resume no longer reads as proof of no goals.
--
-- Receiving signals: interpersonal_substrate reads sustained consultative /
-- customer-facing work (Quinones, Ford & Teachout 1995, Personnel Psychology 48:
-- task-level experience .41 vs .27 overall; Verbeke, Dietz & Verwaal 2011, JAMS:
-- selling-related knowledge beta .28, top sales-performance driver). autonomy
-- reads self-initiated activity and was the only signal tracking GMA in the local
-- n=50 sample.
--
-- Blast radius, tested on all 413 scored candidates before applying: rank
-- correlation old vs new .985; pass band 6 -> 8; decline band 283 -> 252;
-- candidates scoring >=70 on goal_orientation lose 1.5 points on average (nobody
-- changes band); licensed candidates gain 2.7 on average.
-- Nonzero weights still sum to 1.000.
UPDATE public.hiregauge_resume_signal_weights SET
  weight = 0.080,
  notes  = 'Cut from .20 2026-08-26 (Peter). Free-form resume goal language is the weak form of the accomplishment predictor (McDaniel/Schmidt/Hunter 1988: point method .11 vs behavioural consistency .45). Retained deliberately - numbers on a page are real evidence. The structured screener accomplishment question carries the strong form.'
WHERE signal_key = 'goal_orientation';

UPDATE public.hiregauge_resume_signal_weights SET
  weight = 0.160,
  notes  = 'Raised from .10 2026-08-26 (Peter), +.06 from goal_orientation. Reads sustained consultative/customer-facing work - task-level experience, the most predictive experience measure (Quinones/Ford/Teachout 1995 .41 vs .27; Verbeke 2011 selling-related knowledge beta .28).'
WHERE signal_key = 'interpersonal_substrate';

UPDATE public.hiregauge_resume_signal_weights SET
  weight = 0.120,
  notes  = 'Raised from .06 2026-08-26 (Peter), +.06 from goal_orientation. Reads checkable self-initiated activity (optional credentials, side ventures, self-taught systems). Only resume signal tracking GMA in the local n=50 sample (r .29).'
WHERE signal_key = 'autonomy';
