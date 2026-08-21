-- Tier A persistent_memory cleanup: legacy table + column names → new agency_snapshot names.
-- Guard pattern: 'book_snapshot_weekly_alert' identifier (function + module_reference) is preserved
-- via TEMPGUARD substitution; only table-name and column-name references update.

-- Recipe names like "Weekly Book Snapshot - Gmail Parse" use capitalized "Book Snapshot" (with space)
-- and are NOT touched by lowercase 'book_snapshot' replace.

BEGIN;

-- ============================================================
-- (1) accounting_rules row — full rewrite (title + content)
-- ============================================================
UPDATE public.persistent_memory
SET title = 'agency_snapshot + lead_source_quarterly — book/lead tracking (rewritten 2026-06-20)',
    content = $rw$PURPOSE: Periodic snapshot of in-force book of business + flow (YTD production/lost) + weekly lead-source-by-quarter tracking.

==========================================
TABLE: public.agency_snapshot
==========================================
(Merged 2026-06-20 from former book_snapshot + sf_on_time_snapshot — single source of truth for both stock and flow.)

STORED COLUMNS:
- snapshot_date, cadence (weekly|monthly|ad-hoc)
- Auto block:  auto_new_ytd, auto_lost_ytd, auto_pif, auto_premium
- Fire block:  fire_new_ytd, fire_lost_ytd, fire_pif, fire_premium
- Life block:  life_new_ytd, life_lost_ytd, life_pif, life_paid_for_count_ytd, life_paid_for_premium_ytd, life_premium
- IPS:         ips_new_money_ytd
- household_count
- source, notes
- UNIQUE(agency_id, snapshot_date, cadence)

DERIVED IN v_agency_snapshot_with_changes (NEVER stored):
- pc_premium = auto_premium + fire_premium
- pc_per_hh, auto_share_pc_pct
- WoW, MoM, QoQ, YoY, cumulative-from-anchor % changes for each LOB and HH

NO TOTAL PIF COLUMNS. Per-LOB PIF only (auto policy != life policy operationally).

POPULATION POLICY:
- Stock columns (premium $, PIF, household_count): auto-populated every Saturday weekly row via the SF CRM Analytics Gmail-parse recipe.
- Flow columns (*_new_ytd, *_lost_ytd, life_paid_for_count_ytd, life_paid_for_premium_ytd, ips_new_money_ytd): entered manually by Peter each week via Financials > Book of Business form (typically Saturday morning from the CPR YTD column).
- Queries needing YTD data must filter .not('auto_new_ytd','is',null) before ordering by snapshot_date DESC, because not every row carries YTD.

LOOKBACK LOGIC (date-based via LATERAL joins, NOT LAG(N) — necessary because weekly/monthly rows interleave):
- WoW: most recent row at or before (current_date - INTERVAL '7 days')  (only computed for cadence=weekly)
- MoM: most recent row at or before (current_date - INTERVAL '1 month')  (calendar-aware, fixes Feb-March edge case)
- QoQ: most recent row at or before (current_date - INTERVAL '91 days')
- YoY: most recent row at or before (current_date - INTERVAL '1 year')   (calendar-aware, leap-year safe)
- Anchor: earliest snapshot per agency = appointment date 10/1/2018

Reference dates exposed in view: wow_compare_date, mom_compare_date, qoq_compare_date, yoy_compare_date, anchor_date.

v_agency_growth_summary: thin DISTINCT ON selector returning most recent row per agency per cadence.

CADENCE RULES:
- Monthly: 93 rows backfilled from PDF (2018-10-01 -> 2026-06-01). Month-end close uses the monthly row.
- Weekly: Peter forwards SF CRM Analytics widget subscription email to paper.newt.management@gmail.com each Friday. First weekly row = 2026-06-13.

RETIRED FROM PRIOR SCHEMA (do not re-add):
- Health columns (health_premium, health_pif) — SF CRM Analytics email never carried them; 95 rows of historical health_premium data dropped in the merge per Peter.
- Ambassador credit columns (ambassador_life_travel_credits_ytd, ambassador_total_travel_credits_ytd) — folded into life_paid_for_premium_ytd (Peter: "close to same number").
- All MTD columns (auto/fire/life production+lapse) — retired; YTD-only flow tracking.
- DSS%, MLD%, count_hh_1/2/3_lob, source_document_id — dropped as unused.
- All QTD columns (auto/fire production+lapse, life paid count) — were NULL in every row.

