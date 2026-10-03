#!/usr/bin/env bash
# install-hooks.sh - OPT-IN installer for the partyOS git pre-commit hook.
#
# The hook runs `make test-prod` (the hardware-free regression gate,
# docs/TESTING.md) before every commit and BLOCKS the commit on failure.
# Nothing installs this automatically. Run it once per clone to enforce the gate:
#
#   make install-hooks        (or: bash scripts/dev/install-hooks.sh)
#
# An existing pre-commit hook is backed up to pre-commit.bak first, never
# silently overwritten. A RE-RUN over our own already-installed hook takes no
# backup (backing up would clobber the original .bak from the first
# install), and an existing .bak is never overwritten - the installer refuses
# instead. The escape hatch (SKIP_TESTS=1) is documented in the hook itself.
set -euo pipefail

# Resolve the hooks dir through git so core.hooksPath overrides are honoured.
HOOKS_DIR="$(git rev-parse --git-path hooks 2>/dev/null)" || {
    echo "install-hooks: not inside a git repository" >&2
    exit 1
}
HOOK="${HOOKS_DIR}/pre-commit"
mkdir -p "${HOOKS_DIR}"

# The hook content, emitted from one place so the compare-before-backup below
# always judges against exactly what would be installed.
emit_hook() {
cat <<'HOOKEOF'
#!/usr/bin/env bash
# pre-commit - partyOS regression gate (installed by scripts/dev/install-hooks.sh).
# Runs the hardware-free test suite before every commit and BLOCKS the commit
# on failure - nothing old may break silently (docs/TESTING.md).
#
# Escape hatch (use sparingly, e.g. a WIP commit while a suite fix is pending):
#   SKIP_TESTS=1 git commit ...
set -uo pipefail
if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "[pre-commit] SKIP_TESTS=1 - skipping make test-prod" >&2
    exit 0
fi
cd "$(git rev-parse --show-toplevel)" || exit 1
echo "[pre-commit] running make test-prod (escape hatch: SKIP_TESTS=1 git commit ...)" >&2
if ! make test-prod; then
    echo "[pre-commit] test-prod FAILED - commit blocked. Fix the tests, or SKIP_TESTS=1 to bypass." >&2
    exit 1
fi
HOOKEOF
}

if [ -e "${HOOK}" ]; then
    if emit_hook | cmp -s "${HOOK}" -; then
        # Re-run over our own unchanged hook: nothing to do, and CRUCIALLY no
        # backup - a backup here would overwrite the original
        # pre-commit.bak from the first install with our generated hook.
        echo "install-hooks: pre-commit already installed and up to date (no backup taken)"
        exit 0
    fi
    if [ -e "${HOOK}.bak" ]; then
        # A differing hook AND an existing backup: backing up would destroy
        # the only copy of the original hook. Refuse; the user decides what
        # to keep.
        echo "install-hooks: refusing: ${HOOK} differs from the generated hook and ${HOOK}.bak already exists." >&2
        echo "install-hooks: move ${HOOK}.bak aside (or remove it) so the original backup is not clobbered, then re-run." >&2
        exit 1
    fi
    cp "${HOOK}" "${HOOK}.bak"
    echo "install-hooks: existing pre-commit backed up to ${HOOK}.bak"
fi

emit_hook > "${HOOK}"
chmod +x "${HOOK}"
echo "install-hooks: pre-commit installed at ${HOOK} (runs make test-prod; SKIP_TESTS=1 skips)"
