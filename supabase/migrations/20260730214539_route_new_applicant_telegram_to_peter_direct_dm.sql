-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 21:45:39 UTC (ledger name: route_new_applicant_telegram_to_peter_direct_dm) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730214539.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- 1) Store Peter's private Telegram DM chat_id (his 1:1 with @paper_newt_bot).
INSERT INTO public.settings (agency_id, setting_key, setting_value)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'peter_direct_chat_id', '7778113542')
ON CONFLICT (agency_id, setting_key) DO UPDATE SET setting_value = EXCLUDED.setting_value;

-- 2) Point the new-applicant notifier at Peter's real DM, not the shared Paper Newt Management group.
CREATE OR REPLACE FUNCTION public.notify_peter_new_applicants()
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_chat_id   bigint;
  v_candidate record;
  v_full_name text;
  v_url       text;
  v_html      text;
  v_resp      jsonb;
  v_sent      int := 0;
  v_failed    int := 0;
BEGIN
  -- Peter's real private DM with @paper_newt_bot. NOT the shared Paper Newt Management group.
  SELECT setting_value::bigint
    INTO v_chat_id
    FROM public.settings
   WHERE agency_id  = '126794dd-25ff-47d2-a436-724499733365'
     AND setting_key = 'peter_direct_chat_id';

  IF v_chat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'peter_direct_chat_id not configured');
  END IF;

  -- Scan for un-notified applicants who reached status=applied. Cap at 10 per
  -- run so a webhook flood can't fire 100 DMs at once — next run picks up the rest.
  FOR v_candidate IN
    SELECT id, first_name, last_name, candidate_name
      FROM public.hiring_candidates
     WHERE agency_id         = '126794dd-25ff-47d2-a436-724499733365'
       AND status            = 'applied'
       AND peter_notified_at IS NULL
     ORDER BY created_at ASC
     LIMIT 10
  LOOP
    v_full_name := COALESCE(
      NULLIF(trim(concat_ws(' ', v_candidate.first_name, v_candidate.last_name)), ''),
      v_candidate.candidate_name,
      'Unknown Applicant'
    );

    v_url := 'https://newtworks.vercel.app/hr?tab=growth&candidate=' || v_candidate.id::text;

    -- Telegram HTML parse mode: whole visible text is the anchor, so tapping
    -- anywhere on the line opens the candidate page. Escape name in case a
    -- payload ever contains <, > or &.
    v_html := '<a href="' || v_url || '">Candidate: '
           || replace(replace(replace(v_full_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
           || '</a>';

    v_resp := public.paper_newt_send_message(v_chat_id, v_html, 'HTML');

    IF (v_resp->>'ok')::boolean IS TRUE THEN
      UPDATE public.hiring_candidates
         SET peter_notified_at = NOW()
       WHERE id = v_candidate.id;
      v_sent := v_sent + 1;
    ELSE
      v_failed := v_failed + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'ok',     true,
    'sent',   v_sent,
    'failed', v_failed
  );
END;
$function$;

-- 3) Update the recipe description so the docs match reality (used to say "DM" but pointed at the group).
UPDATE public.automation_recipes
   SET recipe_description = 'Every 5 min: scan hiring_candidates for status=applied + peter_notified_at IS NULL. Send short Telegram DM to Peter''s private DM (peter_direct_chat_id setting), tap-through link to /hr?tab=growth&candidate=<id>. Rate cap 10/run. Direct-cron (pg_cron -> notify_peter_new_applicants()), not routed through automation-runner.',
       updated_at = NOW()
 WHERE id = '64dfda59-6e14-43fc-9879-2e23ac569a23';

-- 4) Re-send Madison May's notification to Peter's DM (the earlier one went to the group by mistake).
-- Reset peter_notified_at so the next cron pass picks her up, or the caller can invoke notify_peter_new_applicants() directly.
UPDATE public.hiring_candidates
   SET peter_notified_at = NULL
 WHERE id = 'ac8924f3-22ba-4f9e-a176-cac3c933eb08';
