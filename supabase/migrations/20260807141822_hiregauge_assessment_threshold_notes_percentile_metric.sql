UPDATE public.hiregauge_verdict_thresholds
SET notes = 'Assessment layer — percentile-metric composite '
  '(role_fit_v5_0_facet_direct capability + Migration E percentile '
  'character/commitment). 75+ pass, 60-74 consider, <60 decline. '
  'Values retained deliberately on the new metric 2026-08-07: anchor '
  '50 = typical adult; applicant pools run ~+0.5 SD elevated on '
  'desirable traits (Birkeland et al. 2006, Int J Selection & '
  'Assessment 14:317-335), so 60 sits near the applicant-pool '
  'midline and 75 is clearly above it. Cutoffs absent local '
  'criterion data are judgmental-normative (Cascio, Alexander & '
  'Barrett 1988, Personnel Psychology 41:1-24); verdicts are '
  'advisory, final call is a documented human decision (Schmidt, '
  'Mack & Hunter 1984). Validated against the 9-candidate cohort '
  'including owner ground truth. RECALIBRATE at N>=25 real v2 '
  'completions — see open_questions.',
    updated_at = now()
WHERE layer = 'assessment';
