#!/usr/bin/env python3
"""
Fix: KernelSU-Next allowlist never persists on FBE devices (-126 / ENOKEY).

In do_persistent_allow_list() we replace

    const struct cred *saved = override_creds(ksu_cred);   ->  get_current_cred();
    revert_creds(saved);                                   ->  put_cred(saved);

Unlike a git patch this does NOT depend on line numbers or surrounding
context. It finds the function by name and edits only inside it, so it keeps
working when the rest of the file changes.

Usage:
    python3 fix_allowlist_creds.py [path/to/allowlist.c] [--dry-run]
Default path: drivers/kernelsu/policy/allowlist.c
"""
import difflib
import re
import shutil
import sys

DEFAULT_PATH = "drivers/kernelsu/policy/allowlist.c"
FUNC = "do_persistent_allow_list"

# \s* lets the patterns survive different spacing/formatting.
OVERRIDE = re.compile(r"override_creds\s*\(\s*ksu_cred\s*\)")
REVERT = re.compile(r"revert_creds\s*\(\s*saved\s*\)")


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry_run = "--dry-run" in sys.argv
    path = args[0] if args else DEFAULT_PATH

    # newline="" keeps the file's original line endings untouched.
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            src = f.read()
    except OSError as e:
        die(f"cannot read {path}: {e}")

    # 1. Find the function definition (not the later `cb->func = ...` use).
    m = re.search(
        r"^static\s+void\s+" + FUNC + r"\s*\([^)]*\)\s*\{", src, re.MULTILINE
    )
    if not m:
        die(f"could not find the definition of {FUNC}() in {path}")
    start = m.start()

    # 2. Its end: the first line that is just "}" at column 0 (kernel style).
    end_m = re.search(r"^\}[ \t]*\r?$", src[m.end():], re.MULTILINE)
    if not end_m:
        die("could not find the end of the function")
    end = m.end() + end_m.end()
    body = src[start:end]

    # 3. Already patched?
    if "get_current_cred()" in body and not OVERRIDE.search(body):
        print("already patched, nothing to do.")
        return

    # 4. Safety: expect exactly one of each, otherwise stop without writing.
    n_over = len(OVERRIDE.findall(body))
    n_rev = len(REVERT.findall(body))
    if n_over != 1 or n_rev != 1:
        die(
            f"expected 1 override_creds(ksu_cred) and 1 revert_creds(saved) "
            f"inside {FUNC}(), found {n_over} and {n_rev}. Not touching the file."
        )

    # 5. Do the replacement only inside the function body.
    new_body = OVERRIDE.sub("get_current_cred()", body)
    new_body = REVERT.sub("put_cred(saved)", new_body)
    new_src = src[:start] + new_body + src[end:]

    diff = difflib.unified_diff(
        src.splitlines(keepends=True),
        new_src.splitlines(keepends=True),
        fromfile=path,
        tofile=path + " (patched)",
        n=2,
    )
    print("".join(diff))

    if dry_run:
        print("dry run: file not modified.")
        return

    shutil.copy2(path, path + ".orig")  # backup
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(new_src)
    print(f"patched {path} (backup: {path}.orig)")


if __name__ == "__main__":
    main()
