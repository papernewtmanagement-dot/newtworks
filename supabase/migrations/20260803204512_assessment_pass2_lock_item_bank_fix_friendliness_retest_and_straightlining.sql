-- =====================================================================
-- Newtworks assessment — second audit pass, 2026-08-03
-- =====================================================================
-- FIX A: the item bank was readable with the public anon key.
--   /assess ships VITE_SUPABASE_ANON_KEY in the browser bundle (it has to
--   -- it is the bearer token the edge function's verify_jwt requires).
--   anon also held SELECT on hiregauge_instrument_items, and the read
--   policy was USING (true) granted to PUBLIC. So any candidate mid-test
--   could open devtools, lift the key out of the bundle, and query every
--   answer_key plus the is_nonsense flag that marks which vocabulary words
--   are made up. That defeats the reasoning score, the scenario score, and
--   the over-claiming exit gate simultaneously.
--   Nothing in src/ reads this table (only two comment references in
--   GmaPatternItem.jsx / GmaNumericalItem.jsx). The edge function reaches
--   it with the service role key, which bypasses RLS entirely, and
--   migrations run as owner. So anon loses the grant, reads narrow to
--   authenticated, and the blanket ALL/PUBLIC write policy goes away --
--   item-bank changes belong to migrations, not to any logged-in session.
--
-- FIX B: item 238 was a broken cross-construct retest. It carried
--   hypothesized_trait='friendliness' but retest_of_item_number=51, which
--   is a COMPASSION item. Both share the text "Cheer people up." because
--   that line appears in two different published IPIP scales, and the
--   retest was matched on text instead of on trait. Three consequences:
--   the friendliness consistency check compared a friendliness response
--   against a compassion response; off-construct content was scored into
--   the friendliness facet; and the candidate saw the identical sentence
--   twice inside stint 2. Repointed to friendliness item 162 with matching
--   text, keying, and scale. No new content authored -- a retest row is by
--   definition a verbatim duplicate of its original.
--
-- FIX C: straight-lining detection compared RAW response_value across the
--   personality section, which deliberately mixes scale_max 4 / 5 / 7 (see
--   op-rule "mixed scale sizes are locked, not a defect", which states
--   outright that careless-response detection must read scale_max per item
--   rather than assume a fixed range -- that requirement was not
--   implemented here). Raw comparison fails both directions: a candidate
--   clicking the top option on every item yields 5,7,4,5,7... and never
--   registers a run, which is precisely the behaviour the check exists to
--   catch; and a 4 on a 5-point item gets treated as identical to a 4 on a
--   7-point item, where it means something else entirely. Now compares
--   normalized position (response_value - 1) / (scale_max - 1), so "same
--   position" means the same thing on every scale in the battery.
--   Tie-break on r.id added so the ordering is deterministic, matching the
--   convention already used in hiregauge_v2_stint1_exit_gate.
-- =====================================================================

-- --- FIX A ------------------------------------------------------------
REVOKE SELECT ON public.hiregauge_instrument_items FROM anon;
REVOKE SELECT ON public.hiregauge_item_extra_traits FROM anon;

DROP POLICY IF EXISTS items_read  ON public.hiregauge_instrument_items;
DROP POLICY IF EXISTS items_write ON public.hiregauge_instrument_items;

CREATE POLICY items_read_authenticated
  ON public.hiregauge_instrument_items
  FOR SELECT TO authenticated
  USING (true);

-- No write policy by design. authenticated retains the table grant but RLS
-- denies every write; the service role and the table owner bypass RLS, which
-- is how the edge function and migrations continue to work.

-- --- FIX B ------------------------------------------------------------
UPDATE public.hiregauge_instrument_items AS r
SET retest_of_item_number = o.item_number,
    item_text             = o.item_text,
    hypothesized_trait    = o.hypothesized_trait,
    reverse_coded         = o.reverse_coded,
    scale_max             = o.scale_max,
    notes                 = 'Within-sitting consistency retest of friendliness item '
                            || o.item_number
                            || '. Repointed 2026-08-03: previously pointed at compassion item 51, '
                            || 'matched on duplicate item text ("Cheer people up.") rather than on trait.',
    updated_at            = now()
FROM public.hiregauge_instrument_items AS o
WHERE r.section = 'newtworks_v2_personality'
  AND r.item_number = 238
  AND o.section = 'newtworks_v2_personality'
  AND o.item_number = 162
  AND o.is_active = true;

-- --- FIX C ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.hiregauge_v2_careless_straightlining(p_candidate_id uuid)
 RETURNS TABLE(fired boolean, detail text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH ordered AS (
    -- Normalized scale position, not the raw click value. The personality
    -- battery mixes scale_max 4 / 5 / 7 on purpose (each item keeps its own
    -- source instrument's published response format), so a raw value is not
    -- comparable across items: 4 is the top of a 4-point scale, "agree" on a
    -- 5-point scale, and mid-range on a 7-point scale. Position normalizes
    -- all of them to 0..1, which is what "same answer position" has to mean
    -- for a long-string index to work. Rounded to 4 places so float
    -- representation never splits a genuine run.
    SELECT ROUND(
             (r.response_value::numeric - 1)
             / NULLIF(i.scale_max::numeric - 1, 0)
           , 4) AS pos_norm,
           ROW_NUMBER() OVER (ORDER BY r.served_at, r.id) AS pos
    FROM public.hiregauge_candidate_responses r
    JOIN public.hiregauge_instrument_items i ON i.id = r.item_id
    WHERE r.candidate_id = p_candidate_id
      AND i.section = 'newtworks_v2_personality'
      AND r.response_value IS NOT NULL
      AND r.served_at IS NOT NULL
      AND i.scale_max IS NOT NULL
      AND i.scale_max > 1
  ),
  grp AS (
    SELECT pos_norm, pos,
           pos - ROW_NUMBER() OVER (PARTITION BY pos_norm ORDER BY pos) AS grp_key
    FROM ordered
    WHERE pos_norm IS NOT NULL
  ),
  runs AS (
    SELECT pos_norm, count(*)::int AS run_length
    FROM grp
    GROUP BY pos_norm, grp_key
  ),
  agg AS (
    SELECT COALESCE(max(run_length), 0) AS longest_run
    FROM runs
  )
  SELECT
    (longest_run >= 10) AS fired,
    format('longest run at an identical scale position: %s items', longest_run) AS detail
  FROM agg;
$function$;
