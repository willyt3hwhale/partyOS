# phase 25-strip - sourced by build-custom-image.sh; not standalone
# --- 4-pre. strip installer/recovery/unused packages -------------------------
# partyOS starts from the stock Arch *installer* ISO (a kitchen-sink recovery
# env). Remove what a netbooted XFCE desktop never uses. The list lives in
# scripts/build/removed-packages.txt (also the undo list + LAN-mirror manifest).
# Best-effort: a pkg still required by a keeper is left in place + logged.
REMLIST=""
for _c in "$(dirname "${BASH_SOURCE[0]}")/removed-packages.txt" \
          /scripts/removed-packages.txt \
          /removed-packages.txt /build/removed-packages.txt \
          /out/removed-packages.txt /work/removed-packages.txt; do
  [ -f "${_c}" ] && { REMLIST="${_c}"; break; }
done
if [ -n "${REMLIST}" ]; then
  mapfile -t REMOVE < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "${REMLIST}")
  echo "[build] stripping ${#REMOVE[@]} packages (from ${REMLIST})..."
  for _p in "${REMOVE[@]}"; do
    if arch-chroot "${ROOTFS}" pacman -Rns --noconfirm "${_p}" >/dev/null 2>&1; then
      echo "[build]   removed ${_p}"
    else
      echo "[build]   kept ${_p} (required by a keeper / absent)"
    fi
  done
  # NB: pacman -Qdtq exits 1 when there are NO orphans; with pipefail that would
  # fail the assignment and (set -e) abort the build, so guard it.
  _orph="$(arch-chroot "${ROOTFS}" pacman -Qdtq 2>/dev/null | tr '\n' ' ')" || _orph=""
  if [ -n "${_orph// /}" ]; then
    echo "[build]   sweeping orphans: ${_orph}"
    arch-chroot "${ROOTFS}" pacman -Rns --noconfirm ${_orph} >/dev/null 2>&1 || true
  fi
  # bake ldconfig cache (boot-time ldconfig blocks sysinit ~10s) + mask NTP wait
  arch-chroot "${ROOTFS}" ldconfig 2>/dev/null || true
  ln -sf /dev/null "${ROOTFS}/etc/systemd/system/ldconfig.service"
  ln -sf /dev/null "${ROOTFS}/etc/systemd/system/systemd-time-wait-sync.service"
  echo "[build] package strip complete"
else
  echo "[build] WARN removed-packages.txt not found - skipping package strip"
fi

