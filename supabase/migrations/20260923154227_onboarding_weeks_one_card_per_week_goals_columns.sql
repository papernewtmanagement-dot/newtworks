-- Onboarding weeks, Peter 2026-09-23.
-- * A combined card (Weeks 3-4, 5-8, 9-13, 14-26) is one major card in the
--   template with one set of subcards. On a plan it becomes one card per week,
--   the subcards copied into each. A subcard can be limited to some of the
--   weeks (weeks int[]; NULL = every week of the card).
-- * Each week's subcards open on the Monday that week starts.
-- * Goals subcards sit across the top of the card (full_width).
-- * The other weekly subcards sit in five columns: Learn, Watch, Role Play,
--   This Week, With Peter.
-- * onboarding_phases.week_titles: {"5": "Other Fire", ...} names each week.

ALTER TABLE public.onboarding_step_templates ADD COLUMN IF NOT EXISTS weeks int[];
ALTER TABLE public.onboarding_step_templates ADD COLUMN IF NOT EXISTS full_width boolean NOT NULL DEFAULT false;
ALTER TABLE public.onboarding_step_templates ADD COLUMN IF NOT EXISTS plan_week_no int;
ALTER TABLE public.onboarding_step_templates ADD COLUMN IF NOT EXISTS plan_unlocks_on date;
COMMENT ON COLUMN public.onboarding_step_templates.plan_week_no IS
  'Only set on the rows onboarding_templates_for_plan() returns for one plan (the week that copy is for). Always NULL in the table.';
COMMENT ON COLUMN public.onboarding_step_templates.plan_unlocks_on IS
  'Only set on the rows onboarding_templates_for_plan() returns for one plan (the day that copy opens). Always NULL in the table.';
ALTER TABLE public.team_onboarding_steps ADD COLUMN IF NOT EXISTS week_no int;
ALTER TABLE public.team_onboarding_steps ADD COLUMN IF NOT EXISTS full_width boolean NOT NULL DEFAULT false;
ALTER TABLE public.onboarding_phases ADD COLUMN IF NOT EXISTS week_titles jsonb;

-- One rule for "how many weeks come before this card".
CREATE OR REPLACE FUNCTION public.onboarding_phase_weeks_before(p_agency_id uuid, p_phase integer)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE(sum(prior.weeks_long)::int, 0)
  FROM public.onboarding_phases prior
  WHERE prior.agency_id = p_agency_id AND prior.stage = 'ramp' AND prior.phase < p_phase;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_phase_opens_on(p_agency_id uuid, p_phase integer, p_start_date date)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT CASE
           WHEN p_start_date IS NULL THEN NULL
           WHEN ph.stage = 'ramp' THEN p_start_date + 7 * public.onboarding_phase_weeks_before(p_agency_id, p_phase)
           ELSE p_start_date + COALESCE(ph.days_from_start, 0)
         END
  FROM public.onboarding_phases ph
  WHERE ph.agency_id = p_agency_id AND ph.phase = p_phase;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_phase_first_week(p_agency_id uuid, p_phase integer)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT 1 + public.onboarding_phase_weeks_before(p_agency_id, p_phase);
$$;
GRANT EXECUTE ON FUNCTION public.onboarding_phase_first_week(uuid, integer) TO authenticated;

-- The templates a plan gets, one copy per week for a weekly card.
CREATE OR REPLACE FUNCTION public.onboarding_templates_for_plan(p_plan_id uuid)
RETURNS SETOF public.onboarding_step_templates
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $function$
  SELECT (jsonb_populate_record(NULL::public.onboarding_step_templates,
            to_jsonb(t) || jsonb_build_object(
              'template_key', CASE WHEN ph.weeks_long > 1 THEN t.template_key || '@w' || w.n ELSE t.template_key END,
              'plan_week_no', w.n,
              'plan_unlocks_on', COALESCE(
                 public.onboarding_unlock_date(t.unlock_rule, p.start_date),
                 CASE WHEN w.n IS NOT NULL AND p.start_date IS NOT NULL
                      THEN public.onboarding_phase_opens_on(p.agency_id, t.phase, p.start_date)
                           + 7 * (w.n - public.onboarding_phase_first_week(p.agency_id, t.phase)) END)))).*
  FROM public.team_onboarding_plans p
  JOIN public.onboarding_step_templates t
    ON t.agency_id = p.agency_id
   AND t.is_active = true
   AND (t.applies_to_roles           IS NULL OR p.role_snapshot          = ANY (t.applies_to_roles))
   AND (t.applies_to_role_categories IS NULL OR p.role_category_snapshot = ANY (t.applies_to_role_categories))
   AND (t.applies_to_role_levels     IS NULL OR p.role_level_snapshot    = ANY (t.applies_to_role_levels))
  LEFT JOIN public.onboarding_phases ph
    ON ph.agency_id = p.agency_id AND ph.phase = t.phase AND ph.stage = 'ramp' AND COALESCE(ph.weeks_long, 0) >= 1
  LEFT JOIN LATERAL (
    SELECT gs AS n
    FROM generate_series(public.onboarding_phase_first_week(p.agency_id, t.phase),
                         public.onboarding_phase_first_week(p.agency_id, t.phase) + ph.weeks_long - 1) gs
    WHERE ph.phase IS NOT NULL AND (t.weeks IS NULL OR gs = ANY (t.weeks))
  ) w ON true
  WHERE p.id = p_plan_id
    AND (ph.phase IS NULL OR w.n IS NOT NULL);
