#!/usr/bin/env python3
"""Scan text files. This file does not store a word list."""
import base64
import json
import os
import re
import subprocess
import sys
import urllib.request

ALLOW = (
    "kgknutsson/github-workflows",
    "kgknutsson/github-actions",
)
GUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
OWNER = "kgknutsson"
OTHER_OWNER = re.compile(OWNER + r"/(?!github-workflows\b|github-actions\b)")
MAX_BYTES = 1_000_000


def load_terms():
    raw = os.environ.get("PUBLIC_REPO_DENYLIST", "")
    path = os.environ.get("DENYLIST_FILE", "")
    if path and os.path.isfile(path):
        raw = open(path, encoding="utf-8").read()
    terms = [
        line.strip()
        for line in raw.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    required = os.environ.get("DENYLIST_REQUIRED", "true").lower() == "true"
    if required and not terms:
        print(
            "::error::The word list is empty. Set PUBLIC_REPO_DENYLIST or DENYLIST_FILE.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return terms


def github_json(url, token):
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "User-Agent": "public-content-guard",
        },
    )
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def safe_path(path):
    parts = path.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts):
        return False
    return True


def download_tree(repo, sha, dest, token):
    tree = github_json(
        "https://api.github.com/repos/" + repo + "/git/trees/" + sha + "?recursive=1",
        token,
    )
    if tree.get("truncated"):
        print("::error::The file tree is truncated.", file=sys.stderr)
        raise SystemExit(1)
    os.makedirs(dest, exist_ok=True)
    for item in tree.get("tree", []):
        if item.get("type") != "blob":
            continue
        path = item.get("path", "")
        if not safe_path(path):
            print("::error::The file tree has an unsafe path.", file=sys.stderr)
            raise SystemExit(1)
        if item.get("size", 0) > MAX_BYTES:
            continue
        blob = github_json(item["url"], token)
        if blob.get("encoding") != "base64":
            continue
        target = os.path.join(dest, *path.split("/"))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as handle:
            handle.write(base64.b64decode(blob["content"]))


def iter_files(root):
    scan_dir = os.environ.get("SCAN_DIR", "")
    if scan_dir:
        for dirpath, dirnames, filenames in os.walk(scan_dir):
            dirnames[:] = [name for name in dirnames if name != ".git"]
            for name in filenames:
                full = os.path.join(dirpath, name)
                yield os.path.relpath(full, scan_dir), full
        return
    listed = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    for raw_path in listed.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", "surrogateescape")
        yield path, os.path.join(root, path)


def line_failed(line, terms):
    redacted = line
    for allowed in ALLOW:
        redacted = redacted.replace(allowed, "")
    structural = (
        GUID.search(redacted)
        or EMAIL.search(redacted)
        or ("atlassian" + ".net") in redacted.lower()
        or OTHER_OWNER.search(redacted)
    )
    denied = any(term.lower() in redacted.lower() for term in terms)
    return structural or denied


def main():
    token = os.environ.get("GITHUB_TOKEN", "")
    scan_repo = os.environ.get("SCAN_REPO", "")
    scan_sha = os.environ.get("SCAN_SHA", "")
    scan_dir = os.environ.get("SCAN_DIR", "")
    if scan_repo or scan_sha:
        if not scan_repo or not scan_sha or not token:
            print("::error::The proposed revision is incomplete.", file=sys.stderr)
            raise SystemExit(1)
        dest = scan_dir or os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "proposed-files")
        download_tree(scan_repo, scan_sha, dest, token)
        os.environ["SCAN_DIR"] = dest
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.environ.get("SCAN_DIR"):
        os.chdir(root)
    terms = load_terms()
    failed = False
    for path, full in iter_files(root):
        if not os.path.isfile(full):
            continue
        try:
            text = open(full, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if line_failed(line, terms):
                print(f"{path}:{number}: content rule failed")
                failed = True
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
