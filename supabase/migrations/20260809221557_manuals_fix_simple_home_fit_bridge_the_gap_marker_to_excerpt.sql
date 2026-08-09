-- Pre-existing bug, same class as the conversion just shipped: Simple Home FIT
-- carries '[Included from: Bridge the Gap]', but 'Bridge the Gap' has lived as a
-- manual_type='excerpt' row since the original Confluence excerpt recovery. The
-- include resolver only sees rows of the current manual_type, so this marker has
-- been rendering a yellow "Missing include" banner on the page rather than the
-- fragment. Repoint it at the excerpt resolver.
UPDATE manuals
   SET content = replace(content,
         '[Included from: Bridge the Gap]',
         '[Embedded excerpt from: Bridge the Gap]'),
       updated_at = now()
 WHERE agency_id = '126794dd-25ff-47d2-a436-724499733365'
   AND content LIKE '%[Included from: Bridge the Gap]%';
