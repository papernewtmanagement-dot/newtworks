#!/usr/bin/env python3
"""
Bundle document-processor edge function into a single-file deployable .ts

Reads:  supabase/functions/document-processor/*.ts (multi-file source)
Writes: dist/document-processor.bundle.ts (default; override via --out)

Why this exists:
    Supabase edge functions can be deployed multi-file (Deno resolves ./ imports
    at runtime) OR single-file bundle. This project deploys as a single-file
    bundle. Three parser files each declare `const SYSTEM_PROMPT` at module
    scope; concatenated naively that produces a SyntaxError at boot. This
    script renames them per-parser and produces a boot-clean bundle.

Deploying the bundle (from a Claude/Composio session):

    with open("dist/document-processor.bundle.ts") as f: body = f.read()
    run_composio_tool("SUPABASE_DEPLOY_FUNCTION", {
        "ref": "vulhdujhbwvibbojiimi",
        "slug": "document-processor",
        "file_content": body,
    })
    # DEPLOY_FUNCTION defaults verify_jwt=True. To match production semantics:
    run_composio_tool("SUPABASE_UPDATE_A_FUNCTION", {
        "ref": "vulhdujhbwvibbojiimi",
        "function_slug": "document-processor",
        "verify_jwt": False,
    })

DO NOT deploy code via SUPABASE_UPDATE_A_FUNCTION with a `body` arg. It
silently corrupts the deploy: the tool reports version=N status=ACTIVE but
every invocation returns BOOT_ERROR 503. Use DEPLOY_FUNCTION for source
changes; UPDATE only for settings (verify_jwt, name, slug) with NO body.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

# Canonical concat order — earlier files define symbols used by later files.
# Do NOT reorder without understanding the dependency chain.
ORDER = [
    "lib/supabase.ts",
    "lib/composio.ts",
    "lib/llm.ts",
    "classifier.ts",
    "gl-poster.ts",
    "suspense.ts",
    "parsers/bank.ts",
    "parsers/comp_recap.ts",
    "parsers/deduction.ts",
    "parsers/payroll.ts",
    "parsers/production.ts",
    "parsers/surepayroll.ts",
    "parsers/sf_daily_call_log.ts",
    "parsers/pfa_statement.ts",
    "index.ts",
]

# Files that declare a module-scoped `const SYSTEM_PROMPT` — rename per parser.
SYSTEM_PROMPT_RENAMES = {
    "parsers/bank.ts":       "SYSTEM_PROMPT_BANK",
    "parsers/payroll.ts":    "SYSTEM_PROMPT_PAYROLL",
    "parsers/production.ts": "SYSTEM_PROMPT_PRODUCTION",
    "parsers/pfa_statement.ts": "SYSTEM_PROMPT_PFA_STATEMENT",
}

BANNER = (
    "// =========================================================================\n"
    "// document-processor bundle (auto-generated)\n"
    "// Source of truth: supabase/functions/document-processor/*.ts (multi-file).\n"
    "// This single-file bundle is what gets deployed to the Supabase edge runtime.\n"
    "// Do NOT hand-edit. Regenerate via `python scripts/bundle_document_processor.py`.\n"
    "// =========================================================================\n"
)


def strip_imports(text: str, externals_seen: "dict[str, str]") -> str:
    """Remove local ./ or ../ imports; collect first-occurrence of each external
    (jsr:, npm:, https:) into externals_seen. Multi-line import statements
    (open brace across newlines) are handled.
    """
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("import"):
            stmt = line
            j = i
            while not stmt.rstrip().endswith(";"):
                j += 1
                if j >= len(lines):
                    break
                stmt += "\n" + lines[j]
            is_local = ('"./' in stmt) or ('"../' in stmt) or ("'./" in stmt) or ("'../" in stmt)
            is_external = ('"jsr:' in stmt) or ('"npm:' in stmt) or ('"https:' in stmt)
            if is_local:
                i = j + 1
                continue
            if is_external:
                m = re.search(r'"((?:jsr|npm|https)[^"]+)"', stmt)
                target = m.group(1) if m else None
                if target and target not in externals_seen:
                    externals_seen[target] = stmt.strip()
                i = j + 1
                continue
            # Unknown import shape (bare specifier, side-effect non-external) — keep
            out.append(stmt)
            i = j + 1
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def build_bundle(source_dir: Path) -> str:
    externals_seen = {}
    processed = {}
    for rel in ORDER:
        path = source_dir / rel
        if not path.exists():
            raise FileNotFoundError(f"missing source file: {path}")
        text = path.read_text(encoding="utf-8")
        if rel in SYSTEM_PROMPT_RENAMES:
            text = text.replace("SYSTEM_PROMPT", SYSTEM_PROMPT_RENAMES[rel])
        text = strip_imports(text, externals_seen)
        processed[rel] = text

    parts = [BANNER]
    for stmt in externals_seen.values():
        parts.append(stmt)
    parts.append("")
    for rel in ORDER:
        parts.append("// ==================== " + rel + " ====================")
        parts.append(processed[rel])
    bundle = "\n".join(parts)
    if not bundle.endswith("\n"):
        bundle += "\n"
    return bundle


def validate(bundle: str) -> None:
    """Structural sanity checks. Fail loud if any are wrong — that's boot failure
    waiting to happen."""
    # No local imports leaked
    if re.search(r'^import[^;]*"\.\.?/', bundle, re.MULTILINE):
        raise ValueError("local import survived into bundle")
    # SYSTEM_PROMPT collision must be resolved
    dupes = re.findall(r'^const SYSTEM_PROMPT\b', bundle, re.MULTILINE)
    if dupes:
        raise ValueError(f"bare `const SYSTEM_PROMPT` still present ({len(dupes)}x) — rename incomplete")
    # All three parser variants must be present
    for want in ("SYSTEM_PROMPT_BANK", "SYSTEM_PROMPT_PAYROLL", "SYSTEM_PROMPT_PRODUCTION", "SYSTEM_PROMPT_PFA_STATEMENT"):
        if want not in bundle:
            raise ValueError(f"expected {want} not in bundle")
    # Exactly one entry point
    if bundle.count("Deno.serve(run);") != 1:
        raise ValueError(f"expected exactly one `Deno.serve(run);`, found {bundle.count('Deno.serve(run);')}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Bundle document-processor for Supabase edge deploy.")
    ap.add_argument(
        "--source-dir",
        default="supabase/functions/document-processor",
        help="source directory (default: supabase/functions/document-processor)",
    )
    ap.add_argument(
        "--out",
        default="dist/document-processor.bundle.ts",
        help="output path (default: dist/document-processor.bundle.ts)",
    )
    ap.add_argument("--stdout", action="store_true", help="write to stdout instead of file")
    args = ap.parse_args()

    src_dir = Path(args.source_dir)
    if not src_dir.is_dir():
        print(f"source dir not found: {src_dir}", file=sys.stderr)
        return 1

    bundle = build_bundle(src_dir)
    validate(bundle)
    sha = hashlib.sha256(bundle.encode("utf-8")).hexdigest()

    if args.stdout:
        sys.stdout.write(bundle)
    else:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(bundle, encoding="utf-8")
        print(f"wrote {len(bundle)} chars to {out_path}", file=sys.stderr)
        print(f"sha256: {sha}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
