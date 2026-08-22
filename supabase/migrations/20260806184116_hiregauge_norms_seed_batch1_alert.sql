INSERT INTO public.alerts (agency_id, alert_type, severity, title, module_reference, is_resolved, message)
VALUES ('126794dd-25ff-47d2-a436-724499733365', 'hiregauge_norm_missing', 'warning',
  'HireGauge norm missing: emotional_stability',
  'hiring_assessment', false,
  'HireGauge norms seed: no row inserted for facet "emotional_stability". This Newtworks facet is NOT an IPIP-NEO-120 facet (verified against hiregauge_instrument_items — it is built from Goldberg''s separate 10-item IPIP Big-Five Neuroticism marker scale, reverse-keyed). Attempted source: Gow, Whiteman, Pattie & Deary (2005), Personality and Individual Differences 39(2):317-329 — could not retrieve a clean combined-sample mean/SD from that paper''s tables in this pass (fetch rate-limited). Facet renders as "—" in the UI until resolved. Needs either a successful fetch of the Gow et al. 2005 full table, or a different named source for this specific 10-item scale.');
