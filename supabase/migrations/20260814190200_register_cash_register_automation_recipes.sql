-- Registers the two Step 6 automation recipes for the cash-register-first
-- ledger build: posting every 2 hours, and a nightly not-on-statement check.
INSERT INTO automation_recipes (agency_id, recipe_name, recipe_description, trigger_type, cron_expression, internal_handler, output_table, timezone, is_active)
VALUES
('126794dd-25ff-47d2-a436-724499733365', 'Cash Register GL Writer', 'Posts cash-register (bank-alert) rows to the ledger every 2 hours, holding entries in unclassified suspense until a statement claims them. Suppresses same-day same-amount internal transfers before posting.', 'cron', '0 */2 * * *', 'run_cash_register_gl_writer', 'ledger', 'America/Chicago', true),
('126794dd-25ff-47d2-a436-724499733365', 'Not-On-Statement Nightly Check', 'Raises one alert per account per statement period when a cash-register-sourced ledger row was never claimed by that period''s statement.', 'cron', '0 6 * * *', 'raise_not_on_statement_alerts', 'alerts', 'America/Chicago', true)
ON CONFLICT DO NOTHING;
