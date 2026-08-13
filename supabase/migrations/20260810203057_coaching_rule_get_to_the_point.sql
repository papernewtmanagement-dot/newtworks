-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-10 20:30:57 UTC (ledger name: coaching_rule_get_to_the_point) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260810203057.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
INSERT INTO public.coaching_rules
  (agency_id, category, fit_step, title, content, source, sort_order, is_active, requires_license)
SELECT '126794dd-25ff-47d2-a436-724499733365', 'sales_method', NULL,
'Short is respect — cut our words, never their answers',
$c$Job: use as little of their time as the job actually takes, and spend what we do use on their answers instead of our talking. A long call is not a thorough call.

Move: say why you called in one sentence, and name what it costs them ("two questions and I'll let you go"). Then trade statements for questions — the successful call is not the longer one, it is the one carrying a higher ratio of good questions to our own explaining (Rackham). They should be doing most of the talking (Miner). Ask one question, stop, let the silence dig. Mirrors and labels run one to three words, never a paragraph. Cut throat-clearing outright: no "I just wanted to reach out," no "does that make sense," no recapping what you already said. End on the concrete next step instead of winding down.

Never shorten by cutting questions. Shorten by cutting OUR words. Dropping a discovery question to save ninety seconds costs the sale; dropping a paragraph of our narration costs nothing — the diagnosis is the work, the commentary is not (Keenan). And if the call runs long because THEY are talking, let it run: that is their time being spent on them, which is the whole point.

Tell: if you are talking more than they are, you are the one wasting the time.$c$,
'SPIN Selling (Rackham); Jeremy Miner (NEPQ); Gap Selling (Keenan); Chris Voss; Sandler (up-front contract)',
90, true, false
WHERE NOT EXISTS (
  SELECT 1 FROM public.coaching_rules
  WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
    AND title = 'Short is respect — cut our words, never their answers'
);
