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

Delete mode:
  python3 commit_newtworks.py path/in/repo --delete --message 'chore: remove stale file'

  Fetches the file's current blob sha first (that sha requirement IS the
  stale-basis guard — GitHub rejects the delete if the file changed
  underneath you). Cannot combine with --replace/--content-file/--create.

Batch mode (several files, ONE commit, ONE Vercel deployment):
  python3 commit_newtworks.py --batch /home/claude/manifest.json \
      --message 'migration: default_deny_tier2 batches 1-8'

  Use this whenever more than one file is going out together. The single-file
  modes create a separate commit and a separate deployment per file, which is
  what exhausted the free-tier daily deployment cap on 2026-08-07.

  Manifest entries can also delete a file with {"path": "...", "delete": true,
  "expect_sha": "..."} — expect_sha is REQUIRED on delete entries since batch
  has no other confirmation mechanism.

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


def delete_file(path, sha, message, branch="main"):
    body = {
        "message": message,
        "sha": sha,
        "branch": branch,
    }
    status, data = gh_request("DELETE", f"/contents/{path}", body=body)
    if status not in (200, 201):
        die(f"Delete failed ({status}): {json.dumps(data)[:400]}")
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


def gh_get_json(path):
    status, data = gh_request("GET", path)
    if status != 200:
        die(f"GET {path} failed ({status}): {json.dumps(data)[:400]}")
    return data


def gh_post_json(path, body):
    status, data = gh_request("POST", path, body=body)
    if status not in (200, 201):
        die(f"POST {path} failed ({status}): {json.dumps(data)[:400]}")
    return data


def fetch_file_at(path, ref):
    """Fetch a file pinned to a specific commit. Returns None if it does not exist."""
    status, data = gh_request("GET", f"/contents/{path}?ref={ref}")
    if status == 404:
        return None
    if status != 200:
        die(f"Fetch failed ({status}) for {path}: {json.dumps(data)[:400]}")
    if data.get("encoding") != "base64":
        die(f"Unexpected encoding for {path}: {data.get('encoding')}")
    content = base64.b64decode(data["content"].replace("\n", "")).decode("utf-8")
    return {"sha": data["sha"], "content": content}


