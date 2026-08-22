-- Amazon transaction records, used to cross-reference cash-register / ledger entries
-- so Amazon charges can be sorted to the right category instead of landing in Unclassified.

CREATE TABLE IF NOT EXISTS public.amazon_orders (
    order_id text PRIMARY KEY,
    agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
    order_date timestamptz,
    order_status text,
    website text,
    currency text,
    ship_to_name text,
    ship_to_address text,
    payment_method_raw text,
    payment_card_network text,
    payment_card_last4 text,
    target_business_entity_id uuid REFERENCES public.business_entities(id),
    grand_total numeric,
    item_count integer,
    matched_ledger_id uuid REFERENCES public.ledger(id),
    matched_at timestamptz,
    source text NOT NULL DEFAULT 'csv_import',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.amazon_order_items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id text NOT NULL REFERENCES public.amazon_orders(order_id) ON DELETE CASCADE,
    agency_id uuid NOT NULL DEFAULT '126794dd-25ff-47d2-a436-724499733365',
    asin text,
    product_name text,
    product_condition text,
    original_quantity integer,
    unit_price numeric,
    unit_price_tax numeric,
    shipment_item_subtotal numeric,
    shipment_item_subtotal_tax numeric,
    total_discounts numeric,
    total_amount numeric,
    shipping_charge numeric,
    shipping_option text,
    shipment_status text,
    ship_date timestamptz,
    carrier_tracking text,
    purchase_order_number text,
    gift_recipient_contact text,
    gift_sender_name text,
    item_serial_number text,
    gl_account_code text,
    category_label text,
    classified_at timestamptz,
    source text NOT NULL DEFAULT 'csv_import',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_amazon_orders_date ON public.amazon_orders(order_date);
CREATE INDEX IF NOT EXISTS idx_amazon_orders_entity ON public.amazon_orders(target_business_entity_id);
CREATE INDEX IF NOT EXISTS idx_amazon_orders_matched ON public.amazon_orders(matched_ledger_id);
CREATE INDEX IF NOT EXISTS idx_amazon_order_items_order ON public.amazon_order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_amazon_order_items_asin ON public.amazon_order_items(asin);

ALTER TABLE public.amazon_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.amazon_order_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY amazon_orders_agency_isolation ON public.amazon_orders
    FOR ALL USING (agency_id = '126794dd-25ff-47d2-a436-724499733365');
CREATE POLICY amazon_order_items_agency_isolation ON public.amazon_order_items
    FOR ALL USING (agency_id = '126794dd-25ff-47d2-a436-724499733365');

