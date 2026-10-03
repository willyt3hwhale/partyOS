#!/usr/bin/env bash
# test-install-hooks.sh - hardware-FREE test for scripts/dev/install-hooks.sh,
# the opt-in git pre-commit hook installer. Runs entirely in a TEMP git repo
# with its own stub Makefile (a controllable test-prod target), so the real
# repo's hooks and the real test suite are never touched.
#
# Covers: hook installed + executable, an existing pre-commit is backed up to
# pre-commit.bak (content preserved), a SECOND run never destroys that backup
# (identical hook = no backup taken; differing hook + existing .bak = refuse),
# a failing `make test-prod` BLOCKS the commit, a passing one lets it through,
# and SKIP_TESTS=1 is a working escape hatch past a failing suite.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

INSTALLER="${REPO_ROOT}/scripts/dev/install-hooks.sh"
[ -f "${INSTALLER}" ] || { echo "FAIL: install-hooks.sh not found at ${INSTALLER}"; exit 1; }

TMPDIR_T="$(mktemp -d "${TMPDIR:-/tmp}/partyos-hooktest.XXXXXX")"
cleanup() { rm -rf "${TMPDIR_T}"; }
trap cleanup EXIT

REPO="${TMPDIR_T}/repo"
mkdir -p "${REPO}"
cd "${REPO}"
git init -q
git config user.email "test@partyos.local"
git config user.name "partyOS test"
# Force local hooks: a user-global core.hooksPath must not leak into the test.
git config core.hooksPath .git/hooks

# Stub Makefile: test-prod fails iff the flag file .fail-tests exists.
printf 'test-prod:\n\t@test ! -f .fail-tests\n\t@echo stub-test-prod-passed\n' > Makefile

echo "================ install-hooks pre-commit installer test ================"

# ----------------------------------------------------------------------------
echo
echo "---- 1. existing hook is backed up, new hook installed + executable ----"
mkdir -p .git/hooks
printf '#!/bin/sh\n# old-operator-hook\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
out="$(bash "${INSTALLER}" 2>&1)"
assert_true "$?" "installer exits 0"
assert_true "$([ -f .git/hooks/pre-commit ]; echo $?)" "pre-commit hook installed"
assert_true "$([ -x .git/hooks/pre-commit ]; echo $?)" "pre-commit hook is executable"
assert_true "$([ -f .git/hooks/pre-commit.bak ]; echo $?)" "existing hook backed up to pre-commit.bak"
assert_contains "$(cat .git/hooks/pre-commit.bak)" "old-operator-hook" "backup preserves the old hook content"
assert_contains "$(cat .git/hooks/pre-commit)" "make test-prod" "installed hook runs make test-prod"
assert_contains "$(cat .git/hooks/pre-commit)" "SKIP_TESTS=1" "escape hatch documented in the hook itself"
assert_contains "${out}" "backed up" "installer announced the backup"

# ----------------------------------------------------------------------------
echo
echo "---- 1b. second run: the operator's original backup survives ----"
# Re-run over our own unchanged hook: must be a no-op WITHOUT a backup - the
# first-run backup (the operator's original hook) would be clobbered otherwise.
out="$(bash "${INSTALLER}" 2>&1)"
rc=$?
assert_true "${rc}" "re-run over the unchanged installed hook exits 0"
assert_contains "${out}" "no backup taken" "re-run says no backup was taken"
assert_contains "$(cat .git/hooks/pre-commit.bak)" "old-operator-hook" "original backup still intact after the re-run"
# A DIFFERING hook while a .bak exists: refuse rather than destroy the backup.
echo "# operator-customization" >> .git/hooks/pre-commit
rc=0
out="$(bash "${INSTALLER}" 2>&1)" || rc=$?
assert_false "${rc}" "differing hook + existing .bak: installer refuses"
assert_contains "${out}" "refusing" "the refusal says so"
assert_contains "$(cat .git/hooks/pre-commit.bak)" "old-operator-hook" "original backup untouched by the refusal"
assert_contains "$(cat .git/hooks/pre-commit)" "operator-customization" "customized hook untouched by the refusal"
# Operator moves the backup aside -> the differing hook is backed up + replaced.
mv .git/hooks/pre-commit.bak "${TMPDIR_T}/original-hook.bak"
out="$(bash "${INSTALLER}" 2>&1)"
assert_true "$?" "after moving the .bak aside the installer proceeds"
assert_contains "$(cat .git/hooks/pre-commit.bak)" "operator-customization" "the customized hook became the new backup"
assert_not_contains "$(cat .git/hooks/pre-commit)" "operator-customization" "the installed hook is the clean generated one again"

# ----------------------------------------------------------------------------
echo
echo "---- 2. passing test-prod lets the commit through (hook actually ran) ----"
git add Makefile
out="$(git commit -q -m "initial" 2>&1)"
rc=$?
assert_true "${rc}" "commit succeeds when test-prod passes"
assert_contains "${out}" "stub-test-prod-passed" "the hook really ran make test-prod"
assert_eq "$(git rev-list --count HEAD)" "1" "one commit landed"

# ----------------------------------------------------------------------------
echo
echo "---- 3. failing test-prod BLOCKS the commit ----"
touch .fail-tests
echo "change" >> Makefile
git add Makefile
rc=0
out="$(git commit -q -m "should be blocked" 2>&1)" || rc=$?
assert_false "${rc}" "commit is blocked when test-prod fails"
assert_contains "${out}" "commit blocked" "the hook says why it blocked"
assert_eq "$(git rev-list --count HEAD)" "1" "no new commit landed"

# ----------------------------------------------------------------------------
echo
echo "---- 4. SKIP_TESTS=1 escape hatch commits past the failing suite ----"
rc=0
out="$(SKIP_TESTS=1 git commit -q -m "escape hatch" 2>&1)" || rc=$?
assert_true "${rc}" "SKIP_TESTS=1 commit succeeds despite failing test-prod"
assert_contains "${out}" "skipping" "the hook announces the skip"
assert_eq "$(git rev-list --count HEAD)" "2" "the escape-hatch commit landed"

# ----------------------------------------------------------------------------
echo
echo "---- 5. re-run on a fresh repo with NO existing hook: no backup made ----"
REPO2="${TMPDIR_T}/repo2"
mkdir -p "${REPO2}"
cd "${REPO2}"
git init -q
git config core.hooksPath .git/hooks
bash "${INSTALLER}" >/dev/null 2>&1
assert_true "$?" "installer exits 0 with no pre-existing hook"
assert_true "$([ -x .git/hooks/pre-commit ]; echo $?)" "hook installed in the fresh repo"
assert_true "$([ ! -e .git/hooks/pre-commit.bak ]; echo $?)" "no spurious .bak when nothing existed"

# ----------------------------------------------------------------------------
echo
echo "---- 6. outside a git repo the installer fails loud ----"
cd "${TMPDIR_T}"
rc=0
out="$(GIT_CEILING_DIRECTORIES="${TMPDIR_T}" bash "${INSTALLER}" 2>&1)" || rc=$?
assert_false "${rc}" "installer exits non-zero outside a git repo"
assert_contains "${out}" "not inside a git repo" "installer says why"

assert_summary "test-install-hooks" || exit 1
echo "test-install-hooks: ALL PASS"
