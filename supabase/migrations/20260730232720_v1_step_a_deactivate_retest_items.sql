-- Deactivate 8 same-wording retest items in v1 personality.
-- Reverse-coded items already carry reliability; same-sitting exact-text
-- retest is redundant and produces candidate friction.
UPDATE hiregauge_instrument_items
SET is_active = false
WHERE item_number IN (200, 201, 202, 203, 204, 205, 206, 207)
  AND section = 'newtworks_v1_personality';
