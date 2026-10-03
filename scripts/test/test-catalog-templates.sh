#!/usr/bin/env bash
# test-catalog-templates.sh - hardware-free check of the catalog config seeds.
#
# partyos-launch fetches each config_template of a catalog row from
# <server>/server/<config_template> and renders it to <config_dir>/<config_out>.
# If the template is not in server/, the fetch fails and the game starts with
# its default first-run config (for example "nameless tee" in DDNet).
#
# Asserts, for every row of server/games/catalog.v2.json with a config_template:
#   * config_dir and config_out are set,
#   * config_template and config_out hold the same number of paths,
#   * each template file exists under server/ and is not empty,
#   * one template of the row has the @NICK@ placeholder.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
# shellcheck source=lib-assert.sh
source "${SELF_DIR}/lib-assert.sh"

CATALOG="${REPO_ROOT}/server/games/catalog.v2.json"
[ -f "${CATALOG}" ] || { echo "FAIL: catalog not found at ${CATALOG}"; exit 1; }

# One line per row with a config_template: name<TAB>config_dir<TAB>templates<TAB>outs
ROWS="$(python3 - "${CATALOG}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get("games", []):
    if "config_template" in r:
        print("\t".join([r.get("name", "?"), r.get("config_dir", ""),
                         r.get("config_template", ""), r.get("config_out", "")]))
PY
)"
[ -n "${ROWS}" ] || { echo "FAIL: no catalog row has a config_template"; exit 1; }

echo "================ every catalog config_template is in server/ ========"
while IFS=$'\t' read -r name cdir tmpls outs; do
    read -r -a T <<< "${tmpls}"
    read -r -a O <<< "${outs}"
    assert_true "$([ -n "${cdir}" ]; echo $?)" "${name}: config_dir is set"
    assert_true "$([ "${#O[@]}" -gt 0 ]; echo $?)" "${name}: config_out is set"
    assert_eq "${#T[@]}" "${#O[@]}" "${name}: one config_out for each config_template"
    all=""
    for t in "${T[@]}"; do
        f="${REPO_ROOT}/server/${t}"
        assert_true "$([ -s "${f}" ]; echo $?)" "${name}: server/${t} exists"
        [ -s "${f}" ] && all="${all}$(cat "${f}")"
    done
    assert_contains "${all}" "@NICK@" "${name}: a template has @NICK@"
done <<< "${ROWS}"

assert_summary "test-catalog-templates" || exit 1
echo "test-catalog-templates: ALL PASS"
