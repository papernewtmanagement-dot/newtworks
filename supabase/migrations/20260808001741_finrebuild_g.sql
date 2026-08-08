-- Peter directive: restaurants on card 1003 (chart code 2141, PaperNewt) -> business meals.
-- Restaurants on card 3447 and its sub cards 4676/3439 (all one accounts row, chart code 2113,
-- Peter Story State Farm) -> business meals. Amazon on either -> that entity's unclassified expense.
-- Account code 6860 and 0003 both exist per entity; cc_gl_writer resolves the code inside the
-- card's own entity first, so one code serves both cards correctly.
-- Both debit_account_code and credit_account_code are set to the target so refunds post as a
-- negative expense to the same account instead of falling through.
-- match_priority is ASCENDING preference in cc_gl_writer -- lower number wins.

INSERT INTO public.gl_classification_rules
 (agency_id, rule_name, match_priority, match_payee_regex, match_source_account,
  match_direction, debit_account_code, credit_account_code, sub_category_label,
  confidence, source, is_active)
VALUES
 ('126794dd-25ff-47d2-a436-724499733365',
  'Amazon on AMEX 1003 -> PaperNewt unclassified expense', 15,
  '(AMAZON|AMZN)', '2141', 'both', '0003', '0003', 'Amazon pending review',
  'high', 'peter_directive', true),

 ('126794dd-25ff-47d2-a436-724499733365',
  'Amazon on US Bank 3447 family -> agency unclassified expense', 15,
  '(AMAZON|AMZN)', '2113', 'both', '0003', '0003', 'Amazon pending review',
  'high', 'peter_directive', true),

 ('126794dd-25ff-47d2-a436-724499733365',
  'Restaurants on AMEX 1003 -> PaperNewt business meals', 20,
  '(TST\*|UEP\*|CKE\*|FH\*|MARCOS PIZZA|JERSEY MIKE|TACO SHOP|TAQUITO|TAQUERIA|WINGSTOP|WHATABURGER|ANGKOR BISTRO|CHICK-FIL-A|SMOKEY MOS|RED ROBIN|BAKUDAN|LAS PALAPAS|ISLAND BAR|POPEYES|HESTERS|TORTUGAS|ISLAND CAFE|BLUE BONNET|LA HACIENDA|KUMI BUFFET|COAL OVEN PIZZA|SO SEOUL|THE GAFF|KERROW|SEAFOOD & SPAGHETTI|HORSESHOE BAY RESTAURANT|C-TREATS|MCDONALD|STARBUCKS|CHIPOTLE|PANDA EXPRESS|SUBWAY|PIZZA HUT|DOMINO|TACO CABANA|BILL MILLER|SONIC DRIVE|BURGER KING|WENDY|IHOP|CRACKER BARREL|OLIVE GARDEN|APPLEBEE|BUFFALO WILD|TORCHY|FREEBIRDS|SALTGRASS|TEXAS ROADHOUSE|LONGHORN|PAPPADEAUX|PANERA|DUNKIN|CAFE|BISTRO|CANTINA|GRILL|RESTAURANT|STEAKHOUSE|BREWING|BREWERY|SUSHI|RAMEN|BBQ|BAR-B)',
  '2141', 'both', '6860', '6860', 'Business meals',
  'high', 'peter_directive', true),

 ('126794dd-25ff-47d2-a436-724499733365',
  'Restaurants on US Bank 3447 family -> agency business meals', 20,
  '(TST\*|UEP\*|CKE\*|FH\*|MARCOS PIZZA|JERSEY MIKE|TACO SHOP|TAQUITO|TAQUERIA|WINGSTOP|WHATABURGER|ANGKOR BISTRO|CHICK-FIL-A|SMOKEY MOS|RED ROBIN|BAKUDAN|LAS PALAPAS|ISLAND BAR|POPEYES|HESTERS|TORTUGAS|ISLAND CAFE|BLUE BONNET|LA HACIENDA|KUMI BUFFET|COAL OVEN PIZZA|SO SEOUL|THE GAFF|KERROW|SEAFOOD & SPAGHETTI|HORSESHOE BAY RESTAURANT|C-TREATS|MCDONALD|STARBUCKS|CHIPOTLE|PANDA EXPRESS|SUBWAY|PIZZA HUT|DOMINO|TACO CABANA|BILL MILLER|SONIC DRIVE|BURGER KING|WENDY|IHOP|CRACKER BARREL|OLIVE GARDEN|APPLEBEE|BUFFALO WILD|TORCHY|FREEBIRDS|SALTGRASS|TEXAS ROADHOUSE|LONGHORN|PAPPADEAUX|PANERA|DUNKIN|CAFE|BISTRO|CANTINA|GRILL|RESTAURANT|STEAKHOUSE|BREWING|BREWERY|SUSHI|RAMEN|BBQ|BAR-B)',
  '2113', 'both', '6860', '6860', 'Business meals',
  'high', 'peter_directive', true);