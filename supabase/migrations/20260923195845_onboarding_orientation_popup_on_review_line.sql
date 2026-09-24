-- Peter 2026-09-23: the Orientation pop-up opens from an (i) next to the "Orientation" line on the Review With Peter
-- card, only Peter sees that (i), and he edits the pop-up himself. At the bottom he checks off each new hire who was
-- there, which ticks that line on their card; nobody else can tick it. The separate Orientation card goes away and
-- its talking points move into the pop-up word for word. Replaces the card-level version (migration 20260923183202).

ALTER TABLE public.onboarding_instructions ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE public.onboarding_instructions
  DROP CONSTRAINT IF EXISTS onboarding_instructions_kind_chk,
  ADD CONSTRAINT onboarding_instructions_kind_chk CHECK (kind IS NULL OR kind = 'orientation');
COMMENT ON COLUMN public.onboarding_instructions.kind IS
  'orientation = Peter''s orientation pop-up: owner-only (i) next to the sub-item with this label, a checkmark per new hire, and only the owner can tick that sub-item (onboarding_step_complete_gate). For this kind body_md holds the talking points in the sub-item text format, not markdown.';

-- The talking points, converted from the Orientation card with the app's own substepsToText (checked to convert back
-- unchanged). The md5 check below stops the whole migration if a single character differs.
INSERT INTO public.onboarding_instructions (agency_id, substep_label, title, body_md, kind)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'Orientation', 'Orientation', $orient$About Us:
We are the largest P&C insurer in the country and have been for over 100 years--why?
We do what’s right
We follow some simple principles

