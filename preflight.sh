#!/usr/bin/env bash
# Preflight checks. Run this FIRST, on whatever box you're deploying to.
#
# Tells you which MONGO_TAG to set and flags anything that'll bite later.
#   ./preflight.sh

set -uo pipefail

PASS="  [ ok ]"
WARN="  [warn]"
FAIL="  [FAIL]"

echo
echo "T1 CGM Display - preflight"
echo "=============================="
echo

# ---- architecture --------------------------------------------------------

ARCH="$(uname -m)"
echo "Architecture: ${ARCH}"

MONGO_TAG="7"

case "$ARCH" in
    x86_64|amd64)
        # MongoDB 5.0+ needs AVX. Absent on older chips AND on plenty of
        # current low-power ones - Celeron, Atom, Pentium Silver, N-series.
        # Without it mongod dies at startup: Illegal instruction (core dumped)
        if grep -qm1 '^flags.*\bavx\b' /proc/cpuinfo; then
            echo "$PASS AVX present - MongoDB 7 is fine"
        else
            MONGO_TAG="4.4"
            echo "$WARN No AVX on this CPU."
            echo "       MongoDB 5.0+ will crash with 'Illegal instruction'."
            echo "       Set MONGO_TAG=4.4 in .env"
            echo "       (4.4 is EOL - acceptable on a LAN-only box with no"
            echo "        inbound exposure, but know that's the trade.)"
        fi
        ;;
    aarch64|arm64)
        # Mongo 5+ needs ARMv8.2-A. Pi 5 (Cortex-A76) yes, Pi 4 (A72) no.
        if grep -qm1 'asimdrdm\|lse\|atomics' /proc/cpuinfo; then
            echo "$PASS ARMv8.2-A features present - MongoDB 7 should be fine"
        else
            MONGO_TAG="4.4"
            echo "$WARN CPU looks pre-ARMv8.2-A (Pi 4 or older)."
            echo "       Set MONGO_TAG=4.4 in .env"
        fi
        ;;
    armv7l|armhf)
        echo "$FAIL 32-bit ARM. MongoDB 4+ is arm64 only."
        echo "       Reinstall with a 64-bit OS."
        exit 1
        ;;
    *)
        echo "$WARN Unrecognised architecture - proceed carefully"
        ;;
esac

echo

# ---- docker --------------------------------------------------------------

if command -v docker >/dev/null 2>&1; then
    echo "$PASS docker present: $(docker --version | cut -d, -f1)"
    if docker compose version >/dev/null 2>&1; then
        echo "$PASS docker compose plugin present"
    else
        echo "$FAIL 'docker compose' not available. Install docker-compose-plugin."
    fi
    if ! docker ps >/dev/null 2>&1; then
        echo "$WARN can't talk to the docker socket as $(whoami)"
        echo "       sudo usermod -aG docker $(whoami)  (then log out and back in)"
    fi
else
    echo "$FAIL docker not installed:  curl -fsSL https://get.docker.com | sh"
fi

echo

# ---- storage -------------------------------------------------------------

ROOT_DEV="$(findmnt -no SOURCE / 2>/dev/null | sed 's/[0-9]*$//')"
if [[ "$ROOT_DEV" == *mmcblk* ]]; then
    echo "$WARN Root filesystem is on an SD card."
    echo "       Libre 2 Plus streams every minute; Mongo will write"
    echo "       continuously and eat the card. Move to SSD or NVMe."
else
    echo "$PASS Root filesystem is not an SD card"
fi

AVAIL_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if (( AVAIL_GB < 10 )); then
    echo "$WARN Only ${AVAIL_GB}G free on /"
else
    echo "$PASS ${AVAIL_GB}G free on /"
fi

echo

# ---- display / compositor ------------------------------------------------

if command -v chromium >/dev/null 2>&1; then
    echo "$PASS chromium present"
elif command -v chromium-browser >/dev/null 2>&1; then
    echo "$PASS chromium-browser present"
else
    echo "$WARN Chromium not installed."
    echo "       Debian:  sudo apt install chromium"
    echo "       Pi OS:   sudo apt install chromium-browser"
fi

if command -v cage >/dev/null 2>&1; then
    echo "$PASS cage present (recommended kiosk compositor for a plain PC)"
elif pgrep -x wayfire >/dev/null 2>&1 || pgrep -x labwc >/dev/null 2>&1; then
    echo "$PASS Pi OS compositor running - install-kiosk.sh will use autostart"
else
    echo "$WARN No kiosk compositor found."
    echo "       On Debian:  sudo apt install cage"
    echo "       install-kiosk.sh will then set up a proper kiosk session."
fi

echo

# ---- display outputs -----------------------------------------------------

echo "Display outputs:"
FOUND_ANY=0
HAS_VGA=0
HAS_DIGITAL=0

for c in /sys/class/drm/card*-*/status; do
    [[ -e "$c" ]] || continue
    NAME="$(basename "$(dirname "$c")" | sed 's/^card[0-9]*-//')"
    STATE="$(cat "$c" 2>/dev/null || echo unknown)"
    FOUND_ANY=1

    # Native mode, if EDID could be read at all
    MODES="$(dirname "$c")/modes"
    TOPMODE="$(head -1 "$MODES" 2>/dev/null || true)"

    if [[ "$STATE" == "connected" ]]; then
        echo "$PASS ${NAME}: connected${TOPMODE:+ (${TOPMODE})}"
        case "$NAME" in
            VGA*|SVIDEO*) HAS_VGA=1 ;;
            HDMI*|DP*|eDP*|DVI*) HAS_DIGITAL=1 ;;
        esac
        if [[ -z "$TOPMODE" ]]; then
            echo "       No modes listed - EDID couldn't be read."
            echo "       You'll need to force the resolution. See README > VGA."
        fi
    else
        echo "       ${NAME}: ${STATE}"
    fi
done

if (( FOUND_ANY == 0 )); then
    echo "$WARN No DRM connectors found. Headless, or a very old/unsupported GPU."
    echo "       If the GPU has no KMS support, cage won't start - use the"
    echo "       X11 fallback:  KIOSK_BACKEND=x11 ./install-kiosk.sh"
fi

if (( HAS_VGA == 1 && HAS_DIGITAL == 0 )); then
    echo
    echo "$WARN VGA only."
    echo "       - If the TV has no VGA socket you need an ACTIVE VGA->HDMI"
    echo "         converter. A passive cable will not work."
    echo "       - Expect EDID trouble. See README > VGA and analogue output."
fi

# GPU age check - wlroots (cage) needs working KMS/GBM
if [[ -e /dev/dri/card0 ]]; then
    echo "$PASS /dev/dri present - KMS available, cage should work"
else
    echo "$WARN No /dev/dri. cage/wlroots will not start."
    echo "       Use:  KIOSK_BACKEND=x11 ./install-kiosk.sh"
fi

echo

echo
echo "=============================="
echo "Suggested .env setting:"
echo
echo "  MONGO_TAG=${MONGO_TAG}"
echo
