-- Migration: everquote_review_tables
-- Applied via Supabase MCP on 2026-07-10 02:48:46 UTC
-- Purpose: schema for ingesting monthly EverQuote BC review decks
--
-- Two tables: everquote_reviews (one header row per deck, includes raw OCR jsonb)
-- and everquote_review_metrics (long-form dimensional breakouts per review).

CREATE TABLE IF NOT EXISTS public.everquote_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL REFERENCES public.agency(id) ON DELETE CASCADE,
  review_date date NOT NULL,
  current_period_start date,
  current_period_end date,
  previous_period_start date,
  previous_period_end date,
  bind_date_as_of date,
  is_ytd boolean NOT NULL DEFAULT false,
  gmail_message_id text,
  gmail_thread_id text,
  drive_file_id text,
  drive_url text,
  file_name text,
  source_document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  raw_ocr jsonb,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_everquote_reviews_agency_period
  ON public.everquote_reviews(agency_id, current_period_start DESC);

CREATE TABLE IF NOT EXISTS public.everquote_review_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  review_id uuid NOT NULL REFERENCES public.everquote_reviews(id) ON DELETE CASCADE,
  period_scope text NOT NULL CHECK (period_scope = ANY (ARRAY['current','previous'])),
  dimension text NOT NULL,
  dimension_value text NOT NULL,
  leads integer,
  binds numeric,
  cpb numeric,
  bind_pct numeric,
  quotes numeric,
  fill_rate numeric,
  daily_capsum numeric,
  extra jsonb,
  sort_order integer,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_everquote_metrics_review
  ON public.everquote_review_metrics(review_id, dimension, period_scope);

CREATE INDEX IF NOT EXISTS idx_everquote_metrics_dim_lookup
  ON public.everquote_review_metrics(dimension, dimension_value);
