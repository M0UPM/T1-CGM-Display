#!/usr/bin/env python3
"""
Pull carb/bolus entries from Glooko into Nightscout.

Why this exists
---------------
nightscout-connect's Glooko driver queries /api/v2/pumps/normal_boluses with
startDate/endDate. That endpoint now requires lastUpdatedAt and limit instead,
so the request errors, the driver treats it as an empty result, and logs
"returning 0 treatments" while the data sits there perfectly available.

This queries the way the API actually wants and posts what it finds.

Pens vs pumps
-------------
On pens, mylife is a bolus *calculator*: it records the carb entry and its own
dose suggestion, but nothing links it to what was injected. Every record comes
back with insulinDelivered = 0 and a totalInsulinRecommendation. Both are
carried through - the recommendation into notes, so the display can show it
labelled as a suggestion rather than as a delivered dose.

Timestamps
----------
pumpTimestamp is local wall-clock time wearing a "Z" suffix. The account's real
offset comes back in the login response as utcOffset ("+01:00"), so that is
used to convert - which means it follows BST on its own rather than needing a
config value changed twice a year.

Usage
-----
    ./glooko-carbs.py            # normal run
    ./glooko-carbs.py --dry-run  # show what it would post, change nothing
    ./glooko-carbs.py --days 7   # widen the initial backfill

Reads CONNECT_GLOOKO_EMAIL / CONNECT_GLOOKO_PASSWORD / CONNECT_GLOOKO_ENV and
API_SECRET from .env alongside this file.
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = HERE / ".glooko-seen.json"

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Safari/605.1.15")

SERVERS = {
    "default": "api.glooko.com",
    "eu": "eu.api.glooko.com",
    "ca": "ca.api.glooko.com",
}


def load_env():
    env = {}
    path = HERE / ".env"
    if not path.exists():
        sys.exit(f"No .env found at {path}")
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
    return env


class Glooko:
    def __init__(self, env):
        region = env.get("CONNECT_GLOOKO_ENV", "eu")
        self.host = SERVERS.get(region, SERVERS["eu"])
        self.api = f"https://{self.host}"
        self.origin = f"https://{self.host.replace('api.', 'my.')}"
        self.email = env["CONNECT_GLOOKO_EMAIL"]
        self.password = env["CONNECT_GLOOKO_PASSWORD"]
        self.cookie = None
        self.patient = None
        self.utc_offset = timedelta(0)

    def _request(self, url, data=None, headers=None):
        h = {
            "User-Agent": UA,
            "Accept": "application/json, text/plain, */*",
            "Origin": self.origin,
            "Referer": self.origin + "/",
        }
        if self.cookie:
            h["Cookie"] = self.cookie
        if headers:
            h.update(headers)
        body = None
        if data is not None:
            body = json.dumps(data).encode()
            h["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=body, headers=h)
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode()
            setcookie = resp.headers.get("Set-Cookie")
            if setcookie:
                self.cookie = setcookie.split(";")[0]
            return json.loads(raw) if raw else {}

    def login(self):
        # deviceInformation must be minimal - a richer block gets a 422.
        payload = {
            "userLogin": {"email": self.email, "password": self.password},
            "deviceInformation": {"deviceModel": "iPhone"},
        }
        d = self._request(f"{self.api}/api/v2/users/sign_in", data=payload)
        user = d.get("userLogin", {})
        self.patient = user.get("glookoCode")
        if not self.patient:
            raise RuntimeError("no glookoCode in login response")

        # e.g. "+01:00" - follows BST without anyone editing a config file
        off = user.get("utcOffset") or "+00:00"
        sign = -1 if off.startswith("-") else 1
        hh, mm = off.lstrip("+-").split(":")
        self.utc_offset = sign * timedelta(hours=int(hh), minutes=int(mm))
        return user

    # Glooko insists on this but ignores its value. The upstream driver calls
    # it "hardcoded, random guid; no Glooko docs to explain need for param or
    # why bad data works" - which is as good an explanation as exists.
    LAST_GUID = "1e0c094e-1e54-4a4f-8e6a-f94484b53789"

    def boluses(self, since, limit=200):
        # lastUpdatedAt + limit + lastGuid, NOT startDate/endDate. This is the
        # bit the upstream driver gets wrong.
        q = urllib.parse.urlencode({
            "patient": self.patient,
            "lastUpdatedAt": since.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "limit": limit,
            "lastGuid": self.LAST_GUID,
        })
        d = self._request(f"{self.api}/api/v2/pumps/normal_boluses?{q}")
        return d.get("normalBoluses", [])


def to_utc(stamp, offset):
    """pumpTimestamp is local time labelled Z - shift it back to real UTC."""
    dt = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S.000Z").replace(
        tzinfo=timezone.utc)
    return dt - offset


def post_treatment(ns_url, secret_sha1, treatment, dry_run=False):
    if dry_run:
        print("   would post:", json.dumps(treatment))
        return True
    body = json.dumps([treatment]).encode()
    req = urllib.request.Request(
        f"{ns_url}/api/v1/treatments",
        data=body,
        headers={
            "Content-Type": "application/json",
            "API-SECRET": secret_sha1,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status in (200, 201)
    except urllib.error.HTTPError as e:
        print(f"   POST failed {e.code}: {e.read().decode()[:200]}")
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=3,
                    help="how far back to look (default 3)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--ns", default="http://localhost:1337")
    args = ap.parse_args()

    env = load_env()
    secret = env.get("API_SECRET")
    if not secret:
        sys.exit("API_SECRET missing from .env")
    secret_sha1 = hashlib.sha1(secret.encode()).hexdigest()

    seen = set()
    if STATE.exists():
        try:
            seen = set(json.loads(STATE.read_text()))
        except Exception:
            pass

    g = Glooko(env)
    user = g.login()
    print(f"logged in: {user.get('firstName')} {user.get('lastName')} "
          f"({g.patient}), utcOffset {user.get('utcOffset')}")

    since = datetime.now(timezone.utc) - timedelta(days=args.days)
    records = g.boluses(since)
    print(f"fetched {len(records)} records since {since:%Y-%m-%d %H:%M}Z")

    posted = skipped = 0
    for r in sorted(records, key=lambda x: x.get("pumpTimestamp", "")):
        guid = r.get("guid")
        carbs = r.get("carbsInput")
        insulin = r.get("insulinDelivered") or 0
        stamp = r.get("pumpTimestamp")

        # Nothing to record - no carbs and no insulin.
        if not stamp or (not carbs and not insulin):
            continue
        if guid in seen:
            skipped += 1
            continue

        when = to_utc(stamp, g.utc_offset)

        treatment = {
            "eventType": "Meal Bolus" if carbs else "Correction Bolus",
            "created_at": when.strftime("%Y-%m-%dT%H:%M:%S.000Z"),
            "enteredBy": "glooko-carbs",
        }
        if carbs:
            treatment["carbs"] = float(carbs)
        if insulin:
            treatment["insulin"] = float(insulin)

        # Keep the calculator output so the display can show it as a
        # suggestion. Never as a delivered dose.
        rec = r.get("totalInsulinRecommendation")
        if rec:
            treatment["notes"] = json.dumps({
                "totalInsulinRecommendation": rec,
                "insulinDelivered": insulin,
                "carbsInput": carbs,
                "source": "glooko-carbs",
            })

        local = when + g.utc_offset
        label = []
        if carbs:
            label.append(f"{carbs:g}g")
        if insulin:
            label.append(f"{insulin:g}u")
        if rec:
            label.append(f"(suggested {rec:g}u)")
        print(f" + {local:%d %b %H:%M} local  {' '.join(label)}")

        if post_treatment(args.ns, secret_sha1, treatment, args.dry_run):
            posted += 1
            seen.add(guid)

    if not args.dry_run:
        # Keep the state file from growing without bound.
        STATE.write_text(json.dumps(sorted(seen)[-2000:]))

    print(f"posted {posted}, already had {skipped}")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode()[:300]}")
    except Exception as e:
        sys.exit(f"error: {e}")
