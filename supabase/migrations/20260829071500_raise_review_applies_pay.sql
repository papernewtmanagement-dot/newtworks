-- Peter 2026-08-28: the raise review APPLIES the raise. A review that only
-- leaves a note is just a reminder.
--
-- Safety, because this writes real wages:
--   * It only ever moves pay UP. If the computed new rate is not higher than
--     what the person is on, nothing is written — that is the "a raise never
--     steps back down" rule enforced in code, not just in prose.
--   * One rung per close. team_raise_progress only ever reports the next
--     rung, so the step is bounded by construction; a sanity guard rejects
--     any jump over $3/hr as well, in case the ladder or a title step is
--     ever misconfigured.
--   * SALARY seats are paid weekly, so the new weekly figure is the new
--     hourly times forty. HOURLY seats take the hourly rate directly.
--   * The before and after rates are written to raise_review_log, so there
--     is a record of every automatic pay change and what it replaced.
--   * The task it opens is now a notice of what was applied, not a to-do.

ALTER TABLE public.raise_review_log
  ADD COLUMN IF NOT EXISTS applied_at        timestamptz,
  ADD COLUMN IF NOT EXISTS previous_pay_rate numeric,
  ADD COLUMN IF NOT EXISTS new_pay_rate      numeric,
  ADD COLUMN IF NOT EXISTS pay_type          text,
  ADD COLUMN IF NOT EXISTS not_applied_note  text;

COMMENT ON COLUMN public.raise_review_log.previous_pay_rate IS
  'team.pay_rate immediately before the automation changed it. This log is the audit trail for automatic pay changes.';

