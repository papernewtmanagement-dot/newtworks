-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-30 21:51:21 UTC (ledger name: exclude_careerplug_source_from_peter_dm_notifier) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260730215121.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- CareerPlug already emails Peter directly with its Fast Track notification.
-- Skip those in the Telegram DM path — DM is reserved for higher-fidelity intake sources
-- (direct careersite path where we get email/phone/resume attached to the row).
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
  v_skipped   int := 0;
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

  -- CareerPlug applicants: skip the DM but mark peter_notified_at so they don't sit forever
  -- in the pending queue. CareerPlug sends its own email notification.
  UPDATE public.hiring_candidates
     SET peter_notified_at = NOW()
   WHERE agency_id         = '126794dd-25ff-47d2-a436-724499733365'
     AND status            = 'applied'
     AND peter_notified_at IS NULL
     AND ingestion_metadata->>'source' = 'careerplug';
  GET DIAGNOSTICS v_skipped = ROW_COUNT;

  -- Scan for remaining un-notified applicants (non-CareerPlug sources). Cap at 10 per run.
  FOR v_candidate IN
    SELECT id, first_name, last_name, candidate_name
      FROM public.hiring_candidates
     WHERE agency_id         = '126794dd-25ff-47d2-a436-724499733365'
       AND status            = 'applied'
       AND peter_notified_at IS NULL
       AND COALESCE(ingestion_metadata->>'source', '') <> 'careerplug'
     ORDER BY created_at ASC
     LIMIT 10
  LOOP
    v_full_name := COALESCE(
      NULLIF(trim(concat_ws(' ', v_candidate.first_name, v_candidate.last_name)), ''),
      v_candidate.candidate_name,
      'Unknown Applicant'
    );

    v_url := 'https://newtworks.vercel.app/hr?tab=growth&candidate=' || v_candidate.id::text;

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
    'ok',      true,
    'sent',    v_sent,
    'failed',  v_failed,
    'skipped_careerplug', v_skipped
  );
END;
$function$;

-- Sync recipe description with new behavior.
UPDATE public.automation_recipes
   SET recipe_description = 'Every 5 min: scan hiring_candidates for status=applied + peter_notified_at IS NULL. Send short Telegram DM to Peter''s private DM (peter_direct_chat_id setting), tap-through link to /hr?tab=growth&candidate=<id>. CareerPlug-sourced applicants are skipped (CareerPlug sends its own email); only non-CareerPlug intake paths trigger the DM. Rate cap 10/run. Direct-cron (pg_cron -> notify_peter_new_applicants()), not routed through automation-runner.',
       updated_at = NOW()
 WHERE id = '64dfda59-6e14-43fc-9879-2e23ac569a23';