LEGACY COLUMN-RENAME MAP (for reading old session_notes and migration history):
- auto/fire/life_production_ytd → *_new_ytd
- auto/fire_lapse_ytd + life_loss_ytd → *_lost_ytd
- life_paid_count_ytd → life_paid_for_count_ytd
- life_premium_credits_ytd → life_paid_for_premium_ytd
- ips_activity_ytd → ips_new_money_ytd
Note: Life's YTD lost column was historically named life_loss_ytd, not life_lapse_ytd (lapse was the QTD-only column name on sf_on_time_snapshot).

KNOWN STEP-CHANGES (do not treat as organic growth/loss):
- 2025-12-01: Corporate platform modernization. Auto +11.17%, Fire +8.44% MoM. Corrected baseline.
- 2026-01-01: HH count step-down 1004 -> 918. Same platform event.
- 2026-06-01: Corporate reporting system switch. Life -12.05% MoM. Corrected baseline.

PIF BACKFILL: Pre-2026-06-13 rows have NULL for all *_pif (PDF had no PIF data). Going forward, weekly entries populate Auto/Fire/Life PIF from the SF email.

==========================================
TABLE: public.lead_source_quarterly
==========================================
PURPOSE: Captures the quarter-to-date "Won" data by lead source from the SF CRM Analytics widget email. Stock-of-flow: each row is Q-to-date as of snapshot_date. No automation hangs off it yet — captured for trend analysis later.

STORED COLUMNS:
- snapshot_date, period_year, period_quarter (1-4)
- source (text: Referral, SF.com, EverQuote, QuoteWizard, MediaAlpha, etc.)
- won_households, won_premium
- source_document_id, notes
- UNIQUE(agency_id, snapshot_date, period_year, period_quarter, source)

INGESTION: Same email as agency_snapshot. Each Friday email creates one agency_snapshot row (weekly) + N rows in lead_source_quarterly (one per source).

CURRENT SOURCES SEEN: Referral, SF.com, EverQuote, QuoteWizard, MediaAlpha. Free-text column — new sources accepted.

==========================================
SHARED INGESTION FROM SF CRM ANALYTICS EMAIL
==========================================
Subject: "FW: [EXTERNAL] Your CRM Analytics subscriptions" (forwarded from peter.story.yrru@statefarm.com)
Sender originally: noreply@salesforce.com on behalf of Peter Story, YRRU, 53-1BDD
Each email is "For Friday, [date]" with widget cards: HH#, Auto#, Auto$, Fire#, Fire$, Life#, Life$, plus per-source Won HH and Won $ for the current quarter.

The parse recipe "Weekly Book Snapshot - Gmail Parse" handles this automatically each Saturday at 14:00 UTC. The recipe still uses the legacy name; output_table = 'agency_snapshot' after the 2026-06-20 merge.$rw$,
    updated_at = NOW()
WHERE id = 'a8c613b8-c234-4c64-b3c6-399698b7f5fd';

-- ============================================================
-- (2) Bulk REPLACE chain for the remaining 13 rows
-- ============================================================
UPDATE public.persistent_memory
SET content =
  replace(
    replace(
      replace(
        replace(
          replace(
            replace(
              replace(
                replace(
                  replace(
                    replace(
                      replace(
                        replace(
                          replace(
                            replace(
                              replace(
                                replace(content,
                                  'book_snapshot_weekly_alert', 'TEMPGUARD_BSWA'),
                                'sf_on_time_snapshot', 'agency_snapshot'),
                              'v_sf_on_time_snapshot', 'v_agency_snapshot_with_changes'),
                            'v_book_snapshot_with_changes', 'v_agency_snapshot_with_changes'),
                          'v_book_growth_summary', 'v_agency_growth_summary'),
                        'book_snapshot', 'agency_snapshot'),
                      'TEMPGUARD_BSWA', 'book_snapshot_weekly_alert'),
                    'auto_production_ytd', 'auto_new_ytd'),
                  'auto_lapse_ytd', 'auto_lost_ytd'),
                'fire_production_ytd', 'fire_new_ytd'),
              'fire_lapse_ytd', 'fire_lost_ytd'),
            'life_production_ytd', 'life_new_ytd'),
          'life_loss_ytd', 'life_lost_ytd'),
        'life_paid_count_ytd', 'life_paid_for_count_ytd'),
      'life_premium_credits_ytd', 'life_paid_for_premium_ytd'),
    'ips_activity_ytd', 'ips_new_money_ytd'),
  updated_at = NOW()
