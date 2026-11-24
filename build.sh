#!/usr/bin/env bash
# Build Profligacy (MAME core + JUCE plugin) with a TEMPORARY swap file.
# The swap file is created before the build and always removed afterwards
# (also on Ctrl-C or a failed build). /etc/fstab is never touched.
#
# Usage:   ./build.sh [--deps] [--optimize]
#            --deps      apt install the build dependencies first
#            --optimize  build MAME with -mcpu=cortex-a76 (Raspberry Pi 5 only; the
#                        result will not run on a Pi 4). Switching this flag on or
#                        off rebuilds the whole MAME core (hours on a Pi).
# Options: SWAP_GB=6  JOBS=n  BUILD_DIR=build  (environment variables)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

SWAP_GB="${SWAP_GB:-6}"
SWAPFILE="${SWAPFILE:-/swapfile-profligacy-build}"
BUILD_DIR="${BUILD_DIR:-build}"
SWAP_ACTIVE=0

cleanup() {
	if [[ "$SWAP_ACTIVE" == 1 ]]; then
		echo ">> removing temporary swap $SWAPFILE"
		sudo swapoff "$SWAPFILE" || true
		sudo rm -f "$SWAPFILE"
	fi
}
trap cleanup EXIT

DO_DEPS=0
for arg in "$@"; do
	case "$arg" in
		--deps) DO_DEPS=1 ;;
		--optimize)
			if [[ "$(uname -m)" != aarch64 ]]; then
				echo "error: --optimize is only for aarch64 (Raspberry Pi 5)" >&2
				exit 1
			fi
			export MAME_ARCHOPTS="-mcpu=cortex-a76" ;;
		*) echo "error: unknown option $arg" >&2; exit 1 ;;
	esac
done

if [[ "$DO_DEPS" == 1 ]]; then
	sudo apt update
	sudo apt install -y build-essential cmake git python3 pkg-config \
		libsdl2-dev libsdl2-ttf-dev libpulse-dev libx11-dev libxext-dev libxi-dev \
		libxinerama-dev libxrandr-dev libxcursor-dev libxcomposite-dev \
		libfontconfig1-dev libfreetype-dev libasound2-dev libgl-dev \
		libgtk-3-dev libwebkit2gtk-4.1-dev
fi

# --- temporary swap ---------------------------------------------------------
if [[ -e "$SWAPFILE" ]]; then
	echo "error: $SWAPFILE already exists; remove it first (sudo swapoff $SWAPFILE; sudo rm $SWAPFILE)" >&2
	exit 1
fi
avail_gb=$(( $(df --output=avail -k "$(dirname "$SWAPFILE")" | tail -1) / 1024 / 1024 ))
if (( avail_gb < SWAP_GB + 2 )); then
	echo "error: only ${avail_gb} GB free for a ${SWAP_GB} GB swap file" >&2
	exit 1
fi
echo ">> creating temporary ${SWAP_GB} GB swap at $SWAPFILE"
sudo fallocate -l "${SWAP_GB}G" "$SWAPFILE" 2>/dev/null \
	|| sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( SWAP_GB * 1024 )) status=progress
sudo chmod 600 "$SWAPFILE"
sudo mkswap "$SWAPFILE" >/dev/null
sudo swapon "$SWAPFILE"
SWAP_ACTIVE=1
swapon --show

# --- build ------------------------------------------------------------------
git submodule update --init --recursive

# --regen only on the first run; later runs are incremental.
if [[ -d extern/mame/build/linux_gcc || -d extern/mame/build/projects/sdl/mamepropmin/gmake-linux ]]; then
	scripts/build_mame_core.sh
else
	scripts/build_mame_core.sh --regen
fi

cmake -S . -B "$BUILD_DIR"
cmake --build "$BUILD_DIR" -j"${JOBS:-$(nproc)}"

echo ">> build done"
find "$BUILD_DIR" -maxdepth 4 \( -name 'Profligacy.lv2' -o -name 'Profligacy.vst3' \) | sed 's/^/   /'