def run_batch(manifest_path, message, branch, dry_run):
    """Land several files in ONE commit via the Git Data API.

    Why this exists: the Contents API used by the single-file modes creates one
    commit AND one ref update per file, and Vercel raises one deployment per ref
    update. On 2026-08-07 eight migration mirrors pushed one at a time burned
    eight deployments for zero site change and tipped the project over the
    free-tier daily deployment cap, which silently stopped every later push from
    building. This path builds one tree, one commit and one ref update, so the
    same eight files cost a single deployment.

    Manifest is JSON:
      {"files": [
         {"path": "supabase/migrations/x.sql", "content_file": "/home/claude/x.sql"},
         {"path": "src/modules/Team.jsx",
          "replace": [["old", "new"], ["old2", "new2", 3]],
          "expect_sha": "abc123..."},
         {"path": "docs/_stale.md", "delete": true, "expect_sha": "def456..."}
      ]}

    Per entry: "content_file" writes the whole file; "replace" applies the same
    exact-match patching as --replace (optional third element pins the expected
    occurrence count); "delete": true removes the file from the tree. Optional
    "expect_sha" aborts if the file's blob at the base commit is not the one the
    edit was built against, which is the batch equivalent of the stale-basis
    guard on the single-file overwrite path. "delete": true entries REQUIRE
    expect_sha — batch has no other mechanism to confirm you're deleting the
    file you think you are, so this is not optional the way it is elsewhere.
    """
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    files = manifest.get("files") or []
    if not files:
        die(f"Manifest {manifest_path} has no 'files' entries.")

    ref = gh_get_json(f"/git/ref/heads/{branch}")
    base_sha = ref["object"]["sha"]
    base_tree = gh_get_json(f"/git/commits/{base_sha}")["tree"]["sha"]
    print(f"[base] {branch} @ {base_sha[:12]} (tree {base_tree[:12]})")

    staged = []
    seen = set()
    for entry in files:
        path = entry.get("path")
        if not path:
            die(f"Manifest entry missing 'path': {json.dumps(entry)[:200]}")
        if path in seen:
            die(f"{path} appears twice in the manifest. Merge the edits into one entry.")
        seen.add(path)

        current = fetch_file_at(path, base_sha)

        expect = entry.get("expect_sha")
        is_delete = bool(entry.get("delete"))

        if is_delete and not expect:
            die(f"{path}: 'delete' entries require expect_sha. Batch has no other way to "
                "confirm you're deleting the file you think you are.")

        if expect:
            if current is None:
                die(f"{path}: expect_sha given but the file does not exist at the base commit.")
            if not current["sha"].startswith(expect):
                die(f"{path}: blob is {current['sha'][:12]}, manifest expected {expect[:12]}. "
                    "Stale basis - reconcile before committing.")

        if is_delete:
            if current is None:
                die(f"{path}: 'delete' entry but the file does not exist at the base commit.")
            print(f"[delete] {path} - {current['sha'][:12]}")
            staged.append((path, None, True))
            continue

        if "replace" in entry:
            if current is None:
                die(f"{path}: 'replace' entry but the file does not exist at the base commit.")
            reps = [(p[0], p[1], p[2] if len(p) > 2 else None) for p in entry["replace"]]
            new_content = apply_replacements(current["content"], reps)
        elif "content_file" in entry:
            with open(entry["content_file"], "rb") as f:
                new_content = f.read().decode("utf-8")
        else:
            die(f"{path}: entry needs 'replace', 'content_file', or 'delete': true.")

        if current is not None and new_content == current["content"]:
            print(f"[skip] {path} unchanged")
            continue
        verb = "create" if current is None else "update"
        print(f"[{verb}] {path} - {len(new_content)} bytes")
        staged.append((path, new_content, False))

    if not staged:
        print("[skip] Nothing changed, no commit made.")
        return

    if dry_run:
        n_delete = sum(1 for _, _, d in staged if d)
        n_write = len(staged) - n_delete
        print(f"[dry-run] Would land {n_write} write(s) and {n_delete} delete(s) "
              f"in ONE commit. Not committing.")
        return

    tree_entries = []
    for path, content, is_delete in staged:
        if is_delete:
            tree_entries.append({"path": path, "mode": "100644", "type": "blob", "sha": None})
            continue
        blob = gh_post_json("/git/blobs", {
            "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
            "encoding": "base64",
        })
        tree_entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})

    tree = gh_post_json("/git/trees", {"base_tree": base_tree, "tree": tree_entries})
    commit = gh_post_json("/git/commits", {
        "message": message,
        "tree": tree["sha"],
        "parents": [base_sha],
    })

    status, data = gh_request("PATCH", f"/git/refs/heads/{branch}",
                              body={"sha": commit["sha"], "force": False})
    if status != 200:
        die(f"Ref update failed ({status}). HEAD moved mid-batch and NOTHING was published - "
            f"rebuild the manifest against the new HEAD: {json.dumps(data)[:400]}")

    print(f"[commit] {commit['sha']} - {len(staged)} file(s) in one commit, one deployment")
    print(f"[link] https://github.com/{OWNER}/{REPO}/commit/{commit['sha']}")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("path", nargs="?",
                    help="Path in repo (e.g. src/modules/CPRDetail.jsx). Omit when using --batch.")
    ap.add_argument("--batch",
                    help="JSON manifest of files to land in ONE commit (one Vercel deployment)")
    ap.add_argument("--replace", nargs=2, action="append", metavar=("OLD", "NEW"), default=[])
    ap.add_argument("--count", type=int, action="append", default=[],
                    help="Expected occurrence count per --replace (positional match)")
    ap.add_argument("--content-file", help="Local file whose content replaces remote entirely")
    ap.add_argument("--message", required=True)
    ap.add_argument("--branch", default="main")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--create", action="store_true",
                    help="Create new file (no existing remote file expected)")
    ap.add_argument("--delete", action="store_true",
                    help="Delete an existing file. Cannot combine with --replace/--content-file/--create.")
    args = ap.parse_args()

    if args.batch:
        if args.path or args.replace or args.content_file or args.create or args.delete:
            die("--batch is standalone. Put every file in the manifest instead.")
        run_batch(args.batch, args.message, args.branch, args.dry_run)
        return

    if not args.path:
        die("Missing repo path. Pass a path, or use --batch with a manifest.")

    if args.delete:
        if args.replace or args.content_file or args.create:
            die("--delete cannot combine with --replace, --content-file, or --create.")
        current = fetch_file_at(args.path, ref=args.branch)
        if current is None:
            die(f"{args.path} does not exist on branch {args.branch} — nothing to delete.")
        print(f"[delete] {args.path} @ {current['sha'][:12]} — {len(current['content'])} bytes")
        if args.dry_run:
            print("[dry-run] Not committing.")
            return
        commit_sha = delete_file(args.path, current["sha"], args.message, args.branch)
        print(f"[commit] {commit_sha}")
        print(f"[link] https://github.com/{OWNER}/{REPO}/commit/{commit_sha}")
        return

    if args.replace and args.content_file:
        die("Use --replace OR --content-file, not both.")
    if not args.replace and not args.content_file:
        die("Nothing to do. Pass --replace, --content-file, or --delete.")

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
