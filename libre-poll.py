#!/usr/bin/env python3
"""
Pull glucose readings from LibreLinkUp into Nightscout.

Why this exists
---------------
nightscout-librelink-up schedules on a cron expression, and cron's floor is one
minute. That's fine, but it means worst-case latency between a reading landing
in Abbott's cloud and appearing on the wall is a full minute. This polls on a
plain interval, so it can run every 30 seconds - or whatever you set.

To be clear about what this does and doesn't buy you: it does NOT recover
missed readings, because none are being missed. The graph endpoint returns
recent history, so a late poll still collects everything. This only reduces
how long a new reading sits unseen.

The rest of the chain - sensor to phone, phone to Abbott's cloud - is not
tunable from here and is usually the larger share of the delay.

Deduplication
-------------
Every reading is keyed on its own timestamp. Anything already posted is
skipped, so polling faster than readings arrive is harmless and safe to run
alongside the existing bridge during a changeover.

Usage
-----
    ./libre-poll.py                 # one pass
    ./libre-poll.py --dry-run       # show what it would post
    ./libre-poll.py --loop 30       # run forever, every 30 seconds
    ./libre-poll.py --backfill 12   # also post up to 12h of history

Reads LINK_UP_USERNAME / LINK_UP_PASSWORD / LINK_UP_REGION and API_SECRET
from .env alongside this file.
"""

import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = HERE / ".libre-seen.json"

# Abbott rejects stale client versions. If logins start failing with an
# unhelpful error, this is the first thing to check against the LibreLinkUp
# app's current version.
LLU_VERSION = "4.16.0"

REGIONS = {
    "EU":  "api-eu.libreview.io",
    "EU2": "api-eu2.libreview.io",
    "US":  "api-us.libreview.io",
    "AU":  "api-au.libreview.io",
    "AP":  "api-ap.libreview.io",
    "CA":  "api-ca.libreview.io",
    "DE":  "api-de.libreview.io",
    "FR":  "api-fr.libreview.io",
    "JP":  "api-jp.libreview.io",
}

MGDL_PER_MMOL = 18.018


def load_env():
    env = {}
    p = HERE / ".env"
    if not p.exists():
        sys.exit(f"No .env at {p}")
    for line in p.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


class LibreLinkUp:
    def __init__(self, env):
        region = (env.get("LINK_UP_REGION") or "EU").upper()
        self.host = REGIONS.get(region, REGIONS["EU"])
        self.user = env["LINK_UP_USERNAME"]
        self.password = env["LINK_UP_PASSWORD"]
        self.want_patient = env.get("LINK_UP_CONNECTION") or None
        self.token = None
        self.account_id = None

    def _headers(self):
        h = {
            "product": "llu.android",
            "version": LLU_VERSION,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0",
        }
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        if self.account_id:
            # Newer API versions reject requests without this. It's the SHA256
            # of the account id from the login response.
            h["Account-Id"] = self.account_id
        return h

    def _get(self, path):
        req = urllib.request.Request("https://" + self.host + path,
                                     headers=self._headers())
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.loads(r.read().decode())

    def login(self):
        body = json.dumps({"email": self.user, "password": self.password}).encode()
        req = urllib.request.Request("https://" + self.host + "/llu/auth/login",
                                     data=body, headers=self._headers())
        with urllib.request.urlopen(req, timeout=25) as r:
            d = json.loads(r.read().decode())

        # A wrong region answers with a redirect rather than an error.
        if d.get("data", {}).get("redirect"):
            hint = d["data"].get("region", "?")
            raise RuntimeError(
                f"wrong region - this account lives on '{hint.upper()}'. "
                f"Set LINK_UP_REGION in .env")

        ticket = d.get("data", {}).get("authTicket")
        if not ticket:
            raise RuntimeError("no authTicket - check the credentials, and "
                               "that the follower invitation was accepted")
        self.token = ticket["token"]
        uid = d["data"]["user"]["id"]
        self.account_id = hashlib.sha256(uid.encode()).hexdigest()

    def patient(self):
        d = self._get("/llu/connections")
        conns = d.get("data", [])
        if not conns:
            raise RuntimeError("no connections - has the follower invitation "
                               "been accepted in the LibreLinkUp app?")
        if self.want_patient:
            for c in conns:
                if c["patientId"] == self.want_patient:
                    return c
            raise RuntimeError(f"LINK_UP_CONNECTION not found among "
                               f"{[c['patientId'] for c in conns]}")
        if len(conns) > 1:
            print("  note: multiple connections; using the first. Set "
                  "LINK_UP_CONNECTION to pick one:")
            for c in conns:
                print(f"    {c['patientId']}  {c.get('firstName','?')}")
        return conns[0]

    def readings(self, patient_id):
        """Current value plus recent history, newest last."""
        d = self._get(f"/llu/connections/{patient_id}/graph")
        data = d.get("data", {})
        out = list(data.get("graphData", []))
        cur = data.get("connection", {}).get("glucoseMeasurement")
        if cur:
            out.append(cur)
        return out


