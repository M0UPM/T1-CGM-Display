#!/usr/bin/env bash
# Nightly encrypted backup of the Nightscout database.
#
# This is the part that actually matters. LibreView only keeps a rolling
# window and gives you nothing useful for export, so this Pi becomes the only
# complete record of her data. If the SSD dies and there's no dump, that
# history is gone - including everything her consultant will want to look
# back over in two years' time.
#
# Dumps mongo, encrypts with age, ships to the VPS, prunes old local copies.
# The VPS never sees plaintext, so the privacy posture holds even though the
# backup leaves the house.
#
# Needs: age  (sudo apt install age)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# shellcheck disable=SC1091
set -a; source .env; set +a

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
OUT="${SCRIPT_DIR}/backups"
mkdir -p "$OUT"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log() { echo "[$(date -Is)] $*"; }

if [[ -z "${AGE_RECIPIENT:-}" ]]; then
    log "ERROR: AGE_RECIPIENT not set in .env - refusing to write an unencrypted backup"
    exit 1
fi

log "dumping mongo"
docker exec ns-mongo mongodump \
    --db nightscout \
    --archive=/tmp/ns.archive \
    --gzip \
    --quiet
docker cp ns-mongo:/tmp/ns.archive "$WORK/ns.archive"
docker exec ns-mongo rm -f /tmp/ns.archive

SIZE=$(stat -c%s "$WORK/ns.archive")
log "dump ok, ${SIZE} bytes"

# Sanity check: a dump that suddenly shrinks means something is wrong -
# a wiped collection, a half-broken mongo. Better to shout than to quietly
# overwrite good backups with a bad one.
LAST_SIZE_FILE="${OUT}/.last_size"
if [[ -f "$LAST_SIZE_FILE" ]]; then
    LAST=$(cat "$LAST_SIZE_FILE")
    if (( SIZE < LAST / 2 )); then
        log "WARNING: dump is less than half the size of the previous one (${SIZE} vs ${LAST})"
        log "         keeping it, but go and look at why"
    fi
fi
echo "$SIZE" > "$LAST_SIZE_FILE"

log "encrypting"
age -r "$AGE_RECIPIENT" -o "${OUT}/nightscout-${STAMP}.archive.age" "$WORK/ns.archive"

if [[ -n "${BACKUP_TARGET:-}" ]]; then
    log "shipping to ${BACKUP_TARGET}"
    rsync -a --timeout=120 "${OUT}/nightscout-${STAMP}.archive.age" "$BACKUP_TARGET" \
        && log "shipped" \
        || log "ERROR: rsync to VPS failed - local copy retained"
fi

log "pruning local copies, keeping ${BACKUP_KEEP:-7}"
ls -1t "${OUT}"/nightscout-*.archive.age 2>/dev/null \
    | tail -n "+$(( ${BACKUP_KEEP:-7} + 1 ))" \
    | xargs -r rm -f

log "done"

# ---------------------------------------------------------------------------
# RESTORE
#
# You will be doing this while stressed and not thinking clearly, so read it
# now rather than then.
#
# You need TWO things, and neither lives on the display machine:
#   1. the private key  (ns-backup.key)
#   2. the `age` binary  (sudo apt install age - the backup host probably
#      does not have it, which is a fine thing to discover today rather than
#      on the day the SSD dies)
#
# Step 1 - decrypt. Do this first; it is the step that actually fails.
#
#   age -d -i ~/ns-backup.key -o ns.archive nightscout-TIMESTAMP.archive.age
#   ls -lh ns.archive          # sanity check the size looks right
#
# Step 2 - restore into a scratch container and check the counts before you
# touch anything live:
#
#   docker run -d --name rtest-mongo mongo:7
#   sleep 12
#   docker cp ns.archive rtest-mongo:/tmp/
#   docker exec rtest-mongo mongorestore --archive=/tmp/ns.archive --gzip
#   docker exec rtest-mongo mongosh nightscout --quiet --eval \
#     'print("entries: "+db.entries.countDocuments())'
#   docker rm -f rtest-mongo
#
# Step 3 - only once the counts look right, restore for real. --drop replaces
# the live collections, so be sure.
#
#   docker cp ns.archive ns-mongo:/tmp/ns.archive
#   docker exec ns-mongo mongorestore --archive=/tmp/ns.archive --gzip --drop
#
# An untested backup is a rumour.
# ---------------------------------------------------------------------------
