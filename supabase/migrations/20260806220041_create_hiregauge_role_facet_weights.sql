CREATE TABLE IF NOT EXISTS hiregauge_role_facet_weights (
  agency_id uuid NOT NULL,
  role_category text NOT NULL,
  input_name text NOT NULL,
  weight smallint NOT NULL CHECK (weight IN (-1,0,1,2,3)),
  basis_type text NOT NULL CHECK (basis_type IN ('meta_analysis','study','job_analysis')),
  citation text NOT NULL,
  notes text,
  updated_at timestamptz DEFAULT now(),
  updated_by text,
  UNIQUE(agency_id, role_category, input_name)
);

ALTER TABLE hiregauge_role_facet_weights ENABLE ROW LEVEL SECURITY;

CREATE POLICY anon_read_hiregauge_role_facet_weights
  ON hiregauge_role_facet_weights
  FOR SELECT
  TO authenticated
  USING (true);
