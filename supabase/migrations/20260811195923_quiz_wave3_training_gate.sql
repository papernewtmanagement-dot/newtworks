-- 1a. Columns: attempts learn their topic set + pass result; steps and
-- templates learn their required gate. NULL everywhere = no gate = no
-- behavior change on ship day.
ALTER TABLE public.quiz_attempts
  ADD COLUMN IF NOT EXISTS topic_set_id uuid NULL REFERENCES public.quiz_topic_sets(id),
  ADD COLUMN IF NOT EXISTS passed boolean NULL;
ALTER TABLE public.onboarding_step_templates
  ADD COLUMN IF NOT EXISTS required_topic_set_id uuid NULL REFERENCES public.quiz_topic_sets(id),
  ADD COLUMN IF NOT EXISTS required_mode_key text NULL
    CHECK (required_mode_key IN ('gauntlet','phase_final'));
ALTER TABLE public.team_onboarding_steps
  ADD COLUMN IF NOT EXISTS required_topic_set_id uuid NULL REFERENCES public.quiz_topic_sets(id),
  ADD COLUMN IF NOT EXISTS required_mode_key text NULL
    CHECK (required_mode_key IN ('gauntlet','phase_final'));

-- 1b. Owner-override table (release valve 1: override with logged reason)
CREATE TABLE IF NOT EXISTS public.quiz_gate_overrides (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  team_member_id uuid NOT NULL REFERENCES public.team(id),
  topic_set_id uuid NOT NULL REFERENCES public.quiz_topic_sets(id),
  mode_key text NOT NULL CHECK (mode_key IN ('gauntlet','phase_final')),
  reason text NOT NULL CHECK (length(btrim(reason)) >= 5),
  granted_by uuid REFERENCES public.team(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.quiz_gate_overrides ENABLE ROW LEVEL SECURITY;
CREATE POLICY qgo_admin_all ON public.quiz_gate_overrides
  FOR ALL USING (is_agency_admin()) WITH CHECK (is_agency_admin());
CREATE POLICY qgo_own_select ON public.quiz_gate_overrides
  FOR SELECT USING (team_member_id = public.current_team_member_id());

-- 1c. ONE pool definition, used by both the sampler and the admin
-- preview so they can never drift. Excludes drafts and reported items
-- (release valve 2: a report pulls the item from the gated pool
-- immediately). tag_label on the rules table is dormant — no item
-- column matches it; do NOT invent semantics for it.
CREATE OR REPLACE FUNCTION public.quiz_topic_set_pool(p_set_id uuid)
RETURNS TABLE (item_id uuid)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT DISTINCT qi.id
    FROM public.quiz_items qi
    JOIN public.quiz_topic_sets ts
      ON ts.id = p_set_id AND ts.agency_id = qi.agency_id
   WHERE ts.agency_id IN (SELECT u.agency_id FROM public.users u
                           WHERE u.auth_user_id = auth.uid())
     AND qi.status = 'approved' AND qi.report_blocked = false
     AND EXISTS (
       SELECT 1 FROM public.quiz_topic_set_rules r
        WHERE r.set_id = p_set_id
          AND ( r.item_id = qi.id
                OR ( r.item_id IS NULL
                     AND (r.category   IS NULL OR r.category   = qi.category)
                     AND (r.difficulty IS NULL OR r.difficulty = qi.difficulty) ) )
     );
$$;

-- 1d. Server-drawn gated attempt. The client NEVER samples for gating
-- modes; the server controls the draw.
CREATE OR REPLACE FUNCTION public.quiz_start_gated_attempt(p_mode_key text, p_topic_set_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_agency uuid; v_member uuid; v_mode public.quiz_modes;
  v_ids uuid[]; v_new uuid;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();
  IF v_member IS NULL OR v_agency IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT * INTO v_mode FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = p_mode_key
     AND is_gating = true AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'not a gating mode'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.quiz_topic_sets
                  WHERE id = p_topic_set_id AND agency_id = v_agency
                    AND is_active = true) THEN
    RAISE EXCEPTION 'topic set not found or inactive';
  END IF;

  SELECT array_agg(x.item_id) INTO v_ids FROM (
    SELECT pool.item_id FROM public.quiz_topic_set_pool(p_topic_set_id) pool
     ORDER BY random() LIMIT v_mode.question_count
  ) x;
  IF v_ids IS NULL OR array_length(v_ids, 1) < v_mode.question_count THEN
    RAISE EXCEPTION 'not enough approved questions in this topic set yet (need %, have %)',
      v_mode.question_count, COALESCE(array_length(v_ids, 1), 0);
  END IF;

  INSERT INTO public.quiz_attempts
    (agency_id, team_member_id, mode_key, topic_set_id, context)
  VALUES (v_agency, v_member, p_mode_key, p_topic_set_id,
          jsonb_build_object('item_ids', to_jsonb(v_ids),
                             'topic_set_id', p_topic_set_id))
  RETURNING id INTO v_new;
  RETURN v_new;
END; $$;

-- 1e. quiz_finish_attempt FULL REPLACEMENT. Four changes vs the live
-- Block B body, everything else byte-identical in spirit:
--   (1) mode row looked up; (2) passed computed for gating modes;
--   (3) weekly sum counts NON-GATING modes only; (4) leaderboard block
--   skipped entirely for gating modes. Exam grinding must never touch
--   the trivia_week_points records board.
CREATE OR REPLACE FUNCTION public.quiz_finish_attempt(p_attempt_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_att        public.quiz_attempts;
  v_mode       public.quiz_modes;
  v_agency     uuid;
  v_member     uuid;
  v_correct    int;
  v_total      int;
  v_points     int;
  v_passed     boolean := NULL;
  v_day        date;
  v_dow        int;
  v_week_start date;
  v_week_sat   date;
  v_week_pts   int := 0;
  v_label      text;
  v_on_board   boolean := false;
BEGIN
  v_member := public.current_team_member_id();
  SELECT u.agency_id INTO v_agency
    FROM public.users u WHERE u.auth_user_id = auth.uid();

  SELECT * INTO v_att FROM public.quiz_attempts
   WHERE id = p_attempt_id AND team_member_id = v_member AND agency_id = v_agency
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'attempt not found or not yours'; END IF;

  SELECT * INTO v_mode FROM public.quiz_modes
   WHERE agency_id = v_agency AND mode_key = v_att.mode_key;

  IF v_att.finished_at IS NOT NULL THEN
    RETURN jsonb_build_object('already_finished', true,
      'correct_count', v_att.correct_count,
      'question_count', v_att.question_count,
      'points_earned', v_att.points_earned,
      'passed', v_att.passed,
      'passing_score', v_mode.passing_score);
  END IF;

  UPDATE public.quiz_answers a
     SET was_correct = EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct),
         points = CASE WHEN EXISTS (SELECT 1 FROM public.quiz_item_options o
            WHERE o.id = a.chosen_option_id AND o.item_id = a.item_id AND o.is_correct)
            THEN 10 ELSE 0 END
   WHERE a.attempt_id = p_attempt_id;

  SELECT COUNT(*), COUNT(*) FILTER (WHERE was_correct), COALESCE(SUM(points),0)
    INTO v_total, v_correct, v_points
    FROM public.quiz_answers WHERE attempt_id = p_attempt_id;

  IF COALESCE(v_mode.is_gating, false) AND v_mode.passing_score IS NOT NULL THEN
    v_passed := (v_total > 0
                 AND (v_correct * 100.0 / v_total) >= v_mode.passing_score);
  END IF;

  UPDATE public.quiz_items qi
     SET times_served  = qi.times_served + 1,
         times_correct = qi.times_correct + CASE WHEN a.was_correct THEN 1 ELSE 0 END,
         updated_at    = now()
    FROM public.quiz_answers a
   WHERE a.attempt_id = p_attempt_id AND qi.id = a.item_id AND qi.agency_id = v_agency;

  UPDATE public.quiz_attempts
     SET finished_at = now(), question_count = v_total,
         correct_count = v_correct, points_earned = v_points,
         score = v_points, passed = v_passed
   WHERE id = p_attempt_id;

  IF NOT COALESCE(v_mode.is_gating, false) THEN
    v_day        := v_att.attempt_day;
    v_dow        := EXTRACT(DOW FROM v_day)::int;
    v_week_start := v_day - v_dow;
    v_week_sat   := v_week_start + 6;
    v_label      := 'Trivia week of ' || to_char(v_week_sat, 'Mon DD, YYYY');

    SELECT COALESCE(SUM(qa.points_earned),0) INTO v_week_pts
      FROM public.quiz_attempts qa
      JOIN public.quiz_modes qm
        ON qm.agency_id = qa.agency_id AND qm.mode_key = qa.mode_key
     WHERE qa.agency_id = v_agency AND qa.team_member_id = v_member
       AND qa.finished_at IS NOT NULL
       AND qm.is_gating = false
       AND qa.attempt_day BETWEEN v_week_start AND v_week_sat;

    IF v_week_pts > 0 THEN
      DELETE FROM public.leaderboards
       WHERE agency_id = v_agency AND category = 'trivia_week_points'
         AND team_member_id = v_member AND record_period_label = v_label;

      WITH combined AS (
        SELECT team_member_id, record_value, record_period_label, set_at
          FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
        UNION ALL
        SELECT v_member, v_week_pts::numeric, v_label, now()
      ),
      ranked AS (
        SELECT *, ROW_NUMBER() OVER (ORDER BY record_value DESC, set_at DESC) AS rn
          FROM combined
      ),
      wiped AS (
        DELETE FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
        RETURNING 1
      )
      INSERT INTO public.leaderboards
        (agency_id, category, tier, team_member_id, record_value,
         record_period_label, record_week_ending, set_at)
      SELECT v_agency, 'trivia_week_points', rn, team_member_id, record_value,
             record_period_label, NULL, set_at
        FROM ranked WHERE rn <= 3 AND (SELECT COUNT(*) FROM wiped) >= 0;

      v_on_board := EXISTS (SELECT 1 FROM public.leaderboards
         WHERE agency_id = v_agency AND category = 'trivia_week_points'
           AND team_member_id = v_member AND record_period_label = v_label);
    END IF;
  END IF;

  RETURN jsonb_build_object('correct_count', v_correct, 'question_count', v_total,
    'points_earned', v_points, 'week_points', v_week_pts,
    'on_leaderboard', v_on_board, 'passed', v_passed,
    'passing_score', v_mode.passing_score);
END; $$;

-- 1f. The gate itself: a database trigger, not a screen check.
CREATE OR REPLACE FUNCTION public.enforce_quiz_gate_on_step_complete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_member uuid; v_agency uuid; v_set_title text;
BEGIN
  IF NEW.completed_at IS NULL OR OLD.completed_at IS NOT NULL THEN RETURN NEW; END IF;
  IF NEW.required_topic_set_id IS NULL THEN RETURN NEW; END IF;

  SELECT p.team_member_id, p.agency_id INTO v_member, v_agency
    FROM public.team_onboarding_plans p WHERE p.id = NEW.plan_id;

  IF EXISTS (SELECT 1 FROM public.quiz_attempts a
              WHERE a.agency_id = v_agency AND a.team_member_id = v_member
                AND a.topic_set_id = NEW.required_topic_set_id
                AND a.mode_key = COALESCE(NEW.required_mode_key, 'gauntlet')
                AND a.finished_at IS NOT NULL AND a.passed = true)
     OR EXISTS (SELECT 1 FROM public.quiz_gate_overrides o
              WHERE o.agency_id = v_agency AND o.team_member_id = v_member
                AND o.topic_set_id = NEW.required_topic_set_id
                AND o.mode_key = COALESCE(NEW.required_mode_key, 'gauntlet'))
  THEN
    RETURN NEW;
  END IF;

  SELECT title INTO v_set_title FROM public.quiz_topic_sets
   WHERE id = NEW.required_topic_set_id;
  RAISE EXCEPTION 'This step is locked until "%" is passed (%). An owner can override with a logged reason.',
    COALESCE(v_set_title, 'the required topic set'),
    COALESCE(NEW.required_mode_key, 'gauntlet');
END; $$;

DROP TRIGGER IF EXISTS trg_enforce_quiz_gate ON public.team_onboarding_steps;
CREATE TRIGGER trg_enforce_quiz_gate
  BEFORE UPDATE ON public.team_onboarding_steps
  FOR EACH ROW EXECUTE FUNCTION public.enforce_quiz_gate_on_step_complete();

-- 1g. The teammate's own gate list for the Training card.
CREATE OR REPLACE FUNCTION public.quiz_my_gates()
RETURNS TABLE (step_id uuid, step_title text, phase integer, topic_set_id uuid,
               set_title text, mode_key text, question_count integer,
               passing_score integer, passed boolean, overridden boolean,
               best_pct numeric)
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT s.id, s.title, s.phase, s.required_topic_set_id, ts.title,
         COALESCE(s.required_mode_key, 'gauntlet'),
         m.question_count, m.passing_score,
         EXISTS (SELECT 1 FROM public.quiz_attempts a
                  WHERE a.team_member_id = p.team_member_id
                    AND a.agency_id = p.agency_id
                    AND a.topic_set_id = s.required_topic_set_id
                    AND a.mode_key = COALESCE(s.required_mode_key, 'gauntlet')
                    AND a.finished_at IS NOT NULL AND a.passed = true),
         EXISTS (SELECT 1 FROM public.quiz_gate_overrides o
                  WHERE o.team_member_id = p.team_member_id
                    AND o.agency_id = p.agency_id
                    AND o.topic_set_id = s.required_topic_set_id
                    AND o.mode_key = COALESCE(s.required_mode_key, 'gauntlet')),
         (SELECT MAX(ROUND(a.correct_count * 100.0 / NULLIF(a.question_count, 0), 0))
            FROM public.quiz_attempts a
           WHERE a.team_member_id = p.team_member_id
             AND a.agency_id = p.agency_id
             AND a.topic_set_id = s.required_topic_set_id
             AND a.mode_key = COALESCE(s.required_mode_key, 'gauntlet')
             AND a.finished_at IS NOT NULL)
    FROM public.team_onboarding_steps s
    JOIN public.team_onboarding_plans p ON p.id = s.plan_id
    JOIN public.quiz_topic_sets ts ON ts.id = s.required_topic_set_id
    LEFT JOIN public.quiz_modes m
      ON m.agency_id = p.agency_id
     AND m.mode_key = COALESCE(s.required_mode_key, 'gauntlet')
   WHERE p.team_member_id = public.current_team_member_id()
     AND p.agency_id IN (SELECT u.agency_id FROM public.users u
                          WHERE u.auth_user_id = auth.uid())
     AND s.required_topic_set_id IS NOT NULL
     AND s.completed_at IS NULL
   ORDER BY s.phase, s.sort_order;
$$;

-- 1h. Grants: logged-in staff only
REVOKE ALL ON FUNCTION public.quiz_topic_set_pool(uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_start_gated_attempt(text, uuid) FROM anon, public;
REVOKE ALL ON FUNCTION public.quiz_my_gates() FROM anon, public;
GRANT EXECUTE ON FUNCTION public.quiz_topic_set_pool(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_start_gated_attempt(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.quiz_my_gates() TO authenticated;