CREATE OR REPLACE FUNCTION public.quarter_close_raise_review(p_agency_id uuid, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r             record;
  v_task_id     uuid;
  v_qualified   int := 0;
  v_applied     int := 0;
  v_reviewed    int := 0;
  v_names       text[] := ARRAY[]::text[];
  v_pay_type    text;
  v_old_rate    numeric;
  v_new_rate    numeric;
  v_did_apply   boolean;
  v_note        text;
  c_max_step    CONSTANT numeric := 3.00;   -- sanity ceiling, $/hr, one rung
BEGIN
  FOR r IN SELECT * FROM public.team_raise_progress(p_agency_id, p_as_of) LOOP
    v_reviewed := v_reviewed + 1;
    v_task_id := NULL; v_did_apply := false; v_note := NULL;
    v_old_rate := NULL; v_new_rate := NULL; v_pay_type := NULL;

    IF r.on_track AND r.next_tier IS NOT NULL THEN
      SELECT l.task_id INTO v_task_id
        FROM public.raise_review_log l
       WHERE l.agency_id = p_agency_id AND l.reviewed_on = p_as_of
         AND l.team_member_id = r.team_member_id AND l.qualified;

      SELECT t.pay_type, t.pay_rate INTO v_pay_type, v_old_rate
        FROM public.team t WHERE t.id = r.team_member_id;

      v_new_rate := CASE WHEN UPPER(COALESCE(v_pay_type,'')) = 'SALARY'
                         THEN ROUND(r.next_hourly * 40.0, 2)
                         ELSE ROUND(r.next_hourly, 2) END;

      IF v_old_rate IS NULL THEN
        v_note := 'No pay rate on file — nothing applied.';
      ELSIF v_new_rate <= v_old_rate THEN
        -- Pay never steps down, and never sideways.
        v_note := 'Computed rate ' || v_new_rate || ' is not above the current '
                  || v_old_rate || ' — left alone.';
      ELSIF (r.next_hourly - r.current_hourly) > c_max_step THEN
        v_note := 'Step of $' || ROUND(r.next_hourly - r.current_hourly, 2)
                  || '/hr is larger than one rung — held for review.';
      ELSE
        UPDATE public.team SET pay_rate = v_new_rate, updated_at = now()
         WHERE id = r.team_member_id;
        v_did_apply := true;
        v_applied := v_applied + 1;
      END IF;

      IF v_task_id IS NULL THEN
        INSERT INTO public.tasks (agency_id, title, description, task_category, task_type,
                                  priority, status, due_date, related_id, created_at, updated_at)
        VALUES (
          p_agency_id,
          CASE WHEN v_did_apply
               THEN 'Raise applied — ' || r.first_name || ' to $' || to_char(r.next_hourly, 'FM990.00') || '/hr'
               ELSE 'Raise earned, NOT applied — ' || r.first_name END,
          r.first_name || ' met raise tier ' || r.next_tier || ' at the ' || p_as_of || ' quarter close.'
            || E'\n\nNeeded: ' || COALESCE(r.next_requirement, 'the next step')
            || CASE WHEN r.avg_weekly_sp IS NOT NULL
                    THEN E'\nTheir average: ' || r.avg_weekly_sp || ' a week' ELSE '' END
            || CASE WHEN v_did_apply THEN
                 E'\n\nPay rate has been updated automatically.'
                 || E'\nWas: ' || v_old_rate || ' (' || COALESCE(v_pay_type,'?') || ')'
                 || E'\nNow: ' || v_new_rate || ' (' || COALESCE(v_pay_type,'?') || ')'
                 || E'\nThat is $' || to_char(r.next_hourly, 'FM990.00') || '/hr'
                 || CASE WHEN COALESCE(r.title_increment,0) > 0
                         THEN ', including $' || to_char(r.title_increment, 'FM990.00')
                              || ' ' || COALESCE(r.role_level,'title') ELSE '' END
                 || E'\n\nNothing further to do — this is a record of the change.'
               ELSE
                 E'\n\nNOT APPLIED: ' || COALESCE(v_note, 'see the raise review log.')
                 || E'\nHandle this one by hand.'
               END,
          'admin', 'epic', CASE WHEN v_did_apply THEN 'medium' ELSE 'high' END,
          'open', p_as_of + 7, r.team_member_id, now(), now()
        )
        RETURNING id INTO v_task_id;
      END IF;

      v_qualified := v_qualified + 1;
      v_names := array_append(v_names, r.first_name);
    END IF;

    INSERT INTO public.raise_review_log (
      agency_id, reviewed_on, team_member_id, first_name, role_category, role_level,
      current_hourly, title_increment, tier_hourly, current_tier, next_tier, next_hourly,
      next_requirement, avg_weekly_sp, qualified, task_id,
      applied_at, previous_pay_rate, new_pay_rate, pay_type, not_applied_note)
    VALUES (
      p_agency_id, p_as_of, r.team_member_id, r.first_name, r.role_category, r.role_level,
      r.current_hourly, r.title_increment, r.tier_hourly, r.current_tier, r.next_tier,
      r.next_hourly, r.next_requirement, r.avg_weekly_sp,
      COALESCE(r.on_track, false) AND r.next_tier IS NOT NULL, v_task_id,
      CASE WHEN v_did_apply THEN now() END, v_old_rate,
      CASE WHEN v_did_apply THEN v_new_rate END, v_pay_type, v_note)
    ON CONFLICT (agency_id, reviewed_on, team_member_id) DO UPDATE
      SET current_hourly    = EXCLUDED.current_hourly,
          avg_weekly_sp     = EXCLUDED.avg_weekly_sp,
          qualified         = EXCLUDED.qualified,
          task_id           = COALESCE(public.raise_review_log.task_id, EXCLUDED.task_id),
          applied_at        = COALESCE(public.raise_review_log.applied_at, EXCLUDED.applied_at),
          previous_pay_rate = COALESCE(public.raise_review_log.previous_pay_rate, EXCLUDED.previous_pay_rate),
          new_pay_rate      = COALESCE(public.raise_review_log.new_pay_rate, EXCLUDED.new_pay_rate),
          not_applied_note  = EXCLUDED.not_applied_note;
  END LOOP;

  RETURN jsonb_build_object(
    'reviewed_on', p_as_of,
    'seats_reviewed', v_reviewed,
    'raises_earned', v_qualified,
    'raises_applied', v_applied,
    'who', v_names);
END;
$function$;
