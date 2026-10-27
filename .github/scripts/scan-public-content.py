#!/usr/bin/env python3
"""Scan tracked files. This file does not store a word list."""
import os
import re
import subprocess
import sys

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


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    os.chdir(root)
    terms = load_terms()
    listed = subprocess.check_output(["git", "ls-files", "-z"])
    failed = False
    for raw_path in listed.split(b"\0"):
        if not raw_path:
            continue
        path = raw_path.decode("utf-8", "surrogateescape")
        if not os.path.isfile(path):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
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
            if structural or denied:
                print(f"{path}:{number}: content rule failed")
                failed = True
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
