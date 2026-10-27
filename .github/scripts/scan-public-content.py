#!/usr/bin/env python3
"""Scan text files. This file does not store a word list."""
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ALLOWED_REPOS = (
    "kgknutsson/github-workflows",
    "kgknutsson/github-actions",
)
GUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
MAX_BYTES = 1_000_000


def owner_prefix():
    return ALLOWED_REPOS[0].split("/", 1)[0] + "/"


def redact_allowed(line):
    redacted = line
    for name in ALLOWED_REPOS:
        redacted = re.sub(re.escape(name) + r"(?![\w-])", "", redacted)
    return redacted


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


def load_raw_denylist():
    path = os.environ.get("DENYLIST_FILE", "")
    if path and os.path.isfile(path):
        return open(path, encoding="utf-8").read()
    raw = os.environ.get("PUBLIC_REPO_DENYLIST", "")
    if raw.strip():
        return raw
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    token = os.environ.get("GITHUB_TOKEN", "")
    var_name = os.environ.get("DENYLIST_VARIABLE", "PUBLIC_REPO_DENYLIST")
    if not repo or not token:
        return ""
    url = "https://api.github.com/repos/" + repo + "/actions/variables/" + var_name
    try:
        payload = github_json(url, token)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return ""
        raise
    return payload.get("value", "") or ""


def load_terms():
    raw = load_raw_denylist()
    terms = [
        line.strip()
        for line in raw.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    required = os.environ.get("DENYLIST_REQUIRED", "true").lower() == "true"
    structural_only = os.environ.get("ALLOW_STRUCTURAL_ONLY", "false").lower() == "true"
    if required and not terms:
        if structural_only:
            return []
        print(
            "::error::The word list is empty. Set the PUBLIC_REPO_DENYLIST repository variable, or DENYLIST_FILE for local runs.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return terms


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


def iter_working_files(root):
    scan_dir = os.environ.get("SCAN_DIR", "")
    if scan_dir:
        for dirpath, dirnames, filenames in os.walk(scan_dir):
            dirnames[:] = [name for name in dirnames if name != ".git"]
            for name in filenames:
                full = os.path.join(dirpath, name)
                yield os.path.relpath(full, scan_dir), full, None
        return
    listed = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    for raw_path in listed.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", "surrogateescape")
        yield path, os.path.join(root, path), None


def iter_index_files(root):
    listed = subprocess.check_output(
        ["git", "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"],
        cwd=root,
    )
    for raw_path in listed.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", "surrogateescape")
        try:
            content = subprocess.check_output(["git", "show", ":" + path], cwd=root)
        except subprocess.CalledProcessError:
            continue
        yield path, None, content


def line_failed(line, terms):
    redacted = redact_allowed(line)
    structural = (
        GUID.search(redacted)
        or EMAIL.search(redacted)
        or ("atlassian" + ".net") in redacted.lower()
        or owner_prefix() in redacted
    )
    denied = any(term.lower() in redacted.lower() for term in terms)
    return bool(structural or denied)


def scan_text(path, text, terms):
    failed = False
    for number, line in enumerate(text.splitlines(), start=1):
        if line_failed(line, terms):
            print(f"{path}:{number}: content rule failed")
            failed = True
    return failed


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
    use_index = os.environ.get("SCAN_INDEX", "false").lower() == "true"
    rows = iter_index_files(root) if use_index else iter_working_files(root)
    for path, full, content in rows:
        if content is None:
            if not full or not os.path.isfile(full):
                continue
            try:
                text = open(full, encoding="utf-8").read()
            except UnicodeDecodeError:
                continue
        else:
            try:
                text = content.decode("utf-8")
            except UnicodeDecodeError:
                continue
        if scan_text(path, text, terms):
            failed = True
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
