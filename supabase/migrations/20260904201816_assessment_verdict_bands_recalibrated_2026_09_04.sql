-- Assessment-layer verdict bands, recalibrated 2026-09-04. Was pass 75 /
-- consider 60, which no candidate had ever cleared: across the first 20
-- completed sittings not one reached 75 and the top score was 72.76, so the
-- band that means "advance" was unreachable and the band that means "decline"
-- sat on the pool mean.
--
-- WHY THE OLD NUMBERS STOPPED FITTING. They were set 2026-08-07 for a metric
-- that no longer exists in the same shape, on the reasoning that an applicant
-- pool runs about +0.5 SD elevated on desirable traits (Birkeland, Manson,
-- Kisamore, Brannick & Smith 2006, Int J Selection & Assessment 14:317-335),
-- so 60 would sit near the pool midline. The prediction was right -- observed
-- mean is 65.18 -- but a composite built by averaging 27 percentile inputs
-- regresses hard toward the middle, so the observed SD is only 3.97. The
-- whole pool spans 57.0 to 72.8. A 75 cutoff is roughly 2.5 SD above the mean
-- of the people actually applying.
--
-- HOW THESE WERE SET. No criterion data exists (20 completions, no on-job
-- outcomes), so the method is judgmental-normative, which is the accepted
-- fallback (Cascio, Alexander & Barrett 1988, Personnel Psychology 41:1-24).
-- Two constraints shaped the numbers:
--  1. Standard error of measurement. At an SD of 3.97 and a composite
--     reliability around .85, one SEM is about 1.5 points. A cutoff must not
--     slice through a region where candidates differ by less than roughly two
--     SEM, because that difference is noise (AERA/APA/NCME Standards 2014
--     ch. 2 and 5). A bottom-quartile cut at 62.6 would have separated
--     candidates 0.7 points apart -- half an SEM -- so quartile banding was
--     rejected.
--  2. Selection ratio. With a small applicant flow, the utility of a
--     selection system comes mostly from ranking, not from screening volume
--     out; an aggressive cutoff on a low-validity-per-unit composite
--     discards more good candidates than bad (Taylor & Russell 1939 JAP
--     23:565-578). The screen is therefore permissive and the ranking does
--     the work.
--
-- pass 70 sits about +1.2 SD (top ~15% of the pool); auto-decline below 60
-- sits about -1.3 SD, clear of the main mass by more than 2 SEM, so it fires
-- only on genuine separation rather than on measurement noise. On the current
-- 20: 3 pass, 16 consider, 1 decline.
--
-- These remain PROVISIONAL. Verdicts are advisory and the final call is a
-- documented human decision (Schmidt, Mack & Hunter 1984 JAP 69:490-497).
-- Recalibrate against real hire outcomes at N >= 25, not against candidate
-- scores from this pre-outcome cohort.
UPDATE public.hiregauge_verdict_thresholds
SET pass_threshold = 70,
    consider_threshold = 60,
    notes = 'Assessment layer — percentile-metric composite. 70+ pass, 60-69 consider, <60 decline. RECALIBRATED 2026-09-04: was 75/60, which nothing had ever cleared (20 completions, max 72.76). Observed pool mean 65.18, SD 3.97 — a 27-input percentile average regresses to the middle, so the usable range is narrow and 75 sat ~2.5 SD above the applicant mean. Bands set judgmental-normatively (Cascio, Alexander & Barrett 1988) under two constraints: cutoffs must clear ~2 standard errors of measurement (SEM ~1.5 here, so quartile banding was rejected as slicing through noise — AERA/APA/NCME Standards 2014 ch. 2, 5), and with small applicant flow a permissive screen beats an aggressive one because ranking carries the utility (Taylor & Russell 1939). pass 70 ~ +1.2 SD, decline <60 ~ -1.3 SD. PROVISIONAL — advisory only, final call is a documented human decision (Schmidt, Mack & Hunter 1984). Recalibrate at N>=25 against on-job outcomes, never against pre-outcome candidate scores. NOTE: the narrow spread is itself a defect — capability sums 25 personality facets against 1 cognitive input, so the composite compresses. Construct-level weighting is the real fix and is tracked as an open question; revisit these bands after it lands.',
    updated_at = now()
WHERE layer = 'assessment';
