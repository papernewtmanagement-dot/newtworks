-- ─── 1. Column on hiring_candidates for notification tracking ──────────────
ALTER TABLE public.hiring_candidates
ADD COLUMN IF NOT EXISTS peter_notified_at TIMESTAMPTZ;

COMMENT ON COLUMN public.hiring_candidates.peter_notified_at IS
'Timestamp when Peter received a Telegram DM about this applicant. NULL = not yet notified. Set by notify_peter_new_applicants() on successful send.';

-- ─── 2. Backfill so existing candidates don''t retroactively notify ────────
-- Any candidate that already exists as of this migration is considered
-- "already known" — we don''t want to spam Peter with historical rows if
-- someone flipped statuses around later.
UPDATE public.hiring_candidates
SET peter_notified_at = COALESCE(created_at, NOW())
WHERE peter_notified_at IS NULL;

-- ─── 3. Partial index for the cron scan predicate ─────────────────────────
CREATE INDEX IF NOT EXISTS idx_hiring_candidates_notify_scan
ON public.hiring_candidates (agency_id, status, created_at)
WHERE peter_notified_at IS NULL;

-- ─── 4. Send-Telegram-DM function ─────────────────────────────────────────
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
  -- Load Peter's Telegram channel (Paper Newt Management group, effectively a 2-person DM with Marie).
  SELECT setting_value::bigint
    INTO v_chat_id
    FROM public.settings
   WHERE agency_id  = '126794dd-25ff-47d2-a436-724499733365'
     AND setting_key = 'paper_newt_management_group_chat_id';

  IF v_chat_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'chat_id not configured');
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

COMMENT ON FUNCTION public.notify_peter_new_applicants() IS
'Every 5 min via pg_cron. Scans hiring_candidates for status=applied + peter_notified_at IS NULL, sends short Telegram DM to the Paper Newt Management group with a tap-through link to /hr?tab=growth&candidate=<id>, marks peter_notified_at on success. Rate cap 10 per run.';

-- ─── 5. pg_cron schedule (idempotent) ─────────────────────────────────────
DO $$
DECLARE
  v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'notify-peter-new-applicants';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;
END $$;

SELECT cron.schedule(
  'notify-peter-new-applicants',
  '*/5 * * * *',
  'SELECT public.notify_peter_new_applicants();'
);

-- ─── 6. Register in automation_recipes for BCC visibility ──────────────────
INSERT INTO public.automation_recipes (
  agency_id,
  recipe_name,
  recipe_description,
  trigger_type,
  cron_expression,
  is_active
)
SELECT
  '126794dd-25ff-47d2-a436-724499733365',
  'New Applicant Telegram DM',
  'Every 5 min: scan hiring_candidates for status=applied + peter_notified_at IS NULL. Send short Telegram DM to Peter via paper_newt_management_group_chat_id, tap-through link to /hr?tab=growth&candidate=<id>. Rate cap 10/run. Direct-cron (pg_cron -> notify_peter_new_applicants()), not routed through automation-runner.',
  'manual',
  '*/5 * * * *',
  true
WHERE NOT EXISTS (
  SELECT 1 FROM public.automation_recipes
   WHERE agency_id  = '126794dd-25ff-47d2-a436-724499733365'
     AND recipe_name = 'New Applicant Telegram DM'
);
