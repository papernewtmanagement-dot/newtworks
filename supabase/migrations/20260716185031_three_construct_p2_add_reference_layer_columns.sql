-- Add reference-check per-construct scoring columns to hiring_assessments.
-- Reference is Suggs's 4th pre-hire scored layer (Resume / Assessment / Interview / Reference).
-- Peter scores each construct 1-10 based on reference-call responses:
--   ref_nature   → what former manager/peer observed re: innate behavior/energy/style
--   ref_nurture  → what former manager/peer observed re: character (Honesty, HWE, Concern, PersRes)
--   ref_drivers  → what former manager/peer observed re: motivation (stated vs actual pursuit)

ALTER TABLE public.hiring_assessments
  ADD COLUMN IF NOT EXISTS ref_nature   smallint CHECK (ref_nature IS NULL OR (ref_nature >= 1 AND ref_nature <= 10)),
  ADD COLUMN IF NOT EXISTS ref_nurture  smallint CHECK (ref_nurture IS NULL OR (ref_nurture >= 1 AND ref_nurture <= 10)),
  ADD COLUMN IF NOT EXISTS ref_drivers  smallint CHECK (ref_drivers IS NULL OR (ref_drivers >= 1 AND ref_drivers <= 10));

COMMENT ON COLUMN public.hiring_assessments.ref_nature IS
'Reference-check score 1-10 for Nature construct (innate behavior/energy/style observations from former managers/peers). Feeds hiregauge_three_construct_verdict at 5% weight within Nature.';
COMMENT ON COLUMN public.hiring_assessments.ref_nurture IS
'Reference-check score 1-10 for Nurture construct (character observations: Honesty, HWE, PersRes, Concern). Feeds hiregauge_three_construct_verdict at 30% weight within Nurture — highest-validity third-party character read.';
COMMENT ON COLUMN public.hiring_assessments.ref_drivers IS
'Reference-check score 1-10 for Drivers construct (motivation: stated-vs-actual pursuit). Feeds hiregauge_three_construct_verdict at 20% weight within Drivers.';
