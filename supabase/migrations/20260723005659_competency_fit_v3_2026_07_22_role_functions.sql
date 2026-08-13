-- Mirrored 2026-08-13 during the un-mirrored-migration audit.
-- This migration was applied live on 2026-07-23 00:56:59 UTC (ledger name: competency_fit_v3_2026_07_22_role_functions) but was never
-- committed to this repo at the time. Content below is copied verbatim
-- from supabase_migrations.schema_migrations.statements for version 20260723005659.
-- No live change is made by adding this file — it only brings the repo
-- mirror into sync with what is already running in production, so a
-- fresh `supabase db reset` from this repo reproduces live state.
-- v3 role-fit functions, blind theory-derived weights
CREATE OR REPLACE FUNCTION public.competency_fit_v3_sales_outbound(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((20*dm + 15*rd + 15*asrt + 15*is_ + 5*an + 5*co + 10*sp + 0*bo + 15*op)/100.0, 1) $$;

CREATE OR REPLACE FUNCTION public.competency_fit_v3_sales_inbound(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((10*dm + 10*rd + 10*asrt + 0*is_ + 10*an + 20*co + 15*sp + 15*bo + 10*op)/100.0, 1) $$;

CREATE OR REPLACE FUNCTION public.competency_fit_v3_sales_in_book(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((15*dm + 10*rd + 15*asrt + 10*is_ + 20*an + 10*co + 0*sp + 10*bo + 10*op)/100.0, 1) $$;

CREATE OR REPLACE FUNCTION public.competency_fit_v3_retention_reception(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((10*dm + 0*rd + 5*asrt + 5*is_ + 10*an + 25*co + 10*sp + 20*bo + 15*op)/100.0, 1) $$;

CREATE OR REPLACE FUNCTION public.competency_fit_v3_retention_escalation(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((15*dm + 10*rd + 15*asrt + 5*is_ + 20*an + 15*co + 0*sp + 10*bo + 10*op)/100.0, 1) $$;

CREATE OR REPLACE FUNCTION public.competency_fit_v3_retention_support(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((20*dm + 0*rd + 5*asrt + 20*is_ + 20*an + 10*co + 5*sp + 10*bo + 10*op)/100.0, 1) $$;

CREATE OR REPLACE FUNCTION public.competency_fit_v3_aspirant(
  dm int, rd int, asrt int, is_ int, an int, co int, sp int, bo int, op int
) RETURNS numeric LANGUAGE sql IMMUTABLE AS
$$ SELECT ROUND((15*dm + 15*rd + 15*asrt + 15*is_ + 10*an + 10*co + 0*sp + 5*bo + 15*op)/100.0, 1) $$;
