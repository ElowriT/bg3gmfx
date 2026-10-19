#!/usr/bin/env python3
"""Scoped cleanup for `make clean` and `make clean-evidence`.

    cleanup.py bin|evidence BIN_DIR EVIDENCE_DIR

Removes BIN_DIR (mode `bin`) or EVIDENCE_DIR (mode `evidence`) and nothing
else: retained captures, historical files and downloaded references elsewhere
under build/ stay. Both directories are checked before anything is deleted:
their names must end in 'bin' and 'evidence', neither may contain the other,
and no component of either path may be a symlink.
"""

import os
import shutil
import sys


def fail(message):
    print(f"cleanup: {message}", file=sys.stderr)
    sys.exit(2)


def checked(path, name):
    if not path:
        fail(f"no {name} directory given")
    absolute = os.path.abspath(path)
    if os.path.basename(absolute) != name:
        fail(f"{path} must end in '{name}'")
    # Every existing prefix, the directory itself included: a symlink anywhere
    # could send the deletion outside the build tree.
    current = os.sep
    for part in absolute.strip(os.sep).split(os.sep):
        current = os.path.join(current, part)
        if os.path.islink(current):
            fail(f"{path} contains a symlink ({current})")
    return absolute


def main(argv):
    if len(argv) != 4 or argv[1] not in ("bin", "evidence"):
        fail("usage: cleanup.py bin|evidence BIN_DIR EVIDENCE_DIR")
    binaries = checked(argv[2], "bin")
    evidence = checked(argv[3], "evidence")
    if os.path.commonpath([binaries, evidence]) in (binaries, evidence):
        fail(f"{binaries} and {evidence} overlap")
    target = binaries if argv[1] == "bin" else evidence
    if os.path.isdir(target):
        shutil.rmtree(target)
    elif os.path.exists(target):
        fail(f"{target} is not a directory")


if __name__ == "__main__":
    main(sys.argv)
