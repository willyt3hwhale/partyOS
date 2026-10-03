#!/bin/bash
# extract-game-icons.sh - pull each game blob's NATIVE app icon out of its squashfs
# into server/games/icons/<name>.png, so the desktop launchers can show real icons
# instead of the generic category gamepad. Games are blobs (not installed
# system-wide), so their icons aren't in the image's icon theme - we bake these
# extracted PNGs into the image instead (build-custom-image.sh).
#
# Needs unsquashfs (+ imagemagick/librsvg to normalize svg/xpm -> png). macOS can't
# read squashfs, so on a non-Linux/no-unsquashfs host it re-execs in a container.
set -euo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GDIR="${1:-$(cd "${SD}/../../server/games" && pwd)}"

# In a pacman env (Arch / the container), make sure the tools are present.
if command -v pacman >/dev/null 2>&1; then
    if ! command -v unsquashfs >/dev/null 2>&1 || ! command -v convert >/dev/null 2>&1; then
        printf '\nDisableSandbox\n' >> /etc/pacman.conf 2>/dev/null || true
        # Upgrade the container FIRST. archlinux:latest lags the repos, so a freshly
        # installed imagemagick links a newer glibc than the image ships and every
        # convert call dies with "GLIBC_2.xx not found" - which silently fell back to
        # copying the raw icon file under a .png name. Same skew the proton builder
        # already works around. --overwrite: the split-lib packages ship files the
        # image already owns.
        pacman -Syu --noconfirm --overwrite '*' >/dev/null 2>&1 || true
        pacman -S --noconfirm --needed squashfs-tools imagemagick librsvg >/dev/null 2>&1 || true
    fi
fi
# Still missing a tool (e.g. macOS host has unsquashfs but no imagemagick) -> run
# the whole thing in an archlinux container that has both.
if ! command -v unsquashfs >/dev/null 2>&1 || ! command -v convert >/dev/null 2>&1; then
    echo "[icons] need unsquashfs+convert -> running in archlinux container..."
    exec docker run --rm --platform linux/amd64 \
        -v "$(cd "${SD}/../../server/games" && pwd):/g" -v "${SD}:/s:ro" archlinux:latest \
        bash /s/extract-game-icons.sh /g
fi

# --- work (native Linux or in-container) -------------------------------------
mkdir -p "${GDIR}/icons"

for sq in "${GDIR}"/*.squashfs; do
    [ -f "${sq}" ] || continue
    name="$(basename "${sq}" .squashfs)"
    rm -rf /tmp/x
    unsquashfs -n -d /tmp/x "${sq}" \
        usr/share/applications usr/share/icons usr/share/pixmaps >/dev/null 2>&1 || true

    # the game's icon NAME: from <name>.desktop, else a Game-category .desktop, else first
    dt="/tmp/x/usr/share/applications/${name}.desktop"
    [ -f "${dt}" ] || dt="$(grep -lE '^Categories=.*Game' /tmp/x/usr/share/applications/*.desktop 2>/dev/null | head -1 || true)"
    [ -n "${dt}" ] && [ -f "${dt}" ] || dt="$(ls /tmp/x/usr/share/applications/*.desktop 2>/dev/null | head -1 || true)"
    icon=""
    [ -n "${dt}" ] && icon="$(grep -h '^Icon=' "${dt}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]')"
    [ -n "${icon}" ] || icon="${name}"

    # icon NAME -> a source file: largest hicolor png, else scalable svg, else pixmaps
    src=""
    # Icon= may be an ABSOLUTE PATH rather than a theme name, and the file may be a
    # .ico (ezquake ships Icon=/usr/share/pixmaps/ezquake.ico). Resolve that against
    # the extracted tree first; the name-based lookups below never match a path.
    case "${icon}" in
        /*) [ -f "/tmp/x${icon}" ] && src="/tmp/x${icon}"
            icon="$(basename "${icon}")"; icon="${icon%.*}" ;;
    esac
    for sz in 512x512 256x256 192x192 128x128 96x96 64x64 48x48; do
        f="/tmp/x/usr/share/icons/hicolor/${sz}/apps/${icon}.png"
        [ -f "${f}" ] && { src="${f}"; break; }
    done
    [ -n "${src}" ] || { f="/tmp/x/usr/share/icons/hicolor/scalable/apps/${icon}.svg"; [ -f "${f}" ] && src="${f}"; }
    # some packages drop the icon straight in usr/share/icons/<name>.png (e.g. warzone2100)
    [ -n "${src}" ] || src="$(ls /tmp/x/usr/share/icons/${icon}.png /tmp/x/usr/share/icons/${icon}.svg 2>/dev/null | head -1 || true)"
    [ -n "${src}" ] || src="$(ls /tmp/x/usr/share/pixmaps/${icon}.png /tmp/x/usr/share/pixmaps/${icon}.svg /tmp/x/usr/share/pixmaps/${icon}.xpm 2>/dev/null | head -1 || true)"
    [ -n "${src}" ] || src="$(find /tmp/x -name "${icon}.png" 2>/dev/null | sort | tail -1 || true)"

    if [ -z "${src}" ]; then echo "[icons] ${name}: NO ICON found (icon name='${icon}')"; continue; fi
    # normalize to a <=256 png (never upscale a tiny one)
    if convert "${src}" -background none -resize '256x256>' "${GDIR}/icons/${name}.png" 2>/dev/null; then :; else
        cp "${src}" "${GDIR}/icons/${name}.png"
    fi
    # A .ico holds several frames, so convert writes <name>-0.png, <name>-1.png ...
    # instead of one file. Keep the largest frame and drop the rest.
    if [ ! -f "${GDIR}/icons/${name}.png" ]; then
        big="$(ls -S "${GDIR}/icons/${name}"-*.png 2>/dev/null | head -1 || true)"
        [ -n "${big}" ] && mv "${big}" "${GDIR}/icons/${name}.png"
    fi
    rm -f "${GDIR}/icons/${name}"-*.png 2>/dev/null || true
    echo "[icons] ${name} <- ${icon} ($(basename "${src}"))"
done
echo "[icons] done -> ${GDIR}/icons/"
ls -1 "${GDIR}/icons/" 2>/dev/null | sed 's/^/  /'
