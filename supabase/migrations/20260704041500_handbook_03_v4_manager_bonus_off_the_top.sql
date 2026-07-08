-- Handbook 03 v4: Manager Bonus mechanic clarified — subtracted from pool basis before splitting
-- Peter's design lock 2026-07-04: manager gets Manager Bonus off the top, then also participates in pool share on remainder.
-- Also updates open_questions to reflect the resolved (a)+(b) decisions and surface the SQL wire gap.
-- 2026-07-04

-- REPLACE the Manager Bonus section in-place with clarified wording (off-the-top mechanic).
UPDATE public.handbook
SET content = REPLACE(
      content,
      '<v3 Manager Bonus section — see handbook table>',
      '<v4 Manager Bonus section — subtracted from pool basis before splitting; manager also gets pool share on remainder>'
    ),
    updated_at = NOW()
WHERE id = '5269ab5a-e575-4287-9ea2-d529b19c90a6';

-- Update the open_questions entry: (a) mechanic LOCKED (subtract from pool basis), (b) percentages restored at original;
-- new open items: (1) magnitude tweak (are 0.1/0.2/0.3% still sized correctly under residual pool), (2) SQL wire gap
-- (compute_pool_basis_and_envelope + compute_weekly_comp_residual_pool need Manager Bonus subtraction added before
-- first manager promotion), (3) Owner + admin-backoffice exclusions unchanged.
UPDATE public.persistent_memory
SET content = REPLACE(content, '<v3 Manager Bonus open item>', '<v4 Manager Bonus open item — LOCKED mechanic + magnitude+SQL wire pending>'),
    updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';
