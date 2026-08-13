-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-04 07:08:03 UTC (ledger name: handbook_03_v4_manager_bonus_off_the_top) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260704070803.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Handbook 03 v4: Manager Bonus mechanic clarified — subtracted from pool basis before splitting
-- Also update open_questions to reflect the "subtract from pool basis" design decision + surface SQL wire gap
-- 2026-07-04

UPDATE public.handbook
SET content = REPLACE(
      content,
      $bcc$## Manager Bonus

If you hold a manager role, you receive a share of the agency's on-time Scorecard payout in addition to your pool share:

- **Unit Manager:** 0.1% of the agency's on-time Scorecard
- **Team Manager:** 0.2% of the agency's on-time Scorecard
- **Office Manager:** 0.3% of the agency's on-time Scorecard$bcc$,
      $bcc$## Manager Bonus

If you hold a manager role, a Manager Bonus is paid to you off the top of the pool basis each year, calculated on the agency's on-time Scorecard payout:

- **Unit Manager:** 0.1% of the agency's on-time Scorecard
- **Team Manager:** 0.2% of the agency's on-time Scorecard
- **Office Manager:** 0.3% of the agency's on-time Scorecard

The Manager Bonus is subtracted from the pool basis before the remainder is split among the team. Managers also receive their pool share on that remainder alongside everyone else — so a manager's total is their Manager Bonus plus their normal pool share.$bcc$
    ),
    updated_at = NOW(),
    fetched_at = NOW(),
    notes = 'v4 (2026-07-04): Manager Bonus mechanic clarified per Peter — subtracted from pool basis before splitting, manager still gets pool share on the remainder.'
WHERE id = '5269ab5a-e575-4287-9ea2-d529b19c90a6';

-- Update open_questions: resolve the "layered vs. subtracted" question; surface the SQL wire gap
UPDATE public.persistent_memory
SET content = REPLACE(
      content,
      $bcc$[OPEN 2026-07-04 — Manager Bonus % — keep or tweak] Peter wants to retain some form of Manager Bonus tied to agency on-time Scorecard even under residual-pool comp. Original mechanic (prior handbook): Unit Manager 0.1%, Team Manager 0.2%, Office Manager 0.3% of on-time Scorecard. Decisions needed: (1) keep percentages as-is or scale; (2) layered on top of pool share, or subtracted from pool basis before splitting; (3) restored in v3 handbook with original percentages — evaluate whether to keep as-is or scale under residual pool; (4) Peter as Owner + Marie as admin-backoffice fall outside (Owner not in comp math, Marie not in production per is_admin_backoffice rule). Design pass required before wiring or team-facing publication.$bcc$,
      $bcc$[OPEN 2026-07-04 — Manager Bonus % — magnitude tweak + SQL wire] Design decisions LOCKED 2026-07-04: (a) mechanic = Manager Bonus subtracted from pool basis before splitting, manager also participates in pool share on remainder (handbook v4). (b) percentages restored at original values in v3+ handbook: UM 0.1% / TM 0.2% / OM 0.3% of agency on-time Scorecard. Still open: (1) magnitude tweak — evaluate whether 0.1/0.2/0.3% still sized correctly under residual-pool comp given (i) surrounding comp shape changed materially from old base-advance+True-Pay-Bonus+surge+profit stack, (ii) manager now also gets pool share of remainder, (iii) need to preserve manager premium ratio over regular team; (2) SQL wire gap — compute_pool_basis_and_envelope + compute_weekly_comp_residual_pool do not currently subtract Manager Bonus before splitting; when a manager is added to team, split math will not match handbook v4 without wire change; (3) Peter as Owner + Marie as admin-backoffice fall outside (Owner not in comp math, Marie not in production per is_admin_backoffice rule). Currently no team member holds a manager role → SQL wire gap non-blocking, but must be addressed before first manager promotion.$bcc$
    ),
    updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';
