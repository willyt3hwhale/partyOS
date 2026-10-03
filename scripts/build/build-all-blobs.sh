#!/usr/bin/env bash
# build-all-blobs.sh - build every not-yet-built BLOB row in catalog.v2.json via
# build-app-blob.sh, one at a time. AUR/repo build failures are retried ONCE, then
# logged + skipped so one bad game doesn't sink the batch. linphone is skipped
# (server-side SIP, not a client blob). Regenerates catalog.json at the end.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SELF_DIR}/../.." && pwd)"
V2="${REPO_ROOT}/server/games/catalog.v2.json"
# skip: linphone (server-side SIP, not a client blob) + the 4K test stubs
# (hello/pong/dummy/demo are synthetic, not real Arch packages).
SKIP="${SKIP:-linphone hello pong dummy demo}"

OK=(); FAIL=()
# emit: name<TAB>source<TAB>pkgs<TAB>exec<TAB>title<TAB>category<TAB>id<TAB>ram_min<TAB>ram_max
mapfile -t ROWS < <(SKIP="${SKIP}" python3 - "${V2}" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
skip = set(os.environ.get("SKIP","").split())
for g in d.get("games", []):
    if g.get("source") != "blob": continue
    name = g["name"]
    if name in skip: continue
    # proton (Windows-game) blobs are built by build-proton-blob.sh from a staged
    # game dir, NOT by build-app-blob.sh from a pacman pkg name. Skip them here.
    if g.get("proton"): continue
    blob = os.path.join(os.path.dirname(sys.argv[1]) if False else "", g.get("blob",""))
    # built already if the squashfs exists and is > 1MB (skip the 4K test stubs? keep them)
    p = g.get("blob","")
    if p and os.path.exists(p) and os.path.getsize(p) > 1_000_000:
        continue
    src = "aur" if g.get("aur") else "repo"
    # extra_pkgs: extra REPO libs baked into the rootfs on top of the game (runtime
    # deps the game dlopen's that the AUR/repo pkg does not pull - e.g. libxi,
    # systemd-libs, libglvnd, sed). Passed to build-app-blob.sh via EXTRA_PKGS.
    print("\t".join([name, src, str(g.get("pkgs") or g.get("pkg") or name),
                     str(g.get("exec") or name), str(g.get("title") or name),
                     str(g.get("category") or "game"), str(g.get("id") or "partyos."+name),
                     str(g.get("ram_min",512)), str(g.get("ram_max",2048)),
                     str(g.get("extra_pkgs") or "")]))
PY
)

echo "[all-blobs] ${#ROWS[@]} blob(s) to build: $(printf '%s ' "${ROWS[@]%%	*}")" >&2
for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r name src pkgs exec title cat id rmin rmax extra <<<"${row}"
    echo "[all-blobs] === ${name} (${src}: ${pkgs}${extra:+ +extra:${extra}}) exec='${exec}' ===" >&2
    ok=0
    for attempt in 1 2; do
        if EXTRA_PKGS="${extra}" bash "${SELF_DIR}/build-app-blob.sh" "${name}" "${src}" "${pkgs}" "${exec}" \
                "${title}" "${cat}" "${id}" "${rmin}" "${rmax}"; then
            ok=1; break
        fi
        echo "[all-blobs] ${name} attempt ${attempt} FAILED" >&2
        [ "${attempt}" = 1 ] && echo "[all-blobs] retrying ${name}..." >&2
    done
    if [ "${ok}" = 1 ]; then OK+=("${name}"); echo "[all-blobs] ${name} OK" >&2
    else FAIL+=("${name}"); echo "[all-blobs] ${name} GIVE UP (logged unbuildable)" >&2; fi
done

echo "[all-blobs] regenerating catalog.json..." >&2
bash "${SELF_DIR}/build-game-blobs.sh" >/dev/null 2>&1 || true
echo "[all-blobs] ===== SUMMARY =====" >&2
echo "[all-blobs] BUILT (${#OK[@]}): ${OK[*]:-none}" >&2
echo "[all-blobs] UNBUILDABLE (${#FAIL[@]}): ${FAIL[*]:-none}" >&2
