CREATE OR REPLACE FUNCTION public.ingest_careerplug_applications(p_agency_id uuid, p_recipe_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cid text; v_csec text; v_scopes text; v_token text;
  v_evt record;
  v_status int; v_body jsonb; v_app jsonb;
  v_email text; v_existing uuid;
  v_inserted int := 0; v_matched int := 0; v_errors int := 0; v_skipped int := 0;
  v_error_details jsonb := '[]'::jsonb;
  v_resume text;
begin
  select
    max(setting_value) filter (where setting_key = 'careerplug_client_id'),
    max(setting_value) filter (where setting_key = 'careerplug_client_secret'),
    max(setting_value) filter (where setting_key = 'careerplug_scopes')
  into v_cid, v_csec, v_scopes
  from public.settings
  where agency_id = p_agency_id and setting_key like 'careerplug%';

  if v_cid is null or v_csec is null then
    return jsonb_build_object('ran_at', now(), 'records_processed', 0,
      'output_summary', 'ERROR: CareerPlug credentials missing from settings');
  end if;

  select (r.content::jsonb ->> 'access_token') into v_token
  from extensions.http((
    'POST', 'https://partner-api.careerplug.com/oauth/token',
    ARRAY[extensions.http_header('Accept','application/json')],
    'application/x-www-form-urlencoded',
    'grant_type=client_credentials&client_id=' || v_cid ||
    '&client_secret=' || v_csec ||
    '&scope=' || replace(coalesce(v_scopes,''), ' ', '%20')
  )::extensions.http_request) r;

  if v_token is null or v_token = '' then
    return jsonb_build_object('ran_at', now(), 'records_processed', 0,
      'output_summary', 'ERROR: could not obtain CareerPlug access token');
  end if;

  for v_evt in
    select id, app_id, payload
    from public.careerplug_webhook_events
    where agency_id = p_agency_id
      and processed = false
      and app_id is not null
      and coalesce(signature_valid, true) = true
      and coalesce(event_type, '') in ('app_created', 'app_updated')
    order by received_at
    limit 20
  loop
    begin
      select r.status, r.content::jsonb into v_status, v_body
      from extensions.http((
        'GET', 'https://partner-api.careerplug.com/v1/apps/' || v_evt.app_id,
        ARRAY[
          extensions.http_header('Authorization', 'Bearer ' || v_token),
          extensions.http_header('Accept','application/json')
        ], NULL, NULL
      )::extensions.http_request) r;

      if v_status <> 200 then
        v_errors := v_errors + 1;
        v_error_details := v_error_details || jsonb_build_object('app_id', v_evt.app_id, 'status', v_status);
        perform pg_sleep(1);
        continue;
      end if;

      v_app := v_body -> 'app';
      v_email := nullif(lower(trim(v_app ->> 'email')), '');

      if v_email is null then
        update public.careerplug_webhook_events set processed = true where id = v_evt.id;
        v_skipped := v_skipped + 1;
        perform pg_sleep(1);
        continue;
      end if;

      v_resume := nullif(trim(coalesce(v_app ->> 'resume_text', '')), '');

      -- Does this person already have a row? All matching logic lives in
      -- find_existing_candidate so this path and upsert_candidate_from_careerplug
      -- behave identically. Rewritten 2026-09-18 — the old inline version matched on
      -- application id, or email, or first plus last name when email was absent, and
      -- never on phone number. Peter directive: check phone, email, address and name
      -- before creating any candidate row.
      v_existing := public.find_existing_candidate(
        p_agency_id         => p_agency_id,
        p_email             => v_email,
        p_phone             => v_app ->> 'phone',
        p_first_name        => v_app ->> 'firstname',
        p_last_name         => v_app ->> 'lastname',
        p_position          => v_evt.payload -> 'data' -> 'job' ->> 'name',
        p_careerplug_app_id => v_evt.app_id
      );

      if v_existing is not null then
        update public.hiring_candidates hc
        set first_name  = coalesce(hc.first_name, v_app ->> 'firstname'),
            last_name   = coalesce(hc.last_name,  v_app ->> 'lastname'),
            email       = coalesce(hc.email,      v_app ->> 'email'),
            phone       = coalesce(hc.phone, public.normalise_us_phone(v_app ->> 'phone')),
            position    = coalesce(hc.position,   v_evt.payload -> 'data' -> 'job' ->> 'name'),
            applied_at  = coalesce(hc.applied_at, (v_app ->> 'created_at')::timestamptz),
            resume_extracted_text = coalesce(hc.resume_extracted_text, v_resume),
            careerplug_app_id = coalesce(hc.careerplug_app_id, v_evt.app_id),
            careerplug_source_platform = coalesce(hc.careerplug_source_platform, v_app ->> 'source_name'),
            updated_at = now()
        where hc.id = v_existing;
        v_matched := v_matched + 1;
      else
        insert into public.hiring_candidates (
          agency_id, first_name, last_name, email, phone, position, status,
          applied_at, resume_extracted_text, source_channel,
          careerplug_app_id, careerplug_source_platform, ingestion_metadata
        ) values (
          p_agency_id,
          v_app ->> 'firstname',
          v_app ->> 'lastname',
          v_app ->> 'email',
          public.normalise_us_phone(v_app ->> 'phone'),
          v_evt.payload -> 'data' -> 'job' ->> 'name',
          'applied',
          (v_app ->> 'created_at')::timestamptz,
          v_resume,
          'careerplug',
          v_evt.app_id,
          v_app ->> 'source_name',
          jsonb_build_object(
            'source', 'careerplug',
            'ingested_at', now(),
            'careerplug', jsonb_build_object(
              'careerplug_app_id', v_evt.app_id,
              'method', 'webhook_api'
            )
          )
        );
        v_inserted := v_inserted + 1;
      end if;

      update public.careerplug_webhook_events set processed = true where id = v_evt.id;
      perform pg_sleep(1);

    exception when others then
      v_errors := v_errors + 1;
      v_error_details := v_error_details || jsonb_build_object('app_id', v_evt.app_id, 'error', SQLERRM);
    end;
  end loop;

  return jsonb_build_object(
    'ran_at', now(),
    'records_processed', v_inserted + v_matched,
    'inserted', v_inserted,
    'enriched_existing', v_matched,
    'skipped_no_email', v_skipped,
    'errors', v_errors,
    'error_details', v_error_details,
    'output_summary', format('CareerPlug intake: %s new, %s enriched, %s skipped, %s errors',
                             v_inserted, v_matched, v_skipped, v_errors)
  );
end;
$function$;
