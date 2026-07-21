-- Migration 20260721230529 (mirror of applied migration)
-- Second-pass weight tuning on the four competencies where first-principles judgment
-- had left accuracy sensitivity too high for what are effectively temperament/emotional
-- reads, not cognitive-reasoning reads. All shipped 2026-07-20; tuned 2026-07-21.
--
--   receives_coaching:              acc 0.50 -> 0.20  (coachability is temperament, not IQ)
--   works_without_close_supervision: acc 0.50 -> 0.20, spd 0.50 -> 0.30 (drive/temperament > cognition)
--   balances_logic_and_emotion_when_hiring: acc 0.50 -> 0.30 (emotional maturity > cognition)
--   rapid_rapport_warm:             acc 0.40 -> 0.20 (warmth isn't cognitive; speed stays 0.80)

UPDATE public.hiregauge_competencies
SET lss_acc_weight = 0.20, updated_at = NOW()
WHERE competency = 'receives_coaching';

UPDATE public.hiregauge_competencies
SET lss_acc_weight = 0.20, lss_spd_weight = 0.30, updated_at = NOW()
WHERE competency = 'works_without_close_supervision';

UPDATE public.hiregauge_competencies
SET lss_acc_weight = 0.30, updated_at = NOW()
WHERE competency = 'balances_logic_and_emotion_when_hiring';

UPDATE public.hiregauge_competencies
SET lss_acc_weight = 0.20, updated_at = NOW()
WHERE competency = 'rapid_rapport_warm';
