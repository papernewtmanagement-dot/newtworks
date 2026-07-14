-- fit_scorecards.entry_type is auto-derived from tenure tier per
-- handbook "Your Path" §Scorecarding Cadence. Not user-editable.

-- 1. Canonical tenure -> entry_type mapping (single source of truth)
CREATE OR REPLACE FUNCTION public.fit_scorecard_entry_type_for_tenure(p_tier text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_tier
    WHEN 'weeks_1_8'     THEN 'conversation'
    WHEN 'weeks_9_13'    THEN 'quote_review'
    WHEN 'weeks_14_plus' THEN 'end_of_day'
    ELSE 'end_of_day'
  END;
$$;

-- 2. Trigger: recompute both fields server-side from team + date
CREATE OR REPLACE FUNCTION public.tg_fit_scorecards_enforce_entry_type()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_tier text;
BEGIN
  v_tier := public.fit_scorecard_tenure_tier(NEW.team_member_id, NEW.scorecard_date);
  IF v_tier IS NULL THEN
    v_tier := 'weeks_14_plus';
  END IF;
  NEW.tenure_tier_at_entry := v_tier;
  NEW.entry_type           := public.fit_scorecard_entry_type_for_tenure(v_tier);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS tg_fit_scorecards_enforce_entry_type ON public.fit_scorecards;

CREATE TRIGGER tg_fit_scorecards_enforce_entry_type
BEFORE INSERT OR UPDATE OF team_member_id, scorecard_date, entry_type, tenure_tier_at_entry
ON public.fit_scorecards
FOR EACH ROW
EXECUTE FUNCTION public.tg_fit_scorecards_enforce_entry_type();

-- 3. Backfill: normalize existing rows to satisfy the invariant
UPDATE public.fit_scorecards
SET entry_type = public.fit_scorecard_entry_type_for_tenure(tenure_tier_at_entry)
WHERE entry_type IS DISTINCT FROM public.fit_scorecard_entry_type_for_tenure(tenure_tier_at_entry);
