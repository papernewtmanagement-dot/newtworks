DO $$
DECLARE
    t text;
    policy_name text;
    policy_exists boolean;
BEGIN
    FOR t IN
        SELECT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables tt
          ON tt.table_schema = c.table_schema
         AND tt.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND c.column_name = 'agency_id'
          AND tt.table_type = 'BASE TABLE'
        ORDER BY c.table_name
    LOOP
        policy_name := 'anon_read_' || t;
        SELECT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'public' AND tablename = t AND policyname = policy_name
        ) INTO policy_exists;
        IF NOT policy_exists THEN
            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR SELECT TO anon USING (true)',
                policy_name, t
            );
        END IF;
    END LOOP;
END $$;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
