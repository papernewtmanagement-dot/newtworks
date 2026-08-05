-- Peter directive 2026-08-05 (post self-test): every rated personality item must read as a
-- complete first-person sentence IN THE STORED TEXT itself, not via frontend prefixing.
-- Converts IPIP/IPIP-HEXACO/IPIP-NEO verb-phrase fragments ("Cheer people up.") to full
-- sentences ("I cheer people up."). IPIP items are public domain and explicitly modifiable
-- (Goldberg et al. 2006, J Research in Personality 40:84-96); the "I " stem completes the
-- instrument's own implied stem ("Describe yourself: ..."). Content unchanged.
-- Excluded: full-sentence source instruments (LOT-R, GSE, Seibert proactive, PSI networking,
-- Brown et al. customer orientation, VandeWalle goal orientations, competitiveness,
-- enterprising), vocabulary items (choices payload), items already starting with I.
-- Deterministic transform applies identically to retest copies, so verbatim-pair integrity
-- (retest_of_item_number linkage, Meade & Craig 2012) is preserved.
-- Frontend formatItemText() passes through any text matching ^I[ '] — renders correctly
-- immediately, prefix logic becomes a dormant guard.
UPDATE hiregauge_instrument_items
SET item_text = 'I ' || lower(left(item_text,1)) || substr(item_text,2)
WHERE section = 'newtworks_v2_personality'
  AND choices IS NULL
  AND (hypothesized_trait IS NULL OR hypothesized_trait NOT IN
      ('dispositional_optimism','self_efficacy','proactive_personality','political_skill_networking',
       'customer_orientation','learning_goal_orientation','prove_goal_orientation','avoid_goal_orientation',
       'competitiveness','enterprising'))
  AND item_text !~ '^I[ ''\u2019]';
