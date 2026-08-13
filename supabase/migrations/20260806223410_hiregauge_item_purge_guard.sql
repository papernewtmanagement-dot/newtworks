-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-08-06 22:34:10 UTC (ledger name: hiregauge_item_purge_guard) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260806223410.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- Step 5 of the 2026-08-06 compassion-purge revert plan.
-- Blocks the exact class of mistake that hit items 51/55/238 twice
-- (2026-08-03 and 2026-08-06): deactivating or scoring-excluding a shared
-- item without checking what it feeds.

CREATE OR REPLACE FUNCTION public.hiregauge_facet_item_count(
  p_section text, p_facet text, p_check text  -- p_check: 'serving' or 'scoring'
) RETURNS integer LANGUAGE sql STABLE AS $$
  WITH scored AS (
    SELECT i.item_number, i.is_active, i.score_excluded, i.stint
    FROM public.hiregauge_instrument_items i
    WHERE i.section = p_section AND i.retest_of_item_number IS NULL
      AND i.hypothesized_trait = p_facet
    UNION ALL
    SELECT i.item_number, i.is_active, i.score_excluded, i.stint
    FROM public.hiregauge_item_extra_traits e
    JOIN public.hiregauge_instrument_items i
      ON i.item_number = e.item_number AND i.section = e.section
    WHERE e.section = p_section AND e.hypothesized_trait = p_facet
      AND e.is_scored_facet = true AND i.retest_of_item_number IS NULL
  )
  SELECT count(*)::int FROM scored
  WHERE CASE
    WHEN p_check = 'serving' THEN is_active AND stint <= 2
    ELSE score_excluded IS NOT TRUE
  END;
$$;

CREATE OR REPLACE FUNCTION public.hiregauge_item_purge_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_facets text[];
  v_facet text;
  v_retest_count int;
  v_extra_count int;
  v_would_be int;
BEGIN
  -- Escape hatch: a migration that genuinely needs to retire an item sets
  -- this LOCAL first. Forces a human to read this comment before bypassing.
  IF current_setting('hiregauge.allow_item_purge', true) = 'on' THEN
    RETURN NEW;
  END IF;

  -- Only fires on the two transitions that remove an item from serving or
  -- scoring. Reactivating, or any other column change, passes straight through.
  IF NOT (
    (TG_OP = 'UPDATE' AND OLD.is_active = true AND NEW.is_active = false)
    OR (TG_OP = 'UPDATE' AND COALESCE(OLD.score_excluded, false) = false AND NEW.score_excluded = true)
  ) THEN
    RETURN NEW;
  END IF;

  -- Retest rows don't independently hold a facet baseline slot (they merge
  -- into their anchor item), so the floor check below doesn't apply to them.
  -- They can still orphan a consistency check, but that's a softer harm and
  -- not blocked here.
  IF NEW.retest_of_item_number IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- (a) Item is scored into a SECOND facet via hiregauge_item_extra_traits.
  SELECT count(*) INTO v_extra_count
  FROM public.hiregauge_item_extra_traits e
  WHERE e.section = NEW.section AND e.item_number = NEW.item_number
    AND e.is_scored_facet = true;

  IF v_extra_count > 0 THEN
    RAISE EXCEPTION 'hiregauge_item_purge_guard: item % (section %) is scored into % additional facet(s) via hiregauge_item_extra_traits. Deactivating or excluding it silently damages a facet nobody was looking at -- this is exactly how items 51/55 were mis-flagged as duplicates on 2026-08-03 and 2026-08-06. Set hiregauge.allow_item_purge=on LOCAL if this is genuinely intended.',
      NEW.item_number, NEW.section, v_extra_count;
  END IF;

  -- (b) Another active item retests this one.
  SELECT count(*) INTO v_retest_count
  FROM public.hiregauge_instrument_items o
  WHERE o.section = NEW.section AND o.retest_of_item_number = NEW.item_number
    AND o.is_active = true AND o.id <> NEW.id;

  IF v_retest_count > 0 THEN
    RAISE EXCEPTION 'hiregauge_item_purge_guard: item % (section %) has % active retest item(s) pointing at it (a within-sitting consistency check). Deactivating the anchor orphans the retest -- this is what happened to item 238 twice. Set hiregauge.allow_item_purge=on LOCAL if this is genuinely intended.',
      NEW.item_number, NEW.section, v_retest_count;
  END IF;

  -- (c) Facet floor: would this change drop any facet below 4 items, counted
  -- the way compute_newtworks_v2_facets_as_row actually counts?
  IF NEW.hypothesized_trait IS NOT NULL THEN
    v_facets := ARRAY[NEW.hypothesized_trait];
  ELSE
    v_facets := ARRAY[]::text[];
  END IF;
  SELECT v_facets || array_agg(DISTINCT e.hypothesized_trait)
    INTO v_facets
  FROM public.hiregauge_item_extra_traits e
  WHERE e.section = NEW.section AND e.item_number = NEW.item_number
    AND e.is_scored_facet = true;

  FOREACH v_facet IN ARRAY COALESCE(v_facets, ARRAY[]::text[]) LOOP
    IF v_facet IS NULL THEN CONTINUE; END IF;

    IF TG_OP = 'UPDATE' AND OLD.is_active = true AND NEW.is_active = false THEN
      v_would_be := public.hiregauge_facet_item_count(NEW.section, v_facet, 'serving') - 1;
      IF v_would_be < 4 THEN
        RAISE EXCEPTION 'hiregauge_item_purge_guard: deactivating item % would drop facet "%" to % active baseline item(s) (floor is 4). This is what starved compassion to 3 items on 2026-08-06. Set hiregauge.allow_item_purge=on LOCAL if this is genuinely intended.',
          NEW.item_number, v_facet, v_would_be;
      END IF;
    END IF;

    IF TG_OP = 'UPDATE' AND COALESCE(OLD.score_excluded, false) = false AND NEW.score_excluded = true THEN
      v_would_be := public.hiregauge_facet_item_count(NEW.section, v_facet, 'scoring') - 1;
      IF v_would_be < 4 THEN
        RAISE EXCEPTION 'hiregauge_item_purge_guard: score-excluding item % would drop facet "%" to % scoreable item(s) (floor is 4), retroactively for every candidate already scored. Set hiregauge.allow_item_purge=on LOCAL if this is genuinely intended.',
          NEW.item_number, v_facet, v_would_be;
      END IF;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hiregauge_item_purge_guard ON public.hiregauge_instrument_items;
CREATE TRIGGER trg_hiregauge_item_purge_guard
  BEFORE UPDATE ON public.hiregauge_instrument_items
  FOR EACH ROW EXECUTE FUNCTION public.hiregauge_item_purge_guard();

COMMENT ON FUNCTION public.hiregauge_item_purge_guard() IS
  'Guards against re-deactivating shared/anchor/floor items. Exists because items 51, 55, and 238 were wrongly flagged as duplicates and deactivated twice -- 2026-08-03 (reverted same day) and 2026-08-06 (reverted by planning-thread ruling). See persistent_memory operational_rule with matching title for full history.';
