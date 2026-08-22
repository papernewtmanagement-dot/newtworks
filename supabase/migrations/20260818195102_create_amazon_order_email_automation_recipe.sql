INSERT INTO automation_recipes (
  agency_id, recipe_name, recipe_description, trigger_type, cron_expression,
  internal_handler, input_config, is_active, timezone
) VALUES (
  '126794dd-25ff-47d2-a436-724499733365',
  'Amazon Order Email Capture',
  'Every 30 min: pulls unstarred Amazon order-confirmation emails (auto-confirm@amazon.com, filtered into Label_12 Operations/Amazon Transactions) from paper.newt.management@gmail.com, extracts order#/category/ship-to/grand-total, upserts into amazon_orders (source=email_live), stars processed messages, and calls match_amazon_orders_to_cash_register() to resolve entity/card attribution for any newly-matchable orders against recent bank-alert transactions. Built 2026-08-18.',
  'cron',
  '*/30 * * * *',
  'dispatch_document_processor',
  '{"mode": "amazon_order_email", "max_results": 100}'::jsonb,
  true,
  'America/Chicago'
);
