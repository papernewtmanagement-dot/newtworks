CREATE TABLE IF NOT EXISTS opening_balances (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id     uuid NOT NULL,
  as_of_date    date NOT NULL,
  account_code  text NOT NULL,
  account_name  text NOT NULL,
  account_type  text NOT NULL,   -- asset | liability | equity
  opening_balance numeric NOT NULL,  -- natural sign: assets +, liabilities +, equity +
  source        text DEFAULT 'books_historical_balance_sheet_2026ytd_pdf',
  created_at    timestamptz DEFAULT now(),
  UNIQUE (agency_id, as_of_date, account_code)
);
