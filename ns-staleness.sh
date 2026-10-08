#!/usr/bin/env bash
# Staleness watchdog for the LibreLinkUp bridge.
#
# This is NOT a glucose alarm and must never become one. Harper's Libre app is
# the safety layer and stays that way. This watches the *plumbing*: it tells
# you when the feed has stopped, which is a different problem with a different
# urgency and a different response.
#
# The failure it exists for: the bridge dies - Abbott bumps the app version,
# DNS breaks inside the container, the region setting gets reverted - and
# Nightscout keeps serving the last reading it got. The kitchen display
# handles that honestly on its own (colour drains, age in a black badge), but
# nothing tells you if you are not in the kitchen.
#
# Notifies once when the feed goes stale and once when it comes back. It does
# not repeat every ten minutes, because an alert you learn to ignore is worse
# than no alert at all.
#
# Run from a systemd timer every 10 minutes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
[[ -f .env ]] && { set -a; source .env; set +a; }

NS="${NS_URL:-http://localhost:1337}"

# Libre 2 Plus streams every minute and LibreLinkUp batches, so 20 minutes of
# silence is well past anything explainable by a missed poll. Raise it if the
# phone routinely wanders out of range and you start getting noise.
STALE_MINUTES="${STALE_MINUTES:-20}"

# Remembers whether the current outage has already been reported.
STATE="${SCRIPT_DIR}/.staleness-state"

log() { echo "[$(date -Is)] $*"; }

# ---- notification --------------------------------------------------------

# The poller writes a specific reason here when it hits something a retry
# won't fix (e.g. Terms of Use re-acceptance). Surface it in the alert so the
# 4am message says what to actually do, not just "something's wrong".
POLLER_STATUS="${SCRIPT_DIR}/.poller-status"
poller_reason() {
    [[ -f "$POLLER_STATUS" ]] || return 0
    # Only trust it if it's recent (updated in the last 2 hours), so a stale
    # leftover reason can't mislead.
    local age_s=$(( $(date +%s) - $(stat -c %Y "$POLLER_STATUS" 2>/dev/null || echo 0) ))
    (( age_s < 7200 )) || return 0
    cat "$POLLER_STATUS"
}

notify() {
    local msg="$1"
    log "$msg"

    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        curl -sf -m 15 \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${msg}" \
            -d "disable_web_page_preview=true" \
            >/dev/null || log "telegram send failed"
    fi

    # Anything else already in use - ntfy, a webhook, whatever.
    if [[ -n "${NOTIFY_URL:-}" ]]; then
        curl -sf -m 10 -d "$msg" "$NOTIFY_URL" >/dev/null || log "notify failed"
    fi
}

was_stale()   { [[ -f "$STATE" ]]; }
mark_stale()  { date -Is > "$STATE"; }
clear_stale() { rm -f "$STATE"; }

# ---- check ---------------------------------------------------------------

# Tolerate whitespace after the colon - not every JSON emitter omits it.
LATEST=$(curl -sf -m 15 "${NS}/api/v1/entries.json?count=1" \
    | grep -o '"date"[[:space:]]*:[[:space:]]*[0-9]*' \
    | head -1 | grep -o '[0-9]*$') || true

if [[ -z "${LATEST:-}" ]]; then
    if was_stale; then
        log "still down, already notified"
    else
        mark_stale
        notify "Nightscout: no readings returned by the API.
Is the stack up?   docker compose ps"
    fi
    exit 1
fi

NOW=$(date +%s%3N)
AGE_MIN=$(( (NOW - LATEST) / 60000 ))

if (( AGE_MIN > STALE_MINUTES )); then
    if was_stale; then
        log "still stale (${AGE_MIN} min), already notified"
        exit 1
    fi
    mark_stale
    REASON="$(poller_reason)"
    notify "Glucose feed stopped - last reading ${AGE_MIN} min ago.
${REASON:+
>> $REASON
}
The display has greyed out, so it is not showing a stale number as if it
were live. The Libre app is unaffected and still alarming.

Usual causes, most likely first:
 - phone out of Bluetooth range of the sensor
 - LibreLinkUp region reverted (needs EU2)
 - container DNS
 - Abbott bumped the app version (LINK_UP_VERSION)

   docker compose logs --tail=30 librelink"
    exit 1
fi

if was_stale; then
    clear_stale
    notify "Glucose feed is back - newest reading ${AGE_MIN} min old."
fi

log "ok - newest reading ${AGE_MIN} min old"