Know your why:
[Video](https://www.facebook.com/share/v/oPaXS7zcYNHTZEUs/?mibextid=w8EBqM)
Our mission statement
Do you have a story?
What are you willing to do for the customer?
Homework: Type it out and get it back to me

Foundation of ethics::
Do what’s right for the company, the agency, and for the customer
Don’t fudge data
Don’t skirt eligibility or rating
Do offer what the customer needs even if they don’t know they need it: mission statement

Let's talk about goals:
[How do you eat an elephant?](https://youtu.be/LZpAYmUpx44?si=2oKB3Wthv-Tcvk-m)
So how do you do this with so much to do?
[20 mile march](https://www.c-span.org/clip/news-conference/user-clip-20-mile-march-jim-collins/5067394)
Break down sales goals to weekly goals to weekly quotes and what is a quote
$100k income = 6 autos, 3 fire, 1 life each week

So how do you make the most of your time:
[Put the big rocks first](https://www.youtube.com/watch?v=WG7R6XodW18)
[4 disciplines of execution](https://www.youtube.com/watch?v=mP7sq_tGZj8)

Now, lots of folks come onboard and wonder::
How will you not screw up?
How will you keep your job?
Ultimately remember the foundation of ethics
But that’s the wrong question, so let’s [reframe failure](https://www.facebook.com/GrowthTribeIO/videos/the-super-mario-effect-mark-rober-tedxpenn/3742136095839571/)
You will fail--a lot!
[YouTube](https://www.youtube.com/watch?v=xKd3MD4n6ng)
[YouTube](https://www.youtube.com/watch?v=pTKfaVzbpJ4)
Just because it’s taking time doesn’t mean it’s not happening

Volume negates luck:
[Video](https://www.youtube.com/shorts/fDm1KLlQ4wM)
As it turns out, the harder you work, the luckier you get
So seek to get 1% better every day

Get used to rejection:
[Rejection therapy (Start at 4:20)](https://www.youtube.com/watch?v=ZFWyseydTkQ)
[Set no goals](https://www.youtube.com/watch?v=SMiJeU7nU7k)
You’re always selling in life, and you’re always getting rejected.
[Don’t stop until you get a no (funny sale until 2:59, then go for no)](https://www.youtube.com/watch?v=UZTKFJ-xipw)
Learn to get a no
[YouTube](https://www.youtube.com/watch?v=waTzPF4P6oY)
[YouTube](https://www.youtube.com/watch?v=hjrmd-TSmbc) (Watch until 4:12)
Is this a bad time?
Do you think insurance is a scam?
Would it be ridiculous to get this started today?

Tactical empathy:
[Video](https://www.youtube.com/watch?v=QIRk382yJm4)
Yes and
[TikTok](https://www.tiktok.com/@askvinh/video/7415565490170449173)
[YouTube](https://www.youtube.com/shorts/il48SeduYOY)

Aim to hit goals in everything:
Reason for our health goals.
It’s not about hitting goals, it’s about becoming the KIND of person who hits goals.

10 to 1 rule:
Understand at a ten, explain at a one
How we explain to customers
How I train you
Don’t try to learn everything on day one--trust the process

You will need help:
If you want to go fast, go alone, but if you want to go far, go with someone.
Bug me if you want to succeed--tell me your obstacles so I can help

To Add:
If poem by Rudyard Kipling
Jeremy Miner videos on Gap selling to show an example of how to uncover the Gap$orient$, 'orientation');

DO $check$
BEGIN
  IF (SELECT md5(body_md) FROM public.onboarding_instructions
       WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND substep_label = 'Orientation')
     IS DISTINCT FROM 'e25db87d6be213ca69789d0d566c03c3' THEN
    RAISE EXCEPTION 'Orientation talking points did not copy over exactly.';
  END IF;
END $check$;

CREATE OR REPLACE FUNCTION public.onboarding_step_complete_gate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_missing int;
BEGIN
  -- The Orientation line (the sub-item named by an onboarding_instructions row with kind 'orientation') is ticked by
  -- Peter at orientation, from its pop-up or on the card. Nobody else can tick or untick it. Work with nobody signed
  -- in (the template sync, a migration) is not a person ticking a box.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.substeps_done IS DISTINCT FROM OLD.substeps_done
       AND auth.uid() IS NOT NULL
       AND COALESCE(public.current_app_user_role(), '') <> 'owner'
       AND EXISTS (
         SELECT 1
         FROM public.onboarding_instructions i
         JOIN public.team_onboarding_plans p ON p.id = NEW.plan_id AND p.agency_id = i.agency_id
         WHERE i.kind = 'orientation'
           AND (CASE WHEN jsonb_typeof(OLD.substeps_done) = 'array' THEN OLD.substeps_done ? i.substep_label ELSE false END)
               IS DISTINCT FROM
               (CASE WHEN jsonb_typeof(NEW.substeps_done) = 'array' THEN NEW.substeps_done ? i.substep_label ELSE false END)
       ) THEN
      RAISE EXCEPTION 'Peter checks off Orientation at orientation.';
    END IF;
  END IF;

  -- Only guard the moment a step goes from open to done.
  IF NEW.completed_at IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.completed_at IS NOT NULL THEN RETURN NEW; END IF;

  IF NEW.auto_source IS NOT NULL
     AND COALESCE(current_setting('app.onboarding_autotick', true), '') <> 'on' THEN
    RAISE EXCEPTION 'This step fills itself in from the rest of Newtworks. It cannot be ticked by hand.';
  END IF;

  IF NEW.unlocks_on IS NOT NULL
     AND NEW.unlocks_on > (now() AT TIME ZONE 'America/Chicago')::date THEN
    RAISE EXCEPTION 'This step opens on %.', to_char(NEW.unlocks_on, 'Dy Mon FMDD');
  END IF;

  IF array_length(public.onboarding_substep_labels(NEW.substeps), 1) IS NULL THEN
    RETURN NEW;
  END IF;

  v_missing := public.onboarding_substeps_missing(NEW.substeps, NEW.substeps_done);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'Finish all the sub-items first. % still open.', v_missing;
  END IF;

  RETURN NEW;
END;
$function$;

-- Back to the version before the card-level Orientation (no widget check).
CREATE OR REPLACE FUNCTION public.task_tick_syncs_onboarding_step()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  s       record;
  v_label text;
BEGIN
  IF NEW.related_id IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT id, completed_at, auto_source, substeps, substeps_done, owner_kind
  INTO s
  FROM public.team_onboarding_steps
  WHERE id = NEW.related_id;

  IF NOT FOUND OR s.auto_source IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Team card: this task is one teammate's own line on it.
  IF s.owner_kind = 'team' THEN
    SELECT public.onboarding_team_label(tm) INTO v_label
    FROM public.users u JOIN public.team tm ON tm.id = u.team_member_id
    WHERE u.id = NEW.assigned_to;
    IF v_label IS NULL OR NOT (v_label = ANY (public.onboarding_substep_labels(s.substeps))) THEN
      RETURN NEW;
    END IF;
    IF NEW.status = 'completed' THEN
      UPDATE public.team_onboarding_steps
      SET substeps_done = COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb)
                          || jsonb_build_array(v_label),
          updated_at = now()
      WHERE id = s.id
        AND NOT (COALESCE(CASE WHEN jsonb_typeof(substeps_done) = 'array' THEN substeps_done END, '[]'::jsonb) ? v_label);
      UPDATE public.team_onboarding_steps
      SET completed_at = now(), completed_by = COALESCE(completed_by, NEW.assigned_to), updated_at = now()
      WHERE id = s.id AND completed_at IS NULL
        AND public.onboarding_substeps_missing(substeps, substeps_done) = 0;
    ELSE
      UPDATE public.team_onboarding_steps
      SET substeps_done = substeps_done - v_label,
          completed_at  = NULL,
          completed_by  = NULL,
          updated_at    = now()
      WHERE id = s.id AND jsonb_typeof(substeps_done) = 'array' AND substeps_done ? v_label;
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' AND s.completed_at IS NULL THEN
    IF public.onboarding_substeps_missing(s.substeps, s.substeps_done) > 0 THEN
      RETURN NEW;   -- sub-items still open; the checklist stays the record
    END IF;

    UPDATE public.team_onboarding_steps
    SET completed_at = now(),
        completed_by = COALESCE(completed_by, NEW.assigned_to),
        updated_at   = now()
    WHERE id = s.id;

  ELSIF NEW.status <> 'completed' AND s.completed_at IS NOT NULL THEN
    UPDATE public.team_onboarding_steps
    SET completed_at = NULL,
        completed_by = NULL,
        updated_at   = now()
    WHERE id = s.id;
  END IF;

  RETURN NEW;
END;
$function$;

DROP FUNCTION IF EXISTS public.onboarding_subitems_required(text);

-- Peter: get rid of the Orientation card. The template sync takes it off both live plans, with its tasks.
DELETE FROM public.onboarding_step_templates
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365' AND template_key = 'p1_orientation_page';

ALTER TABLE public.onboarding_step_templates
  DROP CONSTRAINT IF EXISTS onboarding_step_templates_widget_chk,
  ADD CONSTRAINT onboarding_step_templates_widget_chk CHECK (widget IS NULL OR widget = 'team_forms');
ALTER TABLE public.team_onboarding_steps
  DROP CONSTRAINT IF EXISTS team_onboarding_steps_widget_chk,
  ADD CONSTRAINT team_onboarding_steps_widget_chk CHECK (widget IS NULL OR widget = 'team_forms');
