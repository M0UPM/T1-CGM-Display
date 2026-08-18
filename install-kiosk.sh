#!/usr/bin/env bash
# TV kiosk setup.
#
# Puts Chromium fullscreen on the Nightscout colour clock view, kills screen
# blanking and the mouse pointer, and survives a reboot.
#
# Handles three setups:
#   cage     - plain Debian/Ubuntu. Dedicated kiosk compositor, boots
#              straight to the browser on tty1. Best option for a machine
#              whose only job is the display.
#   labwc    - Pi OS Trixie and later
#   wayfire  - Pi OS Bookworm
#
# Run as the user who'll own the display, NOT with sudo:
#   ./install-kiosk.sh
#
# Most kiosk guides tell you to use xset/X11 to stop screen blanking. That
# does nothing on any of the above - they're all Wayland.

set -euo pipefail

# ---- config --------------------------------------------------------------

# Which view to show. clock-color.html is the one you want on a TV: big
# number, trend arrow, whole background colour-coded by threshold so it
# reads from across the room before anyone parses the digits.
#   /clock-color.html  colour background, BG + arrow
#   /bgclock.html      grey on black, BG + arrow + time of day
#   /clock.html        just the number
#   /                  full graph view - better for the first few weeks
#                      while you're still learning her patterns
KIOSK_URL="${KIOSK_URL:-http://localhost:8080/}"

USER_NAME="$(id -un)"
USER_UID="$(id -u)"

# ---- checks --------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Run this as your normal desktop user, not root." >&2
    exit 1
fi

if command -v chromium >/dev/null 2>&1; then
    CHROMIUM="$(command -v chromium)"
elif command -v chromium-browser >/dev/null 2>&1; then
    CHROMIUM="$(command -v chromium-browser)"
else
    echo "Chromium not found." >&2
    echo "  Debian:  sudo apt install chromium" >&2
    echo "  Pi OS:   sudo apt install chromium-browser" >&2
    exit 1
fi
echo "Using: $CHROMIUM"

# ---- pick a backend ------------------------------------------------------
# Override with:  KIOSK_BACKEND=x11 ./install-kiosk.sh
# Use x11 if cage refuses to start - typically a GPU with no KMS support,
# which is likely on anything old enough to be VGA-only.

if [[ -n "${KIOSK_BACKEND:-}" ]]; then
    MODE="$KIOSK_BACKEND"
elif [[ -f "$HOME/.config/wayfire.ini" ]] || pgrep -x wayfire >/dev/null 2>&1; then
    MODE=wayfire
elif [[ -d "$HOME/.config/labwc" ]] || pgrep -x labwc >/dev/null 2>&1 \
     || grep -qi raspbian /etc/os-release 2>/dev/null; then
    MODE=labwc
elif [[ ! -e /dev/dri/card0 ]]; then
    echo "No /dev/dri - no KMS. Falling back to X11."
    MODE=x11
else
    MODE=cage
fi

echo "Mode: $MODE"

if [[ "$MODE" == "x11" ]]; then
    OZONE_FLAG=""
    # Old Intel graphics: software rendering beats broken GPU compositing.
    GPU_FLAGS="--disable-gpu --disable-software-rasterizer=false"
else
    OZONE_FLAG="--ozone-platform=wayland"
    GPU_FLAGS="${GPU_FLAGS:-}"
fi

# ---- launcher ------------------------------------------------------------
# Waits for Nightscout to answer before opening the browser, otherwise
# Chromium's error page gets baked onto the TV until someone notices.

mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/ns-kiosk.sh" <<EOF
#!/usr/bin/env bash
URL="\${KIOSK_URL:-$KIOSK_URL}"

for i in \$(seq 1 60); do
    curl -sf -o /dev/null "http://localhost:8080/api/v1/status.json" && break
    sleep 5
done

# Under X11 (the fallback backend for old GPUs), kill blanking and DPMS.
# Under Wayland these are no-ops and the compositor handles it instead.
if [[ -n "\${DISPLAY:-}" ]] && command -v xset >/dev/null 2>&1; then
    xset s off
    xset s noblank
    xset -dpms
fi

# Only under X11. On Wayland (cage/labwc/wayfire) the compositor handles the
# pointer, and unclutter burns a whole core fighting Xwayland for no benefit.
if [[ -n "\${DISPLAY:-}" ]] && command -v unclutter >/dev/null 2>&1; then
    unclutter -idle 0 &
fi

# GPU_FLAGS is set by the installer. On old Intel graphics - which is what
# you'll find in anything VGA-only - Chromium's GPU compositing is often
# slower than software rendering, or crashes outright. --disable-gpu is the
# cure, and costs nothing for a page showing one big number.
exec "$CHROMIUM" \\
    --kiosk \\
    --incognito \\
    --noerrdialogs \\
    --disable-infobars \\
    --disable-session-crashed-bubble \\
    --disable-features=Translate \\
    --check-for-update-interval=31536000 \\
    --disable-background-networking \\
    --disable-background-timer-throttling \\
    --disable-component-update \\
    --disable-sync \\
    --disable-breakpad \\
    --disable-domain-reliability \\
    --disable-client-side-phishing-detection \\
    --no-first-run \\
    --no-default-browser-check \\
    --metrics-recording-only \\
    ${GPU_FLAGS:-} \\
    ${OZONE_FLAG} \\
    "\$URL"
EOF
chmod +x "$HOME/.local/bin/ns-kiosk.sh"

