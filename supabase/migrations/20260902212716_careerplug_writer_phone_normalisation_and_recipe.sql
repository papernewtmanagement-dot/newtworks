-- CareerPlug returns phones as "1210-330-5800". Existing rows store bare 10 digits.
create or replace function public.normalise_us_phone(p_raw text)
returns text
language sql
immutable
as $$
  select case
    when p_raw is null then null
    when length(regexp_replace(p_raw, '[^0-9]', '', 'g')) = 11
         and left(regexp_replace(p_raw, '[^0-9]', '', 'g'), 1) = '1'
      then right(regexp_replace(p_raw, '[^0-9]', '', 'g'), 10)
    when length(regexp_replace(p_raw, '[^0-9]', '', 'g')) = 10
      then regexp_replace(p_raw, '[^0-9]', '', 'g')
    else nullif(regexp_replace(p_raw, '[^0-9]', '', 'g'), '')
  end;
$$;

-- Fix the five rows already written.
update public.hiring_candidates
set phone = public.normalise_us_phone(phone), updated_at = now()
where agency_id = '126794dd-25ff-47d2-a436-724499733365'
  and source_channel = 'careerplug'
  and phone is not null
  and phone <> public.normalise_us_phone(phone);

-- Apply the same normalisation inside the writer.
create or replace function public.ingest_careerplug_applications(
  p_agency_id uuid,
  p_recipe_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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

      select id into v_existing
      from public.hiring_candidates
      where agency_id = p_agency_id and lower(email) = v_email
      order by created_at
      limit 1;

      if v_existing is not null then
        update public.hiring_candidates hc
        set first_name  = coalesce(hc.first_name, v_app ->> 'firstname'),
            last_name   = coalesce(hc.last_name,  v_app ->> 'lastname'),
            phone       = coalesce(hc.phone, public.normalise_us_phone(v_app ->> 'phone')),
            position    = coalesce(hc.position,   v_evt.payload -> 'data' -> 'job' ->> 'name'),
            applied_at  = coalesce(hc.applied_at, (v_app ->> 'created_at')::timestamptz),
            resume_extracted_text = coalesce(hc.resume_extracted_text, v_resume),
            ingestion_metadata = coalesce(hc.ingestion_metadata, '{}'::jsonb)
              || jsonb_build_object(
                   'source', 'careerplug',
                   'careerplug', coalesce(hc.ingestion_metadata -> 'careerplug', '{}'::jsonb)
                     || jsonb_build_object(
                          'careerplug_app_id', v_evt.app_id,
                          'careerplug_applicant_id', v_app ->> 'user_id',
                          'job_id', v_app ->> 'job_id',
                          'source_platform', v_app ->> 'source_name',
                          'method', 'webhook_api'
                        )),
            updated_at = now()
        where hc.id = v_existing;
        v_matched := v_matched + 1;
      else
        insert into public.hiring_candidates (
          agency_id, first_name, last_name, email, phone, position, status,
          applied_at, resume_extracted_text, source_channel, ingestion_metadata
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
          jsonb_build_object(
            'source', 'careerplug',
            'ingested_at', now(),
            'careerplug', jsonb_build_object(
              'careerplug_app_id', v_evt.app_id,
              'careerplug_applicant_id', v_app ->> 'user_id',
              'job_id', v_app ->> 'job_id',
              'source_platform', v_app ->> 'source_name',
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