WHERE id IN (
  '80d75f80-de7f-4c5b-91cd-62037f5a091b', -- goals
  'dc5e694a-97a2-426c-8eb2-fbbcb6b1e5b1', -- CPR canonical layout
  '0afe26c3-a7ca-402e-9e95-6f5ff20291f2', -- Date convention
  '811fdee8-1cc3-44fa-be8e-96d5dfc38287', -- Derived metrics
  'f4683285-41f8-48ba-b32f-b01398c2555d', -- FS commissions from comp_recap
  'c17431f1-55cd-4307-93ba-d99ec40ff2ea', -- Life NPF metric
  'f9fd6edc-f6ce-4273-862c-8d899943f313', -- Life Specialist comp v2
  'a7787c93-0f69-4532-a1a7-6aa8fd17b792', -- OT Scorecard MAXED projection
  '6cdeb6e0-c3fd-4604-852f-126b11fdce19', -- Story Agency avg premium per PIF
  'f9588be7-6c9a-48a8-abfd-79c23a2ccaee', -- Weekly CPR recap drafts
  'e8a41e2b-20cd-4109-af11-5043eaeeb11a', -- Two-recipe enforcement pattern
  'b88d4724-29e0-405d-9788-55d4b2247589', -- 2026 AA05 comp mechanics
  '082e69e9-513f-4406-8117-02a9860d6631'  -- 2028 AA28 comp mechanics
);

-- ============================================================
-- (3) Title updates for the two rows whose titles contained legacy names
-- ============================================================
UPDATE public.persistent_memory
SET title = 'Date convention: CPR + agency_snapshot rows are always Saturday-dated (end of agency week)',
    updated_at = NOW()
WHERE id = '0afe26c3-a7ca-402e-9e95-6f5ff20291f2';

UPDATE public.persistent_memory
SET title = 'Story Agency average premium per PIF — agency_snapshot derived',
    updated_at = NOW()
WHERE id = '6cdeb6e0-c3fd-4604-852f-126b11fdce19';

-- ============================================================
-- (4) Open questions row — remove the [OPEN] item rendered moot by the agency_snapshot merge
-- ============================================================
UPDATE public.persistent_memory
SET content = replace(content,
    E'[OPEN] Life monthly lapse/can — the CPR sheet only tracks "New" for Life in the monthly rows, not lost. Confirm with Peter whether life_lapse_mtd should be tracked (he can input it) or just left NULL.\n\n',
    ''),
  updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';

COMMIT;

-- Post-check: any rows still carrying legacy refs (excluding session_notes, recipe-name strings, intentional historical mentions)?
SELECT id, category, title,
       (CASE WHEN content ILIKE '%sf_on_time_snapshot%' THEN 'sf_on_time_snapshot ' ELSE '' END ||
        CASE WHEN content ILIKE '%v_book%' THEN 'v_book_view ' ELSE '' END ||
        CASE WHEN content ILIKE '%v_sf_on_time_snapshot%' THEN 'v_sf_on_time_snapshot ' ELSE '' END ||
        CASE WHEN content ILIKE '%auto_production_ytd%' OR content ILIKE '%auto_lapse_ytd%' THEN 'auto_legacy_ytd ' ELSE '' END ||
        CASE WHEN content ILIKE '%fire_production_ytd%' OR content ILIKE '%fire_lapse_ytd%' THEN 'fire_legacy_ytd ' ELSE '' END ||
        CASE WHEN content ILIKE '%life_production_ytd%' OR content ILIKE '%life_loss_ytd%' OR content ILIKE '%life_lapse_ytd%' THEN 'life_legacy_ytd ' ELSE '' END ||
        CASE WHEN content ILIKE '%life_paid_count_ytd%' THEN 'life_paid_count_ytd ' ELSE '' END ||
        CASE WHEN content ILIKE '%life_premium_credits_ytd%' THEN 'life_premium_credits_ytd ' ELSE '' END ||
        CASE WHEN content ILIKE '%ips_activity_ytd%' THEN 'ips_activity_ytd ' ELSE '' END) AS residuals
FROM public.persistent_memory
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND category <> 'session_note'
  AND id NOT IN ('f9f8c772-291e-40e7-96c1-a27a81ff9a81', 'a8c613b8-c234-4c64-b3c6-399698b7f5fd')
  AND (content ILIKE '%sf_on_time_snapshot%' OR content ILIKE '%v_book%' OR content ILIKE '%v_sf_on_time_snapshot%'
       OR content ILIKE '%auto_production_ytd%' OR content ILIKE '%auto_lapse_ytd%'
       OR content ILIKE '%fire_production_ytd%' OR content ILIKE '%fire_lapse_ytd%'
       OR content ILIKE '%life_production_ytd%' OR content ILIKE '%life_loss_ytd%' OR content ILIKE '%life_lapse_ytd%'
       OR content ILIKE '%life_paid_count_ytd%' OR content ILIKE '%life_premium_credits_ytd%'
       OR content ILIKE '%ips_activity_ytd%')
ORDER BY category, title;
