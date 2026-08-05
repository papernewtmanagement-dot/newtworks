#!/usr/bin/env python3
"""
bundle_edge_fn.py — generic single-file bundler for Newtworks edge functions.

Reads:  supabase/functions/<slug>/index.ts plus everything it imports locally,
        including the shared library at supabase/functions/_shared/*.ts
Writes: dist/<slug>.bundle.ts

Usage:
    python3 scripts/bundle_edge_fn.py <slug> [<slug> ...]
    python3 scripts/bundle_edge_fn.py --all-shared-consumers   # every fn that imports _shared

Why this exists:
    Newtworks edge functions deploy as SINGLE-FILE bundles via the canonical
    file_url deploy path (see op-rule "Supabase edge function deploy —
    canonical workflow"). Multi-file source with a shared `_shared/` library
    is how the repo stays DRY; this script flattens each function + its
    local/shared imports into one boot-clean file, exactly the way
    scripts/bundle_document_processor.py already does for document-processor.

Mechanics:
    - Walks local imports (./x.ts and ../_shared/x.ts) recursively from
      index.ts, topologically orders them (dependencies first, index.ts last).
    - Strips local import statements; hoists deduped external imports
      (jsr:/npm:/https:) to the top.
    - Strips `export ` keywords from shared-module declarations so the bundle
      has plain module-scope symbols (single module = no exports needed).
    - Validates: no leaked local imports, exactly one Deno.serve(, no
      duplicate top-level const/function declarations, non-trivial size.

Deploying a bundle (canonical path):
    1. Commit dist/<slug>.bundle.ts via scripts/commit_newtworks.py
    2. SUPABASE_DEPLOY_FUNCTION { ref, slug, file_url:
       "https://raw.githubusercontent.com/papernewtmanagement-dot/newtworks/<SHA>/dist/<slug>.bundle.ts" }
    3. Preserve the function's existing verify_jwt flag (check
       list_edge_functions BEFORE deploying; pass/update to match).

document-processor keeps its dedicated bundler (bundle_document_processor.py)
because of its hand-tuned rename table; every other function uses this one.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from collections import Counter
from pathlib import Path

FUNCTIONS_DIR = Path("supabase/functions")
SHARED_DIR = FUNCTIONS_DIR / "_shared"
DIST_DIR = Path("dist")

IMPORT_TARGET_RE = re.compile(r'''from\s+["']([^"']+)["']''')
SIDE_EFFECT_IMPORT_RE = re.compile(r'''^import\s+["']([^"']+)["']''')


def find_import_target(stmt: str) -> str | None:
    m = IMPORT_TARGET_RE.search(stmt)
    if m:
        return m.group(1)
    m = SIDE_EFFECT_IMPORT_RE.match(stmt.strip())
    if m:
        return m.group(1)
    return None


def read_import_statements(text: str) -> list[str]:
    """Return every full (possibly multi-line) import statement in the file."""
    stmts = []
    lines = text.split("\n")
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
            stmts.append(stmt)
            i = j + 1
            continue
        i += 1
    return stmts


def collect_files(entry: Path) -> list[Path]:
    """Depth-first post-order walk of local imports → deps first, entry last."""
    ordered: list[Path] = []
    visiting: set[Path] = set()
    done: set[Path] = set()

    def visit(path: Path) -> None:
        path = path.resolve()
        if path in done:
            return
        if path in visiting:
            raise ValueError(f"circular local import involving {path}")
        visiting.add(path)
        text = path.read_text(encoding="utf-8")
        for stmt in read_import_statements(text):
            target = find_import_target(stmt)
            if not target:
                continue
            if target.startswith("./") or target.startswith("../"):
                dep = (path.parent / target).resolve()
                if not dep.exists():
                    raise FileNotFoundError(f"{path} imports missing local file {target}")
                visit(dep)
        visiting.discard(path)
        done.add(path)
        ordered.append(path)

    visit(entry)
    return ordered


def strip_imports(text: str, externals_seen: dict[str, str]) -> str:
    """Remove local imports; collect first occurrence of each external."""
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
            out.append(stmt)
            i = j + 1
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def strip_export_keywords(text: str) -> str:
    """`export const X` → `const X` etc. Single-file bundles need no exports.
    Leaves `export default` untouched (none exist; would be a design error)."""
    return re.sub(r"^export\s+(?=(const|let|var|function|async|interface|type|class)\b)",
                  "", text, flags=re.MULTILINE)


def build_bundle(slug: str, repo_root: Path) -> tuple[str, list[Path]]:
    entry = repo_root / FUNCTIONS_DIR / slug / "index.ts"
    if not entry.exists():
        raise FileNotFoundError(f"no such function source: {entry}")
    ordered = collect_files(entry)

    externals: dict[str, str] = {}
    rendered: list[tuple[str, str]] = []
    for path in ordered:
        rel = path.relative_to((repo_root / FUNCTIONS_DIR).resolve())
        text = path.read_text(encoding="utf-8")
        text = strip_imports(text, externals)
        text = strip_export_keywords(text)
        rendered.append((str(rel), text))

    banner = (
        "// =========================================================================\n"
        f"// {slug} bundle (auto-generated)\n"
        f"// Source of truth: supabase/functions/{slug}/ + supabase/functions/_shared/\n"
        "// This single-file bundle is what gets deployed to the Supabase edge runtime.\n"
        f"// Do NOT hand-edit. Regenerate via `python3 scripts/bundle_edge_fn.py {slug}`.\n"
        "// =========================================================================\n"
    )
    parts = [banner]
    for stmt in externals.values():
        parts.append(stmt)
    parts.append("")
    for rel, text in rendered:
        parts.append("// ==================== " + rel + " ====================")
        parts.append(text)
    bundle = "\n".join(parts)
    if not bundle.endswith("\n"):
        bundle += "\n"
    return bundle, ordered


def validate(slug: str, bundle: str) -> None:
    if len(bundle) < 500:
        raise ValueError(f"{slug}: bundle suspiciously small ({len(bundle)} chars)")
    if re.search(r'^import[^;]*["\']\.\.?/', bundle, re.MULTILINE):
        raise ValueError(f"{slug}: local import survived into bundle")
    serves = bundle.count("Deno.serve(")
    if serves != 1:
        raise ValueError(f"{slug}: expected exactly one Deno.serve(, found {serves}")
    names = re.findall(r"^(?:const|let|var)\s+(\w+)\b", bundle, re.MULTILINE)
    names += re.findall(r"^(?:async\s+)?function\s+(\w+)\b", bundle, re.MULTILINE)
    dupes = {k: v for k, v in Counter(names).items() if v > 1}
    if dupes:
        raise ValueError(
            f"{slug}: top-level declaration collisions {dupes} — rename in the "
            f"function source (shared names win; locals must not shadow them)"
        )


def all_shared_consumers(repo_root: Path) -> list[str]:
    slugs = []
    for d in sorted((repo_root / FUNCTIONS_DIR).iterdir()):
        if not d.is_dir() or d.name == "_shared":
            continue
        idx = d / "index.ts"
        if idx.exists() and "_shared/" in idx.read_text(encoding="utf-8"):
            slugs.append(d.name)
    return slugs


def main() -> int:
    ap = argparse.ArgumentParser(description="Bundle Newtworks edge functions for deploy.")
    ap.add_argument("slugs", nargs="*", help="function slugs to bundle")
    ap.add_argument("--all-shared-consumers", action="store_true",
                    help="bundle every function whose index.ts imports _shared/")
    ap.add_argument("--repo-root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--out-dir", default=None, help="output dir (default: <repo-root>/dist)")
    args = ap.parse_args()

    repo_root = Path(args.repo_root).resolve()
    out_dir = Path(args.out_dir) if args.out_dir else repo_root / DIST_DIR
    out_dir.mkdir(parents=True, exist_ok=True)

    slugs = list(args.slugs)
    if args.all_shared_consumers:
        slugs += [s for s in all_shared_consumers(repo_root) if s not in slugs]
    if not slugs:
        print("nothing to bundle — pass slugs or --all-shared-consumers", file=sys.stderr)
        return 1

    for slug in slugs:
        bundle, files = build_bundle(slug, repo_root)
        validate(slug, bundle)
        out_path = out_dir / f"{slug}.bundle.ts"
        out_path.write_text(bundle, encoding="utf-8")
        sha = hashlib.sha256(bundle.encode("utf-8")).hexdigest()
        rels = ", ".join(p.name for p in files)
        print(f"{slug}: {len(bundle)} chars → {out_path}  [{rels}]", file=sys.stderr)
        print(f"{slug}: sha256 {sha}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
