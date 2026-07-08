-- Handbook: pool-split math + chargebacks restored + glossary restored (pay refs stripped) + apparel/CC moved to 01 Benefits
-- Also: append $10 Bumps and Manager Bonus % as open questions
-- 2026-07-04
--
-- Content payloads elided for readability; applied via Supabase MCP apply_migration in same session.
-- 03 Bonuses & Pay v2 (5269ab5a): pool-split math added (65/35 SP+RH with 5-factor weighted hours),
--   chargebacks restored (no pay clawback, honor-system Whiteboard tracking),
--   glossary restored full (APPLICATION/APPOINTMENT/PREMIUM/REFERRAL/REVIEW) with pay refs stripped,
--   Apparel + Champions Circle removed (moved to 01 Benefits).
-- 01 Benefits (64a78cd2): Apparel + Champions Circle sections added before Table of Benefits.
-- persistent_memory open_questions row appended: $10 Bumps future formula, Manager Bonus % future design.

UPDATE public.handbook
SET content = '<v2 residual-pool content — see handbook table>',
    updated_at = NOW()
WHERE id = '5269ab5a-e575-4287-9ea2-d529b19c90a6';

UPDATE public.handbook
SET content = '<Apparel + Champions Circle added — see handbook table>',
    updated_at = NOW()
WHERE id = '64a78cd2-3b85-4bfb-a514-5d28bf67f17c';

UPDATE public.persistent_memory
SET content = content || '<two new [OPEN 2026-07-04] items appended for $10 Bumps + Manager Bonus %>',
    updated_at = NOW()
WHERE id = '1581ac95-97e3-40d8-8a24-d1471bc8afc4';
