create table if not exists public.careerplug_webhook_events (
  id bigint generated always as identity primary key,
  agency_id uuid not null default '126794dd-25ff-47d2-a436-724499733365',
  received_at timestamptz not null default now(),
  event_type text,
  app_id text,
  headers jsonb,
  payload jsonb,
  raw_body text,
  processed boolean not null default false
);

create index if not exists careerplug_webhook_events_received_at_idx
  on public.careerplug_webhook_events (received_at desc);

create index if not exists careerplug_webhook_events_app_id_idx
  on public.careerplug_webhook_events (app_id);

alter table public.careerplug_webhook_events enable row level security;
