#!/usr/bin/env python3
"""
check_react_hooks.py — catch React hooks that a file uses but never imports.

Why this exists:
    An esbuild parse check proves a file is valid JavaScript. It does NOT
    prove every name the file uses actually exists. A useMemo that was never
    added to the React import line parses perfectly and then throws
    "useMemo is not defined" in the browser the first time that component
    renders. That shipped once. This stops it shipping again.

What it checks, per .jsx / .tsx / .js / .ts file under src/:
    Every React hook name the file CALLS must appear in one of
      import { useMemo, ... } from "react"
      import React, { useMemo } from "react"
      import * as React from "react"          (namespace covers everything)
    Calls written as React.useMemo(...) are fine on their own.
    Hooks declared locally in the same file (custom hooks, or a destructure
    off another import) are fine too.

Usage:
    python3 scripts/check_react_hooks.py                # scan src/
    python3 scripts/check_react_hooks.py path [path..]  # scan named files
    exit 0 = clean, exit 1 = at least one missing import
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
EXTS = (".jsx", ".tsx", ".js", ".ts")

# Built-in React hooks. Anything called as useX( that is not on this list is
# treated as a custom hook and must simply be defined or imported somewhere.
REACT_HOOKS = {
    "useState", "useEffect", "useContext", "useReducer", "useCallback",
    "useMemo", "useRef", "useImperativeHandle", "useLayoutEffect",
    "useDebugValue", "useDeferredValue", "useTransition", "useId",
    "useSyncExternalStore", "useInsertionEffect", "useActionState",
    "useOptimistic", "useFormStatus",
}

# Two passes. Comments are always stripped. Strings are stripped ONLY for
# call detection — stripping them for import detection would erase the
# "react" in `from "react"` and make every import look absent.
def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"(?m)//.*$", " ", src)
    return src


def strip_noise(src: str) -> str:
    src = strip_comments(src)
    src = re.sub(r"`(?:\\.|[^`\\])*`", '""', src, flags=re.S)
    src = re.sub(r"'(?:\\.|[^'\\\n])*'", '""', src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    return src


def react_import_names(src: str):
    """Names pulled off the react module, plus whether it is a namespace import.

    Each import statement is matched on its own. An earlier pattern let the
    match run across intervening import lines, so a file whose react import
    was not the first import read its names off the wrong statement and every
    hook looked un-imported.
    """
    names = set()
    namespace = False
    # [^;] cannot cross a statement terminator, so one match = one import.
    for m in re.finditer(
        r"""(?m)^[ \t]*import\s+([^;]*?)\s+from\s+['"]([^'"]+)['"]""", src
    ):
        clause, module = m.group(1), m.group(2)
        if module != "react":
            continue
        if re.search(r"\*\s+as\s+\w+", clause):
            namespace = True
        brace = re.search(r"\{(.*?)\}", clause, flags=re.S)
        if brace:
            for part in brace.group(1).split(","):
                part = part.strip()
                if not part:
                    continue
                # handle "useMemo as memo"
                names.add(part.split()[0].strip())
    return names, namespace


def locally_defined(src: str, name: str) -> bool:
    if re.search(r"\b(?:function|const|let|var)\s+%s\b" % re.escape(name), src):
        return True
    # destructured from anything, or imported from somewhere other than react
    if re.search(r"\{[^{}]*\b%s\b[^{}]*\}\s*=" % re.escape(name), src):
        return True
    if re.search(
        r"""import\s+\{[^}]*\b%s\b[^}]*\}\s+from\s+['"](?!react['"])"""
        % re.escape(name),
        src,
        flags=re.S,
    ):
        return True
    return False


def check_source(raw: str):
    """The one implementation. Returns [(hook, line), ...] for a file's text.

    commit_newtworks.py calls this directly on the content it is about to
    push, so the gate sees the post-patch file and not whatever is on disk.
    """
    if "react" not in raw:
        return []
    code = strip_noise(raw)          # for call detection
    decls = strip_comments(raw)      # for import / declaration detection
    imported, namespace = react_import_names(decls)
    if namespace:
        return []

    problems = []
    for hook in sorted(REACT_HOOKS):
        # a bare call: useMemo(  — not React.useMemo( and not .useMemo(
        if not re.search(r"(?<![.\w])%s\s*\(" % hook, code):
            continue
        if hook in imported or locally_defined(decls, hook):
            continue
        line = 0
        for i, l in enumerate(raw.split("\n"), 1):
            if re.search(r"(?<![.\w])%s\s*\(" % hook, l):
                line = i
                break
        problems.append((hook, line))
    return problems


def check_file(path: str):
    return check_source(open(path, encoding="utf-8", errors="replace").read())


def main():
    targets = sys.argv[1:]
    if targets:
        files = [t for t in targets if t.endswith(EXTS)]
    else:
        files = []
        for base, dirs, names in os.walk(SRC):
            dirs[:] = [d for d in dirs if d != "node_modules"]
            files += [os.path.join(base, n) for n in names if n.endswith(EXTS)]

    bad = 0
    for f in sorted(files):
        for hook, line in check_file(f):
            rel = os.path.relpath(f, ROOT)
            print(f"{rel}:{line}: {hook} is called but never imported from react")
            bad += 1

    if bad:
        print(f"\n{bad} missing hook import(s). Add them to the react import line.")
        return 1
    print(f"react hook imports clean across {len(files)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
