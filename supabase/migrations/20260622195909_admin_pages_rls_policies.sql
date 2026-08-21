-- Mirror the policy pattern from handbook + playbook on admin_pages.
-- Frontend nav gate (roles: ["owner"] in BCCApp.jsx) is the visibility control;
-- DB is permissive like the rest of the BCC pattern.
CREATE POLICY anon_all_admin_pages ON public.admin_pages
  FOR ALL TO anon USING (true);

CREATE POLICY authenticated_all_admin_pages ON public.admin_pages
  FOR ALL TO authenticated USING (true);
