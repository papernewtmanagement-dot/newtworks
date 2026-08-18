CREATE TABLE IF NOT EXISTS public.amazon_order_category_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id uuid NOT NULL,
  entity_name text NOT NULL,
  target_business_entity_id uuid NOT NULL REFERENCES public.business_entities(id),
  category_pattern text NOT NULL,
  gl_account_code text NOT NULL,
  category_label text NOT NULL,
  priority int NOT NULL DEFAULT 50,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_at timestamptz DEFAULT now()
);
ALTER TABLE public.amazon_order_category_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY amazon_order_category_rules_agency_isolation ON public.amazon_order_category_rules
  USING (agency_id = (current_setting('request.jwt.claims', true)::jsonb ->> 'agency_id')::uuid
         OR current_setting('request.jwt.claims', true) IS NULL);

INSERT INTO amazon_order_category_rules (agency_id, entity_name, target_business_entity_id, category_pattern, gl_account_code, category_label, priority, notes) VALUES
-- Agency (Peter Story State Farm) — break room / office / IT / repairs, matching the
-- entity-level groupings already used by the item-level rules for consistency.
('126794dd-25ff-47d2-a436-724499733365', 'Agency', 'b2222222-2222-2222-2222-222222222222', 'Grocery|Snack Foods|Beverages|Coffee|Kitchen|Appliance', '6160', 'Agency break room', 40, 'Order-level: subject-line category, not item detail'),
('126794dd-25ff-47d2-a436-724499733365', 'Agency', 'b2222222-2222-2222-2222-222222222222', 'Gift Card', '6160', 'Agency employee/client gifts', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Agency', 'b2222222-2222-2222-2222-222222222222', 'Wireless|Electronics|Computer', '6330', 'Agency computer equipment', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Agency', 'b2222222-2222-2222-2222-222222222222', 'Tool|Home Improvement', '6240', 'Agency building/repair', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Agency', 'b2222222-2222-2222-2222-222222222222', 'Storage|Essential', '6910', 'Agency office supplies', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Agency', 'b2222222-2222-2222-2222-222222222222', '.', '6160', 'Agency team relations (fallback)', 999, 'Order-level catch-all, mirrors item-level Agency fallback'),
-- PaperNewt LLC — giveaways / office+pantry / repairs
('126794dd-25ff-47d2-a436-724499733365', 'PaperNewt', 'b1111111-1111-1111-1111-111111111111', 'Grocery|Snack Foods|Beverages|Coffee|Kitchen|Appliance|Storage|Essential|Tool(?!.*Improvement)', '6910', 'PaperNewt office/kitchen supplies', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'PaperNewt', 'b1111111-1111-1111-1111-111111111111', 'Home Improvement', '6240', 'PaperNewt building/repair', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'PaperNewt', 'b1111111-1111-1111-1111-111111111111', 'Gift Card|^Toy|Book', '6400', 'PaperNewt giveaways', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'PaperNewt', 'b1111111-1111-1111-1111-111111111111', '.', '6400', 'PaperNewt giveaways (fallback)', 999, 'Order-level catch-all, mirrors item-level PaperNewt fallback'),
-- Personal — no catch-all fallback, matches item-level system's behavior
-- (unmatched Personal spend stays coded 0004 Unclassified rather than guessed)
('126794dd-25ff-47d2-a436-724499733365', 'Personal', 'b3333333-3333-3333-3333-333333333333', 'Apparel|Shoes|Luggage', '9250', 'Personal - Clothing', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Personal', 'b3333333-3333-3333-3333-333333333333', 'Grocery|Snack Foods|Beverages|Coffee', '9200', 'Personal - Groceries', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Personal', 'b3333333-3333-3333-3333-333333333333', 'Health Care|Drugstore|Beauty|Personal Care|Hair Care|Eyewear', '9500', 'Personal - Medical & Health', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Personal', 'b3333333-3333-3333-3333-333333333333', 'Storage|Home Improvement|^Tool|Essential|Kitchen|Appliance|D.cor|Bedding', '9120', 'Personal - Home Maintenance', 40, 'Order-level'),
('126794dd-25ff-47d2-a436-724499733365', 'Personal', 'b3333333-3333-3333-3333-333333333333', '^Toy|^Book', '9400', 'Personal - Kids', 40, 'Order-level');