$function$;

DO $mig$
DECLARE v_def text; v_new text; v_n int;
BEGIN
  v_def := pg_get_functiondef('public.onboarding_sync_plan(uuid)'::regprocedure);
  v_n := (length(v_def) - length(replace(v_def, 'public.onboarding_unlock_date(t.unlock_rule, p.start_date)', '')))
         / length('public.onboarding_unlock_date(t.unlock_rule, p.start_date)');
  IF v_n <> 4 THEN RAISE EXCEPTION 'expected 4 unlock expressions, found %', v_n; END IF;
  v_new := replace(v_def, 'public.onboarding_unlock_date(t.unlock_rule, p.start_date)', 't.plan_unlocks_on');
  v_new := replace(v_new,
$a$unlock_rule, unlocks_on, widget, assign_role_category
  )$a$,
$b$unlock_rule, unlocks_on, widget, assign_role_category, week_no, full_width
  )$b$);
  v_new := replace(v_new,
$a$t.plan_unlocks_on, t.widget, t.assign_role_category
  FROM public.onboarding_templates_for_plan(p_plan_id) t$a$,
$b$t.plan_unlocks_on, t.widget, t.assign_role_category, t.plan_week_no, t.full_width
  FROM public.onboarding_templates_for_plan(p_plan_id) t$b$);
  v_new := replace(v_new,
$a$      assign_role_category  = t.assign_role_category,$a$,
$b$      assign_role_category  = t.assign_role_category,
      week_no               = t.plan_week_no,
      full_width            = t.full_width,$b$);
  v_new := replace(v_new, $a$s.widget, s.assign_role_category)$a$, $b$s.widget, s.assign_role_category, s.week_no, s.full_width)$b$);
  v_new := replace(v_new, $a$t.widget, t.assign_role_category)$a$, $b$t.widget, t.assign_role_category, t.plan_week_no, t.full_width)$b$);
  IF position('assign_role_category, week_no, full_width' IN v_new) = 0
     OR position('t.assign_role_category, t.plan_week_no, t.full_width' IN v_new) = 0
     OR position('week_no               = t.plan_week_no' IN v_new) = 0
     OR position('s.assign_role_category, s.week_no, s.full_width)' IN v_new) = 0
     OR position('onboarding_unlock_date' IN v_new) > 0 THEN
    RAISE EXCEPTION 'onboarding_sync_plan patch did not apply cleanly';
  END IF;
  EXECUTE v_new;
END
$mig$;

-- Changing a major card (its weeks) re-syncs plans too.
DROP TRIGGER IF EXISTS trg_onboarding_phases_changed ON public.onboarding_phases;
CREATE TRIGGER trg_onboarding_phases_changed
  AFTER INSERT OR UPDATE OR DELETE ON public.onboarding_phases
  FOR EACH STATEMENT EXECUTE FUNCTION public.onboarding_templates_changed();

-- ─── data ─────────────────────────────────────────────────────────────
SELECT set_config('app.onboarding_template_sync', 'off', true);

UPDATE public.onboarding_phases SET name = 'Weeks 14-26', weeks_long = 13, updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase = 75;

