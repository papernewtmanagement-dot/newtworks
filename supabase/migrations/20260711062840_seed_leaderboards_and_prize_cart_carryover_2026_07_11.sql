-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-11 06:28:40 UTC (ledger name: seed_leaderboards_and_prize_cart_carryover_2026_07_11) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260711062840.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- ═══════════════════════════════════════════════════════════════
-- Seed leaderboards + all-stars + Q2→Q3 prize cart carryover
-- ═══════════════════════════════════════════════════════════════

DO $$
DECLARE
  v_agency uuid := '126794dd-25ff-47d2-a436-724499733365';
  v_john   uuid;
  v_tommy  uuid;
BEGIN
  SELECT id INTO v_john  FROM public.team WHERE agency_id=v_agency AND first_name='John' AND is_active=true LIMIT 1;
  SELECT id INTO v_tommy FROM public.team WHERE agency_id=v_agency AND first_name='Thomas' AND is_active=true LIMIT 1;

  -- ─────────────────────────────────────────────────────────────
  -- QUARTER SP LEADERBOARD — top 3 QTD SP across history
  -- Gold:   John,   $7,347.76, Q1 2026
  -- Silver: John,   $5,562.00, Q4 2025
  -- Bronze: Thomas, $5,179.24, Q2 2026
  -- All-star floor = 5,179 rounded down to 100 = 5,100 (formula-derived)
  -- ─────────────────────────────────────────────────────────────
  INSERT INTO public.leaderboards (agency_id, category, tier, team_member_id, record_value, record_period_label, notes)
  VALUES
    (v_agency, 'quarter_sp', 1, v_john,  7347.76, 'Q1 2026', 'Historical seed from weekly_cpr_team_detail'),
    (v_agency, 'quarter_sp', 2, v_john,  5562.00, 'Q4 2025', 'Historical seed'),
    (v_agency, 'quarter_sp', 3, v_tommy, 5179.24, 'Q2 2026', 'Historical seed')
  ON CONFLICT (agency_id, category, tier) DO UPDATE SET
    team_member_id = EXCLUDED.team_member_id,
    record_value = EXCLUDED.record_value,
    record_period_label = EXCLUDED.record_period_label,
    notes = EXCLUDED.notes;

  -- ─────────────────────────────────────────────────────────────
  -- WEEK SP LEADERBOARD — top 3 estimated weekly SP (QTD / 13)
  -- Gold:   John,   $565.21, Q1 2026 (7347.76/13)
  -- Silver: John,   $427.85, Q4 2025 (5562.00/13)
  -- Bronze: Thomas, $398.40, Q2 2026 (5179.24/13)
  -- All-star floor = 398 rounded down to 50 = 350
  -- ─────────────────────────────────────────────────────────────
  INSERT INTO public.leaderboards (agency_id, category, tier, team_member_id, record_value, record_period_label, notes)
  VALUES
    (v_agency, 'week_sp', 1, v_john,  565.21, 'Q1 2026 avg', 'Est weekly = quarter QTD / 13 (even production assumed)'),
    (v_agency, 'week_sp', 2, v_john,  427.85, 'Q4 2025 avg', 'Est weekly = quarter QTD / 13'),
    (v_agency, 'week_sp', 3, v_tommy, 398.40, 'Q2 2026 avg', 'Est weekly = quarter QTD / 13')
  ON CONFLICT (agency_id, category, tier) DO UPDATE SET
    team_member_id = EXCLUDED.team_member_id,
    record_value = EXCLUDED.record_value,
    record_period_label = EXCLUDED.record_period_label,
    notes = EXCLUDED.notes;

  -- ─────────────────────────────────────────────────────────────
  -- WEEK QUOTES LEADERBOARD — Peter's stated Tommy records
  -- Gold:   Thomas, 27, 2026-03-07
  -- Silver: Thomas, 26, 2026-06-06
  -- Bronze: Thomas, 25, 2026-05-23
  -- All-star floor = 25 rounded down to 5 = 25
  -- ─────────────────────────────────────────────────────────────
  INSERT INTO public.leaderboards (agency_id, category, tier, team_member_id, record_value, record_period_label, record_week_ending, notes)
  VALUES
    (v_agency, 'week_quotes', 1, v_tommy, 27, '2026-03-07', '2026-03-07', 'Peter-provided seed'),
    (v_agency, 'week_quotes', 2, v_tommy, 26, '2026-06-06', '2026-06-06', 'Peter-provided seed'),
    (v_agency, 'week_quotes', 3, v_tommy, 25, '2026-05-23', '2026-05-23', 'Peter-provided seed')
  ON CONFLICT (agency_id, category, tier) DO UPDATE SET
    team_member_id = EXCLUDED.team_member_id,
    record_value = EXCLUDED.record_value,
    record_period_label = EXCLUDED.record_period_label,
    record_week_ending = EXCLUDED.record_week_ending,
    notes = EXCLUDED.notes;

  -- ─────────────────────────────────────────────────────────────
  -- ALL-STAR COUNTS (Peter-stated historical seeds)
  -- ─────────────────────────────────────────────────────────────
  INSERT INTO public.all_star_counts (agency_id, category, team_member_id, count, seeded_count)
  VALUES
    (v_agency, 'quarter_sp',  v_john,  6, 6),
    (v_agency, 'week_sp',     v_john,  8, 8),
    (v_agency, 'week_quotes', v_john,  3, 3),
    (v_agency, 'week_quotes', v_tommy, 10, 10)
  ON CONFLICT (agency_id, category, team_member_id) DO UPDATE SET
    count = EXCLUDED.count,
    seeded_count = EXCLUDED.seeded_count,
    updated_at = NOW();
