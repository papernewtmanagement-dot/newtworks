-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-09 17:11:37 UTC (ledger name: coaching_rules_add_requires_license_gate) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260809171137.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- License gate lives on the coaching_rules fit_step rows so the CPR content
-- writer can join teammate license state to the step and never generate
-- coaching that instructs an unlicensed teammate to quote, price,
-- recommend coverage, or close. Cites compliance_rules AA05-008 / LIC-001.

ALTER TABLE public.coaching_rules
  ADD COLUMN IF NOT EXISTS requires_license boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.coaching_rules.requires_license IS
  'TRUE = this FIT step involves quoting, pricing, recommending coverage, or closing, and may only be coached for a teammate holding the relevant license (team.license_pc / team.license_lh). Enforced by the CPR content writer. See compliance_rules AA05-008.';

UPDATE public.coaching_rules
   SET requires_license = true,
       updated_at = now()
 WHERE category = 'fit_step'
   AND fit_step IN (
     'setup_gnc_score',
     'uncover_gap_score',
     'bridge_gap_score',
     'customize_close_score'
   );

UPDATE public.coaching_rules
   SET requires_license = false,
       updated_at = now()
 WHERE category = 'fit_step'
   AND fit_step IN (
     'demeanor_score',
     'frogs_score',
     'intro_score',
     'eligibility_score',
     'set_followup_score',
     'review_referral_score'
   );
