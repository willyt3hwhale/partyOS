#!/usr/bin/env bash
# test-blob-container-quoting.sh - hardware-FREE guard on the blob builders.
#
# build-app-blob.sh and build-proton-blob.sh pass their whole container script to
# docker as ONE single-quoted argument. A bare apostrophe anywhere inside that
# argument CLOSES the quote. Everything after it stops being container script and
# becomes host-level words and redirections, so the build silently runs part of the
# recipe on the build host. That is how the AUR glibc alignment step ended up
# redirecting into /etc/pacman.d/mirrorlist on the macOS dev host, which does not
# exist, and killed every AUR blob build.
#
# The rule: inside the container argument, an apostrophe is legal only as the
# documented '"${VAR}"' escape, which re-opens the quote on the same line.
#
# Asserts, for each builder:
#   * every apostrophe between the opening and the closing quote is balanced on its
#     own line (so the quote state at the end of each line is unchanged).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

echo "================ blob builder container-script quoting ====="

for f in build-app-blob.sh build-proton-blob.sh; do
    SRC="${REPO_ROOT}/scripts/build/${f}"
    OUT="$(SRC="${SRC}" python3 - <<'PY'
import os, re, sys
lines = open(os.environ["SRC"]).read().split("\n")
start = None
for i, line in enumerate(lines):
    # the docker invocation ends its last argv line with an opening single quote
    if re.search(r"/bin/bash -euo pipefail -c '\s*$", line):
        start = i + 1
        break
if start is None:
    print("NO-CONTAINER-BLOCK")
    sys.exit(0)
bad = []
for i in range(start, len(lines)):
    line = lines[i]
    # the closing line of the container argument
    if re.match(r"^' ", line) or line.startswith("' 2>&1"):
        break
    if line.count("'") % 2:
        bad.append("%d: %s" % (i + 1, line.strip()))
print("\n".join(bad) if bad else "CLEAN")
PY
)"
    assert_eq "${OUT}" "CLEAN" "${f}: no unbalanced apostrophe inside the container script"
done

assert_summary
