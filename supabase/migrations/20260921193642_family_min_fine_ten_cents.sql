-- Unpaid habit items (water, burpees, verses) carry the minimum fine. At $0.25 a
-- fully missed week cost more than the most a kid can earn (Becca -$42.80 vs +$24.50),
-- the "bankruptcy" case the token economy literature warns breaks the system. $0.10 keeps it proportional.
ALTER TABLE public.family_settings ALTER COLUMN min_fine SET DEFAULT 0.10;
UPDATE public.family_settings SET min_fine = 0.10, updated_at = now();
