#!/usr/bin/env python3
"""
commit_newtworks.py — Direct GitHub API commit tool for the newtworks repo.

Replaces Composio-based commit paths. Uses fine-grained PAT stored in
public.settings (loaded via GH_TOKEN env var) and calls api.github.com
directly. No workbench, no MCP transport envelope, no encoding traps.

Usage:
  python3 commit_newtworks.py <repo_path> \
      --replace OLD NEW [--replace OLD2 NEW2 ...] \
      [--count N ...] \
      [--content-file LOCAL_PATH] \
      --message "commit message" \
      [--branch main] \
      [--dry-run]

Patch mode (most common):
  python3 commit_newtworks.py src/modules/Foo.jsx \
      --replace 'oldString' 'newString' \
      --message 'fix: rename foo'

  Each --replace pair verified for exact-count match before committing.
  Default requires count >= 1 for each pattern. Use --count N to require
  exactly N occurrences (one --count per --replace, in order).

Overwrite mode:
  python3 commit_newtworks.py path/in/repo \
      --content-file /home/claude/local_edited.jsx \
      --message 'refactor: rewrite Foo'

Dry-run: apply patches locally, print diff stats, do NOT commit.

Env: GH_TOKEN must be set. Load from /home/claude/.gh_pat or Supabase settings.
"""

import argparse
import base64
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

OWNER = "papernewtmanagement-dot"
REPO = "newtworks"
API = f"https://api.github.com/repos/{OWNER}/{REPO}"


def die(msg, code=1):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(code)


def gh_request(method, path, body=None):
    token = os.environ.get("GH_TOKEN")
    if not token:
        die("GH_TOKEN not set. Load from /home/claude/.gh_pat or Supabase settings.")
    url = f"{API}{path}" if path.startswith("/") else f"{API}/{path}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=60) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            err_body = json.loads(raw)
        except Exception:
            err_body = {"error": raw}
        return e.code, err_body


def fetch_file(path, branch="main"):
    status, data = gh_request("GET", f"/contents/{path}?ref={branch}")
    if status != 200:
        die(f"Fetch failed ({status}): {json.dumps(data)[:400]}")
    if data.get("encoding") != "base64":
        die(f"Unexpected encoding: {data.get('encoding')}")
    content_b64 = data["content"].replace("\n", "")
    content = base64.b64decode(content_b64).decode("utf-8")
    return {"sha": data["sha"], "content": content, "size": data.get("size")}


def commit_file(path, new_content, sha, message, branch="main"):
    body = {
        "message": message,
        "content": base64.b64encode(new_content.encode("utf-8")).decode("ascii"),
        "sha": sha,
        "branch": branch,
    }
    status, data = gh_request("PUT", f"/contents/{path}", body=body)
    if status not in (200, 201):
        die(f"Commit failed ({status}): {json.dumps(data)[:400]}")
    return data["commit"]["sha"]


def create_file(path, new_content, message, branch="main"):
    """Create a new file (no sha, since none exists yet)."""
    body = {
        "message": message,
        "content": base64.b64encode(new_content.encode("utf-8")).decode("ascii"),
        "branch": branch,
    }
    status, data = gh_request("PUT", f"/contents/{path}", body=body)
    if status not in (200, 201):
        die(f"Create failed ({status}): {json.dumps(data)[:400]}")
    return data["commit"]["sha"]


def apply_replacements(src, replacements):
    for old, new, expected in replacements:
        found = src.count(old)
        if expected is not None and found != expected:
            die(f"Count mismatch: expected {expected}, found {found} for {repr(old[:120])}")
        if expected is None and found == 0:
            die(f"Pattern not found: {repr(old[:120])}")
        src = src.replace(old, new)
    return src


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("path", help="Path in repo (e.g. src/modules/CPRDetail.jsx)")
    ap.add_argument("--replace", nargs=2, action="append", metavar=("OLD", "NEW"), default=[])
    ap.add_argument("--count", type=int, action="append", default=[],
                    help="Expected occurrence count per --replace (positional match)")
    ap.add_argument("--content-file", help="Local file whose content replaces remote entirely")
    ap.add_argument("--message", required=True)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--create", action="store_true",
                    help="Create new file (no existing remote file expected)")
    args = ap.parse_args()

    if args.replace and args.content_file:
        die("Use --replace OR --content-file, not both.")
    if not args.replace and not args.content_file:
        die("Nothing to do. Pass --replace or --content-file.")

    # CREATE path (no fetch, no sha)
    if args.create:
        if not args.content_file:
            die("--create requires --content-file")
        with open(args.content_file, "rb") as f:
            new_content = f.read().decode("utf-8")
        new_sha256 = hashlib.sha256(new_content.encode("utf-8")).hexdigest()
        print(f"[create] {args.path} — {len(new_content)} bytes (sha256={new_sha256[:12]})")
        if args.dry_run:
            print("[dry-run] Not committing.")
            return
        commit_sha = create_file(args.path, new_content, args.message, args.branch)
        print(f"[commit] {commit_sha}")
        print(f"[link] https://github.com/{OWNER}/{REPO}/commit/{commit_sha}")
        return

    # PATCH or OVERWRITE path
    current = fetch_file(args.path, args.branch)
    print(f"[fetch] {args.path} @ {current['sha'][:12]} — {current['size']} bytes")

    if args.content_file:
        with open(args.content_file, "rb") as f:
            new_content = f.read().decode("utf-8")
    else:
        counts = args.count + [None] * (len(args.replace) - len(args.count))
        replacements = [(o, n, c) for (o, n), c in zip(args.replace, counts)]
        new_content = apply_replacements(current["content"], replacements)

    if new_content == current["content"]:
        print("[skip] Content unchanged, nothing to commit.")
        return

    new_sha256 = hashlib.sha256(new_content.encode("utf-8")).hexdigest()
    print(f"[diff] {len(current['content'])} → {len(new_content)} bytes (sha256={new_sha256[:12]})")

    if args.dry_run:
        print("[dry-run] Not committing.")
        return

    commit_sha = commit_file(args.path, new_content, current["sha"], args.message, args.branch)
    print(f"[commit] {commit_sha}")
    print(f"[link] https://github.com/{OWNER}/{REPO}/commit/{commit_sha}")


if __name__ == "__main__":
    main()
