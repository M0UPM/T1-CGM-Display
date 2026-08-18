#!/usr/bin/env bash
# Guided setup.
#
# Walks through the whole build, validating each thing as you enter it rather
# than letting you discover at the end that a password was wrong or a region
# was EU2. Safe to re-run - it reads your existing .env and offers to keep
# what's already working.
#
#   ./setup.sh
#
# Nothing here is irreversible without asking first.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'
YEL=$'\e[33m'; CYA=$'\e[36m'; OFF=$'\e[0m'

ENV_FILE=.env
say()  { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n%s\n' "$BOLD" "$*" "$OFF" "$(printf '─%.0s' {1..60})"; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$YEL" "$OFF" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$OFF"; }

ask() {  # ask <prompt> <default>
    local prompt="$1" def="${2:-}" reply
    if [[ -n "$def" ]]; then
        read -r -p "  ${prompt} [${def}]: " reply
        printf '%s' "${reply:-$def}"
    else
        read -r -p "  ${prompt}: " reply
        printf '%s' "$reply"
    fi
}

ask_secret() {
    local prompt="$1" reply
    read -r -s -p "  ${prompt}: " reply; echo >&2
    printf '%s' "$reply"
}

yes_no() {  # yes_no <question> <default y|n>
    local q="$1" def="${2:-y}" reply hint
    [[ "$def" == "y" ]] && hint="Y/n" || hint="y/N"
    read -r -p "  ${q} [${hint}]: " reply
    reply="${reply:-$def}"
    [[ "${reply,,}" == y* ]]
}

set_env() {  # set_env KEY VALUE  - replace or append, never duplicate
    local k="$1" v="$2"
    touch "$ENV_FILE"
    if grep -q "^${k}=" "$ENV_FILE"; then
        # value may contain / and & - use a delimiter that won't appear
        python3 - "$ENV_FILE" "$k" "$v" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
out, done = [], False
for line in open(path).read().splitlines():
    if line.startswith(key + "=") and not done:
        out.append(f"{key}={val}"); done = True
    elif line.startswith(key + "="):
        continue          # drop duplicates
    else:
        out.append(line)
if not done:
    out.append(f"{key}={val}")
open(path, "w").write("\n".join(out) + "\n")
PY
    else
        printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
    fi
}

get_env() { [[ -f "$ENV_FILE" ]] && grep "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true; }

# ===========================================================================

clear
cat <<'BANNER'
  ┌────────────────────────────────────────────────────────┐
  │  T1 CGM Display - guided setup                    │
  └────────────────────────────────────────────────────────┘
BANNER

cat <<'INTRO'

  Before anything else, the important bit:

  This is NOT an alarm system. It does not alert on glucose values and
  must never be relied on to. Your CGM app stays the alarm - it is the
  regulated path and it is what wakes you at night.

  This is a record and a wall display. Nothing more.

INTRO
yes_no "Understood?" y || { say "  Fair enough. Nothing changed."; exit 0; }

# ---- 1. preflight ---------------------------------------------------------

head1 "1. Checking this machine"
if [[ -x ./preflight.sh ]]; then
    ./preflight.sh | sed 's/^/  /'
    echo
    yes_no "Continue?" y || exit 0
else
    warn "preflight.sh not found, skipping hardware checks"
fi

if ! command -v docker >/dev/null 2>&1; then
    bad "Docker is not installed."
    note "curl -fsSL https://get.docker.com | sh"
    note "sudo usermod -aG docker \$USER    # then log out and back in"
    exit 1
fi
if ! docker ps >/dev/null 2>&1; then
    bad "Can't talk to Docker as $(whoami)."
    note "sudo usermod -aG docker \$USER    # then log out and back in"
    exit 1
fi
ok "Docker is working"

MONGO_TAG=7
if ! grep -qm1 '^flags.*\bavx\b' /proc/cpuinfo 2>/dev/null; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
        MONGO_TAG=4.4
        warn "No AVX on this CPU - using MongoDB 4.4 (EOL, but 5+ won't start)"
    fi
fi
set_env MONGO_TAG "$MONGO_TAG"

# ---- 2. basics ------------------------------------------------------------

head1 "2. Basic settings"

EXISTING_SECRET="$(get_env API_SECRET)"
if [[ -n "$EXISTING_SECRET" && "$EXISTING_SECRET" != change_me* ]]; then
    ok "API_SECRET already set - keeping it"
    note "changing it would invalidate every access token"
    API_SECRET="$EXISTING_SECRET"
else
    say ""
    note "This is the master password for Nightscout. Pick it once - changing"
    note "it later invalidates every access token."
    if yes_no "Generate a strong one automatically?" y; then
        API_SECRET=$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
        ok "Generated: ${API_SECRET}"
        note "write this down somewhere - you'll need it to log in"
    else
        while :; do
            API_SECRET=$(ask_secret "API secret (12+ chars)")
            [[ ${#API_SECRET} -ge 12 ]] && break
            bad "Too short - Nightscout requires 12 characters minimum"
        done
    fi
    set_env API_SECRET "$API_SECRET"
fi

IP=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
IP="${IP:-127.0.0.1}"
say ""
note "How will you reach this machine from a phone or laptop?"
BASE_HOST=$(ask "Address" "$IP")
set_env BASE_URL "http://${BASE_HOST}:1337"
set_env NS_BIND "0.0.0.0"
ok "BASE_URL = http://${BASE_HOST}:1337"

# ---- 3. LibreLinkUp -------------------------------------------------------

head1 "3. CGM data source (LibreLinkUp)"
cat <<'LLU'

  You need a SECOND LibreView account - one that FOLLOWS the sensor, not
  the account the sensor is registered to.

  To set it up:
    1. Create a second account at libreview.com
    2. In the FreeStyle LibreLink app on the phone with the sensor:
         menu -> Connected apps -> LibreLinkUp -> Manage -> Add connection
       and invite that second account
    3. Accept the invite in the LibreLinkUp app (orange icon), signed in
       as the second account

LLU

if yes_no "Ready to enter the FOLLOWER account details?" y; then
    LLU_USER=$(ask "Follower email" "$(get_env LINK_UP_USERNAME)")
    LLU_PASS=$(ask_secret "Follower password")
    [[ -z "$LLU_PASS" ]] && LLU_PASS="$(get_env LINK_UP_PASSWORD)"

    # Try both EU endpoints so nobody has to discover EU2 from a log file.
    say ""
    printf '  testing login'
    REGION=""
    for R in EU EU2; do
        printf '.'
        HOST="api-eu.libreview.io"; [[ "$R" == "EU2" ]] && HOST="api-eu2.libreview.io"
        RESP=$(curl -s -m 20 -X POST "https://${HOST}/llu/auth/login" \
            -H 'Content-Type: application/json' \
            -H 'product: llu.android' -H 'version: 4.16.0' \
            -H 'accept-encoding: gzip' \
            -d "{\"email\":\"${LLU_USER}\",\"password\":\"${LLU_PASS}\"}" 2>/dev/null)
        if echo "$RESP" | grep -q '"authTicket"'; then REGION="$R"; break; fi
        if echo "$RESP" | grep -qi 'redirect'; then continue; fi
    done
    echo

    if [[ -n "$REGION" ]]; then
        ok "Logged in - your account is on region ${REGION}"
        set_env LINK_UP_USERNAME "$LLU_USER"
        set_env LINK_UP_PASSWORD "$LLU_PASS"
        set_env LINK_UP_REGION "$REGION"
    else
        bad "Could not log in on either EU endpoint."
        note "Check the password, and that the follower invitation was ACCEPTED"
        note "in the LibreLinkUp app. Writing the details anyway so you can"
        note "fix them in .env later."
        set_env LINK_UP_USERNAME "$LLU_USER"
        set_env LINK_UP_PASSWORD "$LLU_PASS"
        set_env LINK_UP_REGION "EU"
        yes_no "Carry on regardless?" y || exit 1
    fi
fi

# ---- 4. bring up the stack ------------------------------------------------

head1 "4. Starting Nightscout"
chmod 600 "$ENV_FILE"
docker compose up -d mongo nightscout display 2>&1 | sed 's/^/  /'

printf '  waiting for Nightscout'
for i in $(seq 1 60); do
    if curl -sf -o /dev/null "http://localhost:1337/api/v1/status.json" 2>/dev/null; then
        echo; ok "Nightscout is up"; break
    fi
    printf '.'; sleep 3
    [[ $i -eq 60 ]] && { echo; bad "Timed out. Check: docker compose logs nightscout"; exit 1; }
done

# ---- 5. token, the bit everyone gets wrong --------------------------------

head1 "5. Creating the bridge access token"
cat <<'TOK'

  The bridge needs to write glucose readings, and no built-in Nightscout
  role allows that. Creating the role and subject through the web UI is
  fiddly, so this does it directly.

TOK

TOKEN_SUFFIX=$(head -c 8 /dev/urandom | xxd -p)
docker compose exec -T mongo mongosh nightscout --quiet --eval "
db.auth_roles.deleteMany({name: {\$in: [null, '']}});
db.auth_roles.updateOne({name:'entries-upload'},
  {\$set:{name:'entries-upload', permissions:['api:entries:create'], notes:''}},
  {upsert:true});
var s = db.auth_subjects.findOne({name:'librelink'});
if (!s) {
  db.auth_subjects.insertOne({
    name:'librelink',
    roles:['careportal','devicestatus-upload','entries-upload'],
    accessToken:'librelink-${TOKEN_SUFFIX}',
    notes:'', created_at:new Date().toISOString()
  });
} else {
  db.auth_subjects.updateOne({name:'librelink'},
    {\$set:{roles:['careportal','devicestatus-upload','entries-upload']}});
}
print(db.auth_subjects.findOne({name:'librelink'}).accessToken);
" 2>/dev/null | tail -1 | tr -d '\r' > /tmp/.nstoken

TOKEN=$(cat /tmp/.nstoken); rm -f /tmp/.nstoken
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    bad "Couldn't create the token automatically."
    note "Do it by hand - see SETUP.md step 4 - then re-run this script."
    exit 1
fi
ok "Token: ${TOKEN}"

# Nightscout caches authorization at startup
docker compose up -d --force-recreate nightscout >/dev/null 2>&1
sleep 15

PERMS=$(curl -s "http://localhost:1337/api/v2/authorization/request/${TOKEN}" 2>/dev/null)
if echo "$PERMS" | grep -q 'api:entries:create'; then
    ok "Token has permission to write readings"
else
    warn "Token created but permissions didn't verify - check SETUP.md"
fi

# The bridge wants the SHA1 HASH, not the token. This trips up everyone.
TOKEN_SHA1=$(printf '%s' "$TOKEN" | sha1sum | cut -d' ' -f1)
set_env NS_API_TOKEN "$TOKEN_SHA1"
ok "Stored its SHA1 hash for the bridge"
note "(the bridge wants the hash, not the token - a common trap)"

docker compose up -d librelink >/dev/null 2>&1
sleep 20
if docker compose logs --tail=30 librelink 2>/dev/null | grep -q "succeeded"; then
    ok "Glucose data is flowing"
elif docker compose logs --tail=30 librelink 2>/dev/null | grep -q "wrong region"; then
    warn "Region wrong - check LINK_UP_REGION in .env"
else
    warn "No upload confirmed yet - check: docker compose logs -f librelink"
fi

# ---- 6. optional extras ---------------------------------------------------

head1 "6. Carb data from Glooko (optional)"
note "Only useful if your pump or pen app forwards to Glooko."
if yes_no "Set up Glooko?" n; then
    G_USER=$(ask "Glooko email" "$(get_env CONNECT_GLOOKO_EMAIL)")
    G_PASS=$(ask_secret "Glooko password")
    G_ENV=$(ask "Region (eu / default / ca)" "eu")
    set_env CONNECT_GLOOKO_EMAIL "$G_USER"
    set_env CONNECT_GLOOKO_PASSWORD "$G_PASS"
    set_env CONNECT_GLOOKO_ENV "$G_ENV"
    set_env NS_EXTRA_ENABLE ""
    say ""
    note "testing..."
    if ./glooko-carbs.py --dry-run 2>&1 | grep -q "logged in"; then
        ok "Glooko login works"
        yes_no "Import carb history now?" y && ./glooko-carbs.py | sed 's/^/  /'
    else
        warn "Glooko login failed - check the credentials in .env"
    fi
fi

head1 "7. Alerts when the feed stops (optional)"
note "Telegram message if data stops arriving. NOT a glucose alarm."
if yes_no "Set up Telegram?" n; then
    cat <<'TG'

    1. Message @BotFather on Telegram, send /newbot, follow the prompts
    2. Send your new bot any message (bots can't message you first)

TG
    TG_TOKEN=$(ask "Bot token" "$(get_env TELEGRAM_BOT_TOKEN)")
    printf '  finding your chat id...'
    TG_CHAT=$(curl -s -m 15 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" \
        | grep -o '"chat":{"id":[-0-9]*' | head -1 | grep -o '[-0-9]*$')
    echo
    if [[ -n "$TG_CHAT" ]]; then
        ok "Found chat id ${TG_CHAT}"
    else
        warn "No messages found - have you messaged the bot yet?"
        TG_CHAT=$(ask "Chat id (enter manually)")
    fi
    set_env TELEGRAM_BOT_TOKEN "$TG_TOKEN"
    set_env TELEGRAM_CHAT_ID "$TG_CHAT"
    set_env STALE_MINUTES "20"
    if ./ns-staleness.sh --test >/dev/null 2>&1; then
        ok "Test alert sent - check your phone"
    else
        warn "Couldn't send a test - check the token and chat id"
    fi
fi

head1 "8. Encrypted backups (optional)"
if yes_no "Set up nightly backups to another machine?" n; then
    if ! command -v age >/dev/null 2>&1; then
        note "installing age..."
        sudo apt-get install -qq -y age rsync
    fi
    B_TARGET=$(ask "Destination (user@host:/path/)" "$(get_env BACKUP_TARGET)")
    if [[ ! -f ~/ns-backup.key ]]; then
        age-keygen -o ~/ns-backup.key 2>/dev/null
        chmod 600 ~/ns-backup.key
        ok "Created ~/ns-backup.key"
    fi
    AGE_PUB=$(grep "public key" ~/ns-backup.key | awk '{print $NF}')
    set_env BACKUP_TARGET "$B_TARGET"
    set_env AGE_RECIPIENT "$AGE_PUB"
    set_env BACKUP_KEEP "7"
    warn "COPY ~/ns-backup.key SOMEWHERE ELSE NOW"
    note "Without it the backups are unreadable. Don't keep the only copy"
    note "on the machine it's protecting, or on the backup destination."
fi

# ---- 9. finish ------------------------------------------------------------

head1 "Done"
chmod 600 "$ENV_FILE"
say ""
ok "Display:    http://${BASE_HOST}:8080/"
ok "Nightscout: http://${BASE_HOST}:1337/   (log in with your API secret)"
say ""
say "  Next steps:"
note "  ./install-kiosk.sh        boot this machine straight to the display"
note "  systemd-units.txt         timers for backups, alerts and Glooko"
say ""
say "  ${BOLD}Remember:${OFF} your CGM app is still the alarm. This isn't."
say ""
