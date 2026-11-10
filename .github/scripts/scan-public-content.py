#!/usr/bin/env python3
"""Scan text files. This file does not store a word list."""
import os
import re
import subprocess
import sys

ALLOWED_REPOS = (
    "kgknutsson/github-workflows",
    "kgknutsson/github-actions",
)
LOCAL_DENYLIST = ".denylist.local"
GUID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")


def owner_prefix():
    return ALLOWED_REPOS[0].split("/", 1)[0] + "/"


def redact_allowed(line):
    redacted = line
    for name in ALLOWED_REPOS:
        redacted = re.sub(re.escape(name) + r"(?![\w-])", "", redacted)
    return redacted


def denylist_path():
    path = os.environ.get("DENYLIST_FILE", "").strip()
    if path:
        return path
    if os.path.isfile(LOCAL_DENYLIST):
        return LOCAL_DENYLIST
    return ""


def load_terms():
    path = denylist_path()
    raw = ""
    if path:
        if not os.path.isfile(path):
            print("::error::The word list file is missing: " + path, file=sys.stderr)
            raise SystemExit(1)
        raw = open(path, encoding="utf-8").read()
    terms = [
        line.strip()
        for line in raw.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    required = os.environ.get("DENYLIST_REQUIRED", "true").lower() == "true"
    if required and not terms:
        print(
            "::error::The word list is empty. Create .denylist.local with one term on each line.",
            file=sys.stderr,
        )
        raise SystemExit(1)
    return terms


def skip_path(path):
    name = path.replace("\\", "/").rsplit("/", 1)[-1]
    return name == LOCAL_DENYLIST


def iter_working_files(root):
    listed = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    for raw_path in listed.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", "surrogateescape")
        if skip_path(path):
            continue
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
        if skip_path(path):
            continue
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
    root = sys.argv[1] if len(sys.argv) > 1 else "."
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