TREND = {1: "SingleDown", 2: "FortyFiveDown", 3: "Flat",
         4: "FortyFiveUp", 5: "SingleUp"}


def to_entry(m, device):
    """LibreLinkUp measurement -> Nightscout entry."""
    ts = m.get("FactoryTimestamp") or m.get("Timestamp")
    if not ts:
        return None
    # FactoryTimestamp is UTC; Timestamp is local. Prefer the former.
    fmt = "%m/%d/%Y %I:%M:%S %p"
    try:
        dt = datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    mgdl = m.get("ValueInMgPerDl")
    if mgdl is None:
        val = m.get("Value")
        if val is None:
            return None
        mgdl = round(val * MGDL_PER_MMOL)
    return {
        "type": "sgv",
        "sgv": int(mgdl),
        "date": int(dt.timestamp() * 1000),
        "dateString": dt.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
        "direction": TREND.get(m.get("TrendArrow"), "NOT COMPUTABLE"),
        "device": device,
    }


def post(ns, secret_sha1, entries, dry_run):
    if dry_run:
        for e in entries:
            print(f"   would post {e['dateString']}  "
                  f"{e['sgv']/MGDL_PER_MMOL:.1f} mmol/L  {e['direction']}")
        return True
    req = urllib.request.Request(
        f"{ns}/api/v1/entries",
        data=json.dumps(entries).encode(),
        headers={"Content-Type": "application/json",
                 "API-SECRET": secret_sha1})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status in (200, 201)
    except urllib.error.HTTPError as e:
        print(f"   POST failed {e.code}: {e.read().decode()[:200]}")
        return False


def load_seen():
    if STATE.exists():
        try:
            return set(json.loads(STATE.read_text()))
        except Exception:
            pass
    return set()


def save_seen(seen):
    # Keep it bounded - a day at one reading a minute is ~1440.
    STATE.write_text(json.dumps(sorted(seen)[-4000:]))


def one_pass(env, args, llu=None):
    secret_sha1 = hashlib.sha1(env["API_SECRET"].encode()).hexdigest()
    device = env.get("LIBRE_DEVICE_NAME", "librelink-poll")

    if llu is None:
        llu = LibreLinkUp(env)
        llu.login()
        llu._patient = llu.patient()
        print(f"  connected: {llu._patient.get('firstName','?')} "
              f"({llu._patient['patientId']})")

    seen = load_seen()
    cutoff = None
    if args.backfill:
        cutoff = datetime.now(timezone.utc) - timedelta(hours=args.backfill)

    fresh = []
    for m in llu.readings(llu._patient["patientId"]):
        e = to_entry(m, device)
        if not e:
            continue
        if cutoff and datetime.fromtimestamp(e["date"] / 1000, timezone.utc) < cutoff:
            continue
        if not args.backfill and e["date"] < (time.time() - 3600) * 1000:
            continue          # by default only care about the last hour
        if e["date"] in seen:
            continue
        fresh.append(e)

    if not fresh:
        return llu, 0

    fresh.sort(key=lambda x: x["date"])
    if post(args.ns, secret_sha1, fresh, args.dry_run):
        if not args.dry_run:
            for e in fresh:
                seen.add(e["date"])
            save_seen(seen)
        newest = fresh[-1]
        age = int(time.time() - newest["date"] / 1000)
        print(f"  +{len(fresh)} reading(s), newest "
              f"{newest['sgv']/MGDL_PER_MMOL:.1f} mmol/L ({age}s old)")
        return llu, len(fresh)
    return llu, 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ns", default="http://localhost:1337")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--loop", type=int, metavar="SECONDS",
                    help="run forever at this interval")
    ap.add_argument("--backfill", type=int, metavar="HOURS",
                    help="also post history this far back")
    args = ap.parse_args()
    env = load_env()

    if not args.loop:
        one_pass(env, args)
        return

    llu = None
    fails = 0
    while True:
        try:
            llu, _ = one_pass(env, args, llu)
            fails = 0
        except Exception as e:
            fails += 1
            print(f"  error: {e}")
            llu = None                      # force a fresh login
            # Back off rather than hammering a service that's unhappy.
            time.sleep(min(300, args.loop * (2 ** min(fails, 4))))
            continue
        time.sleep(args.loop)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:300]}")
    except Exception as e:
        sys.exit(f"error: {e}")
