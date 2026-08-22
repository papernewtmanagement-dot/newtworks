UPDATE public.alerts
SET is_resolved = true, message = message || ' UPDATE 2026-08-06: Q1b ruling confirmed the served set IS exactly the Periatt, LeMay & Chakrabarty (2004) 10-item short form (items 365-374 active, all 24 original Saxe & Weitz items inactive) -- source_scale corrected accordingly, no item-bank conflict remains. Two genuine retrieval attempts made for the paper''s own descriptive statistics (customer-orientation subscale, 5 items): direct fetch of the ResearchGate PDF was rate-limited (429), and a follow-up search did not surface the table. Superseded by a fresh alert for the remaining norms-only gap.'
WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
  AND alert_type = 'hiregauge_norm_missing'
  AND title = 'HireGauge norm missing: customer_orientation'
  AND is_resolved = false;

INSERT INTO public.alerts (agency_id, alert_type, severity, title, module_reference, is_resolved, message)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
  'HireGauge norm missing: customer_orientation (source resolved, stats still needed)',
  'hiring_assessment', false,
  'Source of record confirmed per Q1b ruling: SOCO short form, Periatt, LeMay & Chakrabarty (2004), J. Personal Selling & Sales Management 24(1):49-54, customer-orientation subscale (5 of the 10 items; the other 5 are the selling-orientation subscale, not this facet). Conversion note per ruling: use SOCO''s original published scale range (1-9) when converting, not our 5-point administration. Still needs the paper''s own reported mean/SD for the customer-orientation subscale, or an occupational reference-sample source per the reference-population allowance (employed salespeople acceptable, R4 only bans sex/age splits).');
