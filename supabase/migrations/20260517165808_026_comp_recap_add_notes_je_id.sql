ALTER TABLE comp_recap ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE comp_recap ADD COLUMN IF NOT EXISTS journal_entry_id uuid REFERENCES journal_entries(id);
CREATE INDEX IF NOT EXISTS idx_comp_recap_posted ON comp_recap(agency_id, posted_at);
