-- Band derivation concept, locked by Peter 2026-08-28:
-- Band starts are multiples of the Danger width D — starts at D, 3D, 6D,
-- 10D — which means each band is exactly one Danger-width wider than the
-- band before it (widths D, 2D, 3D, 4D; Elite open-ended). Good is
-- therefore narrower than Great by construction.
-- At the current D = 50 the starts are 50 / 150 / 300 / 500. Only the
-- Caution/Good boundary moves (100 -> 150): Peter 2026-08-28 — Tommy
-- cleared a 130 average in his first quarter, so 100 was too easy a Good
-- floor, and Good must not be wider than Great. Danger (<50), Great
-- (300-500) and Elite (500+, never-move rule) are unchanged at D = 50.
-- The 100 figure remains the Win the Week per-seat expectation — that is
-- a separate weekly measure and is deliberately untouched, as are the
-- single-week mvp_draw_tiers.
UPDATE public.sales_points_band_config
   SET max_threshold = 150,
       notes = '50 to under 150 — below the Good floor. Documented coaching conversation, weekly check-in. No unlocks. Band starts derive from the Danger width (concept locked 2026-08-28: starts at 1x/3x/6x/10x of the width, so each band is one Danger-width wider than the last). Set by Peter 2026-08-28.',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rating_name = 'Caution';

UPDATE public.sales_points_band_config
   SET min_threshold = 150,
       notes = '150 to under 300 — starts at 3x the Danger width (concept locked 2026-08-28; was 100, moved because a solid first-year hire clears 100 in quarter one and Good must be narrower than Great). Unlocks start here: 4-day week, unlimited paid time off, remote work eligibility, Manager Development Program eligibility, base pay rung. Own 13-week average only. The 100 line remains the Win the Week per-seat expectation — separate weekly measure, not band-gated per Peter 2026-08-26.',
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND rating_name = 'Good';

-- Refresh the pay scale so its band column follows the new boundary.
SELECT public.reseed_pay_scale('126794dd-25ff-47d2-a436-724499733365');
