-- Widen res_nature / res_nurture / res_drivers from smallint to numeric(4,2)
-- so construct means preserve 2 decimals (needed for 7.67, 8.25, 5.33, etc.)
-- Non-destructive: existing integer values become N.00.

ALTER TABLE hiring_candidates
  ALTER COLUMN res_nature TYPE numeric(4,2) USING res_nature::numeric(4,2),
  ALTER COLUMN res_nurture TYPE numeric(4,2) USING res_nurture::numeric(4,2),
  ALTER COLUMN res_drivers TYPE numeric(4,2) USING res_drivers::numeric(4,2);;