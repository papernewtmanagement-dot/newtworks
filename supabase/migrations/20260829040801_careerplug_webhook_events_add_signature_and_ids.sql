alter table public.careerplug_webhook_events
  add column if not exists signature_token text,
  add column if not exists signature_valid boolean,
  add column if not exists applicant_id text,
  add column if not exists job_id text,
  add column if not exists account_id text;

create unique index if not exists careerplug_webhook_events_signature_token_key
  on public.careerplug_webhook_events (signature_token)
  where signature_token is not null;
