INSERT INTO public.product_types (agency_id, line_of_business, type_key, label, sort_order, is_active) VALUES
  ('126794dd-25ff-47d2-a436-724499733365','life','term','Term Life',10,true),
  ('126794dd-25ff-47d2-a436-724499733365','life','whole','Whole Life',20,true),
  ('126794dd-25ff-47d2-a436-724499733365','life','universal','Universal Life',30,true),
  ('126794dd-25ff-47d2-a436-724499733365','health','disability_short_term','Short Term Disability Income',10,true),
  ('126794dd-25ff-47d2-a436-724499733365','health','hospital_income','Hospital Income',20,true),
  ('126794dd-25ff-47d2-a436-724499733365','business','business_insurance','Business Insurance',10,true),
  ('126794dd-25ff-47d2-a436-724499733365','business','contractors','Contractors',20,true),
  ('126794dd-25ff-47d2-a436-724499733365','business','workers_comp','Workers Compensation',30,true),
  ('126794dd-25ff-47d2-a436-724499733365','fire','manufactured_home','Manufactured Home',70,true),
  ('126794dd-25ff-47d2-a436-724499733365','fire','farm_ranch','Farm/Ranch',80,true),
  ('126794dd-25ff-47d2-a436-724499733365','fire','premises_liability','Premises/Personal Liability',90,true),
  ('126794dd-25ff-47d2-a436-724499733365','bank','credit_card','Credit Card',10,true)
ON CONFLICT DO NOTHING;
