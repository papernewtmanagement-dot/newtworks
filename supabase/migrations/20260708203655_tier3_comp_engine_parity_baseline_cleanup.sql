-- Cleanup ephemeral parity table used during Tier-3 comp engine refactor.
-- All parity checks verified byte-exact before dropping.
DROP TABLE IF EXISTS public._tier3_comp_parity;
