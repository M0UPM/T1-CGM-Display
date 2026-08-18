#!/usr/bin/env bash
# Force a display mode.
#
# For when the machine can't read the TV's EDID and guesses wrong - which is
# the normal state of affairs over VGA, and near-guaranteed through a
# VGA->HDMI converter. Symptoms: stuck at 1024x768, letterboxed, wrong
# aspect, or no output at all.
#
# Usage:
#   ./force-display.sh                       show what's connected
#   ./force-display.sh VGA-1 1920x1080@60    set it on the kernel cmdline
#   ./force-display.sh --revert              undo
#
# Takes effect after a reboot.

set -euo pipefail

GRUB_FILE=/etc/default/grub

show() {
    echo
    echo "Connectors:"
    for c in /sys/class/drm/card*-*/status; do
        [[ -e "$c" ]] || continue
        D="$(dirname "$c")"
        NAME="$(basename "$D" | sed 's/^card[0-9]*-//')"
        STATE="$(cat "$c")"
        printf '  %-12s %s\n' "$NAME" "$STATE"
        if [[ "$STATE" == "connected" ]]; then
            if [[ -s "$D/modes" ]]; then
                echo "      modes: $(head -5 "$D/modes" | tr '\n' ' ')"
            else
                echo "      modes: (none - EDID unreadable, you'll need to force one)"
            fi
        fi
    done
    echo
    echo "Current kernel cmdline:"
    echo "  $(cat /proc/cmdline)"
    echo
    echo "To force, e.g.:"
    echo "  $0 VGA-1 1920x1080@60"
    echo
    echo "Common safe choices if EDID is unreadable:"
    echo "  1920x1080@60   most TVs since ~2010"
    echo "  1280x720@60    older or fussy sets, and a safe first try"
    echo
    echo "If the TV cuts off the edges (overscan), append -M to disable"
    echo "margin compensation, or use the TV's own picture-size setting -"
    echo "look for 'Just Scan', 'Screen Fit', '1:1' or 'Full Pixel'."
}

revert() {
    sudo sed -i 's/ video=[^" ]*//g' "$GRUB_FILE"
    sudo update-grub
    echo "Reverted. Reboot to apply."
}

case "${1:-}" in
    ""|-h|--help) show; exit 0 ;;
    --revert) revert; exit 0 ;;
esac

CONNECTOR="$1"
MODE="${2:-}"

if [[ -z "$MODE" ]]; then
    echo "Give a mode too, e.g. $0 $CONNECTOR 1920x1080@60" >&2
    exit 1
fi

if [[ ! -e "$GRUB_FILE" ]]; then
    echo "No $GRUB_FILE - not a grub system." >&2
    echo "On a Pi, edit /boot/firmware/cmdline.txt instead and append:" >&2
    echo "  video=${CONNECTOR}:${MODE}" >&2
    exit 1
fi

VIDEO="video=${CONNECTOR}:${MODE}"

sudo cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
sudo sed -i 's/ video=[^" ]*//g' "$GRUB_FILE"
sudo sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${VIDEO}\"/" "$GRUB_FILE"

echo "Set: $VIDEO"
grep '^GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB_FILE"

sudo update-grub
echo
echo "Reboot to apply. If it comes up blank, hold Shift at boot, edit the"
echo "entry and remove the video= argument to get back in."