-- week names from the week columns ("Week 5: Other Fire")
UPDATE public.onboarding_phases ph
   SET week_titles = x.titles, updated_at = now()
  FROM (SELECT phase, jsonb_object_agg(wk::text, ttl) AS titles
        FROM (SELECT DISTINCT phase,
                     (substring(track from '^Week (\d+)'))::int AS wk,
                     NULLIF(trim(substring(track from '^Week \d+:\s*(.*)$')), '') AS ttl
              FROM public.onboarding_step_templates
              WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
                AND phase IN (60, 65, 70, 75) AND track ~ '^Week \d+') y
        WHERE ttl IS NOT NULL
        GROUP BY phase) x
 WHERE ph.agency_id = '126794dd-25ff-47d2-a436-724499733365' AND ph.phase = x.phase;

-- merge subcards that are the same in several weeks of a combined card
CREATE TEMP TABLE _wk ON COMMIT DROP AS
  SELECT t.id, t.phase, t.sort_order,
         (substring(t.track from '^Week (\d+)'))::int AS wk,
         md5(concat_ws('|', t.title, COALESCE(t.description, ''), t.substeps::text,
                       COALESCE(t.applies_to_role_categories::text, ''), COALESCE(t.applies_to_roles::text, ''),
                       COALESCE(t.applies_to_role_levels::text, ''), t.owner_kind, t.is_required::text,
                       t.category, COALESCE(t.blocked_by::text, ''), COALESCE(t.unlock_rule, ''),
                       COALESCE(t.assign_role_category, ''), COALESCE(t.assigned_to::text, ''))) AS sig
  FROM public.onboarding_step_templates t
  WHERE t.agency_id = '126794dd-25ff-47d2-a436-724499733365'
    AND t.phase IN (60, 65, 70, 75) AND t.track ~ '^Week \d+';

CREATE TEMP TABLE _grp ON COMMIT DROP AS
  SELECT phase, sig, o,
         array_agg(wk ORDER BY wk) AS wks,
         (array_agg(id ORDER BY wk, sort_order, id))[1] AS keep_id,
         array_agg(id) AS ids,
         min(wk) AS first_wk,
         (array_agg(sort_order ORDER BY wk, sort_order, id))[1] AS first_sort
  FROM (SELECT *, row_number() OVER (PARTITION BY phase, wk, sig ORDER BY sort_order, id) AS o FROM _wk) z
  GROUP BY phase, sig, o;

DELETE FROM public.onboarding_step_templates t
 USING _grp g
 WHERE t.id = ANY (g.ids) AND t.id <> g.keep_id;

UPDATE public.onboarding_step_templates t
   SET weeks = CASE WHEN g.wks = ARRAY(SELECT generate_series(public.onboarding_phase_first_week(t.agency_id, t.phase),
                                                              public.onboarding_phase_first_week(t.agency_id, t.phase) + ph.weeks_long - 1))
                    THEN NULL ELSE g.wks END,
       sort_order = g.first_wk * 1000 + g.first_sort
  FROM _grp g, public.onboarding_phases ph
 WHERE t.id = g.keep_id AND ph.agency_id = t.agency_id AND ph.phase = t.phase;

-- Goals across the top; everything else in five columns
WITH c AS (
  SELECT id,
         CASE
           WHEN title = 'Goals' THEN NULL
           WHEN title ~* '^Role Play' THEN 'Role Play'
           WHEN title ~* '^(Watch|Stairs & Buckets|Service to Sales|Understanding Money)' THEN 'Watch'
           WHEN title ~* '^(Study|Modules|Read|Book)' THEN 'Learn'
           WHEN title ~* '(Orientation|One-On-One|Review With Peter|Tech Training|Staff Agreement)' THEN 'With Peter'
           ELSE 'This Week'
         END AS col,
         phase, sort_order, title
  FROM public.onboarding_step_templates
  WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND phase >= 55
), o AS (
  SELECT id, col,
         CASE col WHEN 'Learn' THEN 1 WHEN 'Watch' THEN 2 WHEN 'Role Play' THEN 3
                  WHEN 'This Week' THEN 4 WHEN 'With Peter' THEN 5 ELSE 0 END AS col_order,
         row_number() OVER (PARTITION BY phase, col ORDER BY sort_order, id) * 10 AS new_sort
  FROM c
)
UPDATE public.onboarding_step_templates t
   SET track = o.col, track_order = o.col_order, sort_order = o.new_sort,
       full_width = (o.col IS NULL)
  FROM o
 WHERE t.id = o.id;

SELECT set_config('app.onboarding_template_sync', 'on', true);
SELECT public.onboarding_sync_open_plans();
