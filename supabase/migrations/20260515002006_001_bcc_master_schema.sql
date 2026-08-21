-- BCC MASTER SCHEMA MIGRATION v1.0
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS agency (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name                  TEXT NOT NULL,
  owner_name            TEXT NOT NULL,
  entity_type           TEXT,
  tax_id                TEXT,
  state_farm_agent_code TEXT,
  licensing_states      TEXT[],
  primary_email         TEXT NOT NULL,
  phone                 TEXT,
  address               TEXT,
  google_account_email  TEXT,
  supabase_project_id   TEXT,
  composio_account_id   TEXT,
  vercel_url            TEXT,
  setup_date            DATE,
  status                TEXT DEFAULT 'active',
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id       UUID REFERENCES agency(id) ON DELETE CASCADE,
  email           TEXT NOT NULL,
  full_name       TEXT NOT NULL,
  role            TEXT NOT NULL DEFAULT 'readonly',
  auth_user_id    UUID,
  invited_by      UUID REFERENCES users(id),
  invited_at      TIMESTAMPTZ,
  last_login      TIMESTAMPTZ,
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS persistent_memory (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id   UUID REFERENCES agency(id) ON DELETE CASCADE,
  category    TEXT NOT NULL,
  title       TEXT NOT NULL,
  content     TEXT NOT NULL,
  is_active   BOOLEAN DEFAULT TRUE,
  added_by    TEXT DEFAULT 'system',
  source      TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staff (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id       UUID REFERENCES agency(id) ON DELETE CASCADE,
  first_name      TEXT NOT NULL,
  last_name       TEXT NOT NULL,
  role            TEXT,
  employment_type TEXT,
  start_date      DATE,
  end_date        DATE,
  is_active       BOOLEAN DEFAULT TRUE,
  email           TEXT,
  phone           TEXT,
  pay_type        TEXT,
  pay_rate        NUMERIC(10,2),
  notes           TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS alerts (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  alert_type        TEXT NOT NULL,
  severity          TEXT NOT NULL DEFAULT 'info',
  title             TEXT NOT NULL,
  message           TEXT,
  module_reference  TEXT,
  related_id        UUID,
  is_read           BOOLEAN DEFAULT FALSE,
  is_resolved       BOOLEAN DEFAULT FALSE,
  due_date          DATE,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  resolved_at       TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS chart_of_accounts (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  account_code     TEXT NOT NULL,
  account_name     TEXT NOT NULL,
  account_type     TEXT NOT NULL,
  account_subtype  TEXT,
  parent_account_id UUID REFERENCES chart_of_accounts(id),
  is_active        BOOLEAN DEFAULT TRUE,
  is_system        BOOLEAN DEFAULT FALSE,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agency_id, account_code)
);

CREATE TABLE IF NOT EXISTS journal_entries (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  entry_date       DATE NOT NULL,
  entry_type       TEXT,
  reference_number TEXT,
  description      TEXT NOT NULL,
  memo             TEXT,
  source           TEXT DEFAULT 'manual',
  document_id      UUID,
  created_by       TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS journal_lines (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  journal_entry_id UUID REFERENCES journal_entries(id) ON DELETE CASCADE,
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  account_id       UUID REFERENCES chart_of_accounts(id),
  debit            NUMERIC(12,2) DEFAULT 0,
  credit           NUMERIC(12,2) DEFAULT 0,
  description      TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  CONSTRAINT debit_credit_check CHECK (
    (debit > 0 AND credit = 0) OR (credit > 0 AND debit = 0)
  )
);

CREATE TABLE IF NOT EXISTS bank_accounts (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id             UUID REFERENCES agency(id) ON DELETE CASCADE,
  account_name          TEXT NOT NULL,
  institution           TEXT NOT NULL,
  account_type          TEXT,
  account_number_last4  TEXT,
  routing_number_last4  TEXT,
  current_balance       NUMERIC(12,2),
  as_of_date            DATE,
  is_primary            BOOLEAN DEFAULT FALSE,
  is_active             BOOLEAN DEFAULT TRUE,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS credit_accounts (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id             UUID REFERENCES agency(id) ON DELETE CASCADE,
  account_name          TEXT NOT NULL,
  institution           TEXT NOT NULL,
  account_type          TEXT NOT NULL,
  account_number_last4  TEXT,
  credit_limit          NUMERIC(12,2),
  current_balance       NUMERIC(12,2) DEFAULT 0,
  available_credit      NUMERIC(12,2),
  interest_rate         NUMERIC(5,2),
  minimum_payment       NUMERIC(10,2),
  payment_due_day       INTEGER,
  is_active             BOOLEAN DEFAULT TRUE,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  updated_at            TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS credit_transactions (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  credit_account_id UUID REFERENCES credit_accounts(id) ON DELETE CASCADE,
  transaction_date DATE NOT NULL,
  description      TEXT NOT NULL,
  amount           NUMERIC(12,2) NOT NULL,
  transaction_type TEXT,
  journal_entry_id UUID REFERENCES journal_entries(id),
  category         TEXT,
  receipt_url      TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS payroll_runs (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  pay_period_start  DATE NOT NULL,
  pay_period_end    DATE NOT NULL,
  pay_date          DATE NOT NULL,
  payroll_provider  TEXT,
  gross_payroll     NUMERIC(12,2),
  employer_taxes    NUMERIC(12,2),
  net_payroll       NUMERIC(12,2),
  status            TEXT DEFAULT 'draft',
  source_document_id UUID,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS payroll_detail (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  payroll_run_id    UUID REFERENCES payroll_runs(id) ON DELETE CASCADE,
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  staff_id          UUID REFERENCES staff(id),
  gross_pay         NUMERIC(10,2),
  federal_tax       NUMERIC(10,2) DEFAULT 0,
  state_tax         NUMERIC(10,2) DEFAULT 0,
  social_security   NUMERIC(10,2) DEFAULT 0,
  medicare          NUMERIC(10,2) DEFAULT 0,
  other_deductions  NUMERIC(10,2) DEFAULT 0,
  net_pay           NUMERIC(10,2),
  employment_type   TEXT,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS comp_recap (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id            UUID REFERENCES agency(id) ON DELETE CASCADE,
  period_year          INTEGER NOT NULL,
  period_month         INTEGER NOT NULL,
  comp_type            TEXT,
  comp_category        TEXT,
  description          TEXT,
  amount               NUMERIC(12,2) NOT NULL,
  is_aipp_eligible     BOOLEAN DEFAULT FALSE,
  is_scoreboard_eligible BOOLEAN DEFAULT FALSE,
  source_document_id   UUID,
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agency_id, period_year, period_month, comp_category, description)
);

CREATE TABLE IF NOT EXISTS aipp_tracking (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id             UUID REFERENCES agency(id) ON DELETE CASCADE,
  program_year          INTEGER NOT NULL,
  target_amount         NUMERIC(12,2),
  earned_ytd            NUMERIC(12,2) DEFAULT 0,
  projected_full_year   NUMERIC(12,2),
  achievement_percentage NUMERIC(5,2),
  last_updated          TIMESTAMPTZ DEFAULT NOW(),
  notes                 TEXT,
  created_at            TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agency_id, program_year)
);

CREATE TABLE IF NOT EXISTS scoreboard_tracking (
  id                    UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id             UUID REFERENCES agency(id) ON DELETE CASCADE,
  program_year          INTEGER NOT NULL,
  period                TEXT,
  metric_name           TEXT NOT NULL,
  target                NUMERIC(12,2),
  actual                NUMERIC(12,2),
  achievement_percentage NUMERIC(5,2),
  notes                 TEXT,
  created_at            TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS compliance_rules (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id       UUID REFERENCES agency(id) ON DELETE CASCADE,
  rule_code       TEXT,
  category        TEXT NOT NULL,
  title           TEXT NOT NULL,
  description     TEXT NOT NULL,
  requirement     TEXT,
  source          TEXT,
  effective_date  DATE,
  expiration_date DATE,
  severity        TEXT DEFAULT 'info',
  is_active       BOOLEAN DEFAULT TRUE,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS compliance_calendar (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id          UUID REFERENCES agency(id) ON DELETE CASCADE,
  compliance_rule_id UUID REFERENCES compliance_rules(id),
  title              TEXT NOT NULL,
  description        TEXT,
  due_date           DATE NOT NULL,
  recurrence         TEXT DEFAULT 'none',
  status             TEXT DEFAULT 'upcoming',
  completed_at       TIMESTAMPTZ,
  completed_by       TEXT,
  alert_days_before  INTEGER DEFAULT 14,
  created_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS compliance_log (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id          UUID REFERENCES agency(id) ON DELETE CASCADE,
  compliance_rule_id UUID REFERENCES compliance_rules(id),
  event_type         TEXT,
  description        TEXT NOT NULL,
  conversation_reference TEXT,
  created_by         TEXT,
  created_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS automation_recipes (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id           UUID REFERENCES agency(id) ON DELETE CASCADE,
  recipe_name         TEXT NOT NULL,
  recipe_description  TEXT,
  trigger_type        TEXT NOT NULL,
  cron_expression     TEXT,
  trigger_event       TEXT,
  composio_action     TEXT,
  composio_connection TEXT,
  groq_prompt         TEXT,
  input_config        JSONB,
  output_table        TEXT,
  output_config       JSONB,
  is_active           BOOLEAN DEFAULT TRUE,
  last_run_at         TIMESTAMPTZ,
  last_run_status     TEXT,
  created_at          TIMESTAMPTZ DEFAULT NOW(),
  updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS automation_run_log (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  recipe_id         UUID REFERENCES automation_recipes(id),
  run_at            TIMESTAMPTZ DEFAULT NOW(),
  status            TEXT NOT NULL,
  records_processed INTEGER DEFAULT 0,
  error_message     TEXT,
  duration_seconds  INTEGER,
  output_summary    TEXT,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS documents (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  file_name         TEXT NOT NULL,
  file_type         TEXT,
  upload_source     TEXT,
  drive_file_id     TEXT,
  drive_url         TEXT,
  processing_status TEXT DEFAULT 'pending',
  processing_type   TEXT,
  groq_classification TEXT,
  tables_updated    TEXT[],
  records_created   INTEGER DEFAULT 0,
  uploaded_by       TEXT,
  uploaded_at       TIMESTAMPTZ DEFAULT NOW(),
  processed_at      TIMESTAMPTZ,
  notes             TEXT,
  created_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS daily_briefing_log (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  briefing_date    DATE NOT NULL,
  sent_at          TIMESTAMPTZ,
  delivered        BOOLEAN DEFAULT FALSE,
  opened           BOOLEAN DEFAULT FALSE,
  content_snapshot TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS social_accounts (
  id                     UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id              UUID REFERENCES agency(id) ON DELETE CASCADE,
  platform               TEXT NOT NULL,
  account_handle         TEXT,
  account_id             TEXT,
  is_connected           BOOLEAN DEFAULT FALSE,
  last_sync              TIMESTAMPTZ,
  composio_connection_id TEXT,
  notes                  TEXT,
  created_at             TIMESTAMPTZ DEFAULT NOW(),
  updated_at             TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS content_calendar (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  platform         TEXT NOT NULL,
  content_type     TEXT,
  caption          TEXT,
  hashtags         TEXT[],
  media_url        TEXT,
  scheduled_date   DATE,
  scheduled_time   TIME,
  status           TEXT DEFAULT 'draft',
  post_url         TEXT,
  engagement_notes TEXT,
  requires_manual  BOOLEAN DEFAULT FALSE,
  created_by       TEXT,
  created_at       TIMESTAMPTZ DEFAULT NOW(),
  posted_at        TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS social_analytics (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id           UUID REFERENCES agency(id) ON DELETE CASCADE,
  social_account_id   UUID REFERENCES social_accounts(id),
  content_calendar_id UUID REFERENCES content_calendar(id),
  platform            TEXT NOT NULL,
  post_date            DATE,
  impressions         INTEGER DEFAULT 0,
  reach               INTEGER DEFAULT 0,
  likes               INTEGER DEFAULT 0,
  comments            INTEGER DEFAULT 0,
  shares              INTEGER DEFAULT 0,
  clicks              INTEGER DEFAULT 0,
  recorded_at         TIMESTAMPTZ DEFAULT NOW(),
  created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS tasks (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  title             TEXT NOT NULL,
  description       TEXT,
  assigned_to       UUID REFERENCES users(id),
  created_by        TEXT,
  due_date          DATE,
  priority          TEXT DEFAULT 'medium',
  status            TEXT DEFAULT 'open',
  module_reference  TEXT,
  related_id        UUID,
  completed_at      TIMESTAMPTZ,
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS goals (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id     UUID REFERENCES agency(id) ON DELETE CASCADE,
  title         TEXT NOT NULL,
  description   TEXT,
  category      TEXT,
  target_value  NUMERIC(12,2),
  current_value NUMERIC(12,2) DEFAULT 0,
  unit          TEXT,
  target_date   DATE,
  status        TEXT DEFAULT 'active',
  created_by    TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW(),
  updated_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS settings (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id    UUID REFERENCES agency(id) ON DELETE CASCADE,
  setting_key  TEXT NOT NULL,
  setting_value TEXT,
  setting_type TEXT,
  description  TEXT,
  updated_by   TEXT,
  updated_at   TIMESTAMPTZ DEFAULT NOW(),
  created_at   TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agency_id, setting_key)
);

CREATE TABLE IF NOT EXISTS notification_preferences (
  id                UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id         UUID REFERENCES agency(id) ON DELETE CASCADE,
  user_id           UUID REFERENCES users(id) ON DELETE CASCADE,
  notification_type TEXT NOT NULL,
  channel           TEXT DEFAULT 'both',
  is_enabled        BOOLEAN DEFAULT TRUE,
  frequency         TEXT DEFAULT 'immediate',
  created_at        TIMESTAMPTZ DEFAULT NOW(),
  updated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS positions (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id        UUID REFERENCES agency(id) ON DELETE CASCADE,
  title            TEXT NOT NULL,
  department       TEXT,
  employment_type  TEXT,
  license_required BOOLEAN DEFAULT FALSE,
  license_type     TEXT,
  description      TEXT,
  requirements     TEXT,
  status           TEXT DEFAULT 'open',
  opened_date      DATE,
  filled_date      DATE,
  created_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS applicants (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id            UUID REFERENCES agency(id) ON DELETE CASCADE,
  position_id          UUID REFERENCES positions(id),
  first_name           TEXT NOT NULL,
  last_name            TEXT NOT NULL,
  email                TEXT,
  phone                TEXT,
  resume_document_id   UUID REFERENCES documents(id),
  resume_url           TEXT,
  claude_score         INTEGER,
  claude_summary       TEXT,
  interview_focus_doc  TEXT,
  source               TEXT DEFAULT 'email_auto',
  intake_email_id      TEXT,
  intake_received_at   TIMESTAMPTZ,
  status               TEXT DEFAULT 'new',
  created_at           TIMESTAMPTZ DEFAULT NOW(),
  updated_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS interviews (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id       UUID REFERENCES agency(id) ON DELETE CASCADE,
  applicant_id    UUID REFERENCES applicants(id) ON DELETE CASCADE,
  interview_date  TIMESTAMPTZ,
  interviewer     TEXT,
  format          TEXT,
  notes           TEXT,
  rating          INTEGER,
  recommendation  TEXT,
  created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS offers (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id            UUID REFERENCES agency(id) ON DELETE CASCADE,
  applicant_id         UUID REFERENCES applicants(id) ON DELETE CASCADE,
  offer_date           DATE,
  position             TEXT,
  start_date           DATE,
  base_pay             NUMERIC(10,2),
  commission_structure TEXT,
  benefits_summary     TEXT,
  offer_letter_doc_id  UUID REFERENCES documents(id),
  status               TEXT DEFAULT 'pending',
  response_date        DATE,
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS onboarding_checklists (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id     UUID REFERENCES agency(id) ON DELETE CASCADE,
  staff_id      UUID REFERENCES staff(id) ON DELETE CASCADE,
  template_type TEXT,
  item_name     TEXT NOT NULL,
  category      TEXT,
  due_date      DATE,
  completed_at  TIMESTAMPTZ,
  completed_by  TEXT,
  is_required   BOOLEAN DEFAULT TRUE,
  notes         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS commission_structures (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id            UUID REFERENCES agency(id) ON DELETE CASCADE,
  staff_id             UUID REFERENCES staff(id) ON DELETE CASCADE,
  structure_name       TEXT NOT NULL,
  effective_date       DATE NOT NULL,
  commission_type      TEXT,
  rate                 NUMERIC(5,2),
  cap                  NUMERIC(10,2),
  qualifying_products  TEXT[],
  notes                TEXT,
  is_active            BOOLEAN DEFAULT TRUE,
  created_at           TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS staff_performance (
  id                 UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  agency_id          UUID REFERENCES agency(id) ON DELETE CASCADE,
  staff_id           UUID REFERENCES staff(id) ON DELETE CASCADE,
  period_year        INTEGER NOT NULL,
  period_month       INTEGER NOT NULL,
  metric_name        TEXT NOT NULL,
  target             NUMERIC(12,2),
  actual             NUMERIC(12,2),
  achievement_pct    NUMERIC(5,2),
  notes              TEXT,
  created_at         TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(agency_id, staff_id, period_year, period_month, metric_name)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_alerts_agency_unresolved ON alerts(agency_id, is_resolved);
CREATE INDEX IF NOT EXISTS idx_journal_entries_date ON journal_entries(agency_id, entry_date);
CREATE INDEX IF NOT EXISTS idx_journal_lines_account ON journal_lines(account_id);
CREATE INDEX IF NOT EXISTS idx_comp_recap_period ON comp_recap(agency_id, period_year, period_month);
CREATE INDEX IF NOT EXISTS idx_content_calendar_scheduled ON content_calendar(agency_id, scheduled_date, status);
CREATE INDEX IF NOT EXISTS idx_automation_run_log_recipe ON automation_run_log(recipe_id, run_at);
CREATE INDEX IF NOT EXISTS idx_applicants_status ON applicants(agency_id, status);
CREATE INDEX IF NOT EXISTS idx_staff_performance_period ON staff_performance(agency_id, period_year, period_month);
CREATE INDEX IF NOT EXISTS idx_persistent_memory_category ON persistent_memory(agency_id, category);
CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(agency_id, processing_status);
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(agency_id, status, due_date);
CREATE INDEX IF NOT EXISTS idx_compliance_calendar_due ON compliance_calendar(agency_id, due_date, status);

-- RLS on all tables
ALTER TABLE agency ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE persistent_memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE bank_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE credit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll_detail ENABLE ROW LEVEL SECURITY;
ALTER TABLE comp_recap ENABLE ROW LEVEL SECURITY;
ALTER TABLE aipp_tracking ENABLE ROW LEVEL SECURITY;
ALTER TABLE scoreboard_tracking ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_calendar ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_run_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_briefing_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE content_calendar ENABLE ROW LEVEL SECURITY;
ALTER TABLE social_analytics ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE goals ENABLE ROW LEVEL SECURITY;
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE positions ENABLE ROW LEVEL SECURITY;
ALTER TABLE applicants ENABLE ROW LEVEL SECURITY;
ALTER TABLE interviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE onboarding_checklists ENABLE ROW LEVEL SECURITY;
ALTER TABLE commission_structures ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_performance ENABLE ROW LEVEL SECURITY;

-- updated_at trigger
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_agency_updated BEFORE UPDATE ON agency FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_persistent_memory_updated BEFORE UPDATE ON persistent_memory FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_staff_updated BEFORE UPDATE ON staff FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_bank_accounts_updated BEFORE UPDATE ON bank_accounts FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_credit_accounts_updated BEFORE UPDATE ON credit_accounts FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_automation_recipes_updated BEFORE UPDATE ON automation_recipes FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_social_accounts_updated BEFORE UPDATE ON social_accounts FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_tasks_updated BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_goals_updated BEFORE UPDATE ON goals FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_settings_updated BEFORE UPDATE ON settings FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_notification_prefs_updated BEFORE UPDATE ON notification_preferences FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_applicants_updated BEFORE UPDATE ON applicants FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER trg_commission_updated BEFORE UPDATE ON commission_structures FOR EACH ROW EXECUTE FUNCTION update_updated_at();