END $$;

-- ─────────────────────────────────────────────────────────────
-- Q2 → Q3 PRIZE CART CARRYOVER
-- Copy 11 unwon Q2 items to Q3 (quarter_ending_date = 2026-10-03)
-- Reset winner fields on the copies (they haven't been won this quarter).
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.prize_cart (
  agency_id, quarter_ending_date, display_order, prize_description,
  prize_value, winner_team_member_id, won_on, notes, prize_url
)
SELECT
  agency_id,
  '2026-10-03'::date AS quarter_ending_date,
  display_order,
  prize_description,
  prize_value,
  NULL::uuid AS winner_team_member_id,   -- Reset winner
  NULL::date AS won_on,
  COALESCE(notes,'') || ' [Carryover from Q2 2026]' AS notes,
  prize_url
FROM public.prize_cart
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND quarter_ending_date = '2026-07-04'
  AND winner_team_member_id IS NULL;

-- ─────────────────────────────────────────────────────────────
-- Q3 PRIZE CART BUDGET
-- Formula per Peter's stated "old formula" = 1% × on-time Scorecard (annual)
-- Current OT Scorecard = $12,447.20 → 1% = $124.47
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.quarter_prize_budgets (agency_id, quarter_ending_date, budget_dollars, formula_note)
VALUES (
  '126794dd-25ff-47d2-a436-724499733365'::uuid,
  '2026-10-03'::date,
  124.47,
  '1% × on-time Scorecard $12,447.20 (annualized at Q3 start). Formula per Peter 2026-07-11.'
)
ON CONFLICT (agency_id, quarter_ending_date) DO UPDATE SET
  budget_dollars = EXCLUDED.budget_dollars,
  formula_note = EXCLUDED.formula_note;

-- ─────────────────────────────────────────────────────────────
-- 2 NEW PRIZES to bring Q3 cart from 11 → 13
-- Budget: ~$60/each × 2 = ~$120 (fits under $124.47)
-- ─────────────────────────────────────────────────────────────
INSERT INTO public.prize_cart (
  agency_id, quarter_ending_date, display_order, prize_description,
  prize_value, prize_url, notes
)
VALUES
  ('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-10-03'::date, 12,
   'BLACK+DECKER Kitchen Wand 6-in-1', 63.00,
   'https://www.amazon.com/s?k=black+decker+kitchen+wand+6+in+1',
   'Cordless multi-tool: blender, whisk, bottle opener attachments. Q3 restock 2026-07-11.'),
  ('126794dd-25ff-47d2-a436-724499733365'::uuid, '2026-10-03'::date, 13,
   'Travel Weighted Lap Blanket 7lb', 50.00,
   'https://www.amazon.com/s?k=travel+weighted+lap+blanket+7lb',
   'Compact travel/relax accessory. Q3 restock 2026-07-11.');

SELECT
  quarter_ending_date,
  COUNT(*) AS total_items
FROM public.prize_cart
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
GROUP BY quarter_ending_date
ORDER BY quarter_ending_date;
