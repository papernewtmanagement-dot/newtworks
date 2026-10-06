-- Gridstrike bucket: allow the computer version of the game (one HTML file at game/index.html) alongside the PDFs.
-- Idempotent: adds text/html only if it is not already in the list.
UPDATE storage.buckets
SET allowed_mime_types = array_append(allowed_mime_types, 'text/html')
WHERE id = 'gridstrike' AND NOT ('text/html' = ANY(allowed_mime_types));
