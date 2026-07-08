-- 20260707222919_handbook_add_sp_rating_bands_and_link

-- Step 1: Add Sales Points Rating Bands subsection to Getting Paid Part 2 (before Part 3)
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'**One Life policy pays you two ways.** It pays your L&H rate on itself AND boosts your P&C rate on everything else. That''s why writing Life makes every other policy worth more.\n\n## Part 3 — Manager Bonus',
  E'**One Life policy pays you two ways.** It pays your L&H rate on itself AND boosts your P&C rate on everything else. That''s why writing Life makes every other policy worth more.\n\n### <a id="sales-points-rating-bands"></a>Sales Points Rating Bands\n\nYour rolling 13-week average Sales Points maps to one of five ratings. Achieving **Good** or better gates unlimited PTO and 4-day workweek eligibility (see the [Hours & Time Off](/handbook/newtworks-native-handbook-02-hours) page for how each is applied).\n\n| Rating | Rolling 13-week weekly avg Sales Points |\n| --- | --- |\n| Danger | Under $70/wk |\n| Caution | $70 – $99/wk |\n| **Good** | **$100 – $149/wk** — gate for unlimited PTO and 4-day workweek |\n| Great | $150 – $199/wk |\n| Elite | $200+/wk |\n\n## Part 3 — Manager Bonus'
)
WHERE title = 'Getting Paid';

-- Step 2: Link "Good rating" in Hours & Time Off to the new subsection
UPDATE public.handbook
SET content = REPLACE(
  content,
  E'hold at a "Good" rating or better:',
  E'hold at a ["Good" rating](/handbook/newtworks-native-handbook-03-pay#sales-points-rating-bands) or better:'
)
WHERE title = 'Hours & Time Off';
