-- Break out res_subsignals JSONB into first-class columns.
-- Peter directive 2026-07-18: each sub-signal element should be saved to the
-- hiring_candidates table as a queryable column, not buried in JSONB.
-- Two columns per sub-signal: <slug>_score smallint 0-10, <slug>_reason text.
-- JSONB res_subsignals left in place for now; column read cutover ships in the
-- same session, JSONB retirement is a separate follow-up.

ALTER TABLE public.hiring_candidates
  -- Nature (3)
  ADD COLUMN IF NOT EXISTS res_autonomy_score smallint CHECK (res_autonomy_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_autonomy_reason text,
  ADD COLUMN IF NOT EXISTS res_leadership_emergence_score smallint CHECK (res_leadership_emergence_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_leadership_emergence_reason text,
  ADD COLUMN IF NOT EXISTS res_interpersonal_substrate_score smallint CHECK (res_interpersonal_substrate_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_interpersonal_substrate_reason text,
  -- Nurture (4)
  ADD COLUMN IF NOT EXISTS res_honesty_score smallint CHECK (res_honesty_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_honesty_reason text,
  ADD COLUMN IF NOT EXISTS res_concern_for_others_score smallint CHECK (res_concern_for_others_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_concern_for_others_reason text,
  ADD COLUMN IF NOT EXISTS res_hard_work_ethic_score smallint CHECK (res_hard_work_ethic_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_hard_work_ethic_reason text,
  ADD COLUMN IF NOT EXISTS res_personal_responsibility_score smallint CHECK (res_personal_responsibility_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_personal_responsibility_reason text,
  -- Drivers (4, incl. new Goal Orientation)
  ADD COLUMN IF NOT EXISTS res_trajectory_direction_score smallint CHECK (res_trajectory_direction_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_trajectory_direction_reason text,
  ADD COLUMN IF NOT EXISTS res_coherent_pursuit_score smallint CHECK (res_coherent_pursuit_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_coherent_pursuit_reason text,
  ADD COLUMN IF NOT EXISTS res_follow_through_score smallint CHECK (res_follow_through_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_follow_through_reason text,
  ADD COLUMN IF NOT EXISTS res_goal_orientation_score smallint CHECK (res_goal_orientation_score BETWEEN 0 AND 10),
  ADD COLUMN IF NOT EXISTS res_goal_orientation_reason text;

-- Backfill from existing res_subsignals JSONB. Sub-signal label -> column mapping
-- per canonical rubric. Where JSONB is absent or missing a key, columns stay NULL.
UPDATE public.hiring_candidates
SET
  res_autonomy_score               = NULLIF(res_subsignals->'Autonomy'->>'score','')::smallint,
  res_autonomy_reason              = res_subsignals->'Autonomy'->>'reasoning',
  res_leadership_emergence_score   = NULLIF(res_subsignals->'Leadership Emergence'->>'score','')::smallint,
  res_leadership_emergence_reason  = res_subsignals->'Leadership Emergence'->>'reasoning',
  res_interpersonal_substrate_score  = NULLIF(res_subsignals->'Interpersonal Substrate'->>'score','')::smallint,
  res_interpersonal_substrate_reason = res_subsignals->'Interpersonal Substrate'->>'reasoning',
  res_honesty_score                = NULLIF(res_subsignals->'Honesty'->>'score','')::smallint,
  res_honesty_reason               = res_subsignals->'Honesty'->>'reasoning',
  res_concern_for_others_score     = NULLIF(res_subsignals->'Concern for Others'->>'score','')::smallint,
  res_concern_for_others_reason    = res_subsignals->'Concern for Others'->>'reasoning',
  res_hard_work_ethic_score        = NULLIF(res_subsignals->'Hard Work Ethic'->>'score','')::smallint,
  res_hard_work_ethic_reason       = res_subsignals->'Hard Work Ethic'->>'reasoning',
  res_personal_responsibility_score  = NULLIF(res_subsignals->'Personal Responsibility'->>'score','')::smallint,
  res_personal_responsibility_reason = res_subsignals->'Personal Responsibility'->>'reasoning',
  res_trajectory_direction_score   = NULLIF(res_subsignals->'Trajectory Direction'->>'score','')::smallint,
  res_trajectory_direction_reason  = res_subsignals->'Trajectory Direction'->>'reasoning',
  res_coherent_pursuit_score       = NULLIF(res_subsignals->'Coherent Pursuit'->>'score','')::smallint,
  res_coherent_pursuit_reason      = res_subsignals->'Coherent Pursuit'->>'reasoning',
  res_follow_through_score         = NULLIF(res_subsignals->'Follow-Through'->>'score','')::smallint,
  res_follow_through_reason        = res_subsignals->'Follow-Through'->>'reasoning'
  -- Goal Orientation: no prior data in JSONB; column stays NULL until rescored.
WHERE agency_id='126794dd-25ff-47d2-a436-724499733365'
  AND res_subsignals IS NOT NULL;

COMMENT ON COLUMN public.hiring_candidates.res_goal_orientation_score IS
  'Drivers sub-signal added 2026-07-18. Presence of goal/target/quota/KPI language on the resume and quantified attainment against those targets. See hiregauge_rules resume_score_rubric row short_label=Goal Orientation.';
