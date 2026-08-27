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
    if rsync -a --timeout=120 "${OUT}/nightscout-${STAMP}.archive.age" "$BACKUP_TARGET"; then
        log "shipped"
        SHIPPED=1
    else
        log "ERROR: rsync to backup host failed - local copy retained"
        SHIPPED=0
    fi
fi

# ---- prune the remote --------------------------------------------------
# rsync only ever adds, so without this the backup host grows forever. Each
# dump is a full snapshot, so they get bigger as the database does.
#
# Only prunes if tonight's upload actually succeeded. Deleting old backups
# because a new one failed to arrive is exactly the wrong move.
if [[ -n "${BACKUP_TARGET:-}" && "${SHIPPED:-0}" == "1" ]]; then
    REMOTE_HOST="${BACKUP_TARGET%%:*}"
    REMOTE_PATH="${BACKUP_TARGET#*:}"
    KEEP_DAILY="${REMOTE_KEEP_DAILY:-7}"
    KEEP_WEEKLY="${REMOTE_KEEP_WEEKLY:-0}"

    log "pruning ${REMOTE_HOST}, keeping ${KEEP_DAILY} daily${KEEP_WEEKLY:+ + $KEEP_WEEKLY weekly}"

    # Runs on the backup host. Keeps the newest N, and optionally one per
    # ISO week beyond that as protection against corruption you don't spot
    # for a while - seven dailies are no help if all seven are bad.
    ssh -o BatchMode=yes -o ConnectTimeout=20 "$REMOTE_HOST" \
        "KEEP_DAILY='$KEEP_DAILY' KEEP_WEEKLY='$KEEP_WEEKLY' bash -s" <<REMOTE || \
            log "WARNING: remote prune failed - old backups left in place"
set -euo pipefail
KEEP_DAILY="\${KEEP_DAILY:-7}"
KEEP_WEEKLY="\${KEEP_WEEKLY:-0}"
cd "$REMOTE_PATH" 2>/dev/null || exit 0
shopt -s nullglob
ALL=(\$(ls -1 nightscout-*.archive.age 2>/dev/null | sort -r))
[[ \${#ALL[@]} -eq 0 ]] && exit 0

declare -A KEEP
# newest N unconditionally
for ((i=0; i<KEEP_DAILY && i<\${#ALL[@]}; i++)); do KEEP["\${ALL[i]}"]=1; done

# one per ISO week for the older ones
if (( KEEP_WEEKLY > 0 )); then
    declare -A WEEK_SEEN
    kept_weeks=0
    for f in "\${ALL[@]}"; do
        [[ -n "\${KEEP[\$f]:-}" ]] && continue
        stamp="\${f#nightscout-}"; stamp="\${stamp%%.*}"
        d="\${stamp:0:4}-\${stamp:4:2}-\${stamp:6:2}"
        wk=\$(date -d "\$d" +%G-W%V 2>/dev/null) || continue
        if [[ -z "\${WEEK_SEEN[\$wk]:-}" ]]; then
            WEEK_SEEN[\$wk]=1
            KEEP["\$f"]=1
            kept_weeks=\$((kept_weeks+1))
            (( kept_weeks >= KEEP_WEEKLY )) && break
        fi
    done
fi

removed=0
for f in "\${ALL[@]}"; do
    if [[ -z "\${KEEP[\$f]:-}" ]]; then
        rm -f -- "\$f" && removed=\$((removed+1))
    fi
done
echo "remote: \${#ALL[@]} present, \$removed removed, \$(( \${#ALL[@]} - removed )) kept"
REMOTE
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
