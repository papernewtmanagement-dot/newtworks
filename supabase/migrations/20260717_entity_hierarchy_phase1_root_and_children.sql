-- Phase 1: Financials entity hierarchy foundation
-- Adds a personal root (Peter Story), reparents PaperNewt LLC under it,
-- and adds two operating children under PaperNewt (Story Business Admin, Eriosto).
-- EINs left NULL — Peter fills via UPDATE later. Individual (personal) uses SSN, no EIN.
-- Eriosto entity_type=exploration pending Peter confirmation.

INSERT INTO public.business_entities
  (id, agency_id, name, slug, entity_type, parent_entity_id, status, description, ein)
VALUES
  (
    'b3333333-3333-3333-3333-333333333333',
    '126794dd-25ff-47d2-a436-724499733365',
    'Peter Story',
    'personal',
    'personal',
    NULL,
    'active',
    'Individual / household. Root of the consolidated books hierarchy. Personal income and expenses live here; S-Corp distributions from PaperNewt LLC flow up as equity. Uses SSN, no EIN.',
    NULL
  ),
  (
    'b4444444-4444-4444-4444-444444444444',
    '126794dd-25ff-47d2-a436-724499733365',
    'Story Business Administration',
    'story-ba',
    'sole_prop',
    'b1111111-1111-1111-1111-111111111111',
    'active',
    'Sole proprietorship under PaperNewt LLC. Business administrative services. EIN pending — populate business_entities.ein when confirmed.',
    NULL
  ),
  (
    'b5555555-5555-5555-5555-555555555555',
    '126794dd-25ff-47d2-a436-724499733365',
    'Eriosto',
    'eriosto',
    'exploration',
    'b1111111-1111-1111-1111-111111111111',
    'active',
    'Under PaperNewt LLC. Entity type placeholder (exploration) — Peter to confirm actual type (llc / sole_prop / s_corp) and set EIN.',
    NULL
  );

-- Reparent PaperNewt LLC under the personal root.
UPDATE public.business_entities
SET parent_entity_id = 'b3333333-3333-3333-3333-333333333333',
    updated_at = NOW()
WHERE id = 'b1111111-1111-1111-1111-111111111111';