case "$MODE" in

wayfire)
    WF="$HOME/.config/wayfire.ini"
    touch "$WF"
    grep -q '^\[autostart\]' "$WF" || printf '\n[autostart]\n' >> "$WF"
    grep -q '^ns_kiosk' "$WF" || \
        sed -i "/^\[autostart\]/a ns_kiosk = $HOME/.local/bin/ns-kiosk.sh" "$WF"
    grep -q '^\[idle\]' "$WF" || \
        printf '\n[idle]\ndpms_timeout = -1\nscreensaver_timeout = -1\n' >> "$WF"
    echo "wayfire autostart written."
    ;;

labwc)
    mkdir -p "$HOME/.config/labwc"
    AS="$HOME/.config/labwc/autostart"
    touch "$AS"
    grep -q 'ns-kiosk.sh' "$AS" || echo "$HOME/.local/bin/ns-kiosk.sh &" >> "$AS"
    chmod +x "$AS"
    echo "labwc autostart written."
    ;;

cage)
    # Plain Debian. cage is a Wayland compositor that runs exactly one
    # application fullscreen - purpose-built for this. No desktop, no panel,
    # no login screen, boots straight to the display.
    if ! command -v cage >/dev/null 2>&1; then
        echo "Installing cage..."
        sudo apt-get update -qq
        sudo apt-get install -y cage
    fi
    # No unclutter here - see the note in the launcher. It's an X11 tool and
    # costs a core under Wayland.

    # cage talks to the GPU directly via DRM/KMS - without these groups it
    # fails to open /dev/dri/card0 and never draws anything.
    echo "Adding ${USER_NAME} to video and render groups..."
    sudo usermod -aG video,render "${USER_NAME}"

    echo "Writing systemd service..."
    sudo tee /etc/systemd/system/ns-kiosk.service >/dev/null <<EOF
[Unit]
Description=T1 CGM display kiosk
After=docker.service systemd-user-sessions.service
Wants=docker.service

[Service]
Type=simple
User=${USER_NAME}
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
Environment=XDG_RUNTIME_DIR=/run/user/${USER_UID}
Environment=XDG_SESSION_TYPE=wayland
Environment=KIOSK_URL=${KIOSK_URL}
ExecStart=/usr/bin/cage -d -- ${HOME}/.local/bin/ns-kiosk.sh
Restart=always
RestartSec=5

[Install]
# multi-user.target, NOT graphical.target - this script sets the box to boot
# to console, so a graphical.target unit is enabled but never started and
# leaves you with a blank TV and an empty journal.
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable ns-kiosk.service

    # Boot to console, not a desktop login. cage takes tty1 from there.
    echo "Setting default target to multi-user (no desktop login)..."
    sudo systemctl set-default multi-user.target

    echo
    echo "cage kiosk service installed and enabled."
    echo "  start now:  sudo systemctl start ns-kiosk"
    echo "  logs:       journalctl -u ns-kiosk -f"
    echo
    echo "To get a normal desktop back later:"
    echo "  sudo systemctl disable --now ns-kiosk"
    echo "  sudo systemctl set-default graphical.target"
    ;;

x11)
    # Fallback for hardware wlroots won't touch. Bare X, no window manager -
    # Chromium in kiosk mode is the only client, so there's nothing to manage.
    echo "Installing X11 bits..."
    sudo apt-get update -qq
    sudo apt-get install -y xserver-xorg xinit x11-xserver-utils unclutter

    # Let any user start X on the console, otherwise xinit from a service
    # is refused.
    sudo tee /etc/X11/Xwrapper.config >/dev/null <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

    sudo tee /etc/systemd/system/ns-kiosk.service >/dev/null <<EOF
[Unit]
Description=T1 CGM display kiosk (X11)
After=docker.service systemd-user-sessions.service
Wants=docker.service

[Service]
Type=simple
User=${USER_NAME}
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty-fail
StandardOutput=journal
StandardError=journal
Environment=KIOSK_URL=${KIOSK_URL}
ExecStart=/usr/bin/xinit ${HOME}/.local/bin/ns-kiosk.sh -- :0 vt1 -nolisten tcp -novtswitch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable ns-kiosk.service
    sudo systemctl set-default multi-user.target

    echo
    echo "X11 kiosk service installed and enabled."
    echo "  start now:  sudo systemctl start ns-kiosk"
    echo "  logs:       journalctl -u ns-kiosk -f"
    echo
    echo "If the resolution is wrong, force it - see README > VGA."
    ;;

*)
    echo "Unknown KIOSK_BACKEND '$MODE'. Use cage, x11, labwc or wayfire." >&2
    exit 1
    ;;
esac

# ---- screen blanking -----------------------------------------------------

echo
if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_blanking 1 2>/dev/null \
        && echo "Screen blanking disabled." \
        || echo "Set blanking off by hand: raspi-config > Display Options"
else
    # cage passes -d (don't sleep). Also stop console blanking on the tty
    # underneath, which otherwise blacks the screen after 10 minutes.
    sudo tee /etc/systemd/system/disable-console-blank.service >/dev/null <<'EOF'
[Unit]
Description=Disable console blanking

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'setterm --blank 0 --powerdown 0 >/dev/tty1 || true'

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable disable-console-blank.service >/dev/null 2>&1 || true
    echo "Console blanking disabled."
fi

echo
echo "Done. Reboot to test:  sudo reboot"
echo "URL on display: $KIOSK_URL"
