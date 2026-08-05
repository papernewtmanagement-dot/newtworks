CREATE TABLE IF NOT EXISTS public.gl_sign_audit_20260805 (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action text NOT NULL,              -- delete_dup_untyped | delete_pmt_dup | delete_xsource_refund_dup | flip_je | repoint_leg | fuzzy_delete_untyped
  reason text,
  ct_id uuid,
  je_id uuid,
  keep_je_id uuid,                   -- for dup deletions: the JE that remains authoritative
  ct_snapshot jsonb,
  je_snapshot jsonb,
  jl_snapshot jsonb,                 -- array of the JE's lines
  executed_at timestamptz,
  created_at timestamptz DEFAULT now()
);
COMMENT ON TABLE public.gl_sign_audit_20260805 IS 'Reversible snapshot of the 2026-08-05 journal sign/duplicate cleanup. Every deleted or modified row is captured here in full before execution.';
