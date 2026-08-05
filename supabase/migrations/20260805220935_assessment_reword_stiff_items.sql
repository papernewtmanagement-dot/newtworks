-- Peter-approved rewording pass 2026-08-05: smooth stiff phrasing without changing meaning
-- or direction. GSE items (59-68) are stilted German-to-English translations (Schwarzer &
-- Jerusalem 1995); smoothing to natural English preserves the construct. "seldom" kept per
-- Peter (items 135, 215 keep seldom). Impression-management absolutes ("would never...")
-- deliberately untouched — the extremity IS the measurement.
-- Retest #229 changes identically to its original #63 (verbatim-pair integrity).
UPDATE hiregauge_instrument_items SET item_text = 'If someone opposes me, I can usually find a way to get what I want.'
  WHERE section='newtworks_v2_personality' AND item_number = 60;
UPDATE hiregauge_instrument_items SET item_text = 'It''s easy for me to stick to my goals and follow through on them.'
  WHERE section='newtworks_v2_personality' AND item_number = 61;
UPDATE hiregauge_instrument_items SET item_text = 'I''m confident I can handle unexpected events.'
  WHERE section='newtworks_v2_personality' AND item_number = 62;
UPDATE hiregauge_instrument_items SET item_text = 'When something unexpected comes up, I can figure out how to handle it.'
  WHERE section='newtworks_v2_personality' AND item_number IN (63, 229);
UPDATE hiregauge_instrument_items SET item_text = 'I can stay calm in difficult situations because I trust my ability to cope.'
  WHERE section='newtworks_v2_personality' AND item_number = 65;
UPDATE hiregauge_instrument_items SET item_text = 'I often feel down.'
  WHERE section='newtworks_v2_personality' AND item_number = 209;
UPDATE hiregauge_instrument_items SET item_text = 'I seldom feel down.'
  WHERE section='newtworks_v2_personality' AND item_number = 215;
UPDATE hiregauge_instrument_items SET item_text = 'I don''t care much about looking fancy or expensive.'
  WHERE section='newtworks_v2_personality' AND item_number = 28;
